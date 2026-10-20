import AppKit
import PDFKit
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

/// Renders editor and settings windows offscreen to PNGs (`--snapshot-editor`, `--snapshot-settings`).
/// With `demo`, the editor is staged with sample markup so screenshots show real features.
@MainActor
enum EditorSnapshot {
    static func render(_ url: URL, to out: URL, dark: Bool, demo: Bool = false, size: NSSize = NSSize(width: 1000, height: 700)) async -> Int32 {
        guard let kind = EditorCoordinator.kind(for: url) else { return 1 }
        let view: AnyView
        var pdfModel: PDFEditorModel?
        do {
            switch kind {
            case .image:
                let m = try ImageEditorModel(url: url)
                m.showAdjustments = true
                if demo {
                    m.edits.exposure = 0.25
                    m.edits.saturation = 1.15
                    m.edits.annotations = [
                        ImageAnnotation(kind: .arrow, start: CGPoint(x: 0.30, y: 0.72), end: CGPoint(x: 0.58, y: 0.46), color: RGBA(.white), lineWidth: 0.007, fontSize: 0.04),
                        ImageAnnotation(kind: .text, start: CGPoint(x: 0.08, y: 0.74), end: CGPoint(x: 0.08, y: 0.74), text: "Golden hour", color: RGBA(.white), lineWidth: 0.006, fontSize: 0.05),
                        ImageAnnotation(kind: .ellipse, start: CGPoint(x: 0.56, y: 0.22), end: CGPoint(x: 0.80, y: 0.50), color: RGBA(.systemYellow), lineWidth: 0.006, fontSize: 0.04),
                    ]
                    m.tool = .arrow
                }
                view = AnyView(ImageEditorView(model: m))
            case .pdf:
                let m = try PDFEditorModel(url: url)
                if demo, let page = m.document.page(at: 0) {
                    // Anchor demo markup to real text so it reads naturally.
                    func bounds(_ text: String) -> CGRect? {
                        m.document.findString(text, withOptions: []).first?.bounds(for: page)
                    }
                    if let sel = m.document.findString("pick a format on the wheel, done.", withOptions: .caseInsensitive).first {
                        for line in sel.selectionsByLine() {
                            let hl = PDFAnnotation(bounds: line.bounds(for: page).insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
                            hl.color = NSColor.systemYellow.withAlphaComponent(0.55)
                            page.addAnnotation(hl)
                        }
                    }
                    if let done = bounds("Done") {
                        let shape = PDFAnnotation(bounds: done.insetBy(dx: -34, dy: -12), forType: .circle, withProperties: nil)
                        let border = PDFBorder(); border.lineWidth = 2.5
                        shape.border = border
                        shape.color = .systemRed
                        page.addAnnotation(shape)
                    }
                    if let title = bounds("Launch Plan") {
                        let note = PDFAnnotation(bounds: CGRect(x: title.maxX + 18, y: title.minY + 2, width: 170, height: 26), forType: .freeText, withProperties: nil)
                        note.contents = "Approved ✓"
                        note.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
                        note.fontColor = .systemRed
                        note.color = .clear
                        let none = PDFBorder(); none.lineWidth = 0
                        note.border = none
                        page.addAnnotation(note)
                    }
                    m.tool = .highlight
                }
                pdfModel = m
                view = AnyView(PDFEditorView(model: m))
            case .text:
                let m = try TextEditorModel(url: url)
                m.showPreview = m.mode == .markdown
                view = AnyView(TextEditorView(model: m))
            }
        } catch { return 1 }
        return await capture(view, size: size, dark: dark, to: out, pdf: pdfModel)
    }

    static func renderSettings(tab: String, to out: URL, dark: Bool) async -> Int32 {
        SettingsView.requestedTab = SettingsView.Tab(rawValue: tab) ?? .general
        return await capture(AnyView(SettingsView()), size: NSSize(width: 620, height: 500), dark: dark, to: out, pdf: nil, titled: false)
    }

    static func capture(_ view: AnyView, size: NSSize, dark: Bool, to out: URL, pdf: PDFEditorModel?, titled: Bool = true) async -> Int32 {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingController(rootView: titled ? AnyView(view.ignoresSafeArea(.container, edges: .top)) : view)
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500)) // let previews and thumbnails render
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return 1 }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let pdf, let pdfView = pdf.pdfView { drawPDFPages(pdfView, into: rep, root: content, dark: dark) }
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: out)) != nil else { return 1 }
        print(out.path)
        return 0
    }

    /// PDFView draws pages in tiled layers that view caching skips; paint the visible pages
    /// (with their annotations) into the snapshot at the exact on-screen positions.
    private static func drawPDFPages(_ pdfView: PDFView, into rep: NSBitmapImageRep, root: NSView, dark: Bool) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        // The bitmap context already maps points to Retina pixels.
        // The hosting view is flipped (y-down); the bitmap context is y-up.
        func toBitmap(_ r: CGRect) -> CGRect {
            root.isFlipped ? CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height) : r
        }
        let area = toBitmap(pdfView.convert(pdfView.bounds, to: root))
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
        area.fill()
        cg.clip(to: area)
        for page in pdfView.visiblePages {
            let r = toBitmap(root.convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView))
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            NSColor.white.setFill()
            r.fill()
            cg.restoreGState()
            cg.saveGState()
            cg.translateBy(x: r.minX, y: r.minY)
            let b = page.bounds(for: .cropBox)
            cg.scaleBy(x: r.width / b.width, y: r.height / b.height)
            page.draw(with: .cropBox, to: cg)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
