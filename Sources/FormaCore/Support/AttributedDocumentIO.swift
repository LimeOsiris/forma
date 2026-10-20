import AppKit
import Foundation

/// Wraps a non-Sendable value for a hand-off we know is safe (created on one actor,
/// then used exclusively by the receiver).
public struct UncheckedBox<T>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }
}

/// Page geometry for paginated output.
public struct PageLayout: Sendable, Equatable {
    public var paperSize: CGSize
    public var margins: NSEdgeInsets

    public static func == (a: PageLayout, b: PageLayout) -> Bool {
        a.paperSize == b.paperSize && a.margins.top == b.margins.top && a.margins.left == b.margins.left
            && a.margins.bottom == b.margins.bottom && a.margins.right == b.margins.right
    }

    public var contentSize: CGSize {
        CGSize(width: paperSize.width - margins.left - margins.right, height: paperSize.height - margins.top - margins.bottom)
    }

    /// US Letter in the US and a handful of other regions, A4 elsewhere.
    public static var localeDefault: PageLayout {
        let letter = Locale.current.measurementSystem == .us
        return PageLayout(paperSize: letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89),
                          margins: NSEdgeInsets(top: 64, left: 64, bottom: 64, right: 64))
    }

    /// Uses the page setup stored in the document (DOCX/RTF carry it) when sensible.
    public static func from(documentAttributes attrs: [NSAttributedString.DocumentAttributeKey: Any]) -> PageLayout {
        var layout = localeDefault
        if let size = attrs[.paperSize] as? CGSize, size.width > 144, size.height > 144 { layout.paperSize = size }
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
            guard let v = attrs[key] as? CGFloat, v >= 0, v < 300 else { return nil }
            return v
        }
        layout.margins = NSEdgeInsets(top: margin(.topMargin) ?? layout.margins.top,
                                      left: margin(.leftMargin) ?? layout.margins.left,
                                      bottom: margin(.bottomMargin) ?? layout.margins.bottom,
                                      right: margin(.rightMargin) ?? layout.margins.right)
        if layout.contentSize.width < 144 || layout.contentSize.height < 144 { layout.margins = localeDefault.margins }
        return layout
    }
}

/// Loading and saving rich text through the macOS text system (the same engine TextEdit uses).
public enum AttributedDocumentIO {
    public struct Loaded: @unchecked Sendable {
        public var string: NSAttributedString
        public var attributes: [NSAttributedString.DocumentAttributeKey: Any]
    }

