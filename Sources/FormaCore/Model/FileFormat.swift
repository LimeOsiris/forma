import Foundation
import UniformTypeIdentifiers

/// Broad family a format belongs to. Drives which editor and which wheel defaults apply.
public enum FormatCategory: String, Codable, Sendable, CaseIterable {
    case image
    case pdf
    case document
    case text
    case audio
    case video
}

/// Every concrete file format Forma knows how to read or write.
///
/// Knowing a format does not imply a conversion exists; the `ConversionRegistry`
/// is the single source of truth for which input → output pairs are supported.
public enum FileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    // Images
    case png, jpeg, heic, avif, webp, tiff, bmp, gif, svg
    // PDF
    case pdf
    // Rich documents
    case docx, doc, odt, rtf, rtfd, html
    // Plain text
    case txt, markdown
    // Audio
    case m4a, wav, aiff, caf, mp3, flac, aac
    // Video (only used as an audio source / container rewrap)
    case mov, mp4

    public var id: String { rawValue }

    public var category: FormatCategory {
        switch self {
        case .png, .jpeg, .heic, .avif, .webp, .tiff, .bmp, .gif, .svg: .image
        case .pdf: .pdf
        case .docx, .doc, .odt, .rtf, .rtfd, .html: .document
        case .txt, .markdown: .text
        case .m4a, .wav, .aiff, .caf, .mp3, .flac, .aac: .audio
        case .mov, .mp4: .video
        }
    }

    /// Short label shown in the wheel.
    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .svg: "SVG"
        case .pdf: "PDF"
        case .docx: "Word"
        case .doc: "Word 97"
        case .odt: "ODT"
        case .rtf: "RTF"
        case .rtfd: "RTFD"
        case .html: "HTML"
        case .txt: "Text"
        case .markdown: "Markdown"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        case .mp3: "MP3"
        case .flac: "FLAC"
        case .aac: "AAC"
        case .mov: "MOV"
        case .mp4: "MP4"
        }
    }

    /// Longer, VoiceOver-friendly name.
    public var spokenName: String {
        switch self {
        case .docx: "Word document"
        case .doc: "Word 97 document"
        case .odt: "OpenDocument text"
        case .rtf: "Rich Text"
        case .rtfd: "Rich Text with attachments"
        case .txt: "plain text"
        case .html: "web page"
        default: displayName
        }
    }

    public var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .markdown: "md"
        case .txt: "txt"
        case .html: "html"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    /// Extensions that map to this format when the system can't tell us via UTType.
    public var knownExtensions: [String] {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .tiff: ["tif", "tiff"]
        case .heic: ["heic", "heif", "hif"]
        case .markdown: ["md", "markdown", "mdown", "mkd", "mdtext"]
        case .txt: ["txt", "text", "log"]
        case .html: ["html", "htm", "xhtml"]
        case .aiff: ["aiff", "aif"]
        case .aac: ["aac", "adts"]
        default: [rawValue]
        }
    }

    public var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .image
        case .webp: .webP
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        case .svg: .svg
        case .pdf: .pdf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .doc: UTType("com.microsoft.word.doc") ?? .data
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .html: .html
        case .txt: .plainText
        case .markdown: UTType("net.daringfireball.markdown") ?? .plainText
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        case .caf: UTType("com.apple.coreaudio-format") ?? .audio
        case .mp3: .mp3
        case .flac: UTType("org.xiph.flac") ?? .audio
        case .aac: UTType("public.aac-audio") ?? .audio
        case .mov: .quickTimeMovie
        case .mp4: .mpeg4Movie
        }
    }

    /// ImageIO type identifier used for writing, when ImageIO is the encoder.
    public var imageIOIdentifier: String? {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .bmp: "com.microsoft.bmp"
        case .gif: "com.compuserve.gif"
        default: nil
        }
    }

    public var symbolName: String {
        switch self {
        case .png, .jpeg, .heic, .avif, .webp, .bmp: "photo"
        case .tiff: "photo.stack"
        case .gif: "square.stack.3d.forward.dottedline"
        case .svg: "scribble.variable"
        case .pdf: "doc.richtext"
        case .docx, .doc, .odt: "doc.text"
        case .rtf, .rtfd: "textformat"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .txt: "text.alignleft"
        case .markdown: "number"
        case .m4a, .aac, .mp3: "waveform"
        case .wav, .aiff, .caf, .flac: "waveform.path"
        case .mov, .mp4: "film"
        }
    }

    public var supportsTransparency: Bool {
        switch self {
        case .png, .heic, .avif, .webp, .tiff, .gif, .svg, .pdf: true
        default: false
        }
    }

    public var supportsMultipleFrames: Bool {
        switch self {
        case .gif, .tiff, .pdf: true
        default: false
        }
    }

    public var isLossyByNature: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .mp3, .aac, .m4a: true
        default: false
        }
    }

    public static func from(extension ext: String) -> FileFormat? {
        let lower = ext.lowercased()
        return allCases.first { $0.knownExtensions.contains(lower) }
    }
}
