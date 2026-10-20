import Foundation

/// How often each destination has been chosen, overall and per input format.
public struct UsageStats: Codable, Sendable, Equatable {
    /// Keys are "input>output" and "*>output".
    public var counts: [String: Int] = [:]

    public init() {}

    public func count(from input: FileFormat?, to output: FileFormat) -> Int {
        if let input, let c = counts["\(input.rawValue)>\(output.rawValue)"] { return c }
        return (counts["*>\(output.rawValue)"] ?? 0) / 2
    }

    public mutating func record(from input: FileFormat?, to output: FileFormat) {
        if let input { counts["\(input.rawValue)>\(output.rawValue)", default: 0] += 1 }
        counts["*>\(output.rawValue)", default: 0] += 1
    }
}

public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var source: URL
    public var output: URL
    public var format: FileFormat
}

/// Local-only conversion history: a small JSON file in Application Support. Never uploaded.
public final class HistoryStore: @unchecked Sendable {
    struct Payload: Codable {
        var recent: [HistoryEntry] = []
        var usage = UsageStats()
    }

    private let url: URL
    private let lock = NSLock()
    private var payload: Payload
    public static let maxRecent = 30

    public init(fileURL: URL) {
        self.url = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload()
        }
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Forma", isDirectory: true).appendingPathComponent("history.json")
    }

    public var usage: UsageStats { lock.withLock { payload.usage } }

    /// Recent conversions whose outputs still exist.
    public var recent: [HistoryEntry] {
        lock.withLock { payload.recent }.filter { FileManager.default.fileExists(atPath: $0.output.path) }
    }

    /// Records a choice for adaptive ordering (always) and the result for the Recent menu (when enabled).
    public func record(input: FileFormat?, output: FileFormat, source: URL?, result: URL?, keepHistory: Bool) {
        lock.withLock {
            payload.usage.record(from: input, to: output)
            if keepHistory, let source, let result {
                payload.recent.insert(HistoryEntry(date: Date(), source: source, output: result, format: output), at: 0)
                if payload.recent.count > Self.maxRecent { payload.recent.removeLast(payload.recent.count - Self.maxRecent) }
            }
        }
        save()
    }

    /// Forgets recent files but keeps the usage counts that drive wheel ordering.
    public func clearRecent() {
        lock.withLock { payload.recent.removeAll() }
        save()
    }

    public func clear() {
        lock.withLock { payload = Payload() }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(payload) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
