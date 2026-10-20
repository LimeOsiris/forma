import AppKit
import SwiftUI

/// Draws markup identically on screen and in exported files.
enum AnnotationRenderer {
    /// - Parameters:
    ///   - canvas: drawing size in the context's units (pixels for export, points on screen).
    ///   - unit: how many context units one "source longest side" spans; sizes are fractions of it.
    ///   - flipped: true if the context is already y-down.
    @MainActor
    static func draw(_ annotations: [ImageAnnotation], in ctx: CGContext, canvas: CGSize, unit: CGFloat, flipped: Bool, origin: CGPoint = .zero) {
        ctx.saveGState()
        if !flipped {
            ctx.translateBy(x: 0, y: canvas.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.translateBy(x: origin.x, y: origin.y)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for a in annotations { drawOne(a, ctx: ctx, canvas: canvas, unit: unit) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    @MainActor
    private static func drawOne(_ a: ImageAnnotation, ctx: CGContext, canvas: CGSize, unit: CGFloat) {
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * canvas.width, y: p.y * canvas.height) }
        let lw = max(1, a.lineWidth * unit)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let rect = CGRect(p1: pt(a.start), p2: pt(a.end))
        switch a.kind {
        case .rectangle:
            ctx.stroke(rect.insetBy(dx: lw / 2, dy: lw / 2))
        case .ellipse:
            ctx.strokeEllipse(in: rect.insetBy(dx: lw / 2, dy: lw / 2))
        case .highlight:
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.cgColor.copy(alpha: 0.4) ?? a.color.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        case .arrow:
            let s = pt(a.start), e = pt(a.end)
            let angle = atan2(e.y - s.y, e.x - s.x)
            let head = max(lw * 4, 10)
            let shaftEnd = CGPoint(x: e.x - cos(angle) * head * 0.6, y: e.y - sin(angle) * head * 0.6)
            ctx.move(to: s)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.move(to: e)
            ctx.addLine(to: CGPoint(x: e.x - cos(angle - .pi / 7) * head, y: e.y - sin(angle - .pi / 7) * head))
            ctx.addLine(to: CGPoint(x: e.x - cos(angle + .pi / 7) * head, y: e.y - sin(angle + .pi / 7) * head))
            ctx.closePath()
            ctx.fillPath()
        case .pen:
            guard let first = a.points.first else { return }
            ctx.move(to: pt(first))
            for p in a.points.dropFirst() { ctx.addLine(to: pt(p)) }
            ctx.strokePath()
        case .text:
            let font = NSFont.systemFont(ofSize: max(6, a.fontSize * unit), weight: .semibold)
            let attr = NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: a.color.nsColor])
            attr.draw(at: pt(a.start))
        }
    }
}

/// The interactive canvas: shows the preview, draws markup and the crop frame, and turns
/// mouse gestures into edits for the current tool.
struct ImageCanvas: NSViewRepresentable {
    let model: ImageEditorModel

    func makeNSView(context: Context) -> ImageCanvasNSView {
        let v = ImageCanvasNSView()
        v.model = model
        model.cropBridge.apply = { [weak v] in v?.applyCrop() }
        model.cropBridge.setAspect = { [weak v] ratio in
            v?.cropAspect = ratio
            v?.needsDisplay = true
        }
        return v
    }

