import AppKit
import FormaCore

/// Optional menu bar presence: Open, Recent Conversions, Settings, Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    private var item: NSStatusItem?

    func update() {
        if SettingsManager.shared.showMenuBarIcon {
            if item == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = Self.icon()
                item.button?.setAccessibilityLabel("Forma")
                item.button?.toolTip = "Forma"
                self.item = item
            }
            rebuildMenu()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Template glyph drawn in code: two overlapping rounded squares (Forma's mark).
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 5.5, width: 9, height: 9), xRadius: 2.6, yRadius: 2.6)
            back.lineWidth = 1.5
            back.stroke()
            NSColor.black.setFill()
            let front = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2.5, width: 9, height: 9), xRadius: 4.5, yRadius: 4.5)
            front.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func rebuildMenu() {
        guard let item else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Forma…", action: #selector(openFiles), keyEquivalent: "o").target = self
        let finder = menu.addItem(withTitle: "Convert Finder Selection", action: #selector(convertSelection), keyEquivalent: "")
        finder.target = self
        if let key = SettingsManager.shared.hotKey { finder.toolTip = "Shortcut: \(key.displayString)" }

        let recent = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let entries = Engine.shared.history.recent.prefix(10)
        if entries.isEmpty || !SettingsManager.shared.keepHistory {
            sub.addItem(withTitle: SettingsManager.shared.keepHistory ? "No Recent Conversions" : "History Is Off", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for entry in entries {
                let mi = NSMenuItem(title: entry.output.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.output
                mi.image = NSWorkspace.shared.icon(forFile: entry.output.path)
                mi.image?.size = NSSize(width: 16, height: 16)
                mi.toolTip = "From \(entry.source.lastPathComponent) · \(entry.date.formatted(date: .abbreviated, time: .shortened))"
                sub.addItem(mi)
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "Clear Recent", action: #selector(clearRecent), keyEquivalent: "").target = self
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Forma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {}

    @objc private func openFiles() { AppCoordinator.shared.chooseFiles() }
    @objc private func convertSelection() { AppCoordinator.shared.invokeOnFinderSelection() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func clearRecent() { Engine.shared.history.clearRecent(); rebuildMenu() }
    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
