import SwiftUI
import AppKit

// MARK: - Pixel sizing helper

/// True pixel dimensions of an NSImage. `NSImage.size` is in points and does not
/// match the bitmap on Retina or for many loaded files, so we read the largest
/// bitmap representation's `pixelsWide`/`pixelsHigh`. Annotations are stored in
/// these IMAGE PIXEL coordinates so window resizing never corrupts saved data and
/// the export path needs no scale factor.
@MainActor
func imagePixelSize(_ image: NSImage) -> CGSize {
    var best = CGSize.zero
    for rep in image.representations {
        let w = CGFloat(rep.pixelsWide)
        let h = CGFloat(rep.pixelsHigh)
        if w * h > best.width * best.height {
            best = CGSize(width: w, height: h)
        }
    }
    if best.width > 0 && best.height > 0 { return best }
    // Fallback to point size scaled by the main screen backing factor.
    let scale = NSScreen.main?.backingScaleFactor ?? 1
    return CGSize(width: image.size.width * scale, height: image.size.height * scale)
}

// MARK: - Fit math (scaledToFit), top-left / y-down to match SwiftUI & DragGesture

/// Describes how a pixel-sized image is letterboxed inside a view via `scaledToFit`.
/// SwiftUI's Canvas and DragGesture are both top-left, y-down and agree with each
/// other, so NO y-flip happens here. The flip lives only in the export/flatten path.
private struct FitTransform {
    var scale: CGFloat   // pixels -> points
    var offset: CGPoint  // letterbox origin of the image inside the view (points)
    var pxSize: CGSize   // image size in pixels

    init(viewSize: CGSize, pxSize: CGSize) {
        self.pxSize = pxSize
        guard pxSize.width > 0, pxSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            scale = 1; offset = .zero; return
        }
        let s = min(viewSize.width / pxSize.width, viewSize.height / pxSize.height)
        scale = s
        let drawnW = pxSize.width * s
        let drawnH = pxSize.height * s
        offset = CGPoint(x: (viewSize.width - drawnW) / 2,
                         y: (viewSize.height - drawnH) / 2)
    }

    /// View point (gesture) -> image pixel coordinate.
    func viewToImage(_ p: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: (p.x - offset.x) / scale,
                       y: (p.y - offset.y) / scale)
    }

    /// Image pixel coordinate -> view point (for on-screen drawing).
    func imageToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x,
                y: p.y * scale + offset.y)
    }
}

// MARK: - AnnotationCanvas

struct AnnotationCanvas: View {
    @Binding var item: CaptureItem

    @State private var currentKind: AnnotationKind = .arrow
    @State private var draftStart: CGPoint? = nil   // image pixels
    @State private var draftEnd: CGPoint? = nil     // image pixels
    @State private var draftPoints: [CGPoint] = []  // image pixels, freehand pen
    @State private var selectedAnnotationID: Annotation.ID? = nil
    @State private var currentColorHex: String = "#FF3B30"
    @State private var currentLineWidth: CGFloat = 4

    // Undo/redo snapshots of the full annotation array. Canvas is recreated per
    // capture via `.id(...)`, so this per-item history resets naturally.
    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []

    init(item: Binding<CaptureItem>) {
        self._item = item
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            GeometryReader { geo in
                let px = imagePixelSize(item.image)
                let fit = FitTransform(viewSize: geo.size, pxSize: px)
                ZStack {
                    Image(nsImage: item.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)

                    Canvas { ctx, _ in
                        for ann in item.annotations {
                            drawAnnotation(ann, in: &ctx, fit: fit,
                                           selected: ann.id == selectedAnnotationID)
                        }
                        if currentKind == .pen, draftPoints.count > 1 {
                            var draft = Annotation(kind: .pen,
                                                   start: draftPoints.first ?? .zero,
                                                   end: draftPoints.last ?? .zero,
                                                   text: "", colorHex: currentColorHex)
                            draft.points = draftPoints
                            draft.lineWidth = currentLineWidth
                            drawAnnotation(draft, in: &ctx, fit: fit, selected: false)
                        } else if let s = draftStart, let e = draftEnd {
                            var draft = Annotation(kind: currentKind, start: s, end: e,
                                                   text: "", colorHex: currentColorHex)
                            draft.lineWidth = currentLineWidth
                            drawAnnotation(draft, in: &ctx, fit: fit, selected: false)
                        }
                    }
                    .gesture(dragGesture(fit: fit))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            textEditorBar
        }
        .padding(8)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(AnnotationKind.allCases) { kind in
                        Button {
                            currentKind = kind
                        } label: {
                            Image(systemName: kind.systemImageName)
                                .frame(width: 26, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(currentKind == kind
                                      ? Color.accentColor.opacity(0.25)
                                      : Color.clear)
                        )
                        .foregroundColor(currentKind == kind ? .accentColor : .primary)
                        .help(kind.displayName)
                    }
                }
                .padding(.horizontal, 2)
            }

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)

