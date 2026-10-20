import Foundation

/// How editable the produced file is, communicated honestly in the UI.
public enum Editability: String, Codable, Sendable, CaseIterable {
    /// Text and structure remain fully editable (e.g. Markdown → TXT, DOCX → RTF for simple docs).
    case full
    /// Editable, but some formatting or structure may not survive (e.g. DOCX via the macOS text engine).
    case limited
    /// Content is fixed; only annotations, markup and page operations are possible (e.g. anything → PDF).
    case annotationOnly
    /// The result is pixels; text is no longer text (e.g. PDF → PNG, PNG → PDF).
    case rasterized
    /// No editing offered.
    case viewOnly

    public var label: String {
        switch self {
        case .full: "Fully editable"
        case .limited: "Editable with limitations"
        case .annotationOnly: "Annotations only"
        case .rasterized: "Image content"
        case .viewOnly: "View only"
        }
    }

    public var detail: String {
        switch self {
        case .full: "Text and structure stay editable."
        case .limited: "Some formatting may not survive editing."
        case .annotationOnly: "You can mark up, sign and rearrange pages, but not rewrite the original text."
        case .rasterized: "Text becomes part of an image and can't be edited as text."
        case .viewOnly: "This file can be viewed but not edited in Forma."
        }
    }
}

/// Identifies optional third-party command-line tools Forma can use when present.
public enum ExternalTool: String, Codable, Sendable, CaseIterable {
    case libreOffice
    case ffmpeg
    case cwebp

    public var displayName: String {
        switch self {
        case .libreOffice: "LibreOffice"
        case .ffmpeg: "FFmpeg"
        case .cwebp: "cwebp (libwebp)"
        }
    }

    public var purpose: String {
        switch self {
        case .libreOffice: "High-fidelity Word, ODT and legacy Office conversion"
        case .ffmpeg: "MP3 and additional audio encoders"
        case .cwebp: "WebP image encoding"
        }
    }

    public var license: String {
        switch self {
        case .libreOffice: "MPL 2.0"
        case .ffmpeg: "LGPL 2.1+ / GPL depending on build"
        case .cwebp: "BSD 3-Clause"
        }
    }
}

/// A warning surfaced to the user before or after a conversion.
public struct Caveat: Hashable, Codable, Sendable {
    public enum Severity: String, Codable, Sendable { case info, warning, requiresConfirmation }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }

    public static func info(_ m: String) -> Caveat { Caveat(.info, m) }
    public static func warning(_ m: String) -> Caveat { Caveat(.warning, m) }
    public static func confirm(_ m: String) -> Caveat { Caveat(.requiresConfirmation, m) }
}

/// Static description of one input → output path a provider offers.
public struct ConversionCapability: Hashable, Sendable {
    public var input: FileFormat
    public var output: FileFormat
    public var providerID: String
    public var isLossless: Bool
    public var preservesMetadata: Bool
    public var preservesTransparency: Bool
    public var editability: Editability
    public var requiredTool: ExternalTool?
    /// Lower is preferred when two providers offer the same pair.
    public var priority: Int
    /// Static notes always true for this path ("Uses the macOS text engine", …).
    public var notes: [Caveat]
    /// Set when the registry composed two steps; names the intermediate format.
    public var via: FileFormat?

    public init(
        input: FileFormat,
        output: FileFormat,
        providerID: String,
        isLossless: Bool,
        preservesMetadata: Bool = false,
        preservesTransparency: Bool = false,
        editability: Editability,
        requiredTool: ExternalTool? = nil,
        priority: Int = 100,
        notes: [Caveat] = [],
        via: FileFormat? = nil
    ) {
        self.input = input
        self.output = output
        self.providerID = providerID
        self.isLossless = isLossless
        self.preservesMetadata = preservesMetadata
        self.preservesTransparency = preservesTransparency
        self.editability = editability
        self.requiredTool = requiredTool
        self.priority = priority
        self.notes = notes
        self.via = via
    }
}

/// User-tunable, format-aware options. Every field has a sensible default.
public struct ConversionOptions: Hashable, Codable, Sendable {
    /// 0...1 for JPEG / HEIC / AVIF / WebP.
    public var quality: Double = 0.85
    /// Longest edge in pixels; nil keeps the original size.
    public var maxPixelSize: Int? = nil
    /// Rendering resolution for PDF → image.
    public var pdfRenderDPI: Double = 150
    /// Background used when flattening transparency into formats without alpha.
    public var flattenBackgroundWhite: Bool = true
    /// Run Vision OCR when a PDF has no text layer.
    public var ocrWhenNoText: Bool = true
    /// Accept loss of animation for animated GIF sources without asking again.
    public var acceptFirstFrameOnly: Bool = false

    public init() {}
}

/// Facts about a specific input file that influence caveats and planning.
public struct FileFacts: Hashable, Sendable {
    public var url: URL
    public var format: FileFormat
    public var byteCount: Int64
    public var hasAlpha: Bool = false
    public var frameCount: Int = 1
    public var isAnimated: Bool = false
    public var pageCount: Int = 1
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var isEncrypted: Bool = false
    public var isScreenshot: Bool = false

    public init(url: URL, format: FileFormat, byteCount: Int64) {
        self.url = url
        self.format = format
        self.byteCount = byteCount
    }
}

/// A single unit of conversion work handed to a provider.
public struct ConversionJob: Sendable {
    public var input: URL
    public var inputFormat: FileFormat
    public var output: FileFormat
    public var options: ConversionOptions
    /// Empty scratch directory the provider must write into. Forma moves results
    /// into place atomically afterwards, so a provider never touches the final location.
    public var workDirectory: URL
    /// Base file name (no extension) the provider should use for its outputs.
    public var baseName: String

    public init(input: URL, inputFormat: FileFormat, output: FileFormat, options: ConversionOptions, workDirectory: URL, baseName: String) {
        self.input = input
        self.inputFormat = inputFormat
        self.output = output
        self.options = options
        self.workDirectory = workDirectory
        self.baseName = baseName
    }

    /// Conventional single-output location inside the work directory.
    public var defaultOutputURL: URL {
        workDirectory.appendingPathComponent(baseName).appendingPathExtension(output.preferredExtension)
    }
}

/// What a provider produced inside its work directory.
public struct ProviderResult: Sendable {
    /// One file, or several when the conversion naturally splits (PDF pages → PNGs).
    public var files: [URL]
    /// True when `files` should be grouped into a folder at the destination.
    public var isMultiFile: Bool { files.count > 1 }
    /// Caveats discovered while converting (e.g. "Only the first frame was kept").
    public var caveats: [Caveat]

    public init(files: [URL], caveats: [Caveat] = []) {
        self.files = files
        self.caveats = caveats
    }
}

/// The finalized, user-visible outcome of a conversion.
public struct ConversionResult: Sendable, Hashable {
    public var source: URL
    public var outputs: [URL]
    /// Folder containing outputs when the conversion produced several files.
    public var containerFolder: URL?
    public var format: FileFormat
    public var editability: Editability
    public var caveats: [Caveat]

    /// The URL to reveal / open: the folder for multi-file results, the file otherwise.
    public var primaryURL: URL { containerFolder ?? outputs.first ?? source }

    public init(source: URL, outputs: [URL], containerFolder: URL?, format: FileFormat, editability: Editability, caveats: [Caveat]) {
        self.source = source
        self.outputs = outputs
        self.containerFolder = containerFolder
        self.format = format
        self.editability = editability
        self.caveats = caveats
    }
}

public typealias ProgressHandler = @Sendable (Double) -> Void
