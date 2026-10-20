import AppKit
import FormaCore
import SwiftUI

/// A small command-line surface on the same engine, useful for scripting and for
/// verifying conversions and the wheel's rendering without clicking:
///
///     Forma --list <file>
///     Forma --convert <file> --to <format> [--out <dir>] [--quality 0.8] [--max-size 1024] [--dpi 300]
///     Forma --snapshot-wheel <file> --out <png> [--dark] [--hover <index>]
///     Forma --show <file>            (opens the wheel at the screen center, for manual testing)
@MainActor
enum CommandLineInterface {
    static func handles(_ args: [String]) -> Bool {
        args.contains { ["--list", "--convert", "--snapshot-wheel", "--snapshot-editor", "--snapshot-settings", "--ui-test", "--help"].contains($0) }
    }

    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ args: [String]) async -> Int32 {
        let engine = Engine.shared
        if args.contains("--help") {
            print("Usage: Forma --list <file> | --convert <file> --to <format> [--out <dir>] | --snapshot-wheel <file> --out <png> [--dark]")
            return 0
        }
        if let path = value(args, "--list") {
            let url = URL(fileURLWithPath: path)
            do {
                let facts = try engine.coordinator.inspect(url)
                print("\(url.lastPathComponent): \(facts.format.displayName)\(facts.isAnimated ? " (animated, \(facts.frameCount) frames)" : "")\(facts.pageCount > 1 ? " (\(facts.pageCount) pages)" : "")")
                for cap in engine.registry.destinations(for: facts.format) {
                    let notes = engine.coordinator.caveats(for: facts, to: cap.output, options: .init()).map(\.message).joined(separator: " ")
                    print("  → \(cap.output.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(cap.isLossless ? "lossless" : "lossy   ") \(cap.editability.label)\(cap.requiredTool.map { " [\($0.displayName)]" } ?? "")  \(notes)")
                }
                let plan = WheelPlanner(registry: engine.registry).plan(for: [facts])
                print("  wheel: " + plan.primary.map(\.title).joined(separator: " | ") + (plan.overflow.isEmpty ? "" : "  (more: " + plan.overflow.map(\.title).joined(separator: ", ") + ")"))
                return 0
            } catch {
                fputs("error: \(FormaError.wrap(error).localizedDescription)\n", stderr)
                return 1
            }
        }
        if let path = value(args, "--convert") {
            guard let fmtName = value(args, "--to"), let format = FileFormat(rawValue: fmtName.lowercased()) ?? FileFormat.from(extension: fmtName) else {
                fputs("error: --to <format> is required (e.g. png, jpeg, pdf, txt, html, md, docx, m4a)\n", stderr)
                return 2
            }
            let url = URL(fileURLWithPath: path)
            let out = value(args, "--out").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url.deletingLastPathComponent()
            var options = ConversionOptions()
            if let q = value(args, "--quality").flatMap(Double.init) { options.quality = q }
            if let m = value(args, "--max-size").flatMap(Int.init) { options.maxPixelSize = m }
            if let d = value(args, "--dpi").flatMap(Double.init) { options.pdfRenderDPI = d }
            options.acceptFirstFrameOnly = true
            do {
                let start = Date()
                let result = try await engine.coordinator.convert(url, to: format, options: options, into: out)
                for o in result.outputs { print(o.path) }
                for c in result.caveats { print("note: \(c.message)") }
                print(String(format: "done in %.2fs · %@", Date().timeIntervalSince(start), result.editability.label))
                return 0
            } catch {
                fputs("error: \(FormaError.wrap(error).localizedDescription)\n", stderr)
                return 1
            }
        }
        if let path = value(args, "--snapshot-wheel"), let out = value(args, "--out") {
            return snapshotWheel(URL(fileURLWithPath: path), to: URL(fileURLWithPath: out), dark: args.contains("--dark"),
                                 hover: value(args, "--hover").flatMap(Int.init), phase: value(args, "--phase"), transparent: args.contains("--transparent"))
        }
        if let dir = value(args, "--ui-test") {
            return await UITestHarness(outputDirectory: URL(fileURLWithPath: dir, isDirectory: true)).run()
        }
        if let path = value(args, "--snapshot-editor"), let out = value(args, "--out") {
            let w = value(args, "--width").flatMap(Double.init) ?? 1000, h = value(args, "--height").flatMap(Double.init) ?? 700
            return await EditorSnapshot.render(URL(fileURLWithPath: path), to: URL(fileURLWithPath: out), dark: args.contains("--dark"),
                                               demo: args.contains("--demo"), size: NSSize(width: w, height: h))
        }
        if let tab = value(args, "--snapshot-settings"), let out = value(args, "--out") {
            return await EditorSnapshot.renderSettings(tab: tab, to: URL(fileURLWithPath: out), dark: args.contains("--dark"))
        }
        return 2
    }

    /// Renders the real wheel view offscreen. Vibrancy needs a live window, so the
    /// frosted material is approximated with a flat fill in snapshots.
    static func snapshotWheel(_ url: URL, to out: URL, dark: Bool, hover: Int?, phase: String?, transparent: Bool = false) -> Int32 {
        let engine = Engine.shared
        guard let facts = try? engine.coordinator.inspect(url) else { fputs("error: unreadable file\n", stderr); return 1 }
        let settings = SettingsManager.shared
        let plan = WheelPlanner(registry: engine.registry, maxPrimary: settings.maxSegments).plan(for: [facts], usage: engine.history.usage)
        let model = RadialMenuModel(files: [facts], plan: plan, options: .init(), reduceMotion: true, accent: settings.accent.color, diameter: settings.wheelSize.diameter)
        for action in plan.primary + plan.overflow {
            if let f = action.trackedFormat { model.caveatCache[action] = engine.coordinator.caveats(for: facts, to: f, options: .init()) }
        }
        model.appeared = true
        model.hovered = hover
        switch phase {
        case "working": model.phase = .working(progress: 0.42, label: url.lastPathComponent)
        case "done":
            // Show the result of the first wheel format, so a sequence of snapshots tells one story.
            let out = plan.primary.compactMap(\.trackedFormat).first ?? .pdf
            let cap = engine.registry.capability(from: facts.format, to: out)
            model.phase = .done(.init(title: url.deletingPathExtension().lastPathComponent + "." + out.preferredExtension,
                                      detail: "Saved in \(url.deletingLastPathComponent().lastPathComponent)",
                                      primaryURL: url, allOutputs: [url], editable: true, editability: cap?.editability, notes: []))
        case "options": if let a = plan.primary.first { model.phase = .options(a) }
        default: break
        }
        VisualEffectBackground.snapshotMode = true
        let view = RadialMenuView(model: model, actions: RadialMenuActions(select: { _ in }, dismiss: {}, cancelWork: {}, confirmOptions: {}, cancelOptions: {}, done: { _ in }))
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(transparent ? Color.clear : (dark ? Color(white: 0.16) : Color(white: 0.93)))
        let host = NSHostingView(rootView: view)
        let side = model.diameter + RadialMenuView.margin * 2
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: out) } catch { return 1 }
        print(out.path)
        return 0
    }
}
