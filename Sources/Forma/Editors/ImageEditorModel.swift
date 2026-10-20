import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FormaCore
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One geometric step, applied in order after cropping.
enum GeometryOp: Equatable {
    case rotateCW, rotateCCW, flipH, flipV

    /// Forward mapping of a normalized (y-down) canvas point.
    func apply(_ p: CGPoint) -> CGPoint {
        switch self {
        case .rotateCW: CGPoint(x: 1 - p.y, y: p.x)
        case .rotateCCW: CGPoint(x: p.y, y: 1 - p.x)
        case .flipH: CGPoint(x: 1 - p.x, y: p.y)
        case .flipV: CGPoint(x: p.x, y: 1 - p.y)
        }
    }

    var inverse: GeometryOp {
        switch self {
        case .rotateCW: .rotateCCW
        case .rotateCCW: .rotateCW
        case .flipH: .flipH
        case .flipV: .flipV
        }
    }

    var swapsAxes: Bool { self == .rotateCW || self == .rotateCCW }
}

struct RGBA: Equatable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? .black
        r = s.redComponent; g = s.greenComponent; b = s.blueComponent; a = s.alphaComponent
    }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Markup drawn over the image. Points are normalized to the current canvas (y-down);
/// sizes are fractions of the source image's longest side so they survive crops.
struct ImageAnnotation: Identifiable, Equatable {
    enum Kind: Equatable { case rectangle, ellipse, arrow, pen, text, highlight }
    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var color: RGBA
    var lineWidth: CGFloat
    var fontSize: CGFloat

    func mapped(_ f: (CGPoint) -> CGPoint) -> ImageAnnotation {
        var a = self
        a.start = f(start)
        a.end = f(end)
        a.points = points.map(f)
        if kind == .text || kind == .rectangle || kind == .ellipse || kind == .highlight {
            // Keep boxes axis-aligned after rotation/flip.
            let r = CGRect(p1: a.start, p2: a.end)
            if kind == .text { a.start = f(start); a.end = a.start } else { a.start = r.origin; a.end = CGPoint(x: r.maxX, y: r.maxY) }
        }
        return a
    }

    func bounds(padding: CGFloat = 0.01) -> CGRect {
        let pts = points.isEmpty ? [start, end] : points
        let xs = pts.map(\.x), ys = pts.map(\.y)
        var r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        if kind == .text { r.size = CGSize(width: max(0.05, fontSize * CGFloat(max(text.count, 1)) * 0.6), height: fontSize * 1.4) }
        return r.insetBy(dx: -padding, dy: -padding)
    }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}

/// The complete, non-destructive edit state. Undo snapshots this value.
struct ImageEdits: Equatable {
    var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1) // normalized in the oriented source, y-down
    var geometry: [GeometryOp] = []
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var sharpness: Double = 0
    var annotations: [ImageAnnotation] = []
    /// Output pixel size; nil keeps the cropped size.
    var resize: CGSize?

    var hasAdjustments: Bool { exposure != 0 || brightness != 0 || contrast != 1 || saturation != 1 || sharpness != 0 }
}

@MainActor
@Observable
final class ImageEditorModel: EditorDocument {
    enum Tool: Equatable { case none, crop, select, rectangle, ellipse, arrow, pen, text, highlight }

    private(set) var url: URL
    let format: FileFormat
    private let full: CIImage
    private let previewBase: CIImage
    let sourceSize: CGSize
    private let sourceProperties: [CFString: Any]
    private let colorSpace: CGColorSpace

    var edits = ImageEdits() { didSet { schedulePreview() } }
    private var savedEdits = ImageEdits()
    private(set) var preview: CGImage?
    var tool: Tool = .none
    var color = RGBA(.systemRed)
    var lineWidth: CGFloat = 0.006
    var fontSize: CGFloat = 0.04
    var selectedAnnotation: UUID?
    var showAdjustments = false
    var exportQuality: Double = 0.9
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let cropBridge = CropBridge()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    var isDirty: Bool { edits != savedEdits }
    var canExportPDF: Bool { true }

