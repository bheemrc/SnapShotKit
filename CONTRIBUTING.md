# Contributing to SnapShotKit

Thanks for your interest in improving SnapShotKit! This is a native macOS
SwiftUI app for capturing, annotating, and exporting screenshots. Contributions
of all sizes are welcome.

## Building

SnapShotKit is a Swift Package executable. You need macOS 14+ and a recent
Xcode toolchain (Swift 6).

```sh
# Compile and run the package
swift build

# Build a runnable .app bundle
bash make-app.sh
```

Before opening a pull request, please run a release build to make sure
everything compiles cleanly with optimizations on:

```sh
swift build -c release
```

## Code Style

- **Swift 6 with strict concurrency.** Code must build under the strict
  concurrency checking the package enables. Annotate `@MainActor` where UI state
  is touched and avoid data races.
- **No external dependencies.** SnapShotKit uses Apple frameworks only
  (SwiftUI, AppKit, ScreenCaptureKit, PDFKit, Vision, CoreImage,
  UniformTypeIdentifiers, Carbon.HIToolbox). Please do not add SwiftPM packages.
- **Coordinate conventions.** Annotations are stored in **image pixel
  coordinates** with a **top-left origin and y pointing down** (matching SwiftUI
  `Canvas` and `DragGesture`). On-screen drawing in `AnnotationCanvas` uses the
  same top-left / y-down space with no flip.
- **The flatten path owns the y-flip.** `PDFExporter.flatten(_:)` is the single
  place that converts to AppKit's bottom-left / y-up space. It is the one source
  of truth used by PDF export, clipboard copy, PNG save, OCR, and background
  rendering. When you add a new annotation kind, you only need to render it in
  two places: `AnnotationCanvas` (on-screen) and `PDFExporter.flatten`
  (export). Do not introduce additional y-flips elsewhere.
- Keep comments professional and focused on the engineering intent.

## Submitting Issues

When filing an issue, please include:

- Your macOS version and Xcode/Swift toolchain version.
- Steps to reproduce, and what you expected versus what happened.
- A screenshot or sample export when the problem is visual.

## Submitting Pull Requests

1. Fork the repository and create a topic branch for your change.
2. Keep pull requests focused; one logical change per PR is easiest to review.
3. Make sure `swift build -c release` succeeds before submitting.
4. Describe what changed and why, and reference any related issue.

We appreciate every contribution. Thanks for helping make SnapShotKit better!
