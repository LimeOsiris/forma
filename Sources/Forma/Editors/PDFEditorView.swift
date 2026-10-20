import AppKit
import FormaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFEditorView: View {
    @Bindable var model: PDFEditorModel
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(title: model.url.lastPathComponent, badge: .annotationOnly) { toolbar }
            HStack(spacing: 0) {
                PageSidebar(model: model)
                    .frame(width: 150)
                Divider()
                PDFKitView(model: model)
                    .accessibilityLabel("PDF pages")
            }
        }
        .sheet(isPresented: $model.showSignaturePad) { SignaturePad(model: model) }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(PDFEditorModel.Tool.allCases) { tool in
                ToolButton(symbol: tool.symbol, help: tool.label, active: model.tool == tool) {
                    if tool == .signature && model.signature == nil { model.showSignaturePad = true }
                    model.tool = tool
                }
            }
            Menu {
                ForEach(Array(ColorMenu.palette.enumerated()), id: \.offset) { _, c in
                    Button { model.color = RGBA(c) } label: {
                        Label(c.accessibilityName.capitalized, systemImage: RGBA(c) == model.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                Divider()
                Picker("Line", selection: $model.lineWidth) {
                    Text("Thin").tag(CGFloat(1))
                    Text("Medium").tag(CGFloat(2))
                    Text("Thick").tag(CGFloat(4))
                }
                Divider()
                Button("New Signature…") { model.showSignaturePad = true }
            } label: {
                Circle().fill(Color(nsColor: model.color.nsColor)).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            .help("Markup color and line").accessibilityLabel("Markup color and line")
        }
        Divider().frame(height: 20)
        HStack(spacing: 2) {
            ToolButton(symbol: "rotate.left", help: "Rotate Page Left") { model.rotatePage(model.selectedPage, by: -90) }
            ToolButton(symbol: "rotate.right", help: "Rotate Page Right") { model.rotatePage(model.selectedPage, by: 90) }
            ToolButton(symbol: "trash", help: "Delete Page", disabled: model.pageCount < 2) { model.deletePage(model.selectedPage) }
            ToolButton(symbol: "doc.badge.plus", help: "Insert Pages from File…") { insertPages() }
        }
        Divider().frame(height: 20)
        Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .popover(isPresented: $showInfo) {
                Text("Forma edits PDF pages and adds annotations — highlights, notes, text boxes, shapes, drawings and signatures. It can't rewrite the original text of a PDF.")
                    .font(.system(size: 12)).frame(width: 260).padding(14)
            }
            .help("About PDF editing")
        SaveMenu(isDirty: model.isDirty)
    }

    private func insertPages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose PDFs or images to insert after page \(model.selectedPage + 1)"
        guard panel.runModal() == .OK else { return }
        model.insertPages(from: panel.urls, after: model.selectedPage)
    }
}

// MARK: - Sidebar

private struct PageSidebar: View {
    @Bindable var model: PDFEditorModel

    var body: some View {
        List(selection: Binding(get: { model.selectedPage }, set: { i in
            model.selectedPage = i
            if let page = model.document.page(at: i) { model.pdfView?.go(to: page) }
        })) {
            ForEach(0..<model.pageCount, id: \.self) { i in
                PageThumb(page: model.document.page(at: i), number: i + 1, version: model.pageVersion)
                    .tag(i)
                    .contextMenu {
                        Button("Rotate Left") { model.rotatePage(i, by: -90) }
                        Button("Rotate Right") { model.rotatePage(i, by: 90) }
                        Divider()
                        Button("Delete Page") { model.deletePage(i) }.disabled(model.pageCount < 2)
                    }
            }
            .onMove { from, to in
                if let f = from.first { model.movePage(from: f, to: to) }
            }
        }
        .listStyle(.sidebar)
        .id(model.pageVersion)
        .accessibilityLabel("Pages. Drag to reorder.")
    }
}

private struct PageThumb: View {
    let page: PDFPage?
    let number: Int
    let version: Int

    var body: some View {
        VStack(spacing: 4) {
            if let page {
                Image(nsImage: page.thumbnail(of: CGSize(width: 110, height: 140), for: .cropBox))
                    .resizable().scaledToFit()
                    .frame(height: 120)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            Text("\(number)").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
    }
}

// MARK: - PDF view + markup overlay

struct PDFKitView: NSViewRepresentable {
    let model: PDFEditorModel

    func makeNSView(context: Context) -> PDFContainerView { PDFContainerView(model: model) }

    func updateNSView(_ view: PDFContainerView, context: Context) {
        _ = model.tool
        _ = model.pageVersion
        view.toolChanged()
        view.pdfView.layoutDocumentView()
    }
}

@MainActor
final class PDFContainerView: NSView {
    let pdfView = PDFView()
    let overlay: PDFOverlayView
    private let model: PDFEditorModel
    private var mouseUpMonitor: Any?

    init(model: PDFEditorModel) {
        self.model = model
        overlay = PDFOverlayView(model: model)
        super.init(frame: .zero)
        pdfView.document = model.document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.pdfView = pdfView
        addSubview(pdfView)
        addSubview(overlay)
        for v in [pdfView, overlay] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        model.pdfView = pdfView
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.pdfView.currentPage else { return }
                let i = self.model.document.index(for: page)
                if i != NSNotFound, i != self.model.selectedPage { self.model.selectedPage = i }
            }
        }
        // Highlight tool: selecting text and releasing the mouse turns the selection into highlights.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.window, self.model.tool == .highlight else { return }
                DispatchQueue.main.async { self.highlightSelection() }
            }
            return e
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func toolChanged() {
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: overlay)
    }

    private func highlightSelection() {
        guard let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0 else { continue }
                let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.5)
                model.add(a, to: page)
            }
        }
        pdfView.clearSelection()
    }
}

