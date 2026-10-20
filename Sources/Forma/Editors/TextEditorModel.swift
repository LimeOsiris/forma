import AppKit
import FormaCore
import Observation

/// Plain text, Markdown and rich text (RTF/RTFD/HTML/DOCX/ODT/DOC) editing on NSTextView.
@MainActor
@Observable
final class TextEditorModel: EditorDocument {
    enum Mode { case plain, markdown, rich }

    private(set) var url: URL
    let format: FileFormat
    let mode: Mode
    /// The text system's storage; the NSTextView edits it directly.
    @ObservationIgnored let storage: NSTextStorage
    @ObservationIgnored private var documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
    private(set) var isDirty = false
    var fontSize: CGFloat = 14 { didSet { applyBaseFont() } }
    var showPreview = false
    private(set) var previewHTML = ""
    private(set) var wordCount = 0
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    var canExportPDF: Bool { true }

    /// DOCX/DOC/ODT/HTML can't round-trip every feature through the macOS text system.
    var editability: Editability {
        switch format {
        case .txt, .markdown, .rtf, .rtfd: .full
        default: .limited
        }
    }

    var limitationNote: String? {
        switch format {
        case .docx, .doc, .odt:
            "Forma edits Word and ODT files with the macOS text engine. Text, fonts, lists and simple tables are kept; headers, footers, comments, tracked changes and complex layouts may be lost when saving."
        case .html:
            "Saving rewrites the HTML from the formatted text. Scripts, custom CSS and page structure won't be preserved."
        default: nil
        }
    }

    init(url: URL) throws {
        guard let format = FileTypeDetector().format(of: url) else { throw FormaError.unsupportedInput(url.lastPathComponent) }
        self.url = url
        self.format = format
        switch format {
        case .txt:
            mode = .plain
            storage = NSTextStorage(string: try AttributedDocumentIO.readText(url))
        case .markdown:
            mode = .markdown
            storage = NSTextStorage(string: try AttributedDocumentIO.readText(url))
        case .rtf, .rtfd, .docx, .doc, .odt, .html:
            mode = .rich
            guard let type = AttributedDocumentIO.documentType(for: format) else { throw FormaError.unsupportedInput(url.lastPathComponent) }
            var attrs: NSDictionary?
            do {
                let s = try NSAttributedString(url: url, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: &attrs)
                storage = NSTextStorage(attributedString: s)
            } catch {
                throw FormaError.corrupted(url.lastPathComponent)
            }
            documentAttributes = (attrs as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:]
        default:
            throw FormaError.unsupportedInput(url.lastPathComponent)
        }
        if mode != .rich { applyBaseFont() }
        updateCounts()
        if mode == .markdown { refreshPreview(immediate: true) }
    }