    public static func documentType(for format: FileFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .html: .html
        case .txt, .markdown: .plain
        default: nil
        }
    }

    /// Default font for plain text, matching TextEdit's plain-text mode.
    public static var plainTextFont: NSFont { NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular) }

    /// Loads any supported text-family file. HTML and Markdown go through WebKit's importer,
    /// which AppKit requires on the main thread; other formats load on the caller's thread.
    public static func load(_ url: URL, format: FileFormat) async throws -> Loaded {
        switch format {
        case .markdown:
            let md = try readText(url)
            let html = MarkdownRenderer().renderDocument(md, title: url.deletingPathExtension().lastPathComponent, forPrint: true)
            return try await importHTML(Data(html.utf8), baseURL: url.deletingLastPathComponent())
        case .html:
            let data = try Data(contentsOf: url)
            return try await importHTML(data, baseURL: url.deletingLastPathComponent())
        case .txt:
            let text = try readText(url)
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.1
            let attr = NSAttributedString(string: text, attributes: [.font: plainTextFont, .foregroundColor: NSColor.black, .paragraphStyle: para])
            return Loaded(string: attr, attributes: [:])
        default:
            guard let type = documentType(for: format) else { throw FormaError.unsupportedInput(url.lastPathComponent) }
            var attrs: NSDictionary?
            do {
                let s = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attrs)
                return Loaded(string: s, attributes: (attrs as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:])
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadCorruptFileError { throw FormaError.corrupted(url.lastPathComponent) }
                if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError) { throw FormaError.unreadable(url.lastPathComponent) }
                throw FormaError.corrupted(url.lastPathComponent)
            }
        }
    }

    @MainActor
    static func importHTMLOnMain(_ data: Data, baseURL: URL) throws -> Loaded {
        var attrs: NSDictionary?
        let s = try NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .baseURL: baseURL,
        ], documentAttributes: &attrs)
        return Loaded(string: s, attributes: (attrs as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:])
    }

    static func importHTML(_ data: Data, baseURL: URL) async throws -> Loaded {
        try await MainActor.run { try importHTMLOnMain(data, baseURL: baseURL) }
    }

    /// Reads text trying UTF-8 first, then letting Foundation guess the encoding.
    public static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw FormaError.unreadable(url.lastPathComponent) }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        var converted: NSString?
        var lossy: ObjCBool = false
        let enc = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.macOSRoman.rawValue]], convertedString: &converted, usedLossyConversion: &lossy)
        if enc != 0, let s = converted as String? { return s }
        throw FormaError.corrupted(url.lastPathComponent)
    }

    /// Serializes to a document format through the text system.
    public static func data(_ string: NSAttributedString, format: FileFormat, attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]) throws -> Data {
        guard let type = documentType(for: format) else { throw FormaError.encodeFailed(format) }
        var docAttrs = attributes.filter { [.paperSize, .leftMargin, .rightMargin, .topMargin, .bottomMargin, .title, .author].contains($0.key) }
        docAttrs[.documentType] = type
        if format == .html {
            docAttrs[.excludedElements] = ["XML", "applet", "object", "script"]
            docAttrs[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        if format == .txt { docAttrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            return try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: docAttrs)
        } catch {
            throw FormaError.encodeFailed(format)
        }
    }

    /// RTFD is a package; it must be written as a file wrapper.
    public static func writeRTFD(_ string: NSAttributedString, to url: URL) throws {
        guard let wrapper = string.rtfdFileWrapper(from: NSRange(location: 0, length: string.length), documentAttributes: [:]) else {
            throw FormaError.encodeFailed(.rtfd)
        }
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    public static func containsAttachments(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

/// Paginates attributed text into a PDF using TextKit, so tables (NSTextTable),
/// lists and inline images render the same way they do in TextEdit.
public enum AttributedPDFWriter {
    public static let maxPages = 10_000

    /// Must run on the main actor: attachment cells and some table drawing call into AppKit views.
    @MainActor
    public static func write(_ string: NSAttributedString, layout: PageLayout, to url: URL) throws -> Int {
        let storage = NSTextStorage(attributedString: string.length > 0 ? string : NSAttributedString(string: " "))
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)

        var containers: [NSTextContainer] = []
        let contentSize = layout.contentSize
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            _ = manager.glyphRange(for: container)
        } while NSMaxRange(manager.glyphRange(for: containers.last!)) < manager.numberOfGlyphs && containers.count < maxPages

        var mediaBox = CGRect(origin: .zero, size: layout.paperSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw FormaError.encodeFailed(.pdf) }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        var pages = 0
        for container in containers {
            let range = manager.glyphRange(for: container)
            if range.length == 0 && pages > 0 { continue }
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: layout.paperSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let origin = CGPoint(x: layout.margins.left, y: layout.margins.top)
            manager.drawBackground(forGlyphRange: range, at: origin)
            manager.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
            pages += 1
        }
        ctx.closePDF()
        return pages
    }
}

/// Best-effort rich text → Markdown, for DOCX/RTF/HTML → Markdown.
/// Recognises headings (by relative font size), bold, italic, strikethrough, links, lists and code.
public enum AttributedMarkdownWriter {
    public static func markdown(from s: NSAttributedString) -> String {
        let ns = s.string as NSString
        guard ns.length > 0 else { return "" }
        let bodySize = dominantFontSize(s)
        var lines: [String] = []
        var location = 0
        while location < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paraRange)
            var content = paraRange
            while content.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            let raw = ns.substring(with: content)
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(""); continue }

            let attrs = s.attributes(at: content.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont
            let para = attrs[.paragraphStyle] as? NSParagraphStyle
            let size = font?.pointSize ?? bodySize
            let isMono = font?.isFixedPitch ?? false

            if let list = para?.textLists.last {
                let depth = max(0, (para?.textLists.count ?? 1) - 1)
                let indent = String(repeating: "    ", count: depth)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat == .decimal
                var text = inline(s, content)
                // Strip the visible marker the text system inserts (e.g. "\t•\t" or "\t1.\t").
                text = text.replacingOccurrences(of: #"^\s*(\S{1,4})\t"#, with: "", options: .regularExpression)
                lines.append("\(indent)\(ordered ? "1." : "-") \(text.trimmingCharacters(in: .whitespaces))")
                continue
            }
            if isMono {
                lines.append("    " + raw)
                continue
            }
            let ratio = size / max(bodySize, 1)
            let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
            let heading: Int? = ratio >= 1.6 ? 1 : ratio >= 1.3 ? 2 : (ratio >= 1.1 && bold) ? 3 : nil
            if let h = heading, raw.count < 200 {
                if lines.last.map({ !$0.isEmpty }) ?? false { lines.append("") }
                lines.append(String(repeating: "#", count: h) + " " + raw.trimmingCharacters(in: .whitespaces))
                lines.append("")
            } else {
                lines.append(inline(s, content))
                lines.append("")
            }
        }
        // Collapse runs of blank lines.
        var out: [String] = []
        for l in lines where !(l.isEmpty && (out.last?.isEmpty ?? true)) { out.append(l) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    static func dominantFontSize(_ s: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let f = v as? NSFont { counts[f.pointSize.rounded(), default: 0] += r.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    static func inline(_ s: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        s.enumerateAttributes(in: range) { attrs, r, _ in
            var text = (s.string as NSString).substring(with: r)
            text = text.replacingOccurrences(of: "\u{2028}", with: "  \n")
            let escaped = text.replacingOccurrences(of: #"([\\`*_\[\]])"#, with: #"\\$1"#, options: .regularExpression)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { out += text; return }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var piece = escaped
            if font?.isFixedPitch == true { piece = "`\(text)`" }
            else {
                // Keep surrounding whitespace outside the markers so they stay valid.
                let lead = String(piece.prefix { $0 == " " })
                let trail = String(piece.reversed().prefix { $0 == " " })
                var core = piece.trimmingCharacters(in: .whitespaces)
                if traits.contains(.italicFontMask) { core = "*\(core)*" }
                if traits.contains(.boldFontMask) { core = "**\(core)**" }
                if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { core = "~~\(core)~~" }
                piece = lead + core + trail
            }
            if let link = attrs[.link] {
                let urlString = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !urlString.isEmpty { piece = "[\(piece)](\(urlString))" }
            }
            out += piece
        }
        return out
    }
}