/// Transparent layer above PDFView that turns drags into PDF annotations.
/// In Select mode it only intercepts clicks that land on an annotation, so text
/// selection and links keep working underneath.
@MainActor
final class PDFOverlayView: NSView, NSTextFieldDelegate {
    weak var pdfView: PDFView?
    private let model: PDFEditorModel
    private var start: CGPoint?
    private var current: CGPoint?
    private var inkPoints: [CGPoint] = []
    private var dragging: PDFAnnotation?
    private var dragOrigin: CGRect = .zero
    private var selected: PDFAnnotation?
    private var editor: NSTextField?
    private var editing: PDFAnnotation?

    static let movableTypes: Set<String> = ["Square", "Circle", "Line", "Ink", "FreeText", "Text", "Stamp", "Highlight"]

    init(model: PDFEditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func pagePoint(_ p: CGPoint) -> (PDFPage, CGPoint)? {
        guard let pdfView else { return nil }
        let inPDF = convert(p, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: true) else { return nil }
        return (page, pdfView.convert(inPDF, to: page))
    }

    private func annotation(at p: CGPoint) -> PDFAnnotation? {
        guard let (page, pt) = pagePoint(p), let a = page.annotation(at: pt), Self.movableTypes.contains(a.type ?? "") else { return nil }
        return a
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        switch model.tool {
        case .select: return annotation(at: local) != nil || editor != nil ? self : nil
        case .highlight: return nil
        default: return self
        }
    }

    override func resetCursorRects() {
        switch model.tool {
        case .select, .highlight: break
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitEditor()
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        switch model.tool {
        case .select:
            if let a = annotation(at: p) {
                if event.clickCount == 2, a.type == "FreeText" || a.type == "Text" { beginEditing(a); return }
                selected = a
                dragging = a
                dragOrigin = a.bounds
                start = p
            }
        case .note:
            guard let (page, pt) = pagePoint(p) else { return }
            let a = PDFAnnotation(bounds: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
            a.color = .systemYellow
            a.iconType = .comment
            a.contents = ""
            model.add(a, to: page)
            beginEditing(a)
        case .signature:
            placeSignature(at: p)
        default:
            start = p
            current = p
            inkPoints = [p]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let a = dragging, let s = start, let pdfView, let page = a.page {
            let a0 = pdfView.convert(convert(s, to: pdfView), to: page)
            let a1 = pdfView.convert(convert(p, to: pdfView), to: page)
            a.bounds = dragOrigin.offsetBy(dx: a1.x - a0.x, dy: a1.y - a0.y)
            pdfView.needsDisplay = true
            return
        }
        guard start != nil else { return }
        current = p
        if model.tool == .ink { inkPoints.append(p) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil; inkPoints = []; needsDisplay = true }
        if let a = dragging {
            model.moved(a, from: dragOrigin)
            dragging = nil
            return
        }
        guard let s = start, let e = current, let (page, p0) = pagePoint(s), let (_, p1) = pagePoint(e) else { return }
        let lw = model.lineWidth
        let color = model.color.nsColor
        let border = PDFBorder()
        border.lineWidth = lw
        switch model.tool {
        case .rectangle, .oval:
            let r = CGRect(p1: p0, p2: p1)
            guard r.width > 3, r.height > 3 else { return }
            let a = PDFAnnotation(bounds: r.insetBy(dx: -lw, dy: -lw), forType: model.tool == .rectangle ? .square : .circle, withProperties: nil)
            a.border = border
            a.color = color
            model.add(a, to: page)
        case .line, .arrow:
            guard hypot(p1.x - p0.x, p1.y - p0.y) > 4 else { return }
            let pad = lw * 6
            let r = CGRect(p1: p0, p2: p1).insetBy(dx: -pad, dy: -pad)
            let a = PDFAnnotation(bounds: r, forType: .line, withProperties: nil)
            a.startPoint = CGPoint(x: p0.x - r.minX, y: p0.y - r.minY)
            a.endPoint = CGPoint(x: p1.x - r.minX, y: p1.y - r.minY)
            if model.tool == .arrow { a.endLineStyle = .closedArrow; a.interiorColor = color }
            a.border = border
            a.color = color
            model.add(a, to: page)
        case .ink:
            let pts = inkPoints.compactMap { pagePoint($0)?.1 }
            guard pts.count > 1 else { return }
            addInk([pts], on: page, color: color, width: lw)
        case .text:
            var r = CGRect(p1: p0, p2: p1)
            if r.width < 20 || r.height < 12 { r = CGRect(x: p0.x, y: p0.y - 28, width: 220, height: 28) }
            let a = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
            a.font = NSFont.systemFont(ofSize: 14)
            a.fontColor = color
            a.color = .clear
            a.contents = ""
            let b = PDFBorder(); b.lineWidth = 0
            a.border = b
            model.add(a, to: page)
            beginEditing(a)
        default:
            break
        }
    }

    private func addInk(_ strokes: [[CGPoint]], on page: PDFPage, color: NSColor, width: CGFloat) {
        let all = strokes.flatMap { $0 }
        let xs = all.map(\.x), ys = all.map(\.y)
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -width * 2, dy: -width * 2)
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: stroke[0].x - r.minX, y: stroke[0].y - r.minY))
            for p in stroke.dropFirst() { path.line(to: CGPoint(x: p.x - r.minX, y: p.y - r.minY)) }
            a.add(path)
        }
        let border = PDFBorder()
        border.lineWidth = width
        a.border = border
        a.color = color
        model.add(a, to: page)
    }

