import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// PDF → images (one file per page, or one multi-page TIFF) and PDF → text with optional OCR.
public struct PDFConversionProvider: ConversionProvider {
    public let id = "pdf"
    public init() {}

    /// Refuse to allocate absurd bitmaps for poster-sized pages.
    static let maxRenderEdge: CGFloat = 12_000

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        let encodable = Set(ImageConversionProvider.encodableOutputs())
        var caps: [ConversionCapability] = [.png, .jpeg, .heic, .tiff].filter(encodable.contains).map { out in
            ConversionCapability(input: .pdf, output: out, providerID: id, isLossless: false, preservesTransparency: false,
                                 editability: .rasterized, priority: 10,
                                 notes: [.info("Pages are rendered as pictures; text won't be editable.")])
        }
        caps.append(ConversionCapability(input: .pdf, output: .txt, providerID: id, isLossless: false,
                                         editability: .full, priority: 10,
                                         notes: [.info("Only the text is kept; layout, images and fonts are not.")]))
        return caps
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        var result: [Caveat] = []
        if facts.isEncrypted { result.append(.warning("This PDF is password protected.")) }
        if output != .txt && output != .tiff && facts.pageCount > 1 {
            result.append(.info("Each of the \(facts.pageCount) pages becomes its own \(output.displayName) file at \(Int(options.pdfRenderDPI)) dpi."))
        }
        return result
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        let document = try Self.open(job.input)
        let count = document.numberOfPages
        guard count > 0 else { throw FormaError.corrupted(job.input.lastPathComponent) }

        if job.output == .txt {
            return try await extractText(job, document: document, progress: progress)
        }

