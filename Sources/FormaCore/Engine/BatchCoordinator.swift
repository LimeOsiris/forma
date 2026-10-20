import Foundation

/// What to do with several files at once.
public enum BatchMode: Sendable, Equatable {
    /// Convert each compatible file on its own.
    case each(FileFormat)
    /// Put every image/PDF page into one PDF, in selection order.
    case combinePDF
}

public struct BatchPlan: Sendable {
    public struct Item: Sendable, Hashable {
        public var url: URL
        public var format: FileFormat
    }
    public var mode: BatchMode
    public var items: [Item]
    public var skipped: [(url: URL, reason: String)]

    public var isEmpty: Bool { items.isEmpty }
}

public struct BatchReport: Sendable {
    public var results: [ConversionResult] = []
    public var failures: [(url: URL, message: String)] = []
    public var skipped: [(url: URL, reason: String)] = []
    public var cancelled = false

    public var summary: String {
        var parts: [String] = []
        let n = results.count
        if n > 0 { parts.append("\(n) file\(n == 1 ? "" : "s") converted") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if cancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing to convert" : parts.joined(separator: " · ")
    }
}

/// Plans and runs multi-file conversions with overall progress and cancellation.
public struct BatchCoordinator: Sendable {
    public let coordinator: ConversionCoordinator

    public init(coordinator: ConversionCoordinator) { self.coordinator = coordinator }

    public func plan(_ urls: [URL], mode: BatchMode) -> BatchPlan {
        var items: [BatchPlan.Item] = []
        var skipped: [(URL, String)] = []
        var seen = Set<URL>()
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            guard let facts = try? coordinator.inspect(url) else {
                skipped.append((url, "Unsupported or unreadable file"))
                continue
            }
            switch mode {
            case .each(let out):
                if facts.format == out {
                    skipped.append((url, "Already \(out.displayName)"))
                } else if coordinator.registry.canConvert(facts.format, to: out) {
                    items.append(.init(url: url, format: facts.format))
                } else {
                    skipped.append((url, "Can't convert \(facts.format.displayName) to \(out.displayName)"))
                }
            case .combinePDF:
                if facts.format.category == .image || facts.format == .pdf {
                    if facts.isEncrypted { skipped.append((url, "Password protected")) } else { items.append(.init(url: url, format: facts.format)) }
                } else {
                    skipped.append((url, "Only images and PDFs can be combined"))
                }
            }
        }
        return BatchPlan(mode: mode, items: items, skipped: skipped.map { (url: $0.0, reason: $0.1) })
    }

    /// Runs the plan. Individual failures don't stop the batch; cancellation does.
    public func run(_ plan: BatchPlan, options: ConversionOptions, policy: OutputPolicy,
                    progress: @escaping @Sendable (_ fraction: Double, _ current: String) -> Void) async -> BatchReport {
        var report = BatchReport()
        report.skipped = plan.skipped
        switch plan.mode {
        case .combinePDF:
            guard let first = plan.items.first else { return report }
            do {
                let dir = try coordinator.locator.destinationDirectory(for: first.url, policy: policy)
                let work = try OutputLocator.makeWorkDirectory(near: dir)
                defer { try? FileManager.default.removeItem(at: work) }
                progress(0.1, first.url.lastPathComponent)
                let allPDF = plan.items.allSatisfy { $0.format == .pdf }
                let base = allPDF ? "Merged" : "Combined"
                let tmp = work.appendingPathComponent("\(base).pdf")
                if allPDF {
                    try PDFOperations.merge(plan.items.map(\.url), to: tmp)
                } else {
                    try PDFOperations.combine(plan.items.map { ($0.url, $0.format) }, to: tmp, options: options)
                }
                let placed = try coordinator.locator.finalize([tmp], into: dir, baseName: base, format: .pdf)
                report.results.append(ConversionResult(source: first.url, outputs: placed.outputs, containerFolder: nil, format: .pdf,
                                                       editability: allPDF ? .annotationOnly : .rasterized, caveats: []))
                progress(1, "")
            } catch {
                let e = FormaError.wrap(error)
                if e == .cancelled { report.cancelled = true } else { report.failures.append((first.url, e.localizedDescription)) }
            }
            return report

        case .each(let output):
            let total = Double(max(plan.items.count, 1))
            for (index, item) in plan.items.enumerated() {
                if Task.isCancelled { report.cancelled = true; break }
                progress(Double(index) / total, item.url.lastPathComponent)
                do {
                    let dir = try coordinator.locator.destinationDirectory(for: item.url, policy: policy)
                    let result = try await coordinator.convert(item.url, to: output, options: options, into: dir) { p in
                        progress((Double(index) + p) / total, item.url.lastPathComponent)
                    }
                    report.results.append(result)
                } catch {
                    let e = FormaError.wrap(error)
                    if e == .cancelled { report.cancelled = true; break }
                    report.failures.append((item.url, e.localizedDescription))
                }
            }
            progress(1, "")
            return report
        }
    }
}
