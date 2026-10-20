import Cocoa
import FinderSync

/// Adds "Convert with Forma…" to Finder's context menu for files.
///
/// Finder Sync extensions are sandboxed and run in their own process. This one does the
/// minimum: it reads the items Finder reports as targeted and hands their paths to the
/// main app through a forma:// link. The app only shows its wheel for them; nothing is
/// converted without the user choosing a format.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Monitoring "/" makes the menu available everywhere, including mounted volumes.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Convert with Forma…", action: #selector(convert(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc func convert(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        // selectedItemURLs() is exactly the set Finder's context menu applies to.
        let items = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        guard !items.isEmpty,
              let json = try? JSONEncoder().encode(items.prefix(2000).map(\.path)) else { return }
        let encoded = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "forma"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "paths", value: encoded)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
