import AppKit
import FormaCore
import Observation
import ServiceManagement

/// All user preferences, persisted in UserDefaults. Observable so SwiftUI updates live.
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    enum SaveLocation: String, CaseIterable, Identifiable {
        case besideOriginal, ask, folder
        var id: String { rawValue }
        var label: String {
            switch self {
            case .besideOriginal: "Next to the original"
            case .ask: "Ask each time"
            case .folder: "In a folder…"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum AnimationLevel: String, CaseIterable, Identifiable {
        case full, reduced, off
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum WheelSize: String, CaseIterable, Identifiable {
        case compact, regular, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var diameter: CGFloat {
            switch self {
            case .compact: 264
            case .regular: 304
            case .large: 352
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case system, graphite, blue, teal, orange, pink
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var color: NSColor {
            switch self {
            case .system: .controlAccentColor
            case .graphite: NSColor(white: 0.45, alpha: 1)
            case .blue: .systemBlue
            case .teal: .systemTeal
            case .orange: .systemOrange
            case .pink: .systemPink
            }
        }
    }

    private let defaults = UserDefaults.standard

    var saveLocation: SaveLocation { didSet { defaults.set(saveLocation.rawValue, forKey: "saveLocation") } }
    var outputFolderPath: String? { didSet { defaults.set(outputFolderPath, forKey: "outputFolderPath") } }
    var openAfterConversion: Bool { didSet { defaults.set(openAfterConversion, forKey: "openAfterConversion") } }
    var openEditorAfterConversion: Bool { didSet { defaults.set(openEditorAfterConversion, forKey: "openEditorAfterConversion") } }
    var showNotifications: Bool { didSet { defaults.set(showNotifications, forKey: "showNotifications") } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    var adaptiveOrdering: Bool { didSet { defaults.set(adaptiveOrdering, forKey: "adaptiveOrdering") } }
    var pinnedFormats: [FileFormat] { didSet { defaults.set(pinnedFormats.map(\.rawValue), forKey: "pinnedFormats") } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var animation: AnimationLevel { didSet { defaults.set(animation.rawValue, forKey: "animation") } }
    var wheelSize: WheelSize { didSet { defaults.set(wheelSize.rawValue, forKey: "wheelSize") } }
    var compactMode: Bool { didSet { defaults.set(compactMode, forKey: "compactMode") } }
    var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    var pdfDPI: Double { didSet { defaults.set(pdfDPI, forKey: "pdfDPI") } }
    var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") } }
    var askForOptions: Bool { didSet { defaults.set(askForOptions, forKey: "askForOptions") } }
    var shiftRightClickEnabled: Bool { didSet { defaults.set(shiftRightClickEnabled, forKey: "shiftRightClickEnabled") } }
    var hotKey: HotKey? {
        didSet {
            if let hotKey { defaults.set([Int(hotKey.keyCode), Int(hotKey.modifiers)], forKey: "hotKey") }
            else { defaults.set([Int](), forKey: "hotKey") }
        }
    }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    private init() {
        let d = UserDefaults.standard
        saveLocation = SaveLocation(rawValue: d.string(forKey: "saveLocation") ?? "") ?? .besideOriginal
        outputFolderPath = d.string(forKey: "outputFolderPath")
        openAfterConversion = d.object(forKey: "openAfterConversion") as? Bool ?? false
        openEditorAfterConversion = d.object(forKey: "openEditorAfterConversion") as? Bool ?? false
        showNotifications = d.object(forKey: "showNotifications") as? Bool ?? true
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        adaptiveOrdering = d.object(forKey: "adaptiveOrdering") as? Bool ?? true
        pinnedFormats = (d.stringArray(forKey: "pinnedFormats") ?? []).compactMap(FileFormat.init(rawValue:))
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        accent = Accent(rawValue: d.string(forKey: "accent") ?? "") ?? .system
        animation = AnimationLevel(rawValue: d.string(forKey: "animation") ?? "") ?? .full
        wheelSize = WheelSize(rawValue: d.string(forKey: "wheelSize") ?? "") ?? .regular
        compactMode = d.object(forKey: "compactMode") as? Bool ?? false
        quality = d.object(forKey: "quality") as? Double ?? 0.85
        pdfDPI = d.object(forKey: "pdfDPI") as? Double ?? 150
        ocrEnabled = d.object(forKey: "ocrEnabled") as? Bool ?? true
        askForOptions = d.object(forKey: "askForOptions") as? Bool ?? false
        shiftRightClickEnabled = d.object(forKey: "shiftRightClickEnabled") as? Bool ?? true
        if let stored = d.array(forKey: "hotKey") as? [Int] {
            hotKey = stored.count == 2 ? HotKey(keyCode: UInt32(stored[0]), modifiers: UInt32(stored[1])) : nil
        } else {
            hotKey = HotKey.defaultKey
        }
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
    }

    var outputPolicy: OutputPolicy {
        switch saveLocation {
        case .besideOriginal: return .besideOriginal
        case .ask: return .ask
        case .folder:
            if let p = outputFolderPath { return .folder(URL(fileURLWithPath: p, isDirectory: true)) }
            return .besideOriginal
        }
    }

    var conversionOptions: ConversionOptions {
        var o = ConversionOptions()
        o.quality = quality
        o.pdfRenderDPI = pdfDPI
        o.ocrWhenNoText = ocrEnabled
        return o
    }

    /// Respects both the in-app setting and the system's Reduce Motion preference.
    var reduceMotion: Bool {
        animation != .full || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var maxSegments: Int { compactMode ? 5 : (wheelSize == .large ? 8 : 6) }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Launch at login (SMAppService; the system owns the state)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Forma: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    func resetShortcuts() {
        hotKey = HotKey.defaultKey
        shiftRightClickEnabled = true
    }
}
