import AppKit
import FormaCore
import Observation

/// Everything the wheel shows, as observable state. The controller drives it;
/// the SwiftUI view only renders it and reports interactions.
@MainActor
@Observable
final class RadialMenuModel {
    enum Stage: Equatable { case primary, overflow }

    enum Phase: Equatable {
        /// Picking a destination.
        case choosing
        /// Format options (quality, size, resolution) or a confirmation before converting.
        case options(WheelAction)
        case working(progress: Double?, label: String)
        case done(DoneInfo)
        case failed(title: String, message: String)
    }

    struct DoneInfo: Equatable {
        var title: String
        var detail: String
        var primaryURL: URL
        var allOutputs: [URL]
        var editable: Bool
        var editability: Editability?
        var notes: [String]
    }

    let files: [FileFacts]
    var plan: WheelPlan
    var stage: Stage = .primary
    var phase: Phase = .choosing
    var hovered: Int?
    var keyboardFocus: Int?
    var options: ConversionOptions
    /// Caveats for the hovered action, computed lazily.
    var caveatCache: [WheelAction: [Caveat]] = [:]
    var appeared = false
    /// A conversion was started; ignore further picks until it settles.
    var busy = false
    var reduceMotion: Bool
    var accent: NSColor
    var diameter: CGFloat

    init(files: [FileFacts], plan: WheelPlan, options: ConversionOptions, reduceMotion: Bool, accent: NSColor, diameter: CGFloat) {
        self.files = files
        self.plan = plan
        self.options = options
        self.reduceMotion = reduceMotion
        self.accent = accent
        self.diameter = diameter
    }

    var actions: [WheelAction] {
        switch stage {
        case .primary: plan.primary
        case .overflow: overflowPage
        }
    }

    /// The overflow ring holds up to 7 formats plus Back.
    var overflowPage: [WheelAction] { Array(plan.overflow.prefix(7)) + [.back] }

    var highlighted: Int? { hovered ?? keyboardFocus }

    var highlightedAction: WheelAction? {
        guard let i = highlighted, actions.indices.contains(i) else { return nil }
        return actions[i]
    }

    var isBatch: Bool { files.count > 1 }

    // MARK: Hub text

    var hubTitle: String {
        if isBatch { return "\(files.count) items" }
        return files.first?.url.lastPathComponent ?? ""
    }

    var hubSubtitle: String {
        if isBatch {
            let kinds = Set(files.map(\.format.displayName)).sorted()
            return kinds.count <= 3 ? kinds.joined(separator: " · ") : "\(kinds.count) kinds"
        }
        guard let f = files.first else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: f.byteCount, countStyle: .file)
        return "\(f.format.displayName) · \(size)"
    }

    /// Short description of what the highlighted action will do.
    func detail(for action: WheelAction, caveats: [Caveat]) -> String {
        switch action {
        case .more: return "\(plan.overflow.count) more"
        case .back: return "Main formats"
        case .edit: return "Open in Forma's editor"
        case .quickLook: return "Quick Look"
        case .combinePDF: return files.allSatisfy { $0.format == .pdf } ? "Merge into one PDF" : "One PDF, \(files.count) pages"
        case .splitPDF: return "One PDF per page"
        case .extractText:
            return caveats.first?.message ?? "Plain text"
        case .convert(let f):
            if isBatch { return "Convert each to \(f.displayName)" }
            if let warning = caveats.first(where: { $0.severity != .info }) { return warning.message }
            return caveats.first?.message ?? f.spokenName.capitalizedFirst
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
