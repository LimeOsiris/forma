import Foundation

/// One segment of the radial wheel.
public enum WheelAction: Hashable, Sendable, Codable {
    case convert(FileFormat)
    case edit
    case extractText
    case quickLook
    case combinePDF
    case splitPDF
    case more
    case back

    public var title: String {
        switch self {
        case .convert(let f): f.displayName
        case .edit: "Edit"
        case .extractText: "Text"
        case .quickLook: "Preview"
        case .combinePDF: "Combine"
        case .splitPDF: "Split"
        case .more: "More"
        case .back: "Back"
        }
    }

    public var symbolName: String {
        switch self {
        case .convert(let f): f.symbolName
        case .edit: "slider.horizontal.3"
        case .extractText: "text.viewfinder"
        case .quickLook: "eye"
        case .combinePDF: "doc.on.doc"
        case .splitPDF: "square.split.1x2"
        case .more: "ellipsis"
        case .back: "chevron.backward"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .convert(let f): "Convert to \(f.spokenName)"
        case .edit: "Edit in Forma"
        case .extractText: "Extract text"
        case .quickLook: "Quick Look preview"
        case .combinePDF: "Combine into one PDF"
        case .splitPDF: "Split into single-page PDFs"
        case .more: "More formats"
        case .back: "Back to main formats"
        }
    }

    /// Format the history store counts this action under.
    public var trackedFormat: FileFormat? {
        switch self {
        case .convert(let f): f
        case .extractText: .txt
        default: nil
        }
    }
}

public struct WheelPlan: Sendable, Equatable {
    public var primary: [WheelAction]
    public var overflow: [WheelAction]
}

/// Decides which actions appear on the wheel and in what order.
///
/// Membership adapts (frequently used formats earn a primary slot), but order is always the
/// canonical order for the file type, so a format keeps its position once it's on the wheel.
public struct WheelPlanner: Sendable {
    public var registry: ConversionRegistry
    public var maxPrimary: Int

    public init(registry: ConversionRegistry, maxPrimary: Int = 6) {
        self.registry = registry
        self.maxPrimary = min(8, max(4, maxPrimary))
    }

    /// Preferred order per input, most useful first. Unlisted outputs follow in registry order.
    static func canonicalOrder(for format: FileFormat, isScreenshot: Bool) -> [WheelAction] {
        switch format.category {
        case .image:
            var order: [WheelAction]
            if isScreenshot {
                order = [.convert(.jpeg), .convert(.pdf), .convert(.heic), .convert(.webp), .convert(.png)]
            } else if format == .jpeg || format == .heic {
                order = [.convert(.png), .convert(.heic), .convert(.jpeg), .convert(.pdf), .convert(.webp), .convert(.tiff)]
            } else {
                order = [.convert(.jpeg), .convert(.webp), .convert(.heic), .convert(.png), .convert(.tiff), .convert(.pdf)]
            }
            return order + [.edit, .convert(.avif), .convert(.gif), .convert(.bmp), .quickLook]
        case .pdf:
            return [.edit, .extractText, .convert(.png), .convert(.jpeg), .convert(.tiff), .convert(.heic), .splitPDF, .quickLook]
        case .document:
            switch format {
            case .html:
                return [.convert(.pdf), .convert(.markdown), .convert(.txt), .convert(.docx), .edit, .convert(.rtf), .convert(.odt), .quickLook]
            case .rtf, .rtfd:
                return [.convert(.pdf), .convert(.docx), .convert(.txt), .convert(.html), .edit, .convert(.markdown), .convert(.odt), .quickLook]
            default:
                return [.convert(.pdf), .convert(.rtf), .convert(.txt), .convert(.html), .quickLook, .edit, .convert(.markdown), .convert(.docx), .convert(.odt)]
            }
        case .text:
            if format == .markdown {
                return [.convert(.pdf), .convert(.html), .convert(.docx), .edit, .convert(.rtf), .convert(.txt), .convert(.odt), .quickLook]
            }
            return [.convert(.pdf), .convert(.rtf), .convert(.docx), .edit, .convert(.html), .convert(.odt), .quickLook]
        case .audio:
            return [.convert(.m4a), .convert(.mp3), .convert(.wav), .convert(.flac), .convert(.aiff), .convert(.caf), .quickLook]
        case .video:
            return [.convert(.m4a), .convert(.mp4), .convert(.mov), .convert(.wav), .convert(.mp3), .quickLook]
        }
    }