    func updateNSView(_ v: ImageCanvasNSView, context: Context) {
        v.model = model
        // Touch observed properties so SwiftUI redraws us when they change.
        _ = model.preview
        _ = model.edits
        _ = model.tool
        _ = model.selectedAnnotation
        if model.tool != .crop { v.cropRect = nil }
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}

@MainActor
final class ImageCanvasNSView: NSView, NSTextFieldDelegate {
    weak var model: ImageEditorModel?
    var cropRect: CGRect?           // normalized, y-down
    var cropAspect: CGFloat?        // width / height in pixels
    private var draft: ImageAnnotation?
    private var dragStart: CGPoint?
    private var dragOriginal: ImageAnnotation?
    private var cropHandle: Int?    // 0-3 corners, 4 = move, 5 = new
    private var textField: NSTextField?
    private var textAnchor: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Where the image sits inside the view (aspect-fit with padding).
    var imageRect: CGRect {
        guard let model else { return .zero }
        let size = model.canvasPixelSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let avail = bounds.insetBy(dx: 28, dy: 28)
        let scale = min(avail.width / size.width, avail.height / size.height, 4)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h).integral
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / max(r.width, 1), y: (p.y - r.minY) / max(r.height, 1))
    }

    private func viewPoint(_ n: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        // Checkerboard shows transparency.
        ctx.saveGState()
        ctx.clip(to: r)
        let tile: CGFloat = 8
        NSColor.white.setFill(); ctx.fill(r)
        NSColor(white: 0.9, alpha: 1).setFill()
        var y = r.minY
        var row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : tile)
            while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: tile, height: tile)); x += tile * 2 }
            y += tile; row += 1
        }
        if let image = model.preview {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: r)
            ctx.restoreGState()
        }
        let unit = model.sourceLongest * (r.width / max(model.canvasPixelSize.width, 1))
        var annotations = model.edits.annotations
        if let draft { annotations.append(draft) }
        AnnotationRenderer.draw(annotations, in: ctx, canvas: r.size, unit: unit, flipped: true, origin: r.origin)
        ctx.restoreGState()

        // Hairline border around the image.
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()

        if let id = model.selectedAnnotation, let a = model.edits.annotations.first(where: { $0.id == id }), model.tool == .select {
            let b = a.bounds()
            let vr = CGRect(p1: viewPoint(b.origin), p2: viewPoint(CGPoint(x: b.maxX, y: b.maxY)))
            let path = NSBezierPath(roundedRect: vr, xRadius: 3, yRadius: 3)
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if model.tool == .crop {
            let crop = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let vr = CGRect(p1: viewPoint(crop.origin), p2: viewPoint(CGPoint(x: crop.maxX, y: crop.maxY)))
            // Dim outside the crop.
            let outside = NSBezierPath(rect: r)
            outside.append(NSBezierPath(rect: vr).reversed)
            NSColor.black.withAlphaComponent(0.45).setFill()
            outside.fill()
            NSColor.white.setStroke()
            let frame = NSBezierPath(rect: vr)
            frame.lineWidth = 1.5
            frame.stroke()
            // Rule of thirds.
            NSColor.white.withAlphaComponent(0.4).setStroke()
            for i in 1...2 {
                let fx = vr.minX + vr.width * CGFloat(i) / 3, fy = vr.minY + vr.height * CGFloat(i) / 3
                NSBezierPath.strokeLine(from: CGPoint(x: fx, y: vr.minY), to: CGPoint(x: fx, y: vr.maxY))
                NSBezierPath.strokeLine(from: CGPoint(x: vr.minX, y: fy), to: CGPoint(x: vr.maxX, y: fy))
            }
            NSColor.white.setFill()
            for c in corners(vr) { NSBezierPath(roundedRect: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10), xRadius: 2, yRadius: 2).fill() }
        }
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    override func resetCursorRects() {
        guard let model else { return }
        switch model.tool {
        case .none, .select: addCursorRect(imageRect, cursor: .arrow)
        case .text: addCursorRect(imageRect, cursor: .iBeam)
        default: addCursorRect(imageRect, cursor: .crosshair)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        commitText()
        let p = convert(event.locationInWindow, from: nil)
        let n = normalized(p)
        dragStart = n
        switch model.tool {
        case .crop:
            let crop = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let vr = CGRect(p1: viewPoint(crop.origin), p2: viewPoint(CGPoint(x: crop.maxX, y: crop.maxY)))
            if let i = corners(vr).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 12 }) { cropHandle = i }
            else if vr.contains(p) { cropHandle = 4 }
            else { cropHandle = 5; cropRect = CGRect(origin: n, size: .zero) }
            dragOriginal = nil
        case .select, .none:
            let hit = model.edits.annotations.last { $0.bounds(padding: 0.015).contains(n) }
            model.selectedAnnotation = hit?.id
            dragOriginal = hit
            if hit != nil && model.tool == .none { model.tool = .select }
        case .text:
            beginText(at: n, viewPoint: p)
        case .rectangle, .ellipse, .arrow, .highlight, .pen:
            let kind: ImageAnnotation.Kind = switch model.tool {
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .arrow: .arrow
            case .highlight: .highlight
            default: .pen
            }
            draft = ImageAnnotation(kind: kind, start: n, end: n, points: kind == .pen ? [n] : [],
                                    color: kind == .highlight ? RGBA(.systemYellow) : model.color, lineWidth: model.lineWidth, fontSize: model.fontSize)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let start = dragStart else { return }
        var n = normalized(convert(event.locationInWindow, from: nil))
        n = CGPoint(x: min(max(n.x, 0), 1), y: min(max(n.y, 0), 1))
        switch model.tool {
        case .crop:
            updateCrop(to: n, from: start)
        case .select:
            guard let original = dragOriginal else { return }
            let dx = n.x - start.x, dy = n.y - start.y
            var moved = original.mapped { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            moved.id = original.id
            if let i = model.edits.annotations.firstIndex(where: { $0.id == original.id }) {
                // Live move without undo spam; the undo step is registered on mouse up.
                var e = model.edits
                e.annotations[i] = moved
                model.edits = e
            }
        default:
            guard var d = draft else { return }
            if d.kind == .pen { d.points.append(n) }
            if event.modifierFlags.contains(.shift), d.kind == .rectangle || d.kind == .ellipse {
                let side = max(abs(n.x - d.start.x), abs(n.y - d.start.y))
                n = CGPoint(x: d.start.x + side * (n.x >= d.start.x ? 1 : -1), y: d.start.y + side * (n.y >= d.start.y ? 1 : -1))
            }
            d.end = n
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        defer { dragStart = nil; needsDisplay = true }
        switch model.tool {
        case .crop:
            if let c = cropRect, c.width < 0.01 || c.height < 0.01 { cropRect = nil }
            cropHandle = nil
        case .select:
            if let original = dragOriginal, let now = model.edits.annotations.first(where: { $0.id == original.id }), now != original {
                // Re-register as one undoable move.
                var e = model.edits
                if let i = e.annotations.firstIndex(where: { $0.id == original.id }) { e.annotations[i] = original }
                model.edits = e
                model.updateAnnotation(now)
            }
            dragOriginal = nil
        default:
            if let d = draft {
                let b = d.bounds(padding: 0)
                if d.kind == .pen ? d.points.count > 1 : (b.width > 0.004 || b.height > 0.004) {
                    model.addAnnotation(d)
                }
            }
            draft = nil
        }
    }

    private func updateCrop(to n: CGPoint, from start: CGPoint) {
        guard var c = cropRect ?? Optional(CGRect(x: 0, y: 0, width: 1, height: 1)) else { return }
        switch cropHandle {
        case 4:
            let base = cropRect ?? c
            c = base.offsetBy(dx: n.x - start.x, dy: n.y - start.y)
            c.origin.x = min(max(c.origin.x, 0), 1 - c.width)
            c.origin.y = min(max(c.origin.y, 0), 1 - c.height)
            dragStart = n
        case 5:
            c = CGRect(p1: start, p2: n)
        case let i?:
            let opposite = corners(c)[(i + 2) % 4]
            c = CGRect(p1: opposite, p2: n)
        default:
            break
        }
        if let aspect = cropAspect, let model {
            // Constrain in pixel space.
            let px = model.canvasPixelSize
            let wpx = c.width * px.width
            let hpx = wpx / aspect
            c.size.height = min(hpx / px.height, 1 - c.minY)
        }
        cropRect = c
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: model.deleteSelectedAnnotation()       // delete / forward delete
        case 36 where model.tool == .crop, 76 where model.tool == .crop: applyCrop() // return / enter
        case 53:                                             // escape
            if model.tool == .crop { cropRect = nil; model.tool = .none } else { model.selectedAnnotation = nil; model.tool = .none }
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    func applyCrop() {
        guard let model, let c = cropRect else { return }
        model.applyCrop(c)
        cropRect = nil
    }

    // MARK: Text entry

    private func beginText(at n: CGPoint, viewPoint p: CGPoint) {
        guard let model else { return }
        let unit = model.sourceLongest * (imageRect.width / max(model.canvasPixelSize.width, 1))
        let size = max(10, model.fontSize * unit)
        let field = NSTextField(frame: CGRect(x: p.x, y: p.y, width: 240, height: size * 1.5))
        field.font = .systemFont(ofSize: size, weight: .semibold)
        field.textColor = model.color.nsColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Text"
        field.delegate = self
        field.target = self
        field.action = #selector(textCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textAnchor = n
    }

    @objc private func textCommitted() { commitText() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField, let anchor = textAnchor, let model else { return }
        textField = nil
        textAnchor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        model.addAnnotation(ImageAnnotation(kind: .text, start: anchor, end: anchor, text: text, color: model.color, lineWidth: model.lineWidth, fontSize: model.fontSize))
    }
}
