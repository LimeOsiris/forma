import AppKit
import FormaCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private(set) var isOpen = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: OnboardingView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        isOpen = true
        EditorCoordinator.shared.updateActivationPolicy()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        SettingsManager.shared.hasCompletedOnboarding = true
        DispatchQueue.main.async { EditorCoordinator.shared.updateActivationPolicy() }
    }
}

private struct OnboardingView: View {
    @State private var trusted = AXIsProcessTrusted()
    private let hotKey = SettingsManager.shared.hotKey?.displayString ?? "a shortcut"

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).padding(.top, 34)
            VStack(spacing: 4) {
                Text("Welcome to Forma").font(.system(size: 24, weight: .semibold))
                Text("Convert. Edit. Done. — right from Finder.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Step(symbol: "contextualmenu.and.cursorarrow", title: "Right-click → Convert with Forma…",
                     detail: "Turn on Forma's Finder extension in System Settings › General › Login Items & Extensions › Finder.") {
                    Button("Open Settings") { IntegrationManager.shared.openExtensionsSettings() }
                }
                Step(symbol: "command", title: "Select files and press \(hotKey)",
                     detail: "The wheel opens at your pointer. macOS will ask once whether Forma may read Finder's selection.") { EmptyView() }
                Step(symbol: "shift", title: "Shift + right-click (optional)",
                     detail: "Needs Accessibility access so Forma can tell exactly which file you clicked. Nothing else is monitored.") {
                    if trusted { Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Enable…") { IntegrationManager.shared.requestAccessibility() } }
                }
                Step(symbol: "list.bullet.rectangle", title: "Services › Open in Forma",
                     detail: "Always available in Finder's right-click menu, no setup needed.") { EmptyView() }
            }
            .padding(.horizontal, 36)
            Spacer()
            HStack {
                Text("Everything stays on your Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 520)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct Step<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory.controlSize(.small)
        }
    }
}

/// Renders an editor window offscreen to a PNG (used by `--snapshot-editor`).
@MainActor
enum EditorSnapshot {
    static func render(_ url: URL, to out: URL, dark: Bool) async -> Int32 {
        guard let kind = EditorCoordinator.kind(for: url) else { return 1 }
        let size = NSSize(width: 1000, height: 700)
        let view: AnyView
        do {
            switch kind {
            case .image:
                let m = try ImageEditorModel(url: url)
                m.showAdjustments = true
                view = AnyView(ImageEditorView(model: m))
            case .pdf: view = AnyView(PDFEditorView(model: try PDFEditorModel(url: url)))
            case .text:
                let m = try TextEditorModel(url: url)
                m.showPreview = m.mode == .markdown
                view = AnyView(TextEditorView(model: m))
            }
        } catch { return 1 }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingController(rootView: view.ignoresSafeArea(.container, edges: .top))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500)) // let previews render
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return 1 }
        content.cacheDisplay(in: content.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: out)) != nil else { return 1 }
        print(out.path)
        return 0
    }
}