    static func isEditable(_ format: FileFormat) -> Bool {
        switch format.category {
        case .image: format != .svg && format != .gif
        case .pdf, .text: true
        case .document: [.rtf, .rtfd, .html, .docx, .odt, .doc].contains(format)
        default: false
        }
    }

    /// Every action that is genuinely available for one file.
    func available(for facts: FileFacts) -> Set<WheelAction> {
        var set = Set<WheelAction>()
        for cap in registry.destinations(for: facts.format) {
            if facts.format == .pdf && cap.output == .txt { set.insert(.extractText) } else { set.insert(.convert(cap.output)) }
        }
        if Self.isEditable(facts.format) { set.insert(.edit) }
        if facts.format == .pdf && facts.pageCount > 1 { set.insert(.splitPDF) }
        set.insert(.quickLook)
        return set
    }

    public func plan(for files: [FileFacts], usage: UsageStats = UsageStats(), pinned: [FileFormat] = [], adaptive: Bool = true) -> WheelPlan {
        guard let first = files.first else { return WheelPlan(primary: [], overflow: []) }

        let candidates: [WheelAction]
        var mandatory: Set<WheelAction> = []
        if files.count == 1 {
            let available = available(for: first)
            candidates = ordered(available, canonical: Self.canonicalOrder(for: first.format, isScreenshot: first.isScreenshot))
        } else {
            // Multi-file: outputs that at least one file can reach, ranked by how many can.
            let formats = files.map(\.format)
            let reach = registry.anyDestinations(for: formats)
            let dominant = Dictionary(grouping: formats, by: { $0 }).max { $0.value.count < $1.value.count }!.key
            var available = Set(reach.map { WheelAction.convert($0) })
            if formats.allSatisfy({ $0 == .pdf }) { available.remove(.convert(.txt)) }
            if formats.allSatisfy({ $0.category == .image || $0 == .pdf }) {
                available.insert(.combinePDF)
                mandatory.insert(.combinePDF)
            }
            available.insert(.quickLook)
            candidates = ordered(available, canonical: [.combinePDF, .convert(.pdf)] + Self.canonicalOrder(for: dominant, isScreenshot: files.allSatisfy(\.isScreenshot)))
        }

        if candidates.count <= maxPrimary { return WheelPlan(primary: candidates, overflow: []) }

        // Score: canonical rank, then local history, then pins. Highest scores win the slots.
        let slots = maxPrimary - 1 // leave room for "More"
        let inputKey = files.count == 1 ? first.format : nil
        func score(_ a: WheelAction, rank: Int) -> Double {
            var s = 100 - Double(rank) * 10
            if let f = a.trackedFormat {
                if pinned.contains(f) { s += 10_000 }
                if adaptive { s += min(Double(usage.count(from: inputKey, to: f)), 12) * 9 }
            }
            if mandatory.contains(a) { s += 5_000 }
            return s
        }
        let ranked = candidates.enumerated().sorted { score($0.element, rank: $0.offset) > score($1.element, rank: $1.offset) }
        let chosen = Set(ranked.prefix(slots).map(\.element))
        let primary = candidates.filter { chosen.contains($0) } + [.more]
        let overflow = candidates.filter { !chosen.contains($0) }
        return WheelPlan(primary: primary, overflow: overflow)
    }

    func ordered(_ available: Set<WheelAction>, canonical: [WheelAction]) -> [WheelAction] {
        var seen = Set<WheelAction>()
        var result: [WheelAction] = []
        for a in canonical where available.contains(a) && seen.insert(a).inserted { result.append(a) }
        let rest = available.subtracting(seen).sorted { $0.title < $1.title }
        for r in rest where seen.insert(r).inserted { result.append(r) }
        return result
    }
}
