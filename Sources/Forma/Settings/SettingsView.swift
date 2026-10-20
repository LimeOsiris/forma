import AppKit
import FormaCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private(set) var isOpen = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Forma Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsView.Tab? = nil) {
        if let tab { SettingsView.requestedTab = tab }
        isOpen = true
        EditorCoordinator.shared.updateActivationPolicy()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        DispatchQueue.main.async { EditorCoordinator.shared.updateActivationPolicy() }
    }
}

struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, conversion, appearance, shortcuts, integrations, about }
    @MainActor static var requestedTab: Tab?
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            ConversionSettings().tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }.tag(Tab.conversion)
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }.tag(Tab.appearance)
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }.tag(Tab.shortcuts)
            IntegrationSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag(Tab.integrations)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(width: 620, height: 500)
        .onAppear { if let t = Self.requestedTab { tab = t; Self.requestedTab = nil } }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var s = SettingsManager.shared
    @State private var launchAtLogin = SettingsManager.shared.launchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle("Launch Forma at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in s.launchAtLogin = v; launchAtLogin = s.launchAtLogin }
                Toggle("Show Forma in the menu bar", isOn: $s.showMenuBarIcon)
                    .onChange(of: s.showMenuBarIcon) { _, _ in StatusItemController.shared.update() }
            }
            Section("Saving") {
                Picker("Save converted files", selection: $s.saveLocation) {
                    ForEach(SettingsManager.SaveLocation.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.saveLocation) { _, v in if v == .folder && s.outputFolderPath == nil { chooseFolder() } }
                if s.saveLocation == .folder {
                    HStack {
                        Text(s.outputFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Forma never overwrites files. If a name is taken, it adds a number, like “photo 2.jpg”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Show a notification when a background conversion finishes", isOn: $s.showNotifications)
                Toggle("Keep a history of recent conversions", isOn: $s.keepHistory)
                    .onChange(of: s.keepHistory) { _, _ in StatusItemController.shared.rebuildMenu() }
                HStack {
                    Text("History and format usage stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History") { Engine.shared.history.clear(); StatusItemController.shared.rebuildMenu() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            s.outputFolderPath = url.path
        } else if s.outputFolderPath == nil {
            s.saveLocation = .besideOriginal
        }
    }
}

// MARK: - Conversion

private struct ConversionSettings: View {
    @Bindable var s = SettingsManager.shared
    static let pinnable: [FileFormat] = [.pdf, .png, .jpeg, .heic, .tiff, .txt, .html, .markdown, .docx, .rtf, .m4a, .wav]

    var body: some View {
        Form {
            Section("Defaults") {
                LabeledContent("JPEG / HEIC quality") {
                    HStack {
                        Slider(value: $s.quality, in: 0.4...1).frame(width: 180)
                        Text("\(Int(s.quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("PDF to image resolution", selection: $s.pdfDPI) {
                    Text("72 dpi (screen)").tag(72.0)
                    Text("150 dpi").tag(150.0)
                    Text("300 dpi (print)").tag(300.0)
                    Text("600 dpi").tag(600.0)
                }
                Toggle("Recognize text in scanned PDFs (on-device OCR)", isOn: $s.ocrEnabled)
                Toggle("Ask for options before converting", isOn: $s.askForOptions)
                Text("Hold ⌥ while choosing a format to see options once.").font(.caption).foregroundStyle(.secondary)
            }
            Section("After converting") {
                Toggle("Open the converted file", isOn: $s.openAfterConversion)
                Toggle("Open it in Forma's editor", isOn: $s.openEditorAfterConversion)
            }
            Section("Wheel") {
                Toggle("Move frequently used formats onto the wheel", isOn: $s.adaptiveOrdering)
                Text("Formats keep their positions; only which ones appear adapts. Usage stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Always show") {
                    WrapChips(all: Self.pinnable, selected: $s.pinnedFormats)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WrapChips: View {
    let all: [FileFormat]
    @Binding var selected: [FileFormat]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 6), count: 4), spacing: 6) {
            ForEach(all) { f in
                let on = selected.contains(f)
                Button {
                    if on { selected.removeAll { $0 == f } } else { selected.append(f) }
                } label: {
                    Text(f.displayName).font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Bindable var s = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $s.appearance) {
                    ForEach(SettingsManager.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Accent colour", selection: $s.accent) {
                    ForEach(SettingsManager.Accent.allCases) { a in
                        Label { Text(a.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: a.color)) }.tag(a)
                    }
                }
            }
            Section("Wheel") {
                Picker("Size", selection: $s.wheelSize) {
                    ForEach(SettingsManager.WheelSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Compact mode (fewer segments)", isOn: $s.compactMode)
                Picker("Animation", selection: $s.animation) {
                    ForEach(SettingsManager.AnimationLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("Reduce Motion is on in System Settings, so Forma keeps animations minimal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Preview Wheel") { previewWheel() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func previewWheel() {
        let sample = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Forma Preview.png")
        if !FileManager.default.fileExists(atPath: tmp.path), let img = NSImage(contentsOf: sample), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: tmp)
        }
        AppCoordinator.shared.present([tmp], origin: .menuBar)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Bindable var s = SettingsManager.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Finder selection shortcut") {
                LabeledContent("Convert selected files") {
                    ShortcutRecorder(key: $s.hotKey)
                }
                Text("Works anywhere: press it with files selected in Finder and the wheel opens at the pointer. The first time, macOS asks whether Forma may read Finder's selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shift + right-click") {
                Toggle("Open the wheel with Shift + right-click on a Finder item", isOn: $s.shiftRightClickEnabled)
                    .onChange(of: s.shiftRightClickEnabled) { _, _ in IntegrationManager.shared.configureEventTap() }
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility access granted" : "Needs Accessibility access to see which file you clicked")
                    Spacer()
                    if !trusted { Button("Enable…") { IntegrationManager.shared.requestAccessibility() } }
                }
                Text("You can also press and hold the right button, then release over a format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("“Open in Forma” in Finder's Services menu can also get a shortcut in Keyboard settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Keyboard Settings…") { IntegrationManager.shared.openKeyboardShortcutsSettings() }
                }
                HStack {
                    Spacer()
                    Button("Reset Shortcuts") {
                        s.resetShortcuts()
                        HotKeyManager.shared.register(s.hotKey)
                        IntegrationManager.shared.configureEventTap()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}

struct ShortcutRecorder: View {
    @Binding var key: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (key?.displayString ?? "None"))
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minWidth: 110)
            }
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(key?.displayString ?? "none"). Click to change.")
            if key != nil && !recording {
                Button { key = nil; HotKeyManager.shared.register(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                if e.keyCode == 53 { stop(); HotKeyManager.shared.register(key); return }
                if let hk = HotKey(event: e) {
                    key = hk
                    stop()
                    HotKeyManager.shared.register(hk)
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Integrations

private struct IntegrationSettings: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var automation = FinderSelection.AutomationStatus.unknown
    @State private var finderExtension = IntegrationManager.ExtensionState.unknown
    @State private var tools = Engine.shared.tools

    var body: some View {
        Form {
            Section("Finder") {
                StatusRow(title: "Finder extension", detail: "Adds “Convert with Forma…” to Finder's right-click menu.",
                          ok: finderExtension == .enabled, status: extText) {
                    Button("Extensions…") { IntegrationManager.shared.openExtensionsSettings() }
                }
                StatusRow(title: "Shift + right-click", detail: "Needs Accessibility to identify the clicked item. Off unless you enable it.",
                          ok: accessibility, status: accessibility ? "Enabled" : "Not allowed") {
                    if accessibility { Button("Settings…") { IntegrationManager.shared.openAccessibilitySettings() } }
                    else { Button("Enable…") { IntegrationManager.shared.requestAccessibility() } }
                }
                StatusRow(title: "Shortcut on Finder selection", detail: "Needs permission to read Finder's selection (asked on first use).",
                          ok: automation == .granted, status: autoText) {
                    Button("Automation…") { IntegrationManager.shared.openAutomationSettings() }
                }
                StatusRow(title: "Services menu", detail: "“Open in Forma” in Finder's Services / Quick Actions menu. No permission needed.",
                          ok: true, status: "Available") { EmptyView() }
            }
            Section("Optional components") {
                ForEach(ExternalTool.allCases, id: \.self) { tool in
                    StatusRow(title: tool.displayName, detail: "\(tool.purpose) · \(tool.license)",
                              ok: tools.has(tool), status: tools.path(tool)?.path ?? "Not installed") { EmptyView() }
                }
                Text("Forma works fully without these. If installed (e.g. LibreOffice in /Applications, or `brew install ffmpeg webp`), they're detected automatically and run locally with no network access.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Check Again") { refresh() } }
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private var extText: String {
        switch finderExtension {
        case .enabled: "Enabled"
        case .disabled: "Turn on in System Settings"
        case .notInstalled: "Not registered"
        case .unknown: "Checking…"
        }
    }

    private var autoText: String {
        switch automation {
        case .granted: "Allowed"
        case .notDetermined: "Will ask on first use"
        case .denied: "Denied"
        case .finderNotRunning: "Finder not running"
        case .unknown: "Unknown"
        }
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        automation = FinderSelection.automationStatus()
        Engine.shared.refreshTools()
        tools = Engine.shared.tools
        Task { finderExtension = await IntegrationManager.shared.finderExtensionState() }
    }
}

private struct StatusRow<Accessory: View>: View {
    let title: String
    let detail: String
    let ok: Bool
    let status: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(status).font(.caption).foregroundStyle(ok ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            accessory
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text("Forma").font(.system(size: 22, weight: .semibold))
            Text("Convert. Edit. Done.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.horizontal, 80).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                Label("Everything happens on this Mac. No uploads, accounts, analytics or ads.", systemImage: "lock.shield")
                Label("Forma never overwrites your files and never makes network requests.", systemImage: "doc.on.doc")
                Label("Built with Apple frameworks: ImageIO, PDFKit, Core Image, Vision, AVFoundation, TextKit.", systemImage: "applelogo")
            }
            .font(.system(size: 12))
            .frame(maxWidth: 440, alignment: .leading)
            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }
}