        if job.output == .tiff {
            let url = job.defaultOutputURL
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, count, nil) else {
                throw FormaError.encodeFailed(.tiff)
            }
            for i in 1...count {
                try Task.checkCancellation()
                guard let page = document.page(at: i), let image = Self.render(page, dpi: job.options.pdfRenderDPI) else { continue }
                CGImageDestinationAddImage(dest, image, Self.dpiProps(job.options.pdfRenderDPI) as CFDictionary)
                progress(Double(i) / Double(count))
            }
            guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(.tiff) }
            return ProviderResult(files: [url])
        }

        guard let typeID = job.output.imageIOIdentifier else { throw FormaError.unsupportedConversion(from: .pdf, to: job.output) }
        var files: [URL] = []
        let digits = String(count).count
        for i in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: i), let image = Self.render(page, dpi: job.options.pdfRenderDPI) else {
                throw FormaError.corrupted(job.input.lastPathComponent)
            }
            let name = count == 1 ? job.baseName : "\(job.baseName) page \(String(format: "%0\(digits)d", i))"
            let url = job.workDirectory.appendingPathComponent(name).appendingPathExtension(job.output.preferredExtension)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, typeID as CFString, 1, nil) else {
                throw FormaError.encodeFailed(job.output)
            }
            var props = Self.dpiProps(job.options.pdfRenderDPI)
            if job.output.isLossyByNature { props[kCGImageDestinationLossyCompressionQuality] = job.options.quality }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(job.output) }
            files.append(url)
            progress(Double(i) / Double(count))
        }
        return ProviderResult(files: files)
    }

    static func dpiProps(_ dpi: Double) -> [CFString: Any] {
        [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    }

    /// Opens a PDF, distinguishing damaged files from password-protected ones.
    public static func open(_ url: URL, password: String? = nil) throws -> CGPDFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FormaError.fileNotFound(url) }
        guard let doc = CGPDFDocument(url as CFURL) else { throw FormaError.corrupted(url.lastPathComponent) }
        if doc.isEncrypted && !doc.isUnlocked {
            if !doc.unlockWithPassword(password ?? "") { throw FormaError.passwordProtected(url.lastPathComponent) }
        }
        return doc
    }

    /// Renders a page on white at the given DPI, honouring the page's /Rotate.
    public static func render(_ page: CGPDFPage, dpi: Double) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        var size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        var scale = CGFloat(dpi) / 72
        let longest = max(size.width, size.height) * scale
        if longest > maxRenderEdge { scale *= maxRenderEdge / longest }
        size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(pageTransform(box: box, rotation: page.rotationAngle))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Maps the crop box to an origin-anchored, upright coordinate space for any /Rotate value.
    static func pageTransform(box b: CGRect, rotation: Int32) -> CGAffineTransform {
        switch ((Int(rotation) % 360) + 360) % 360 {
        case 90: CGAffineTransform(translationX: -b.minY, y: b.maxX).rotated(by: -.pi / 2)
        case 180: CGAffineTransform(translationX: b.maxX, y: b.maxY).rotated(by: .pi)
        case 270: CGAffineTransform(translationX: b.maxY, y: -b.minX).rotated(by: .pi / 2)
        default: CGAffineTransform(translationX: -b.minX, y: -b.minY)
        }
    }

    // MARK: - Text

    func extractText(_ job: ConversionJob, document: CGPDFDocument, progress: ProgressHandler) async throws -> ProviderResult {
        guard let pdf = PDFDocument(url: job.input) else { throw FormaError.corrupted(job.input.lastPathComponent) }
        if pdf.isLocked && !pdf.unlock(withPassword: "") { throw FormaError.passwordProtected(job.input.lastPathComponent) }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()
            pages.append(pdf.page(at: i)?.string ?? "")
            progress(Double(i + 1) / Double(pdf.pageCount) * 0.3)
        }
        var text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var caveats: [Caveat] = []
        if text.isEmpty && job.options.ocrWhenNoText {
            text = try await Self.recognizeText(document, progress: { progress(0.3 + $0 * 0.7) })
            if !text.isEmpty { caveats.append(.info("This PDF had no text layer, so the text was recognized from the page images. Check it for mistakes.")) }
        }
        guard !text.isEmpty else { throw FormaError.noTextFound }
        let url = job.defaultOutputURL
        try (text + "\n").write(to: url, atomically: false, encoding: .utf8)
        progress(1)
        return ProviderResult(files: [url], caveats: caveats)
    }

    /// On-device OCR via Vision. Nothing leaves the Mac.
    public static func recognizeText(_ document: CGPDFDocument, progress: ProgressHandler) async throws -> String {
        var out: [String] = []
        let count = document.numberOfPages
        for i in 1...max(1, count) {
            try Task.checkCancellation()
            guard let page = document.page(at: i), let image = render(page, dpi: 220) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            out.append(lines.joined(separator: "\n"))
            progress(Double(i) / Double(count))
        }
        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// PDF-to-PDF operations used by batch actions and the editor.
public enum PDFOperations {
    /// Appends every page of `inputs`, in order, into one new PDF.
    public static func merge(_ inputs: [URL], to output: URL) throws {
        let result = PDFDocument()
        for url in inputs {
            try Task.checkCancellation()
            guard let doc = PDFDocument(url: url) else { throw FormaError.corrupted(url.lastPathComponent) }
            if doc.isLocked && !doc.unlock(withPassword: "") { throw FormaError.passwordProtected(url.lastPathComponent) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        guard result.pageCount > 0, result.write(to: output) else { throw FormaError.encodeFailed(.pdf) }
    }

    /// Writes each page to its own PDF inside `directory`.
    public static func split(_ input: URL, into directory: URL, baseName: String) throws -> [URL] {
        guard let doc = PDFDocument(url: input) else { throw FormaError.corrupted(input.lastPathComponent) }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw FormaError.passwordProtected(input.lastPathComponent) }
        let digits = String(doc.pageCount).count
        var urls: [URL] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let url = directory.appendingPathComponent("\(baseName) page \(String(format: "%0\(digits)d", i + 1)).pdf")
            guard single.write(to: url) else { throw FormaError.encodeFailed(.pdf) }
            urls.append(url)
        }
        return urls
    }

    /// Combines images (and/or PDFs) into one PDF, one picture per page, in the given order.
    public static func combine(_ inputs: [(URL, FileFormat)], to output: URL, options: ConversionOptions) throws {
        let result = PDFDocument()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("forma-combine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (n, (url, format)) in inputs.enumerated() {
            try Task.checkCancellation()
            var pdfURL = url
            if format != .pdf {
                pdfURL = tmp.appendingPathComponent("\(n).pdf")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FormaError.corrupted(url.lastPathComponent) }
                if format == .svg {
                    let job = ConversionJob(input: url, inputFormat: .svg, output: .pdf, options: options, workDirectory: tmp, baseName: "\(n)")
                    pdfURL = try ImageConversionProvider().convertSVG(job).files[0]
                } else {
                    try ImageConversionProvider().writePDF(source: source, frames: [0], to: pdfURL, options: options, progress: { _ in })
                }
            }
            guard let doc = PDFDocument(url: pdfURL) else { throw FormaError.corrupted(url.lastPathComponent) }
            if doc.isLocked && !doc.unlock(withPassword: "") { throw FormaError.passwordProtected(url.lastPathComponent) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        guard result.pageCount > 0, result.write(to: output) else { throw FormaError.encodeFailed(.pdf) }
    }
}
