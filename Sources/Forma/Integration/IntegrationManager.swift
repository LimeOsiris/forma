import AppKit
import ApplicationServices
import FormaCore

/// Status of every way into Forma, for Settings › Integrations and onboarding.
@MainActor
final class IntegrationManager {
    static let shared = IntegrationManager()
    static let extensionBundleID = (Bundle.main.bundleIdentifier ?? "app.forma.mac") + ".FinderSync"

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Starts or stops the Shift + right-click tap to match settings and permission.
    func configureEventTap() {
        let tap = EventTapManager.shared
        if SettingsManager.shared.shiftRightClickEnabled && AXIsProcessTrusted() {
            tap.onShiftRightClick = { resolution, point in
                AppCoordinator.shared.present(resolution.targets, at: point, origin: .shiftRightClick)
            }
            tap.onRightMouseUp = { point in AppCoordinator.shared.wheel.handleRightMouseUp(at: point) }
            tap.start()
        } else {
            tap.stop()
        }
    }

    /// Shows the system Accessibility prompt. Only called from an explicit user action.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { configureEventTap() }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func openExtensionsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }

    func openKeyboardShortcutsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    enum ExtensionState: Equatable { case enabled, disabled, notInstalled, unknown }

    /// Asks pluginkit whether the Finder Sync extension is registered and enabled.
    func finderExtensionState() async -> ExtensionState {
        let id = Self.extensionBundleID
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-m", "-i", id]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return .unknown }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .notInstalled }
            if text.hasPrefix("+") { return .enabled }
            if text.hasPrefix("-") { return .disabled }
            return .disabled // listed without a flag: registered but the user hasn't turned it on
        }.value
    }
}
