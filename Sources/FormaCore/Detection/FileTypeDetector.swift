import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Identifies what a file really is. File contents win over the extension, so a
/// JPEG named `photo.png` is treated as a JPEG and a text file renamed `.pdf` is rejected.
public struct FileTypeDetector: Sendable {
    public init() {}

    public enum DetectionSource: String, Sendable { case signature, typeIdentifier, fileExtension }

    public struct Detection: Sendable, Equatable {
        public var format: FileFormat
        public var source: DetectionSource
        /// True when the bytes disagree with the extension.
        public var extensionMismatch: Bool
    }

    public func detect(_ url: URL) -> Detection? {
        let extFormat = FileFormat.from(extension: url.pathExtension)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isPackage {
            // RTFD is a directory bundle; nothing else we handle is.
            return extFormat == .rtfd ? Detection(format: .rtfd, source: .fileExtension, extensionMismatch: false) : nil
        }
        if let sig = sniff(url) {
            let mismatch = extFormat != nil && extFormat != sig && !Self.compatible(extFormat!, sig)
            // Text-family signatures are weak (HTML vs Markdown both start with text) so prefer the extension among text types.
            if (sig == .txt || sig == .html), let e = extFormat, e.category == .text || e == .html || e == .svg {
                return Detection(format: e, source: .fileExtension, extensionMismatch: false)
            }
            return Detection(format: sig, source: .signature, extensionMismatch: mismatch)
        }
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
           let format = FileFormat.allCases.first(where: { type == $0.utType }), !Self.requiresSignature(format) {
            return Detection(format: format, source: .typeIdentifier, extensionMismatch: false)
        }
        if let e = extFormat, !Self.requiresSignature(e) {
            return Detection(format: e, source: .fileExtension, extensionMismatch: false)
        }
        return nil
    }

    public func format(of url: URL) -> FileFormat? { detect(url)?.format }

    /// Binary formats whose identity must be confirmed by content; an extension alone isn't trusted.
    static func requiresSignature(_ f: FileFormat) -> Bool {
        switch f {
        case .png, .jpeg, .gif, .bmp, .tiff, .pdf, .webp, .heic, .avif, .docx, .odt, .doc, .rtf, .wav, .aiff, .flac, .caf: true
        default: false
        }
    }

    static func compatible(_ a: FileFormat, _ b: FileFormat) -> Bool {
        let groups: [Set<FileFormat>] = [[.heic, .avif], [.m4a, .mp4, .mov, .aac], [.txt, .markdown, .html, .svg], [.docx, .odt]]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Reads the first bytes and matches well-known signatures.
    public func sniff(_ url: URL) -> FileFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else { return nil }
        let b = [UInt8](data)
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + sig.count && Array(b[offset..<offset + sig.count]) == sig
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if ascii("BM") && b.count > 14 { return .bmp }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("%PDF-") { return .pdf }
        if ascii("RIFF") && ascii("WEBP", at: 8) { return .webp }
        if ascii("RIFF") && ascii("WAVE", at: 8) { return .wav }
        if ascii("FORM") && (ascii("AIFF", at: 8) || ascii("AIFC", at: 8)) { return .aiff }
        if ascii("fLaC") { return .flac }
        if ascii("caff") { return .caf }
        if ascii("ID3") || (b.count > 1 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 && (b[1] & 0x06) != 0) { return .mp3 }
        if b.count > 1 && b[0] == 0xFF && (b[1] & 0xF6) == 0xF0 { return .aac }
        if ascii("ftyp", at: 4) {
            let brand = String(bytes: b[8..<min(12, b.count)], encoding: .ascii) ?? ""
            switch brand {
            case "heic", "heix", "heim", "heis", "mif1", "msf1", "hevc": return .heic
            case "avif", "avis": return .avif
            case "M4A ", "M4B ": return .m4a
            case "qt  ": return .mov
            default: return .mp4
            }
        }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .doc }
        if ascii("{\\rtf") { return .rtf }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return zipDocumentKind(url) }

        // Text-ish content: decide between SVG, HTML and plain text.
        if let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(3), encoding: .utf8) {
            let lower = text.lowercased()
            if lower.contains("<svg") { return .svg }
            let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return .html }
            if !b.contains(0) { return .txt }
        }
        return nil
    }

    /// DOCX and ODT are ZIP archives; peek at the local file headers to tell them apart.
    func zipDocumentKind(_ url: URL) -> FileFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        try? handle.close()
        let s = String(decoding: data, as: UTF8.self)
        if s.contains("mimetypeapplication/vnd.oasis.opendocument.text") { return .odt }
        if s.contains("word/") || s.contains("[Content_Types].xml") {
            // [Content_Types].xml is shared by xlsx/pptx; require word/ to claim DOCX.
            return s.contains("word/") ? .docx : nil
        }
        return nil
    }
}

/// Gathers the facts about a file that matter for caveats (alpha, animation, pages, encryption).
public struct FileInspector: Sendable {
    public init() {}

    public func facts(for url: URL, format: FileFormat) -> FileFacts {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]))
        var facts = FileFacts(url: url, format: format, byteCount: Int64(size?.fileSize ?? size?.totalFileAllocatedSize ?? 0))
        facts.isScreenshot = Self.isScreenshot(url)
        switch format.category {
        case .image where format != .svg:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { break }
            facts.frameCount = max(1, CGImageSourceGetCount(src))
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                facts.hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
                facts.pixelWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
                facts.pixelHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            }
            facts.isAnimated = format == .gif && facts.frameCount > 1
            facts.pageCount = facts.frameCount
        case .image:
            facts.hasAlpha = true
        case .pdf:
            if let doc = CGPDFDocument(url as CFURL) {
                facts.isEncrypted = doc.isEncrypted && !doc.isUnlocked
                facts.pageCount = doc.numberOfPages
            }
        default:
            break
        }
        return facts
    }

    /// macOS tags screenshots with kMDItemIsScreenCapture; fall back to the default naming scheme.
    public static func isScreenshot(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") || name.hasPrefix("CleanShot ") { return true }
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, attr, nil, 0, 0, 0)
        return size > 0
    }
}