    private func placeSignature(at p: CGPoint) {
        guard let strokes = model.signature, let (page, center) = pagePoint(p) else { model.showSignaturePad = true; return }
        let height: CGFloat = 48
        let width = height * model.signatureAspect
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        // Normalized strokes are y-down; PDF page space is y-up.
        let mapped = strokes.map { $0.map { CGPoint(x: origin.x + $0.x / model.signatureAspect * width, y: origin.y + (1 - $0.y) * height) } }
        addInk(mapped, on: page, color: NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1), width: 1.6)
        model.tool = .select
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), let a = selected {
            model.remove(a)
            selected = nil
            return
        }
        if event.keyCode == 53 { selected = nil; model.tool = .select; return }
        super.keyDown(with: event)
    }

    // MARK: Inline text editing

    private func beginEditing(_ a: PDFAnnotation) {
        guard let pdfView, let page = a.page else { return }
        let viewRect = convert(pdfView.convert(a.bounds, from: page), from: pdfView)
        let frame = a.type == "Text" ? CGRect(x: viewRect.maxX + 4, y: viewRect.midY - 12, width: 240, height: 24) : viewRect.insetBy(dx: 0, dy: -2)
        let field = NSTextField(frame: frame)
        field.stringValue = a.contents ?? ""
        field.placeholderString = a.type == "Text" ? "Note" : "Text"
        field.font = a.font ?? .systemFont(ofSize: 14)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(commitEditor)
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
        editing = a
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitEditor() }

    @objc private func commitEditor() {
        guard let field = editor, let a = editing else { return }
        editor = nil
        editing = nil
        let text = field.stringValue
        field.removeFromSuperview()
        if text.trimmingCharacters(in: .whitespaces).isEmpty && a.type == "FreeText" {
            model.remove(a)
        } else if text != (a.contents ?? "") {
            model.setContents(a, to: text)
        }
    }

    // MARK: Live feedback

    override func draw(_ dirtyRect: NSRect) {
        guard let s = start, let e = current else { return }
        model.color.nsColor.setStroke()
        let path: NSBezierPath
        switch model.tool {
        case .rectangle, .text: path = NSBezierPath(rect: CGRect(p1: s, p2: e))
        case .oval: path = NSBezierPath(ovalIn: CGRect(p1: s, p2: e))
        case .line, .arrow:
            path = NSBezierPath()
            path.move(to: s)
            path.line(to: e)
        case .ink:
            path = NSBezierPath()
            if let f = inkPoints.first { path.move(to: f); inkPoints.dropFirst().forEach { path.line(to: $0) } }
        default: return
        }
        path.lineWidth = max(1, model.lineWidth * (pdfView?.scaleFactor ?? 1))
        path.lineCapStyle = .round
        path.stroke()
    }
}

// MARK: - Signature

private struct SignaturePad: View {
    let model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign with your trackpad or mouse").font(.headline)
            Canvas { ctx, _ in
                for stroke in strokes + [current] where stroke.count > 1 {
                    var p = Path()
                    p.addLines(stroke)
                    ctx.stroke(p, with: .color(Color(red: 0.05, green: 0.1, blue: 0.35)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 440, height: 160)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).padding(.bottom, 36) }
            .gesture(DragGesture(minimumDistance: 0).onChanged { current.append($0.location) }.onEnded { _ in strokes.append(current); current = [] })
            .accessibilityLabel("Signature drawing area")
            Text("Your signature is kept only while Forma is open and is never uploaded.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Clear") { strokes = [] }.disabled(strokes.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Signature") { useSignature() }.keyboardShortcut(.defaultAction).disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }

    private func useSignature() {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
        let h = max(maxY - minY, 1)
        model.signatureAspect = max(0.5, (maxX - minX) / h)
        model.signature = strokes.map { $0.map { CGPoint(x: ($0.x - minX) / h, y: ($0.y - minY) / h) } }
        model.tool = .signature
        dismiss()
    }
}