    init(url: URL) throws {
        guard let detected = FileTypeDetector().format(of: url), detected.category == .image,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw FormaError.corrupted(url.lastPathComponent)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw FormaError.corrupted(url.lastPathComponent)
        }
        self.url = url
        self.format = detected
        self.sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        self.full = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        self.sourceSize = full.extent.size
        self.colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let longest = max(sourceSize.width, sourceSize.height)
        let scale = min(1, 2200 / longest)
        self.previewBase = scale < 1 ? full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : full
        schedulePreview(immediate: true)
    }

    var sourceLongest: CGFloat { max(sourceSize.width, sourceSize.height) }

    /// Pixel size of the edited image (before any resize).
    var canvasPixelSize: CGSize {
        var s = CGSize(width: sourceSize.width * edits.crop.width, height: sourceSize.height * edits.crop.height)
        for op in edits.geometry where op.swapsAxes { s = CGSize(width: s.height, height: s.width) }
        return CGSize(width: s.width.rounded(), height: s.height.rounded())
    }

    var outputPixelSize: CGSize { edits.resize ?? canvasPixelSize }

    // MARK: Editing with undo

    func commit(_ name: String, _ change: (inout ImageEdits) -> Void) {
        let before = edits
        var after = edits
        change(&after)
        guard after != before else { return }
        edits = after
        registerUndo(name: name, restoring: before)
    }

    private func registerUndo(name: String, restoring state: ImageEdits) {
        guard let undoManager else { return }
        let current = edits
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.edits = state
                target.registerUndo(name: name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    /// For sliders: change live, then register a single undo step when the drag ends.
    private var sliderStart: ImageEdits?
    func beginSlider() { if sliderStart == nil { sliderStart = edits } }
    func endSlider(_ name: String) {
        if let start = sliderStart, start != edits { registerUndo(name: name, restoring: start) }
        sliderStart = nil
    }

    func rotate(clockwise: Bool) {
        let op: GeometryOp = clockwise ? .rotateCW : .rotateCCW
        commit("Rotate") { e in
            e.geometry.append(op)
            e.annotations = e.annotations.map { $0.mapped(op.apply) }
            if let r = e.resize { e.resize = CGSize(width: r.height, height: r.width) }
        }
    }

    func flip(horizontal: Bool) {
        let op: GeometryOp = horizontal ? .flipH : .flipV
        commit("Flip") { e in
            e.geometry.append(op)
            e.annotations = e.annotations.map { $0.mapped(op.apply) }
        }
    }

    /// Applies a crop drawn on the current canvas (normalized, y-down).
    func applyCrop(_ view: CGRect) {
        let v = view.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard v.width > 0.005, v.height > 0.005 else { return }
        // Undo the geometry so the rectangle is expressed in cropped-source space.
        var corners = [CGPoint(x: v.minX, y: v.minY), CGPoint(x: v.maxX, y: v.maxY)]
        for op in edits.geometry.reversed() { corners = corners.map(op.inverse.apply) }
        let r = CGRect(p1: corners[0], p2: corners[1])
        commit("Crop") { e in
            let c = e.crop
            e.crop = CGRect(x: c.minX + r.minX * c.width, y: c.minY + r.minY * c.height, width: r.width * c.width, height: r.height * c.height)
            e.annotations = e.annotations.map { $0.mapped { p in CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height) } }
            e.resize = nil
        }
        tool = .none
    }

    func addAnnotation(_ a: ImageAnnotation) {
        commit("Add Markup") { $0.annotations.append(a) }
        selectedAnnotation = a.id
    }

    func updateAnnotation(_ a: ImageAnnotation, name: String = "Move Markup") {
        commit(name) { e in
            if let i = e.annotations.firstIndex(where: { $0.id == a.id }) { e.annotations[i] = a }
        }
    }

    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotation else { return }
        commit("Delete Markup") { $0.annotations.removeAll { $0.id == id } }
        selectedAnnotation = nil
    }

    func resetAdjustments() {
        commit("Reset Adjustments") { e in
            e.exposure = 0; e.brightness = 0; e.contrast = 1; e.saturation = 1; e.sharpness = 0
        }
    }

    func revertAll() { commit("Revert") { $0 = ImageEdits() } }

    // MARK: Rendering

    private func schedulePreview(immediate: Bool = false) {
        renderTask?.cancel()
        let edits = self.edits
        let base = previewBase
        let size = sourceSize
        renderTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(12)) }
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderPixels(base: base, sourceSize: size, edits: edits, includeResize: false)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview = image
        }
    }

    /// Core Image pipeline: crop → geometry → adjustments → (resize). Annotations are drawn separately.
    nonisolated static func pipeline(base: CIImage, sourceSize: CGSize, edits: ImageEdits, includeResize: Bool) -> CIImage {
        var img = base
        let W = base.extent.width, H = base.extent.height
        let c = edits.crop
        let rect = CGRect(x: c.minX * W, y: (1 - c.maxY) * H, width: c.width * W, height: c.height * H).integral
        img = img.cropped(to: rect)
        func normalize(_ i: CIImage) -> CIImage { i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY)) }
        img = normalize(img)
        for op in edits.geometry {
            switch op {
            case .rotateCW: img = normalize(img.oriented(.right))
            case .rotateCCW: img = normalize(img.oriented(.left))
            case .flipH: img = normalize(img.oriented(.upMirrored))
            case .flipV: img = normalize(img.oriented(.downMirrored))
            }
        }
        if edits.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(edits.exposure)
            img = f.outputImage ?? img
        }
        if edits.brightness != 0 || edits.contrast != 1 || edits.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = Float(edits.brightness)
            f.contrast = Float(edits.contrast)
            f.saturation = Float(edits.saturation)
            img = f.outputImage ?? img
        }
        if edits.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(edits.sharpness)
            f.radius = 1.6
            img = (f.outputImage ?? img).cropped(to: img.extent)
        }
        if includeResize, let target = edits.resize, img.extent.width > 0, img.extent.height > 0 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img
            f.scale = Float(target.height / img.extent.height)
            f.aspectRatio = Float((target.width / img.extent.width) / (target.height / img.extent.height))
            img = normalize(f.outputImage ?? img)
        }
        return img
    }

    nonisolated static func renderPixels(base: CIImage, sourceSize: CGSize, edits: ImageEdits, includeResize: Bool, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let img = pipeline(base: base, sourceSize: sourceSize, edits: edits, includeResize: includeResize)
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: space)
    }

    /// Full-resolution render with annotations baked in.
    func renderFinal() -> CGImage? {
        guard let pixels = Self.renderPixels(base: full, sourceSize: sourceSize, edits: edits, includeResize: true,
                                             colorSpace: colorSpace.model == .rgb ? colorSpace : nil) else { return nil }
        if edits.annotations.isEmpty { return pixels }
        let w = pixels.width, h = pixels.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: pixels.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return pixels }
        ctx.draw(pixels, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Annotation sizes are relative to the source; scale by how much the output was resized.
        let resizeScale = CGFloat(w) / max(canvasPixelSize.width, 1)
        AnnotationRenderer.draw(edits.annotations, in: ctx, canvas: CGSize(width: w, height: h), unit: sourceLongest * resizeScale, flipped: false)
        return ctx.makeImage()
    }

    // MARK: Saving

    func save() throws {
        let target = FileFormat.from(extension: url.pathExtension) ?? format
        let writable = target.imageIOIdentifier != nil ? target : .png
        try write(to: url, format: writable, quality: exportQuality, atomic: true)
        savedEdits = edits
    }

    func write(to destination: URL, format out: FileFormat, quality: Double, atomic: Bool) throws {
        guard let image = renderFinal(), let type = out.imageIOIdentifier else { throw FormaError.encodeFailed(out) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw FormaError.encodeFailed(out) }
        var props = sourceProperties
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        props[kCGImagePropertyOrientation] = 1 // orientation is baked into the pixels
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if out.isLossyByNature { props[kCGImageDestinationLossyCompressionQuality] = quality }
        var final = image
        if !out.supportsTransparency, let flat = try? flatten(image) { final = flat }
        CGImageDestinationAddImage(dest, final, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(out) }
        try SavePanel.atomicWrite(data as Data, to: destination)
    }

    private func flatten(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    func saveCopy(in window: NSWindow?) {
        let formats = ImageConversionProvider.encodableOutputs().filter { [.png, .jpeg, .heic, .tiff, .avif].contains($0) }
        let accessory = ExportAccessory(formats: formats, selected: formats.contains(format) ? format : .png, quality: exportQuality)
        guard let dest = SavePanel.run(suggestedName: SavePanel.editedName(for: url, ext: accessory.selected.preferredExtension),
                                       types: formats, in: window, accessory: accessory.view, directory: url.deletingLastPathComponent()) else { return }
        let fmt = FileFormat.from(extension: dest.pathExtension) ?? accessory.selected
        do {
            try write(to: dest, format: fmt.imageIOIdentifier != nil ? fmt : .png, quality: accessory.quality, atomic: true)
            savedEdits = edits
            url = dest
            window?.title = dest.lastPathComponent
            window?.representedURL = dest
        } catch {
            NSAlert(error: FormaError.wrap(error) as NSError).runModal()
        }
    }

    func exportPDF(in window: NSWindow?) {
        guard let dest = SavePanel.run(suggestedName: url.deletingPathExtension().lastPathComponent + ".pdf", types: [.pdf], in: window, directory: url.deletingLastPathComponent()),
              let image = renderFinal() else { return }
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / 144, height: CGFloat(image.height) * 72 / 144)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

/// Format + quality controls attached to the Save a Copy panel.
@MainActor
final class ExportAccessory: NSObject {
    let formats: [FileFormat]
    var selected: FileFormat
    var quality: Double
    let view: NSView
    private let popup = NSPopUpButton()
    private let slider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1, target: nil, action: nil)

    init(formats: [FileFormat], selected: FileFormat, quality: Double) {
        self.formats = formats
        self.selected = selected
        self.quality = quality
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popup.addItems(withTitles: formats.map(\.displayName))
        popup.selectItem(at: formats.firstIndex(of: selected) ?? 0)
        popup.target = self
        popup.action = #selector(changed)
        slider.doubleValue = quality
        slider.target = self
        slider.action = #selector(changed)
        slider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(NSTextField(labelWithString: "Format:"))
        stack.addArrangedSubview(popup)
        stack.addArrangedSubview(NSTextField(labelWithString: "Quality:"))
        stack.addArrangedSubview(slider)
        changed()
    }

    @objc private func changed() {
        selected = formats[max(0, popup.indexOfSelectedItem)]
        quality = slider.doubleValue
        slider.isEnabled = selected.isLossyByNature
        if let panel = view.window as? NSSavePanel {
            panel.allowedContentTypes = [selected.utType]
        }
    }
}
