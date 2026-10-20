import AppKit
import FormaCore
import SwiftUI
import WebKit

struct TextEditorView: View {
    @Bindable var model: TextEditorModel
    @State private var dismissedBanner = false

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(title: model.url.lastPathComponent, badge: model.editability == .full ? nil : model.editability) { toolbar }
            if let note = model.limitationNote, !dismissedBanner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(note).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open in Default App") { model.openInDefaultApp() }.controlSize(.small)
                    Button { dismissedBanner = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.orange.opacity(0.08))
                .overlay(alignment: .bottom) { Divider() }
            }
            HSplitView {
                TextKitView(model: model)
                    .frame(minWidth: 280)
                if model.mode == .markdown && model.showPreview {
                    MarkdownPreview(html: model.previewHTML, baseURL: model.url.deletingLastPathComponent())
                        .frame(minWidth: 260)
                }
            }
            HStack {
                Text("\(model.wordCount) words")
                Spacer()
                Text(modeLabel)
                if model.isDirty { Text("· Edited") }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: 26)
            .background(.bar).overlay(alignment: .top) { Divider() }
        }
    }

    private var modeLabel: String {
        switch model.mode {
        case .plain: "Plain Text"
        case .markdown: "Markdown"
        case .rich: model.format.displayName
        }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "textformat.size.smaller", help: "Smaller Text (⌘−)") { model.smallerText() }
            ToolButton(symbol: "textformat.size.larger", help: "Bigger Text (⌘+)") { model.biggerText() }
            if model.mode == .rich {
                ToolButton(symbol: "bold", help: "Bold (⌘B)") { NSFontManager.shared.addFontTrait(BoldSender.shared) }
                ToolButton(symbol: "italic", help: "Italic (⌘I)") { NSFontManager.shared.addFontTrait(ItalicSender.shared) }
                ToolButton(symbol: "underline", help: "Underline (⌘U)") { NSApp.sendAction(#selector(NSText.underline(_:)), to: nil, from: nil) }
                ToolButton(symbol: "textformat", help: "Show Fonts (⌘T)") { NSFontManager.shared.orderFrontFontPanel(nil) }
            }
            ToolButton(symbol: "magnifyingglass", help: "Find and Replace (⌥⌘F)") {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            if model.mode == .markdown {
                ToolButton(symbol: "sidebar.right", help: "Preview", active: model.showPreview) { model.showPreview.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
        Divider().frame(height: 20)
        HStack(spacing: 2) {
            ToolButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            ToolButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            Menu {
                Button(model.editability == .full ? "Save (Replace Original)" : "Save (Replace Original, may lose formatting)") {
                    NSApp.sendAction(#selector(EditorWindowController.saveEdits(_:)), to: nil, from: nil)
                }
                Button("Save a Copy…") { NSApp.sendAction(#selector(EditorWindowController.saveCopy(_:)), to: nil, from: nil) }
                Divider()
                Button("Export as PDF…") { model.exportPDF(in: NSApp.keyWindow) }
                if model.mode == .markdown { Button("Export as HTML…") { model.exportHTML(in: NSApp.keyWindow) } }
            } label: {
                Text("Save").font(.system(size: 12, weight: .medium))
            } primaryAction: {
                if model.editability == .full {
                    NSApp.sendAction(#selector(EditorWindowController.saveEdits(_:)), to: nil, from: nil)
                } else {
                    NSApp.sendAction(#selector(EditorWindowController.saveCopy(_:)), to: nil, from: nil)
                }
            }
            .menuStyle(.borderedButton).fixedSize()
        }
    }
}

/// Font-trait senders for NSFontManager (it reads the tag of the sender).
@MainActor final class BoldSender: NSObject { static let shared = BoldSender(); @objc var tag: Int { Int(NSFontTraitMask.boldFontMask.rawValue) } }
@MainActor final class ItalicSender: NSObject { static let shared = ItalicSender(); @objc var tag: Int { Int(NSFontTraitMask.italicFontMask.rawValue) } }

struct TextKitView: NSViewRepresentable {
    let model: TextEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.allowsMagnification = model.mode == .rich
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.layoutManager?.replaceTextStorage(model.storage)
        tv.delegate = context.coordinator
        tv.isRichText = model.mode == .rich
        tv.importsGraphics = model.mode == .rich
        tv.allowsImageEditing = model.mode == .rich
        tv.usesFontPanel = model.mode == .rich
        tv.usesRuler = model.mode == .rich
        tv.isRulerVisible = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = model.mode == .rich
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = model.mode != .plain
        tv.textContainerInset = NSSize(width: model.mode == .rich ? 40 : 28, height: 24)
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        if model.mode != .rich {
            tv.font = model.baseFont
            tv.typingAttributes = [.font: model.baseFont, .foregroundColor: NSColor.labelColor]
        }
        tv.setAccessibilityLabel(model.url.lastPathComponent)
        model.textView = tv
        if model.mode == .markdown { MarkdownHighlighter.highlight(model.storage, baseFont: model.baseFont) }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = model.fontSize
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TextEditorModel
        private var highlightScheduled = false
        init(model: TextEditorModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            model.textDidChange()
            guard model.mode == .markdown, !highlightScheduled else { return }
            highlightScheduled = true
            // Re-highlight after the edit settles; attribute-only changes don't affect undo.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.highlightScheduled = false
                let selected = self.model.textView?.selectedRanges
                MarkdownHighlighter.highlight(self.model.storage, baseFont: self.model.baseFont)
                if let selected { self.model.textView?.selectedRanges = selected }
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { model.undoManager }
    }
}

/// Markdown preview rendered by WebKit with JavaScript disabled.
struct MarkdownPreview: NSViewRepresentable {
    let html: String
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.last = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.last != html else { return }
        context.coordinator.last = html
        view.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}
