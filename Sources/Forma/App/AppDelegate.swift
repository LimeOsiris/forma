import AppKit
import ApplicationServices
import FormaCore
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when launched with command-line arguments (`--convert`, `--list`, `--snapshot`).
    var cliArguments: [String]?
    private let services = ServicesProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if cliArguments == nil {
            NSApp.servicesProvider = services
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let args = cliArguments {
            Task {
                let code = await CommandLineInterface.run(args)
                exit(code)
            }
            return
        }
        let settings = SettingsManager.shared
        settings.applyAppearance()
        MainMenu.install()
        StatusItemController.shared.update()
        NSUpdateDynamicServices()

        HotKeyManager.shared.onPress = { AppCoordinator.shared.invokeOnFinderSelection() }
        HotKeyManager.shared.register(settings.hotKey)

        IntegrationManager.shared.configureEventTap()
        // Re-check when the user grants Accessibility in System Settings.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400)) // the trust database updates slightly after the notification
                IntegrationManager.shared.configureEventTap()
            }
        }

        if !settings.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    /// Files opened via "Open With", drag-to-Dock, `open -a Forma`, and forma:// links from the Finder extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let links = urls.filter { $0.scheme == "forma" }
        if !files.isEmpty {
            AppCoordinator.shared.present(files, origin: .openFile)
        }
        for link in links {
            handleFormaURL(link)
        }
    }

    /// forma://open?paths=<base64url JSON array>. Only ever opens the wheel; never converts on its own.
    private func handleFormaURL(_ url: URL) {
        guard url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let encoded = items.first(where: { $0.name == "paths" })?.value,
              let data = Data(base64URLEncoded: encoded),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return }
        let urls = paths.prefix(2000).map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { FileManager.default.fileExists(atPath: $0.path) }
        AppCoordinator.shared.present(urls, origin: .finderExtension)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorCoordinator.shared.confirmCloseAll() ? .terminateNow : .terminateCancel
    }

    // MARK: Quick Look panel control (the app delegate is the end of the responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLookController.shared }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

/// Handles the "Open in Forma" item macOS adds to Finder's Services / Quick Actions menu.
@MainActor
final class ServicesProvider: NSObject {
    @objc func openInForma(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were provided." as NSString
            return
        }
        AppCoordinator.shared.present(urls, origin: .service)
    }
}

extension Data {
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

/// Programmatic main menu. It's visible while an editor or Settings window is open
/// (Forma switches to a regular app then) and supplies standard shortcuts.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Forma", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",").target = MenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Forma", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Forma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(MenuActions.openFiles), keyEquivalent: "o").target = MenuActions.shared
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveEdits(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save a Copy…", action: #selector(EditorWindowController.saveCopy(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Export as PDF…", action: #selector(EditorWindowController.exportPDF(_:)), keyEquivalent: "e")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        func findAction(_ title: String, _ key: String, _ tag: NSTextFinder.Action, _ mods: NSEvent.ModifierFlags = .command) {
            let mi = find.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
            mi.tag = tag.rawValue
            mi.keyEquivalentModifierMask = mods
        }
        findAction("Find…", "f", .showFindInterface)
        findAction("Find and Replace…", "f", .showReplaceInterface, [.command, .option])
        findAction("Find Next", "g", .nextMatch)
        findAction("Find Previous", "g", .previousMatch, [.command, .shift])
        findAction("Use Selection for Find", "e", .setSearchString)
        findItem.submenu = find
        edit.addItem(findItem)
        editItem.submenu = edit
        main.addItem(editItem)

        let formatItem = NSMenuItem()
        let format = NSMenu(title: "Format")
        let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let fontMenu = NSFontManager.shared.fontMenu(true) ?? NSMenu(title: "Font")
        fontItem.submenu = fontMenu
        format.addItem(fontItem)
        let textItem = NSMenuItem(title: "Text", action: nil, keyEquivalent: "")
        let text = NSMenu(title: "Text")
        text.addItem(withTitle: "Align Left", action: #selector(NSText.alignLeft(_:)), keyEquivalent: "{")
        text.addItem(withTitle: "Center", action: #selector(NSText.alignCenter(_:)), keyEquivalent: "|")
        text.addItem(withTitle: "Align Right", action: #selector(NSText.alignRight(_:)), keyEquivalent: "}")
        textItem.submenu = text
        format.addItem(textItem)
        format.addItem(.separator())
        format.addItem(withTitle: "Bigger Text", action: #selector(EditorWindowController.biggerText(_:)), keyEquivalent: "+")
        format.addItem(withTitle: "Smaller Text", action: #selector(EditorWindowController.smallerText(_:)), keyEquivalent: "-")
        formatItem.submenu = format
        main.addItem(formatItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func openSettings() { SettingsWindowController.shared.show() }
    @objc func openFiles() { AppCoordinator.shared.chooseFiles() }
}
