import AppKit
import Foundation

/// Exports `CaptureItem`s as a PowerPoint (`.pptx`) presentation — one slide per
/// capture, at full pixel resolution.
///
/// A `.pptx` file is an Office Open XML package: a ZIP archive of XML parts plus
/// the embedded media. This exporter assembles a minimal-but-valid package in a
/// temporary directory (content types, relationships, presentation, a slide
/// master / layout / theme, and one slide per image) and then zips it to the
/// destination URL with the system `zip` tool.
///
/// Each capture is flattened (base image + annotations) at full pixel resolution
/// via `PDFExporter.flatten`. Every slide is sized so that the image fills it
/// exactly 1:1: PowerPoint measures in EMUs (English Metric Units), where one
/// inch is 914,400 EMUs and screen content is conventionally 96 px per inch, so
/// `emu = pixels / 96 * 914400`.
@MainActor
enum PPTXExporter {

    enum ExportError: LocalizedError {
        case noItems
        case writeFailed
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .noItems:
                return "There are no captures to export."
            case .writeFailed:
                return "Failed to write the presentation package."
            case .zipFailed:
                return "Failed to compress the presentation package."
            }
        }
    }

    /// Number of EMUs (English Metric Units) per inch, per the OOXML spec.
    private static let emuPerInch: Double = 914_400
    /// Conventional pixels-per-inch used to map screen pixels onto slide EMUs.
    private static let pixelsPerInch: Double = 96

    /// Pixel dimensions translated into slide EMUs.
    private struct SlideSize {
        let widthEMU: Int
        let heightEMU: Int
    }

    // MARK: - Public API

    /// Exports the given items as a `.pptx` presentation written to `url`.
    ///
    /// One slide is generated per item; each slide is sized to its image so the
    /// picture fills it 1:1. The package is built in a temporary directory and
    /// zipped into place. Throws `ExportError` on any failure.
    static func export(_ items: [CaptureItem], to url: URL) throws {
        guard !items.isEmpty else { throw ExportError.noItems }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("SnapShotKit-pptx-\(UUID().uuidString)", isDirectory: true)

        defer { try? fileManager.removeItem(at: workDir) }

        do {
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Encode every image up front so we know the slide dimensions before
            // writing the presentation part.
            var slideSizes: [SlideSize] = []
            slideSizes.reserveCapacity(items.count)

            let mediaDir = workDir.appendingPathComponent("ppt/media", isDirectory: true)
            try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)

            for (index, item) in items.enumerated() {
                let flattened = PDFExporter.flatten(item)
                guard let pngData = pngData(for: flattened) else {
                    throw ExportError.writeFailed
                }
                let imageURL = mediaDir.appendingPathComponent("image\(index + 1).png")
                try pngData.write(to: imageURL)

                let pixels = flattened.pixelSize
                slideSizes.append(slideSize(forPixelWidth: pixels.width,
                                            pixelHeight: pixels.height))
            }

            try writePackage(items: items, slideSizes: slideSizes, into: workDir)
            try zipPackage(at: workDir, to: url)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed
        }
    }

    // MARK: - Image encoding

    /// PNG-encodes a flattened image at full pixel resolution.
    private static func pngData(for image: NSImage) -> Data? {
        if let data = ExportService.pngData(image) {
            return data
        }
        // Fallback: rebuild a bitmap from the image's CGImage.
        let size = image.pixelSize
        var rect = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Geometry

    private static func slideSize(forPixelWidth width: CGFloat, pixelHeight height: CGFloat) -> SlideSize {
        let safeWidth = max(1, Double(width))
        let safeHeight = max(1, Double(height))
        let widthEMU = Int((safeWidth / pixelsPerInch * emuPerInch).rounded())
        let heightEMU = Int((safeHeight / pixelsPerInch * emuPerInch).rounded())
        return SlideSize(widthEMU: max(1, widthEMU), heightEMU: max(1, heightEMU))
    }

    // MARK: - Package assembly

    private static func writePackage(items: [CaptureItem],
                                     slideSizes: [SlideSize],
                                     into workDir: URL) throws {
        let fileManager = FileManager.default
        let count = items.count

        // Directory layout.
        try fileManager.createDirectory(at: workDir.appendingPathComponent("_rels"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDir.appendingPathComponent("ppt/_rels"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDir.appendingPathComponent("ppt/slides/_rels"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDir.appendingPathComponent("ppt/slideMasters/_rels"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDir.appendingPathComponent("ppt/slideLayouts/_rels"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDir.appendingPathComponent("ppt/theme"),
                                        withIntermediateDirectories: true)

        // The presentation's declared slide size uses the largest image so no
        // slide's content is clipped by the canvas; each individual slide also
        // declares its own size further below.
        let maxSize = slideSizes.reduce(SlideSize(widthEMU: 1, heightEMU: 1)) { acc, next in
            SlideSize(widthEMU: max(acc.widthEMU, next.widthEMU),
                      heightEMU: max(acc.heightEMU, next.heightEMU))
        }

        try write(contentTypes(slideCount: count),
                  to: workDir.appendingPathComponent("[Content_Types].xml"))
        try write(rootRels(),
                  to: workDir.appendingPathComponent("_rels/.rels"))
        try write(presentation(slideCount: count, size: maxSize),
                  to: workDir.appendingPathComponent("ppt/presentation.xml"))
        try write(presentationRels(slideCount: count),
                  to: workDir.appendingPathComponent("ppt/_rels/presentation.xml.rels"))
        try write(slideMaster(),
                  to: workDir.appendingPathComponent("ppt/slideMasters/slideMaster1.xml"))
        try write(slideMasterRels(),
                  to: workDir.appendingPathComponent("ppt/slideMasters/_rels/slideMaster1.xml.rels"))
        try write(slideLayout(),
                  to: workDir.appendingPathComponent("ppt/slideLayouts/slideLayout1.xml"))
        try write(slideLayoutRels(),
                  to: workDir.appendingPathComponent("ppt/slideLayouts/_rels/slideLayout1.xml.rels"))
        try write(theme(),
                  to: workDir.appendingPathComponent("ppt/theme/theme1.xml"))

        for index in 0..<count {
            let number = index + 1
            try write(slide(size: slideSizes[index], imageNumber: number),
                      to: workDir.appendingPathComponent("ppt/slides/slide\(number).xml"))
            try write(slideRels(imageNumber: number),
                      to: workDir.appendingPathComponent("ppt/slides/_rels/slide\(number).xml.rels"))
        }
    }

    private static func write(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw ExportError.writeFailed
        }
        try data.write(to: url)
    }

    // MARK: - Zip packaging

    private static func zipPackage(at workDir: URL, to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        // Zip from inside the package directory so the archive contains relative
        // paths (e.g. "ppt/presentation.xml"), as required by OOXML consumers.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-r", "-X", "-q", url.path, "."]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw ExportError.zipFailed
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: url.path) else {
            throw ExportError.zipFailed
        }
    }

    // MARK: - XML parts

    private static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    private static func contentTypes(slideCount: Int) -> String {
        var slideOverrides = ""
        for index in 1...slideCount {
            slideOverrides += """
            <Override PartName="/ppt/slides/slide\(index).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
            """
        }
        return """
        \(xmlHeader)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(slideOverrides)</Types>
        """
    }

    private static func rootRels() -> String {
        """
        \(xmlHeader)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """
    }

    private static func presentation(slideCount: Int, size: SlideSize) -> String {
        // Slide relationship ids: rId1 = slide master, rId2.. = slides,
        // and the theme follows after the slides (see presentationRels).
        var slideIdList = ""
        for index in 1...slideCount {
            // Slide ids must be >= 256 per the schema.
            slideIdList += """
            <p:sldId id="\(255 + index)" r:id="rId\(index + 1)"/>
            """
        }
        return """
        \(xmlHeader)
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(slideIdList)</p:sldIdLst>
        <p:sldSz cx="\(size.widthEMU)" cy="\(size.heightEMU)"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    private static func presentationRels(slideCount: Int) -> String {
        var relationships = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        """
        for index in 1...slideCount {
            relationships += """
            <Relationship Id="rId\(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\(index).xml"/>
            """
        }
        // Theme relationship id follows the slides.
        let themeId = slideCount + 2
        relationships += """
        <Relationship Id="rId\(themeId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        """
        return """
        \(xmlHeader)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships)</Relationships>
        """
    }

    private static func slideMaster() -> String {
        """
        \(xmlHeader)
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        <p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree>
        </p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """
    }

    private static func slideMasterRels() -> String {
        """
        \(xmlHeader)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
    }

    private static func slideLayout() -> String {
        """
        \(xmlHeader)
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
        <p:cSld name="Blank">
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private static func slideLayoutRels() -> String {
        """
        \(xmlHeader)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
    }

    private static func slide(size: SlideSize, imageNumber: Int) -> String {
        """
        \(xmlHeader)
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        <p:pic>
        <p:nvPicPr>
        <p:cNvPr id="2" name="Capture \(imageNumber)"/>
        <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr>
        <p:nvPr/>
        </p:nvPicPr>
        <p:blipFill>
        <a:blip r:embed="rId1"/>
        <a:stretch><a:fillRect/></a:stretch>
        </p:blipFill>
        <p:spPr>
        <a:xfrm><a:off x="0" y="0"/><a:ext cx="\(size.widthEMU)" cy="\(size.heightEMU)"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        </p:spPr>
        </p:pic>
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func slideRels(imageNumber: Int) -> String {
        """
        \(xmlHeader)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(imageNumber).png"/>
        </Relationships>
        """
    }

    private static func theme() -> String {
        """
        \(xmlHeader)
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
        <a:themeElements>
        <a:clrScheme name="Office">
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="44546A"/></a:dk2>
        <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
        <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
        <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
        <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
        <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
        <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
        <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Office">
        <a:majorFont>
        <a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/>
        </a:majorFont>
        <a:minorFont>
        <a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/>
        </a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="Office">
        <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:fillStyleLst>
        <a:lnStyleLst>
        <a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        </a:lnStyleLst>
        <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        </a:effectStyleLst>
        <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }
}
