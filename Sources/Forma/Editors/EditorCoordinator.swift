import AppKit
import FormaCore
import SwiftUI

/// What every editor model provides to its window.
@MainActor
protocol EditorDocument: AnyObject {
    var url: URL { get }
    var isDirty: Bool { get }
    var undoManager: UndoManager? { get set }
    /// Writes over `url`. Called only after the user confirmed replacing the file.
    func save() throws
    /// Writes a modified copy chosen by the user.
    func saveCopy(in window: NSWindow?)
    func exportPDF(in window: NSWindow?)
    var canExportPDF: Bool { get }
    func biggerText()
    func smallerText()
}

extension EditorDocument {
    func biggerText() {}
    func smallerText() {}
}

/// Opens the right editor for a file and manages editor windows.
@MainActor
final class EditorCoordinator {
    static let shared = EditorCoordinator()
    private(set) var controllers: [EditorWindowController] = []

    enum Kind { case image, pdf, text }

    static func kind(for url: URL) -> Kind? {
        guard let format = FileTypeDetector().format(of: url) else { return nil }
        switch format.category {
        case .image: return format == .svg ? nil : .image
        case .pdf: return .pdf
        case .text: return .text
        case .document: return .text
        default: return nil
        }
    }

    static func canEdit(_ url: URL) -> Bool { kind(for: url) != nil }

    func open(_ url: URL) {
        if let existing = controllers.first(where: { $0.editorDocument.url.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let kind = Self.kind(for: url) else {
            Toast.show("Forma can't edit this kind of file.", symbol: "pencil.slash")
            return
        }
        do {
            let controller: EditorWindowController
            switch kind {
            case .image:
                let model = try ImageEditorModel(url: url)
                controller = EditorWindowController(document: model, content: AnyView(ImageEditorView(model: model)), size: NSSize(width: 980, height: 700))
            case .pdf:
                let model = try PDFEditorModel(url: url)
                controller = EditorWindowController(document: model, content: AnyView(PDFEditorView(model: model)), size: NSSize(width: 1000, height: 760))
            case .text:
                let model = try TextEditorModel(url: url)
                controller = EditorWindowController(document: model, content: AnyView(TextEditorView(model: model)), size: NSSize(width: 860, height: 700))
            }
            controllers.append(controller)
            updateActivationPolicy()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let e = FormaError.wrap(error)
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(url.lastPathComponent)”"
            alert.informativeText = e.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func closed(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        updateActivationPolicy()
    }

    /// Asks about unsaved edits before quitting. Returns false to cancel.
    func confirmCloseAll() -> Bool {
        for c in controllers where c.editorDocument.isDirty {
            c.window?.makeKeyAndOrderFront(nil)
            if !c.confirmDiscardOrSave() { return false }
        }
        return true
    }

    /// Regular app (Dock icon, menu bar) while windows are open; menu bar agent otherwise.
    func updateActivationPolicy() {
        let needsRegular = !controllers.isEmpty || SettingsWindowController.shared.isOpen || OnboardingWindowController.shared.isOpen
        let target: NSApplication.ActivationPolicy = needsRegular ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
            if needsRegular { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

/// Hosts one editor. Sits in the responder chain to receive Save / Save a Copy / Export.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    private var confirmedOverwrite = false

    init(document: EditorDocument, content: AnyView, size: NSSize) {
        self.editorDocument = document
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 620, height: 440)
        window.title = document.url.lastPathComponent
        window.representedURL = document.url
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("FormaEditor")
        let host = NSHostingController(rootView: content.ignoresSafeArea(.container, edges: .top))
        host.sizingOptions = [] // the window owns its size; don't grow to fit long documents
        window.contentViewController = host
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
        window.center()
        document.undoManager = window.undoManager
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        EditorCoordinator.shared.closed(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editorDocument.isDirty ? confirmDiscardOrSave() : true
    }

    func windowDidUpdate(_ notification: Notification) {
        window?.isDocumentEdited = editorDocument.isDirty
    }

    /// "Save changes?" Returns true if the window may close.
    func confirmDiscardOrSave() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to keep your edits to “\(editorDocument.url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            editorDocument.saveCopy(in: nil)
            return !editorDocument.isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Menu actions

    @objc func saveEdits(_ sender: Any?) { _ = performSave(confirmed: false) }

    @objc func saveCopy(_ sender: Any?) { editorDocument.saveCopy(in: window) }

    @objc func exportPDF(_ sender: Any?) { editorDocument.exportPDF(in: window) }

    @objc func biggerText(_ sender: Any?) { editorDocument.biggerText() }

    @objc func smallerText(_ sender: Any?) { editorDocument.smallerText() }

    /// Overwriting needs explicit consent once per window.
    @discardableResult
    func performSave(confirmed: Bool) -> Bool {
        if !confirmed && !confirmedOverwrite {
            let alert = NSAlert()
            alert.messageText = "Replace “\(editorDocument.url.lastPathComponent)” with your edits?"
            alert.informativeText = "The file will be overwritten. Choose Save a Copy to keep the current version."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Save a Copy…")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: editorDocument.saveCopy(in: window); return !editorDocument.isDirty
            default: return false
            }
        }
        do {
            try editorDocument.save()
            confirmedOverwrite = true
            window?.isDocumentEdited = false
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save “\(editorDocument.url.lastPathComponent)”"
            alert.informativeText = FormaError.wrap(error).localizedDescription
            alert.runModal()
            return false
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(exportPDF(_:)) { return editorDocument.canExportPDF }
        return true
    }
}

/// Shared save-panel helper used by editors.
@MainActor
enum SavePanel {
    static func run(suggestedName: String, types: [FileFormat], in window: NSWindow?, accessory: NSView? = nil, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = types.map(\.utType)
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory
        panel.accessoryView = accessory
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes data next to `url` via a temporary file and swaps it in atomically.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fm.removeItem(at: tmpDir) }
            let tmp = tmpDir.appendingPathComponent(url.lastPathComponent)
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    static func editedName(for url: URL, ext: String? = nil) -> String {
        url.deletingPathExtension().lastPathComponent + " edited." + (ext ?? url.pathExtension)
    }
}

/// Top bar shared by all editors: sits in the transparent titlebar area next to the traffic lights.
struct EditorTopBar<Content: View>: View {
    let title: String
    let badge: Editability?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let badge {
                    Text(badge.label).font(.system(size: 10)).foregroundStyle(.secondary).help(badge.detail)
                }
            }
            .frame(minWidth: 80, maxWidth: 220, alignment: .leading)
            Spacer(minLength: 8)
            content
        }
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .regular))
                .frame(width: 28, height: 24)
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(disabled ? 0.3 : 0.85))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Color.accentColor.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
