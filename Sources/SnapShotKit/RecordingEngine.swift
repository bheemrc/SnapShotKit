import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Screen recorder that captures the main display (or a region of it) via
/// ScreenCaptureKit and writes an H.264 `.mp4` to a temporary file, plus a
/// helper that renders a GIF from the recorded movie.
///
/// Like the rest of the capture pipeline, recording requires the Screen
/// Recording TCC permission, which the OS keys on the app's bundle identifier
/// and code signature. Run from the real `.app` bundle produced by
/// `make-app.sh`, not the bare SwiftPM binary, or the OS denies the stream
/// (typically surfacing as `SCStreamError` code `-3801`, `userDeclined`).
///
/// Concurrency: this object is `@MainActor`-isolated and owns the public
/// state. The frame data path is deliberately kept off the main actor — a
/// separate, non-isolated `StreamSink` receives `CMSampleBuffer`s on a private
/// serial queue and feeds the `AVAssetWriter` there, so the high-frequency
/// callback never touches main-actor state.
@MainActor
final class RecordingEngine: ObservableObject {

    /// Shared instance used by the app's recording controls.
    static let shared = RecordingEngine()

    /// `true` between a successful `start(region:)` and the following `stop()`.
    @Published private(set) var isRecording: Bool = false

    /// Errors surfaced by the recording pipeline with user-facing descriptions.
    enum RecordingError: LocalizedError {
        case alreadyRecording
        case permissionDenied
        case noDisplay
        case writerSetupFailed
        case streamStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .permissionDenied:
                return "Screen Recording permission is required. Grant it in "
                    + "System Settings ▸ Privacy & Security ▸ Screen Recording, "
                    + "then relaunch SnapShotKit."
            case .noDisplay:
                return "No display was found to record."
            case .writerSetupFailed:
                return "Could not set up the movie writer for recording."
            case .streamStartFailed(let underlying):
                return "Could not start the screen recording: "
                    + underlying.localizedDescription
            }
        }
    }

    // MARK: - Live recording state

    /// The active capture stream while recording; `nil` otherwise.
    private var stream: SCStream?

    /// The output delegate that bridges sample buffers into the writer. Held
    /// strongly because `SCStream` keeps only a weak reference to its outputs.
    private var sink: StreamSink?

    /// Destination of the in-progress recording.
    private var outputURL: URL?

    private init() {}

    // MARK: - Start

    /// Begins recording.
    ///
    /// - Parameter region: When `nil`, records the full main display. Otherwise
    ///   `region` is interpreted as a rectangle in global screen points with a
    ///   bottom-left origin (exactly as produced by the region-selection
    ///   overlay), mapped onto the display containing its center.
    ///
    /// Throws `RecordingError.permissionDenied` if Screen Recording access is
    /// not granted, or another `RecordingError` on setup failure. Calling
    /// `start` while already recording throws `.alreadyRecording`.
    func start(region: CGRect?) async throws {
        guard !isRecording, stream == nil else {
            throw RecordingError.alreadyRecording
        }

        // 1. Enumerate shareable content. The first call triggers the TCC
        //    Screen Recording prompt; failure here usually means denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw RecordingError.permissionDenied
        }

        // 2. Resolve the target display and (for region recording) the local
        //    source rectangle in the display's top-left-origin point space.
        let target = try await resolveTarget(region: region, content: content)
        let display = target.display
        let scale = await Self.backingScale(forDisplayID: display.displayID)

        // 3. Build the stream configuration. Pixel dimensions are the source
        //    size scaled by the backing factor (rounded to even numbers, which
        //    H.264 4:2:0 requires for chroma subsampling).
        let pointSize = target.sourceRect?.size
            ?? CGSize(width: display.width, height: display.height)
        let pixelWidth = Self.evenDimension(pointSize.width * CGFloat(scale))
        let pixelHeight = Self.evenDimension(pointSize.height * CGFloat(scale))

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        // Cap the capture rate at ~30 fps; ScreenCaptureKit only delivers a new
        // frame when the screen content changes, so static regions cost nothing.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        if let sourceRect = target.sourceRect {
            config.sourceRect = sourceRect
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 4. Prepare the writer-backed sink, then the stream.
        let url = Self.makeTempMovieURL()
        let sink: StreamSink
        do {
            sink = try StreamSink(url: url,
                                  width: pixelWidth,
                                  height: pixelHeight)
        } catch {
            throw RecordingError.writerSetupFailed
        }

        let stream = SCStream(filter: filter,
                              configuration: config,
                              delegate: sink)
        do {
            try stream.addStreamOutput(sink,
                                       type: .screen,
                                       sampleHandlerQueue: sink.sampleQueue)
        } catch {
            throw RecordingError.writerSetupFailed
        }

        // 5. Start capture. A denial here is reported as permission denied.
        do {
            try await stream.startCapture()
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw RecordingError.permissionDenied
        } catch {
            throw RecordingError.streamStartFailed(error)
        }

        // 6. Commit live state only after a successful start.
        self.stream = stream
        self.sink = sink
        self.outputURL = url
        self.isRecording = true
    }

    // MARK: - Stop

    /// Stops the active recording, finalizes the movie file, and returns the
    /// `.mp4` URL. Returns `nil` if nothing was recording or finalization
    /// failed. Safe to call when not recording.
    @discardableResult
    func stop() async -> URL? {
        guard isRecording, let stream, let sink else {
            // Idempotent: tolerate a stop with no active recording.
            isRecording = false
            return nil
        }

        // Flip state first so the UI updates and a concurrent stop is a no-op.
        isRecording = false
        self.stream = nil
        self.sink = nil
        let url = outputURL
        self.outputURL = nil

        // Stop the stream before finalizing so no further buffers arrive.
        try? await stream.stopCapture()

        // Drain and finalize the writer off the main actor.
        let finalized = await sink.finish()
        return finalized ? url : nil
    }

    // MARK: - Target resolution

    /// The display to record together with an optional local source rectangle.
    private struct Target {
        let display: SCDisplay
        /// Region rect in the display's local, top-left-origin point space, or
        /// `nil` for a full-display recording.
        let sourceRect: CGRect?
    }

    /// Resolves the recording target from the requested region.
    private func resolveTarget(region: CGRect?,
                               content: SCShareableContent) async throws -> Target {
        guard let region else {
            // Full main display, falling back to the first available one.
            guard let display = content.displays.first(where: {
                $0.displayID == CGMainDisplayID()
            }) ?? content.displays.first else {
                throw RecordingError.noDisplay
            }
            return Target(display: display, sourceRect: nil)
        }

        // Region: map onto the display owning the region's center, then convert
        // the global bottom-left rect into that display's local top-left space.
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let screen = await Self.screen(containing: center) else {
            throw RecordingError.noDisplay
        }
        guard let display = content.displays.first(where: {
            $0.displayID == screen.displayID
        }) else {
            throw RecordingError.noDisplay
        }

        let screenFrame = screen.frame
        let localRect = CGRect(
            x: region.minX - screenFrame.minX,
            y: screenFrame.maxY - region.maxY,
            width: region.width,
            height: region.height
        ).standardized
        return Target(display: display, sourceRect: localRect)
    }

    // MARK: - Display helpers

    /// Locates the display containing `point` (global points, bottom-left
    /// origin), returning its display ID and frame. Falls back to the main
    /// screen. Returns a `Sendable` tuple rather than the non-`Sendable`
    /// `NSScreen` so it can cross the actor boundary.
    private static func screen(containing point: CGPoint) async
        -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        await MainActor.run {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let screen = NSScreen.screens.first(where: {
                $0.frame.contains(point)
            }) ?? NSScreen.main,
                  let displayID = screen.deviceDescription[key] as? CGDirectDisplayID
            else { return nil }
            return (displayID, screen.frame)
        }
    }

    /// Resolves the integer backing scale factor for a display ID, defaulting to
    /// 2.0 when it cannot be matched. Does not assume Retina.
    private static func backingScale(forDisplayID displayID: CGDirectDisplayID) async -> Int {
        await MainActor.run {
            let matched = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID) == displayID
            }
            let factor = matched?.backingScaleFactor ?? 2.0
            return max(1, Int(factor.rounded()))
        }
    }

    /// Rounds a floating-point dimension to the nearest positive even integer,
    /// as required by H.264 4:2:0 chroma subsampling.
    private static func evenDimension(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded % 2 == 0 ? rounded : rounded + 1
    }

    /// A unique temporary `.mp4` URL.
    private static func makeTempMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShotKit-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    // MARK: - GIF export

    /// Renders an animated GIF from a recorded movie.
    ///
    /// Samples `movieURL` at `fps` frames per second using
    /// `AVAssetImageGenerator`, scales each frame down to at most `maxWidth`
    /// points wide (preserving aspect ratio), and writes the result to
    /// `gifURL` with a per-frame delay of `1 / fps`.
    ///
    /// - Returns: `true` on success, `false` if the asset has no video or
    ///   encoding fails. Runs entirely off the main actor.
    static func exportGIF(from movieURL: URL,
                          to gifURL: URL,
                          fps: Double = 12,
                          maxWidth: CGFloat = 800) async -> Bool {
        let frameRate = max(1.0, fps)
        let asset = AVURLAsset(url: movieURL)

        // Resolve duration and a video track; bail if there is no video.
        let duration: CMTime
        let hasVideo: Bool
        do {
            duration = try await asset.load(.duration)
            hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        } catch {
            return false
        }
        guard hasVideo, duration.isValid, duration.seconds > 0 else {
            return false
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Constrain the rendered size so the GIF stays small; the generator
        // preserves aspect ratio when only the width is bounded.
        generator.maximumSize = CGSize(width: maxWidth, height: 0)

        // Build the sample times: one frame every 1/fps seconds.
        let total = duration.seconds
        let step = 1.0 / frameRate
        var times: [NSValue] = []
        var t = 0.0
        while t < total {
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
            t += step
        }
        guard !times.isEmpty else { return false }

        // Collect CGImages in order. Skip any individual frame that fails so a
        // single bad sample doesn't abort the whole export.
        var frames: [CGImage] = []
        frames.reserveCapacity(times.count)
        for value in times {
            do {
                let image = try await generateImage(generator, at: value.timeValue)
                frames.append(image)
            } catch {
                continue
            }
        }
        guard !frames.isEmpty else { return false }

        return GIFEncoder.write(frames: frames,
                                frameDelay: 1.0 / frameRate,
                                to: gifURL)
    }

    /// `async` bridge over the completion-based `AVAssetImageGenerator` API.
    private static func generateImage(_ generator: AVAssetImageGenerator,
                                      at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                if let image, result == .succeeded {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error
                        ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }
}

// MARK: - Stream sink

/// Non-isolated bridge between `SCStream`'s sample callbacks and the
/// `AVAssetWriter`. All writer access happens on `sampleQueue`, the same serial
/// queue ScreenCaptureKit uses to deliver `.screen` buffers, so no additional
/// locking is required. This type intentionally holds no main-actor state.
private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Serial queue that owns all writer mutations and receives sample buffers.
    let sampleQueue = DispatchQueue(label: "com.snapshotkit.recording.samples")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    /// Set once the session has been started at the first frame's timestamp.
    private var started = false

    /// Set when finalization has begun, so late buffers are dropped.
    private var finishing = false

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitRate(width: width, height: height),
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let sourcePixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelAttributes
        )

        guard writer.canAdd(input) else {
            throw RecordingEngine.RecordingError.writerSetupFailed
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RecordingEngine.RecordingError.writerSetupFailed
        }

        super.init()
    }

    /// Heuristic average bitrate (~0.18 bits/pixel at 30 fps), clamped to a
    /// sane range so small regions and full 5K displays both stay reasonable.
    private static func bitRate(width: Int, height: Int) -> Int {
        let pixels = Double(width * height)
        let estimate = pixels * 30.0 * 0.18
        return Int(min(max(estimate, 2_000_000), 60_000_000))
    }

    // MARK: SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, !finishing else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // Only append frames flagged complete & displayed by ScreenCaptureKit;
        // skip idle/blank status frames that carry no fresh pixels.
        guard isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if !started {
            writer.startSession(atSourceTime: pts)
            started = true
        }

        guard input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    /// Reads ScreenCaptureKit's per-frame status attachment, returning `true`
    /// only for `.complete` frames (those carrying new, displayable content).
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            // No status attachment: treat as a usable frame rather than drop it.
            return true
        }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The stream stopped unexpectedly (e.g. display disconnect). Mark
        // finishing so no further buffers are appended; finalization is driven
        // by `RecordingEngine.stop()`.
        sampleQueue.async { [weak self] in
            self?.finishing = true
        }
    }

    // MARK: Finalization

    /// Marks the input finished and finalizes the writer. Returns `true` if the
    /// movie was written successfully. Safe to call exactly once per sink.
    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [self] in
                finishing = true
                guard started, writer.status == .writing else {
                    // Nothing was ever written (or the writer already failed).
                    writer.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed)
                }
            }
        }
    }
}
