import Foundation

/// Runs one conversion end to end: validate → plan → convert in scratch space → finalize atomically.
public struct ConversionCoordinator: Sendable {
    public let registry: ConversionRegistry
    public let detector = FileTypeDetector()
    public let inspector = FileInspector()
    public let locator = OutputLocator()

    public init(registry: ConversionRegistry) {
        self.registry = registry
    }

    /// Describes a file for planning, or throws a readable error.
    public func inspect(_ url: URL) throws -> FileFacts {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FormaError.fileNotFound(url) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FormaError.unreadable(url.lastPathComponent) }
        guard let format = detector.format(of: url) else { throw FormaError.unsupportedInput(url.lastPathComponent) }
        return inspector.facts(for: url, format: format)
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        registry.caveats(for: facts, to: output, options: options)
    }

    /// Converts `source` into `directory`. Output names derive from the source name.
    public func convert(_ source: URL, to output: FileFormat, options: ConversionOptions = ConversionOptions(),
                        into directory: URL, baseName: String? = nil,
                        progress: @escaping ProgressHandler = { _ in }) async throws -> ConversionResult {
        let facts = try inspect(source)
        if facts.isEncrypted { throw FormaError.passwordProtected(source.lastPathComponent) }
        guard let cap = registry.capability(from: facts.format, to: output) else {
            throw FormaError.unsupportedConversion(from: facts.format, to: output)
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw FormaError.destinationNotWritable(directory) }
        try OutputLocator.checkFreeSpace(at: directory, needed: OutputLocator.estimatedOutputSize(input: facts.byteCount, facts: facts, output: output, dpi: options.pdfRenderDPI))

        let base = OutputLocator.sanitize(baseName ?? source.deletingPathExtension().lastPathComponent)
        let work = try OutputLocator.makeWorkDirectory(near: directory)
        defer { try? FileManager.default.removeItem(at: work) }

        var caveats: [Caveat] = []
        let produced: ProviderResult
        do {
            if let via = cap.via {
                guard let firstCap = registry.capability(from: facts.format, to: via), firstCap.via == nil,
                      let p1 = registry.provider(id: firstCap.providerID),
                      let p2 = registry.provider(id: cap.providerID) else {
                    throw FormaError.unsupportedConversion(from: facts.format, to: output)
                }
                let step1Dir = work.appendingPathComponent("step1", isDirectory: true)
                let step2Dir = work.appendingPathComponent("step2", isDirectory: true)
                try FileManager.default.createDirectory(at: step1Dir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: step2Dir, withIntermediateDirectories: true)
                let r1 = try await p1.convert(ConversionJob(input: source, inputFormat: facts.format, output: via, options: options, workDirectory: step1Dir, baseName: base),
                                              progress: { progress($0 * 0.5) })
                guard r1.files.count == 1 else { throw FormaError.unsupportedConversion(from: facts.format, to: output) }
                try Task.checkCancellation()
                let r2 = try await p2.convert(ConversionJob(input: r1.files[0], inputFormat: via, output: output, options: options, workDirectory: step2Dir, baseName: base),
                                              progress: { progress(0.5 + $0 * 0.5) })
                produced = ProviderResult(files: r2.files, caveats: r1.caveats + r2.caveats)
            } else {
                guard let provider = registry.provider(id: cap.providerID) else { throw FormaError.unsupportedConversion(from: facts.format, to: output) }
                produced = try await provider.convert(ConversionJob(input: source, inputFormat: facts.format, output: output, options: options, workDirectory: work, baseName: base),
                                                      progress: progress)
            }
            try Task.checkCancellation()
            try Self.validate(produced.files, format: output)
        } catch {
            throw FormaError.wrap(error)
        }
        caveats += produced.caveats
        let placed = try locator.finalize(produced.files, into: directory, baseName: base, format: output)
        return ConversionResult(source: source, outputs: placed.outputs, containerFolder: placed.folder, format: output,
                                editability: cap.editability, caveats: caveats)
    }

    /// Never report success for an empty or obviously wrong file.
    static func validate(_ files: [URL], format: FileFormat) throws {
        guard !files.isEmpty else { throw FormaError.encodeFailed(format) }
        for f in files {
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue } // RTFD packages
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw FormaError.encodeFailed(format) }
            if let detected = FileTypeDetector().sniff(f), FileTypeDetector.requiresSignature(format) {
                guard detected == format || FileTypeDetector.compatible(detected, format) else { throw FormaError.encodeFailed(format) }
            }
        }
    }
}
