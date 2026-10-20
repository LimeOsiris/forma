import AudioToolbox
import Foundation
import ImageIO

/// Finds optional command-line tools in well-known install locations.
/// GUI apps don't inherit a shell PATH, and we never consult one: only these fixed paths are trusted.
public enum ExternalToolLocator {
    public static func candidates(for tool: ExternalTool) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch tool {
        case .libreOffice:
            return ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        case .ffmpeg:
            return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        case .cwebp:
            return ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp", "/opt/local/bin/cwebp"]
        }
    }

    public static func detect() -> ToolAvailability {
        var paths: [ExternalTool: URL] = [:]
        for tool in ExternalTool.allCases {
            if let path = candidates(for: tool).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                paths[tool] = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        return ToolAvailability(paths: paths)
    }
}

/// Runs a tool with an argument array (never a shell string), honouring cancellation.
public enum ProcessRunner {
    public struct Output: Sendable { public var status: Int32; public var stderr: String }

    public static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil, currentDirectory: URL? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        // Drain stderr continuously so a chatty tool can't block on a full pipe.
        let collected = StderrBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        let box = UncheckedBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Output, Error>) in
                box.value.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collected.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    c.resume(returning: Output(status: p.terminationStatus, stderr: collected.text))
                }
                do { try box.value.run() } catch { c.resume(throwing: error) }
            }
        } onCancel: {
            if box.value.isRunning { box.value.terminate() }
        }
    }
}

/// Keeps the last few KB of a process's stderr.
final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 8192 { data = data.suffix(4096) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data.suffix(4096), as: UTF8.self)
    }
}

/// High-fidelity Office conversion through a locally installed LibreOffice (headless).
public struct LibreOfficeConversionProvider: ConversionProvider {
    public let id = "libreoffice"
    public init() {}

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        guard tools.has(.libreOffice) else { return [] }
        let note = Caveat.info("Converted with LibreOffice, which preserves page layout, tables and images closely.")
        var caps: [ConversionCapability] = []
        for input in [FileFormat.docx, .doc, .odt, .rtf] {
            caps.append(ConversionCapability(input: input, output: .pdf, providerID: id, isLossless: false,
                                             editability: .annotationOnly, requiredTool: .libreOffice, priority: 5, notes: [note]))
        }
        for (i, o) in [(FileFormat.doc, FileFormat.docx), (.odt, .docx), (.docx, .odt), (.doc, .odt)] {
            caps.append(ConversionCapability(input: i, output: o, providerID: id, isLossless: false,
                                             editability: .full, requiredTool: .libreOffice, priority: 5, notes: [note]))
        }
        return caps
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        guard let soffice = ExternalToolLocator.detect().path(.libreOffice) else { throw FormaError.missingTool(.libreOffice) }
        let outDir = job.workDirectory.appendingPathComponent("lo-out", isDirectory: true)
        let profile = job.workDirectory.appendingPathComponent("lo-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter: String = switch job.output {
        case .pdf: "pdf"
        case .docx: "docx:\"MS Word 2007 XML\""
        case .odt: "odt"
        default: job.output.preferredExtension
        }
        progress(0.1)
        // A private profile avoids clashing with a running LibreOffice instance.
        let result = try await ProcessRunner.run(soffice, arguments: [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--norestore", "--nolockcheck", "--nodefault",
            "--convert-to", filter.replacingOccurrences(of: "\"", with: ""),
            "--outdir", outDir.path,
            job.input.path,
        ])
        try Task.checkCancellation()
        let produced = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard result.status == 0, let file = produced.first(where: { $0.pathExtension.lowercased() == job.output.preferredExtension }) else {
            throw FormaError.toolFailed(.libreOffice, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let final = job.defaultOutputURL
        try FileManager.default.moveItem(at: file, to: final)
        try? FileManager.default.removeItem(at: profile)
        progress(1)
        return ProviderResult(files: [final])
    }
}

/// MP3 (and other encoders macOS lacks) through a locally installed FFmpeg.
public struct FFmpegConversionProvider: ConversionProvider {
    public let id = "ffmpeg"
    public init() {}

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        guard tools.has(.ffmpeg) else { return [] }
        var caps: [ConversionCapability] = []
        for input in AudioConversionProvider.audioInputs where input != .mp3 {
            caps.append(ConversionCapability(input: input, output: .mp3, providerID: id, isLossless: false,
                                             editability: .viewOnly, requiredTool: .ffmpeg, priority: 30,
                                             notes: [.info("Encoded with FFmpeg (LAME, VBR quality 2).")]))
        }
        if !AudioConversionProvider.encoderAvailable(kAudioFormatFLAC) {
            for input in AudioConversionProvider.audioInputs where input != .flac {
                caps.append(ConversionCapability(input: input, output: .flac, providerID: id, isLossless: !input.isLossyByNature,
                                                 editability: .viewOnly, requiredTool: .ffmpeg, priority: 30))
            }
        }
        return caps
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        guard let ffmpeg = ExternalToolLocator.detect().path(.ffmpeg) else { throw FormaError.missingTool(.ffmpeg) }
        let out = job.defaultOutputURL
        let codec: [String] = job.output == .mp3 ? ["-codec:a", "libmp3lame", "-q:a", "2"] : ["-codec:a", "flac"]
        // Absolute paths always start with "/", so a filename can never be read as an option.
        let result = try await ProcessRunner.run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-n",
                                                                     "-i", job.input.path, "-vn", "-map_metadata", "0"] + codec + [out.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw FormaError.toolFailed(.ffmpeg, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress(1)
        return ProviderResult(files: [out])
    }
}

/// WebP output through libwebp's `cwebp`, since macOS can read but not write WebP.
public struct WebPEncoderProvider: ConversionProvider {
    public let id = "cwebp"
    public init() {}

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        guard tools.has(.cwebp) else { return [] }
        return [FileFormat.png, .jpeg, .heic, .avif, .tiff, .bmp, .gif].map {
            ConversionCapability(input: $0, output: .webp, providerID: id, isLossless: false, preservesTransparency: true,
                                 editability: .full, requiredTool: .cwebp, priority: 30)
        }
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        facts.isAnimated ? [.confirm("Only the first of \(facts.frameCount) animation frames will be kept.")] : []
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        guard let cwebp = ExternalToolLocator.detect().path(.cwebp) else { throw FormaError.missingTool(.cwebp) }
        // cwebp reads PNG/JPEG/TIFF; normalise everything to an oriented PNG first.
        guard let source = CGImageSourceCreateWithURL(job.input as CFURL, nil),
              let image = ImageConversionProvider.orientedImage(source, index: 0, maxPixelSize: job.options.maxPixelSize) else {
            throw FormaError.corrupted(job.input.lastPathComponent)
        }
        let png = job.workDirectory.appendingPathComponent("cwebp-input.png")
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) else { throw FormaError.encodeFailed(.webp) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(.webp) }
        let out = job.defaultOutputURL
        let result = try await ProcessRunner.run(cwebp, arguments: ["-quiet", "-mt", "-metadata", "icc", "-q", String(Int(job.options.quality * 100)), png.path, "-o", out.path])
        try? FileManager.default.removeItem(at: png)
        guard result.status == 0 else { throw FormaError.toolFailed(.cwebp, result.stderr) }
        progress(1)
        return ProviderResult(files: [out])
    }
}
