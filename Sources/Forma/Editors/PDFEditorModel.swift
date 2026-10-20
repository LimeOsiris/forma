import AppKit
import FormaCore
import Observation
import PDFKit

/// PDF editing built on PDFKit. This edits *pages and annotations*; it does not rewrite
/// the original text of the PDF, and the UI says so.
@MainActor
@Observable
final class PDFEditorModel: EditorDocument {
    enum Tool: String, CaseIterable, Identifiable {
        case select, highlight, note, text, rectangle, oval, line, arrow, ink, signature
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "character.cursor.ibeam"
            case .highlight: "highlighter"
            case .note: "note.text"
            case .text: "character.textbox"
            case .rectangle: "rectangle"
            case .oval: "circle"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .ink: "scribble"
            case .signature: "signature"
            }
        }
        var label: String {
            switch self {
            case .select: "Select Text & Markup"
            case .highlight: "Highlight Selected Text"
            case .note: "Note"
            case .text: "Text Box"
            case .rectangle: "Rectangle"
            case .oval: "Oval"
            case .line: "Line"
            case .arrow: "Arrow"
            case .ink: "Draw"
            case .signature: "Signature"
            }
        }
    }

    private(set) var url: URL
    let document: PDFDocument
    private(set) var isDirty = false
    var tool: Tool = .select
    var color = RGBA(.systemRed)
    var lineWidth: CGFloat = 2
    var selectedPage = 0
    /// Bumped on page changes so thumbnails refresh.
    private(set) var pageVersion = 0
    /// Strokes of the user's signature, normalized to a unit-height box (width = aspect).
    var signature: [[CGPoint]]?
    var signatureAspect: CGFloat = 3
    var showSignaturePad = false
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var pdfView: PDFView?

    var canExportPDF: Bool { false }
    var pageCount: Int { document.pageCount }

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw FormaError.corrupted(url.lastPathComponent) }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw FormaError.passwordProtected(url.lastPathComponent) }
        self.url = url
        self.document = doc
    }

    private func changed(pages: Bool = false) {
        isDirty = true
        if pages { pageVersion += 1 }
    }

    private func undoable(_ name: String, undo: @escaping @MainActor (PDFEditorModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { undo(target) } }
        undoManager?.setActionName(name)
    }

    // MARK: Pages

    func rotatePage(_ index: Int, by degrees: Int) {
        guard let page = document.page(at: index) else { return }
        page.rotation = (page.rotation + degrees + 360) % 360
        changed(pages: true)
        undoable("Rotate Page") { $0.rotatePage(index, by: -degrees) }
    }

    func deletePage(_ index: Int) {
        guard document.pageCount > 1, let page = document.page(at: index) else { NSSound.beep(); return }
        document.removePage(at: index)
        selectedPage = min(selectedPage, document.pageCount - 1)
        changed(pages: true)
        undoable("Delete Page") { $0.insert([page], at: index) }
    }

    func insert(_ pages: [PDFPage], at index: Int) {
        for (i, p) in pages.enumerated() { document.insert(p, at: min(index + i, document.pageCount)) }
        changed(pages: true)
        let count = pages.count
        undoable("Insert Pages") { m in for _ in 0..<count { m.document.removePage(at: index) }; m.changed(pages: true) }
    }

    func movePage(from: Int, to: Int) {
        guard from != to, let page = document.page(at: from) else { return }
        document.removePage(at: from)
        let dest = to > from ? to - 1 : to
        document.insert(page, at: min(dest, document.pageCount))
        selectedPage = min(dest, document.pageCount - 1)
        changed(pages: true)
        undoable("Move Page") { m in m.movePage(from: dest, to: from > dest ? from + 1 : from) }
    }

    /// Merges pages from another PDF or image(s) after `index`.
    func insertPages(from urls: [URL], after index: Int) {
        var pages: [PDFPage] = []
        for url in urls {
            if let doc = PDFDocument(url: url) {
                if doc.isLocked && !doc.unlock(withPassword: "") { continue }
                for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { pages.append(p) } }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                pages.append(page)
            }
        }
        guard !pages.isEmpty else { NSSound.beep(); return }
        insert(pages, at: index + 1)
    }

    // MARK: Annotations

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        changed()
        undoable("Add \(annotation.type ?? "Markup")") { m in m.remove(annotation) }
    }

    func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        changed()
        undoable("Delete Markup") { m in m.add(annotation, to: page) }
    }

    func moved(_ annotation: PDFAnnotation, from old: CGRect) {
        let new = annotation.bounds
        guard new != old else { return }
        changed()
        undoable("Move Markup") { m in
            annotation.bounds = old
            m.pdfView?.needsDisplay = true
            m.moved(annotation, from: new)
        }
    }

    func setContents(_ annotation: PDFAnnotation, to text: String) {
        let old = annotation.contents ?? ""
        annotation.contents = text
        changed()
        undoable("Edit Text") { m in m.setContents(annotation, to: old) }
        pdfView?.needsDisplay = true
    }

    // MARK: Saving

    func save() throws {
        guard let data = document.dataRepresentation() else { throw FormaError.encodeFailed(.pdf) }
        try SavePanel.atomicWrite(data, to: url)
        isDirty = false
    }

    func saveCopy(in window: NSWindow?) {
        guard let dest = SavePanel.run(suggestedName: SavePanel.editedName(for: url, ext: "pdf"), types: [.pdf], in: window, directory: url.deletingLastPathComponent()),
              let data = document.dataRepresentation() else { return }
        do {
            try SavePanel.atomicWrite(data, to: dest)
            url = dest
            isDirty = false
            window?.title = dest.lastPathComponent
            window?.representedURL = dest
        } catch {
            NSAlert(error: FormaError.wrap(error) as NSError).runModal()
        }
    }

    func exportPDF(in window: NSWindow?) { saveCopy(in: window) }
}
