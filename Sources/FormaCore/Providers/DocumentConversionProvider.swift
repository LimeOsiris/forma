import AppKit
import Foundation

/// Text and rich-document conversion built on the macOS text system (NSAttributedString),
/// plus Forma's Markdown renderer. No external dependencies.
///
/// Fidelity is honest: Word/ODT go through the same engine as TextEdit, which keeps
/// paragraphs, fonts, colours, lists, simple tables and images, but not headers, footers,
/// footnotes, comments, columns or floating layout. LibreOffice, when installed, takes
/// priority for Office → PDF.
public struct DocumentConversionProvider: ConversionProvider {
    public let id = "document"
    public init() {}

    static let inputs: [FileFormat] = [.docx, .doc, .odt, .rtf, .rtfd, .html, .txt, .markdown]
    static let officeInputs: Set<FileFormat> = [.docx, .doc, .odt]

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        var caps: [ConversionCapability] = []
        for input in Self.inputs {
            var outputs: [FileFormat] = [.pdf, .docx, .odt, .rtf, .html, .txt]
            if input != .txt { outputs.append(.markdown) }
            for output in outputs where output != input {
                caps.append(ConversionCapability(
                    input: input, output: output, providerID: id,
                    isLossless: false,
                    preservesMetadata: false,
                    editability: editability(input, output),
                    priority: 50,
                    notes: notes(input, output)
                ))
            }
        }
        return caps
    }

    func editability(_ input: FileFormat, _ output: FileFormat) -> Editability {
        switch output {
        case .pdf: return .annotationOnly
        case .txt: return .full
        case .markdown: return .limited
        default: return Self.officeInputs.contains(input) || input == .html ? .limited : .full
        }
    }

    func notes(_ input: FileFormat, _ output: FileFormat) -> [Caveat] {
        var n: [Caveat] = []
        if Self.officeInputs.contains(input) {
            n.append(.info("Uses the macOS text engine: headers, footers, footnotes and complex layouts may not carry over."))
        }
        switch output {
        case .txt where input != .markdown: n.append(.info("Only the text is kept."))
        case .markdown: n.append(.info("Headings, emphasis, links and lists are converted; other formatting is dropped."))
        case .pdf: n.append(.info("The PDF can be annotated, but its text can't be rewritten."))
        default: break
        }
        return n
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        try Task.checkCancellation()
        let url = job.defaultOutputURL
        let title = job.input.deletingPathExtension().lastPathComponent
        progress(0.05)

        // Paths that don't need the rich-text engine.
        switch (job.inputFormat, job.output) {
        case (.markdown, .html):
            let md = try AttributedDocumentIO.readText(job.input)
            try MarkdownRenderer().renderDocument(md, title: title).write(to: url, atomically: false, encoding: .utf8)
            progress(1)
            return ProviderResult(files: [url])
        case (.txt, .html):
            let text = try AttributedDocumentIO.readText(job.input)
            try Self.plainTextHTML(text, title: title).write(to: url, atomically: false, encoding: .utf8)
            progress(1)
            return ProviderResult(files: [url])
        default:
            break
        }

        let loaded = try await AttributedDocumentIO.load(job.input, format: job.inputFormat)
        try Task.checkCancellation()
        progress(0.5)
        var caveats: [Caveat] = []

        switch job.output {
        case .pdf:
            let layout = PageLayout.from(documentAttributes: loaded.attributes)
            let box = UncheckedBox(loaded.string)
            let pages = try await MainActor.run { try AttributedPDFWriter.write(box.value, layout: layout, to: url) }
            if pages >= AttributedPDFWriter.maxPages { caveats.append(.warning("The document was truncated at \(pages) pages.")) }
        case .txt:
            try loaded.string.string.write(to: url, atomically: false, encoding: .utf8)
        case .markdown:
            try AttributedMarkdownWriter.markdown(from: loaded.string).write(to: url, atomically: false, encoding: .utf8)
        case .rtf:
            if AttributedDocumentIO.containsAttachments(loaded.string) {
                caveats.append(.info("RTF can't hold images, so they were left out. Use Word or ODT to keep them."))
            }
            try AttributedDocumentIO.data(loaded.string, format: .rtf, attributes: loaded.attributes).write(to: url)
        case .docx, .odt, .html:
            try AttributedDocumentIO.data(loaded.string, format: job.output, attributes: loaded.attributes).write(to: url)
        default:
            throw FormaError.unsupportedConversion(from: job.inputFormat, to: job.output)
        }
        progress(1)
        return ProviderResult(files: [url], caveats: caveats)
    }

    static func plainTextHTML(_ text: String, title: String) -> String {
        let r = MarkdownRenderer()
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="generator" content="Forma">
        <title>\(r.escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 2em auto; max-width: 52em; padding: 0 1.5em; }
        pre { font-family: "SF Mono", Menlo, monospace; font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; }
        </style>
        </head>
        <body>
        <pre>\(r.escape(text))</pre>
        </body>
        </html>
        """
    }
}