            // Stroke thickness applied to newly created annotations.
            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                Slider(value: $currentLineWidth, in: 1...20)
                    .frame(width: 90)
            }
            .help("Line thickness")

            Spacer()

            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty)
            .keyboardShortcut("z", modifiers: [.command])

            Button {
                redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(redoStack.isEmpty)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedAnnotationID == nil)
        }
    }

    private var textEditorBar: some View {
        HStack {
            Image(systemName: "textformat")
            TextField("Selected annotation text", text: selectedTextBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(selectedAnnotationID == nil)
        }
        .opacity(selectedAnnotationID == nil ? 0.5 : 1)
    }

    private func label(for kind: AnnotationKind) -> String {
        kind.displayName
    }

    // MARK: Bindings

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: currentColorHex) },
            set: { newValue in currentColorHex = hexString(from: newValue) }
        )
    }

    private var selectedTextBinding: Binding<String> {
        Binding(
            get: {
                guard let id = selectedAnnotationID,
                      let ann = item.annotations.first(where: { $0.id == id })
                else { return "" }
                return ann.text
            },
            set: { newValue in
                guard let id = selectedAnnotationID,
                      let idx = item.annotations.firstIndex(where: { $0.id == id })
                else { return }
                item.annotations[idx].text = newValue
            }
        )
    }

    // MARK: Gesture

    private func dragGesture(fit: FitTransform) -> some Gesture {
        // minimumDistance 0 so a click (text placement / zero-length) still fires onChanged.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let s = clamp(fit.viewToImage(value.startLocation), to: fit.pxSize)
                let e = clamp(fit.viewToImage(value.location), to: fit.pxSize)
                if currentKind == .pen {
                    // Accumulate the freehand path as the pointer moves.
                    if draftPoints.isEmpty { draftPoints.append(s) }
                    draftPoints.append(e)
                } else {
                    draftStart = s
                    draftEnd = e
                }
            }
            .onEnded { value in
                let s = clamp(fit.viewToImage(value.startLocation), to: fit.pxSize)
                let e = clamp(fit.viewToImage(value.location), to: fit.pxSize)

                if currentKind == .pen {
                    let path = draftPoints
                    draftPoints = []
                    draftStart = nil
                    draftEnd = nil
                    guard path.count > 1 else {
                        selectedAnnotationID = hitTest(e)
                        return
                    }
                    pushUndo()
                    var ann = Annotation(kind: .pen,
                                         start: path.first ?? s,
                                         end: path.last ?? e,
                                         text: "", colorHex: currentColorHex)
                    ann.points = path
                    ann.lineWidth = currentLineWidth
                    item.annotations.append(ann)
                    selectedAnnotationID = ann.id
                    return
                }

                draftStart = nil
                draftEnd = nil

                if currentKind == .text {
                    // Click to place a text annotation; tap an existing one to select it.
                    if let hit = hitTest(e) {
                        selectedAnnotationID = hit
                    } else {
                        pushUndo()
                        var ann = Annotation(kind: .text, start: e,
                                             end: CGPoint(x: e.x + 160, y: e.y + 40),
                                             text: "Text", colorHex: currentColorHex)
                        ann.text = "Text"
                        ann.lineWidth = currentLineWidth
                        item.annotations.append(ann)
                        selectedAnnotationID = ann.id
                    }
                    return
                }

                if currentKind == .step {
                    // Single click drops a numbered badge at the point.
                    pushUndo()
                    let next = item.annotations.filter { $0.kind == .step }.count + 1
                    var ann = Annotation(kind: .step, start: e, end: e,
                                         text: "", colorHex: currentColorHex)
                    ann.number = next
                    ann.lineWidth = currentLineWidth
                    item.annotations.append(ann)
                    selectedAnnotationID = ann.id
                    return
                }

                // Treat a near-zero drag as a selection click rather than a shape.
                if hypot(e.x - s.x, e.y - s.y) < 4 {
                    selectedAnnotationID = hitTest(e)
                    return
                }

                pushUndo()
                var ann = Annotation(kind: currentKind, start: s, end: e,
                                     text: "", colorHex: currentColorHex)
                ann.lineWidth = currentLineWidth
                item.annotations.append(ann)
                selectedAnnotationID = ann.id
            }
    }

    // MARK: Undo / redo

    /// Snapshot the current annotation array before a mutation.
    private func pushUndo() {
        undoStack.append(item.annotations)
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(item.annotations)
        item.annotations = previous
        selectedAnnotationID = nil
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(item.annotations)
        item.annotations = next
        selectedAnnotationID = nil
    }

    private func clamp(_ p: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width),
                y: min(max(0, p.y), size.height))
    }

    private func hitTest(_ p: CGPoint) -> Annotation.ID? {
        // Reverse order so the topmost annotation wins.
        for ann in item.annotations.reversed() {
            let r = CGRect(x: min(ann.start.x, ann.end.x),
                           y: min(ann.start.y, ann.end.y),
                           width: abs(ann.end.x - ann.start.x),
                           height: abs(ann.end.y - ann.start.y))
                .insetBy(dx: -12, dy: -12)
            if r.contains(p) { return ann.id }
        }
        return nil
    }

    private func deleteSelected() {
        guard let id = selectedAnnotationID else { return }
        pushUndo()
        item.annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
    }

    // MARK: On-screen drawing (top-left / y-down, NO flip)

    private func drawAnnotation(_ ann: Annotation, in ctx: inout GraphicsContext,
                                fit: FitTransform, selected: Bool) {
        let color = Color(hex: ann.colorHex)
        let s = fit.imageToView(ann.start)
        let e = fit.imageToView(ann.end)
        // Multiply stroke weight by fit.scale so the preview visually matches export.
        // Honor a per-annotation override (stored in image pixels) when present.
        let baseWidth = ann.lineWidth ?? 4
        let lineWidth = max(1, baseWidth * fit.scale)

        switch ann.kind {
        case .arrow:
            var line = Path()
            line.move(to: s)
            line.addLine(to: e)
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Arrowhead in SCREEN space (top-left). The flipped recompute is export-only.
            let ang = atan2(e.y - s.y, e.x - s.x)
            let wing = CGFloat.pi / 7
            let head = max(8, 14 * fit.scale)
            var headPath = Path()
            for d in [ang + .pi - wing, ang + .pi + wing] {
                headPath.move(to: e)
                headPath.addLine(to: CGPoint(x: e.x + head * cos(d),
                                             y: e.y + head * sin(d)))
            }
            ctx.stroke(headPath, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        case .rectangle:
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                              width: abs(e.x - s.x), height: abs(e.y - s.y))
            ctx.stroke(Path(rect), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth))

        case .line:
            var line = Path()
            line.move(to: s)
            line.addLine(to: e)
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        case .ellipse:
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                              width: abs(e.x - s.x), height: abs(e.y - s.y))
            ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth))

        case .pen:
            var path = Path()
            let pts = ann.points.map { fit.imageToView($0) }
            if let first = pts.first {
                path.move(to: first)
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth,
                                          lineCap: .round, lineJoin: .round))

        case .blur:
            // Canvas cannot sample the underlying image, so show a redacted
            // placeholder; the real pixelation is applied in the export path.
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                              width: abs(e.x - s.x), height: abs(e.y - s.y))
            let shape = Path(roundedRect: rect, cornerRadius: 4)
            ctx.fill(shape, with: .color(Color(white: 0.5, opacity: 0.55)))
            // Subtle diagonal hatch to read as "redacted".
            var hatch = Path()
            let step = max(6, 10 * fit.scale)
            var x = rect.minX - rect.height
            while x < rect.maxX {
                hatch.move(to: CGPoint(x: x, y: rect.maxY))
                hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += step
            }
            ctx.clip(to: shape)
            ctx.stroke(hatch, with: .color(Color(white: 0.3, opacity: 0.45)),
                       style: StrokeStyle(lineWidth: 1))

        case .step:
            let radius = max(10, 16 * fit.scale)
            let center = s
            let circle = Path(ellipseIn: CGRect(x: center.x - radius,
                                                y: center.y - radius,
                                                width: radius * 2,
                                                height: radius * 2))
            ctx.fill(circle, with: .color(color))
            let fontSize = max(9, radius * 1.1)
            let resolved = ctx.resolve(
                Text("\(ann.number ?? 1)")
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            )
            ctx.draw(resolved, at: center, anchor: .center)

        case .highlight:
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                              width: abs(e.x - s.x), height: abs(e.y - s.y))
            ctx.fill(Path(rect), with: .color(color.opacity(0.30)))

        case .text:
            let fontSize = max(10, 22 * fit.scale)
            let resolved = ctx.resolve(
                Text(ann.text.isEmpty ? "Text" : ann.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(color)
            )
            // Text origin is top-left in SwiftUI; draw at the start anchor.
            ctx.draw(resolved, at: s, anchor: .topLeading)
        }

        if selected {
            // Map the annotation's image-space bounds into view space so pen and
            // step selections are framed correctly too.
            let b = ann.boundingRect
            let origin = fit.imageToView(b.origin)
            var rect = CGRect(x: origin.x, y: origin.y,
                              width: b.width * fit.scale, height: b.height * fit.scale)
            if rect.width < 1 && rect.height < 1 {
                rect = CGRect(x: origin.x - 18, y: origin.y - 18, width: 36, height: 36)
            }
            rect = rect.insetBy(dx: -4, dy: -4)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                       with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: Color <-> hex (mirror of Color(hex:) in AnnotationModels)

    private func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemRed
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
