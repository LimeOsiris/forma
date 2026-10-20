import AppKit
import ApplicationServices

/// Identifies exactly which Finder item is under a screen point using the Accessibility API.
///
/// It never assumes "the click target is whatever is selected": it hit-tests the element
/// under the cursor, reads its URL (or its displayed name plus the window's folder),
/// and verifies the file exists. Ambiguous or unresolvable cases return nil so Finder's
/// normal context menu appears instead of acting on the wrong file.
@MainActor
enum FinderItemResolver {
    struct Resolution: Equatable {
        /// The item under the pointer.
        var clicked: URL
        /// What the action applies to: the whole selection if the clicked item is part of it
        /// (matching Finder's own context-menu behaviour), otherwise just the clicked item.
        var targets: [URL]
    }

    static func finderPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: FinderSelection.finderBundleID).first?.processIdentifier
    }

    /// `point` is in Quartz global coordinates (origin top-left of the primary display), as
    /// delivered by CGEvent and expected by AXUIElementCopyElementAtPosition.
    static func resolve(at point: CGPoint) -> Resolution? {
        guard AXIsProcessTrusted(), let finder = finderPID() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == finder else { return nil }
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(finder), 0.25)

        // Walk up from the hit element, collecting URL attributes, names and context.
        var chain: [AXUIElement] = []
        var cursor: AXUIElement? = element
        while let el = cursor, chain.count < 12 {
            chain.append(el)
            if role(el) == kAXWindowRole as String { break }
            cursor = parent(el)
        }
        let window = chain.last.flatMap { role($0) == kAXWindowRole as String ? $0 : nil } ?? windowOf(element)

        // 1. Direct URL on the item (Finder exposes AXURL on many item elements).
        for el in chain.prefix(6) {
            if let url = fileURL(el, attribute: kAXURLAttribute as String), FileManager.default.fileExists(atPath: url.path) {
                // Don't treat the window/folder itself as the clicked item.
                if let w = window, let doc = documentURL(w), doc.standardizedFileURL == url.standardizedFileURL { continue }
                return finalize(clicked: url, itemElement: el, chain: chain, folders: candidateFolders(window: window))
            }
            if let name = string(el, "AXFilename"), let folder = window.flatMap(documentURL) {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    return finalize(clicked: url, itemElement: el, chain: chain, folders: [folder])
                }
            }
        }

        // 2. Displayed name + folder. Only item-level elements contribute names.
        guard let item = itemElement(in: chain) else { return nil }
        let names = displayedNames(of: item)
        guard !names.isEmpty else { return nil }
        let folders = candidateFolders(window: window)
        var matches = Set<URL>()
        for folder in folders {
            for name in names { matches.formUnion(match(name: name, in: folder)) }
        }
        guard matches.count == 1, let clicked = matches.first else { return nil }
        return finalize(clicked: clicked, itemElement: item, chain: chain, folders: folders)
    }

    // MARK: - Selection

    private static func finalize(clicked: URL, itemElement: AXUIElement, chain: [AXUIElement], folders: [URL]) -> Resolution? {
        // Folders aren't convertible: let Finder show its normal menu for them.
        if isPlainDirectory(clicked) { return nil }
        let selected = selectedURLs(container: containerElement(in: chain), folders: folders)
        if selected.contains(where: { $0.standardizedFileURL == clicked.standardizedFileURL }) {
            return Resolution(clicked: clicked, targets: selected)
        }
        return Resolution(clicked: clicked, targets: [clicked])
    }

    static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    private static func selectedURLs(container: AXUIElement?, folders: [URL]) -> [URL] {
        guard let container else { return [] }
        var elements: [AXUIElement] = []
        for attr in [kAXSelectedRowsAttribute as String, kAXSelectedChildrenAttribute as String] {
            if let arr = value(container, attr) as? [AXUIElement], !arr.isEmpty { elements = arr; break }
        }
        var urls: [URL] = []
        for el in elements.prefix(500) {
            if let url = fileURL(el, attribute: kAXURLAttribute as String) { urls.append(url); continue }
            let names = displayedNames(of: el)
            var found = Set<URL>()
            for folder in folders { for n in names { found.formUnion(match(name: n, in: folder)) } }
            if found.count == 1, let u = found.first { urls.append(u) }
        }
        return urls
    }

    // MARK: - Element helpers

    static let itemRoles: Set<String> = [kAXRowRole as String, kAXCellRole as String, kAXImageRole as String, kAXGroupRole as String, kAXTextFieldRole as String, kAXStaticTextRole as String]
    static let containerRoles: Set<String> = [kAXOutlineRole as String, kAXListRole as String, kAXTableRole as String, kAXBrowserRole as String, "AXCollection"]

    /// The row (list/column view) or icon group (icon/gallery view) that represents one file.
    private static func itemElement(in chain: [AXUIElement]) -> AXUIElement? {
        if let row = chain.first(where: { role($0) == kAXRowRole as String }) { return row }
        for (i, el) in chain.enumerated() {
            let next = i + 1 < chain.count ? role(chain[i + 1]) : nil
            if let next, containerRoles.contains(next) { return el }
        }
        return chain.first.flatMap { itemRoles.contains(role($0) ?? "") ? $0 : nil }
    }

    private static func containerElement(in chain: [AXUIElement]) -> AXUIElement? {
        chain.first { containerRoles.contains(role($0) ?? "") }
    }

    /// Names shown for an item: its own title/value plus text fields inside it.
    private static func displayedNames(of el: AXUIElement) -> [String] {
        var names: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count < 256, !names.contains(s) else { return }
            names.append(s)
        }
        add(string(el, kAXTitleAttribute as String))
        add(string(el, kAXValueAttribute as String))
        add(string(el, kAXDescriptionAttribute as String))
        var queue: [(AXUIElement, Int)] = [(el, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            guard depth < 3 else { continue }
            for child in (value(node, kAXChildrenAttribute as String) as? [AXUIElement] ?? []).prefix(12) {
                let r = role(child)
                if r == kAXTextFieldRole as String || r == kAXStaticTextRole as String {
                    add(string(child, kAXValueAttribute as String))
                    add(string(child, kAXTitleAttribute as String))
                } else if r == kAXImageRole as String {
                    add(string(child, kAXTitleAttribute as String))
                    add(string(child, kAXDescriptionAttribute as String))
                }
                queue.append((child, depth + 1))
            }
        }
        return names
    }

    /// The window's folder, its ancestors (column view shows them) and the Desktop.
    private static func candidateFolders(window: AXUIElement?) -> [URL] {
        var folders: [URL] = []
        if let w = window, let doc = documentURL(w) {
            var f = doc
            for _ in 0..<12 {
                folders.append(f)
                let up = f.deletingLastPathComponent()
                if up.path == f.path { break }
                f = up
            }
        }
        if window == nil || window.flatMap(documentURL) == nil {
            folders.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true))
        }
        return folders
    }

    /// Finds `name` in `folder`, also matching when Finder hides the extension.
    private static func match(name: String, in folder: URL) -> Set<URL> {
        var result = Set<URL>()
        let direct = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { result.insert(direct.standardizedFileURL) }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return result }
        if entries.count > 20_000 { return result } // don't scan huge folders on the event path
        for entry in entries where entry != name {
            let path = folder.appendingPathComponent(entry).path
            if FileManager.default.displayName(atPath: path) == name {
                result.insert(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }
        return result
    }

    private static func documentURL(_ window: AXUIElement) -> URL? {
        guard let s = string(window, kAXDocumentAttribute as String), let url = URL(string: s), url.isFileURL else { return nil }
        return url
    }

    private static func windowOf(_ el: AXUIElement) -> AXUIElement? {
        guard let w = value(el, kAXWindowAttribute as String) else { return nil }
        return (w as! AXUIElement)
    }

    private static func fileURL(_ el: AXUIElement, attribute: String) -> URL? {
        let v = value(el, attribute)
        if let url = v as? URL, url.isFileURL { return url }
        if let s = v as? String, let url = URL(string: s), url.isFileURL { return url }
        return nil
    }

    static func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute as String) }
    static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let p = value(el, kAXParentAttribute as String) else { return nil }
        return (p as! AXUIElement)
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }

    static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }
}