    var baseFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    private func applyBaseFont() {
        guard mode != .rich else { return } // rich text keeps its own fonts; zoom uses magnification
        storage.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: storage.length))
        textView?.typingAttributes[.font] = baseFont
        if mode == .markdown { MarkdownHighlighter.highlight(storage, baseFont: baseFont) }
    }

    func textDidChange() {
        isDirty = true
        updateCounts()
        if mode == .markdown { refreshPreview() }
    }

    private func updateCounts() {
        wordCount = storage.string.split { $0.isWhitespace || $0.isNewline }.count
    }

    func refreshPreview(immediate: Bool = false) {
        previewTask?.cancel()
        let text = storage.string
        let title = url.deletingPathExtension().lastPathComponent
        previewTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let html = await Task.detached { MarkdownRenderer().renderDocument(text, title: title) }.value
            self?.previewHTML = html
        }
    }

    func biggerText() {
        if mode == .rich { (textView?.enclosingScrollView)?.magnification += 0.1 } else { fontSize = min(fontSize + 1, 48) }
    }

    func smallerText() {
        if mode == .rich { (textView?.enclosingScrollView)?.magnification = max(0.5, ((textView?.enclosingScrollView)?.magnification ?? 1) - 0.1) } else { fontSize = max(fontSize - 1, 9) }
    }

    // MARK: Saving

    func data(for format: FileFormat) throws -> Data {
        switch format {
        case .txt, .markdown:
            return Data(storage.string.utf8)
        default:
            return try AttributedDocumentIO.data(storage, format: format, attributes: documentAttributes)
        }
    }

    func save() throws {
        if format == .rtfd {
            try AttributedDocumentIO.writeRTFD(storage, to: url)
        } else {
            try SavePanel.atomicWrite(try data(for: format), to: url)
        }
        isDirty = false
    }

    func saveCopy(in window: NSWindow?) {
        var types: [FileFormat] = []
        for t in mode == .rich ? [format, .rtf, .docx, .odt, .html, .txt] : [format, .txt] where !types.contains(t) { types.append(t) }
        guard let dest = SavePanel.run(suggestedName: SavePanel.editedName(for: url), types: types,
                                       in: window, directory: url.deletingLastPathComponent()) else { return }
        let out = FileFormat.from(extension: dest.pathExtension) ?? format
        do {
            if out == .rtfd { try AttributedDocumentIO.writeRTFD(storage, to: dest) } else { try SavePanel.atomicWrite(try data(for: out), to: dest) }
            if out == format {
                url = dest
                isDirty = false
                window?.title = dest.lastPathComponent
                window?.representedURL = dest
            }
        } catch {
            NSAlert(error: FormaError.wrap(error) as NSError).runModal()
        }
    }

    func exportPDF(in window: NSWindow?) {
        guard let dest = SavePanel.run(suggestedName: url.deletingPathExtension().lastPathComponent + ".pdf", types: [.pdf], in: window, directory: url.deletingLastPathComponent()) else { return }
        Task {
            do {
                let content: NSAttributedString
                switch mode {
                case .markdown:
                    let html = MarkdownRenderer().renderDocument(storage.string, title: url.deletingPathExtension().lastPathComponent, forPrint: true)
                    var attrs: NSDictionary?
                    content = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: &attrs)
                case .plain:
                    content = NSAttributedString(string: storage.string, attributes: [.font: AttributedDocumentIO.plainTextFont, .foregroundColor: NSColor.black])
                case .rich:
                    content = NSAttributedString(attributedString: storage)
                }
                _ = try AttributedPDFWriter.write(content, layout: .from(documentAttributes: documentAttributes), to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                NSAlert(error: FormaError.wrap(error) as NSError).runModal()
            }
        }
    }

    func exportHTML(in window: NSWindow?) {
        guard mode == .markdown,
              let dest = SavePanel.run(suggestedName: url.deletingPathExtension().lastPathComponent + ".html", types: [.html], in: window, directory: url.deletingLastPathComponent()) else { return }
        do {
            try Data(MarkdownRenderer().renderDocument(storage.string, title: url.deletingPathExtension().lastPathComponent).utf8).write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            NSAlert(error: FormaError.wrap(error) as NSError).runModal()
        }
    }

    func openInDefaultApp() {
        NSWorkspace.shared.open(url)
    }
}

/// Lightweight Markdown syntax colouring for the source view.
@MainActor
enum MarkdownHighlighter {
    private static let rules: [(NSRegularExpression, (NSFont) -> [NSAttributedString.Key: Any])] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (re(#"^#{1,6}[ \t].*$"#), { f in [.font: NSFont.monospacedSystemFont(ofSize: f.pointSize, weight: .bold), .foregroundColor: NSColor.labelColor] }),
            (re(#"^\s{0,3}>.*$"#), { _ in [.foregroundColor: NSColor.secondaryLabelColor] }),
            (re(#"^\s*([-*+]|\d+[.)])(?=\s)"#), { _ in [.foregroundColor: NSColor.controlAccentColor] }),
            (re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), { f in [.font: NSFont.monospacedSystemFont(ofSize: f.pointSize, weight: .bold)] }),
            (re(#"(?<![*_\w])([*_])(?=\S)(.+?)(?<=\S)\1(?![*_\w])"#), { f in [.font: NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)] }),
            (re(#"~~(.+?)~~"#), { _ in [.strikethroughStyle: NSUnderlineStyle.single.rawValue] }),
            (re(#"`[^`\n]+`"#), { _ in [.foregroundColor: NSColor.systemPink, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.25)] }),
            (re(#"!?\[[^\]\n]*\]\([^)\n]*\)"#), { _ in [.foregroundColor: NSColor.linkColor] }),
            (re(#"^\s*([-*_]\s*){3,}$"#), { _ in [.foregroundColor: NSColor.tertiaryLabelColor] }),
            (re(#"^(```|~~~).*?^(```|~~~)\s*$"#, [.anchorsMatchLines, .dotMatchesLineSeparators]), { _ in [.foregroundColor: NSColor.systemPink, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)] }),
        ]
    }()

    static func highlight(_ storage: NSTextStorage, baseFont: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length < 2_000_000 else { return }
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)
        for (regex, attrs) in rules {
            let a = attrs(baseFont)
            regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in
                if let r = m?.range { storage.addAttributes(a, range: r) }
            }
        }
        storage.endEditing()
    }
}
