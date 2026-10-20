import Foundation

/// Where converted files go.
public enum OutputPolicy: Codable, Sendable, Equatable {
    case besideOriginal
    case folder(URL)
    case ask
}

/// Chooses destinations, produces safe non-conflicting names and moves finished
/// files into place without ever overwriting anything.
public struct OutputLocator: Sendable {
    public init() {}

    /// Strips path separators, control characters and leading dots so a name can never
    /// escape its directory or become hidden.
    public static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == ".." { s = "Converted" }
        // Stay well inside the 255-byte filename limit, leaving room for " 999.extension".
        while s.utf8.count > 200 { s.removeLast() }
        return s
    }

    /// `name.ext`, then `name 2.ext`, `name 3.ext`, … — the first that doesn't exist.
    public static func uniqueURL(in directory: URL, baseName: String, pathExtension ext: String?, fileManager: FileManager = .default) -> URL {
        let base = sanitize(baseName)
        func make(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = directory.appendingPathComponent(name, isDirectory: ext == nil)
            if let ext, !ext.isEmpty { return url.appendingPathExtension(ext) }
            return url
        }
        var n = 1
        while fileManager.fileExists(atPath: make(n).path) && n < 10_000 { n += 1 }
        return make(n)
    }

    /// Resolves the destination directory and verifies Forma can write there.
    public func destinationDirectory(for source: URL, policy: OutputPolicy, fileManager: FileManager = .default) throws -> URL {
        let dir: URL
        switch policy {
        case .besideOriginal, .ask: dir = source.deletingLastPathComponent()
        case .folder(let url): dir = url
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw FormaError.fileNotFound(dir)
        }
        guard fileManager.isWritableFile(atPath: dir.path) else { throw FormaError.destinationNotWritable(dir) }
        return dir
    }

    /// Ensures there is room for the result before any work starts.
    public static func checkFreeSpace(at directory: URL, needed: Int64) throws {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? Int.max)
        if available < needed { throw FormaError.insufficientDiskSpace(needed: needed, available: available) }
    }

    /// Rough upper bound of output size so we can fail fast on a full disk.
    public static func estimatedOutputSize(input bytes: Int64, facts: FileFacts?, output: FileFormat, dpi: Double) -> Int64 {
        var estimate = max(bytes * 4, 8 * 1024 * 1024)
        if let f = facts, f.format == .pdf, output.category == .image {
            let pagePixels = Int64((8.5 * dpi) * (11 * dpi))
            estimate = max(estimate, Int64(f.pageCount) * pagePixels * 4)
        }
        return estimate
    }

    /// A scratch directory on the same volume as `destination` when possible, so the
    /// final move is an atomic rename and half-written files are never visible.
    public static func makeWorkDirectory(near destination: URL, fileManager: FileManager = .default) throws -> URL {
        if let dir = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true) {
            return dir
        }
        let dir = fileManager.temporaryDirectory.appendingPathComponent("Forma-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves provider output into `directory`. Multiple files are grouped in a new folder.
    /// Never overwrites: on a name collision (even one that appears mid-move) the next number is used.
    public func finalize(_ files: [URL], into directory: URL, baseName: String, format: FileFormat, folderName: String? = nil, fileManager: FileManager = .default) throws -> (outputs: [URL], folder: URL?) {
        guard !files.isEmpty else { throw FormaError.encodeFailed(format) }
        if files.count == 1 {
            let src = files[0]
            let ext = src.pathExtension.isEmpty ? format.preferredExtension : src.pathExtension
            let final = try Self.moveWithoutOverwrite(src, into: directory, baseName: baseName, ext: ext, fileManager: fileManager)
            return ([final], nil)
        }
        // Assemble the folder in the work area, then move it as one unit.
        let staging = files[0].deletingLastPathComponent().appendingPathComponent("forma-group-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for f in files { try fileManager.moveItem(at: f, to: staging.appendingPathComponent(f.lastPathComponent)) }
        let folder = try Self.moveWithoutOverwrite(staging, into: directory, baseName: folderName ?? "\(baseName) (\(format.displayName))", ext: nil, fileManager: fileManager)
        let outputs = files.map { folder.appendingPathComponent($0.lastPathComponent) }
        return (outputs, folder)
    }

    static func moveWithoutOverwrite(_ src: URL, into directory: URL, baseName: String, ext: String?, fileManager: FileManager) throws -> URL {
        // Cross-volume moves copy; copy to a hidden name first so a partial copy is never mistaken for a result.
        let sameVolume = Self.volume(of: src) == Self.volume(of: directory)
        var staged = src
        if !sameVolume {
            staged = directory.appendingPathComponent(".forma-partial-\(UUID().uuidString)")
            try fileManager.copyItem(at: src, to: staged)
        }
        for _ in 0..<50 {
            let target = uniqueURL(in: directory, baseName: baseName, pathExtension: ext, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: staged, to: target)
                if !sameVolume { try? fileManager.removeItem(at: src) }
                return target
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue // someone created that name between our check and the move; try the next one
            } catch {
                if !sameVolume { try? fileManager.removeItem(at: staged) }
                throw FormaError.wrap(error)
            }
        }
        throw FormaError.destinationNotWritable(directory)
    }

    static func volume(of url: URL) -> AnyHashable? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
    }
}
