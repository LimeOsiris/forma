import AppKit
import FormaCore
import SwiftUI

/// Borderless, non-activating panel: it takes keyboard focus without pulling Finder
/// out of the foreground, the same way system popovers behave.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the wheel and resolves clicks on the ring in AppKit, so the very first click
/// lands even though Finder (not Forma) is the active app. Cards (done/options) still
/// get normal SwiftUI event handling.
final class WheelHostingView: NSHostingView<RadialMenuView> {
    var isChoosing: () -> Bool = { false }
    var onRingClick: (CGPoint) -> Void = { _ in }
    var onRingRelease: (CGPoint) -> Void = { _ in }
    private var downAt: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI returns nil over transparent areas; while choosing, claim the whole panel so a
    /// click beside the ring dismisses the wheel instead of silently doing nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isChoosing(), frame.contains(point) { return self }
        return super.hitTest(point)
    }

    /// Point relative to the wheel center, y growing downward (matches RadialGeometry).
    private func centered(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: isFlipped ? p.y - bounds.midY : bounds.midY - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard isChoosing() else { return super.mouseDown(with: event) }
        downAt = centered(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isChoosing() else { return super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isChoosing(), let start = downAt else { return super.mouseUp(with: event) }
        downAt = nil
        let end = centered(event)
        // A press that starts on the hub and is released over a segment selects it too.
        if hypot(end.x - start.x, end.y - start.y) < 6 { onRingClick(end) } else { onRingRelease(end) }
    }
}

/// Owns the floating wheel window: placement, keyboard, dismissal and animation.
@MainActor
final class RadialMenuController {
    struct Handlers {
        var select: (WheelAction) -> Void
        var confirmOptions: () -> Void
        var cancelWork: () -> Void
        var done: (RadialMenuActions.DoneChoice) -> Void
        var dismissed: () -> Void
    }

    private(set) var panel: WheelPanel?
    private(set) var model: RadialMenuModel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var shownAt = Date.distantPast
    private var autoCloseTask: Task<Void, Never>?
    var handlers: Handlers?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Show / hide

    func show(_ model: RadialMenuModel, at point: NSPoint) {
        dismiss(animated: false)
        self.model = model
        let size = CGSize(width: model.diameter + RadialMenuView.margin * 2, height: model.diameter + RadialMenuView.margin * 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = WheelPlacement.frame(size: size, centeredAt: point, in: screen.visibleFrame)

        let panel = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel("Forma")

        let view = RadialMenuView(model: model, actions: RadialMenuActions(
            select: { [weak self] i in self?.select(index: i) },
            dismiss: { [weak self] in self?.dismiss() },
            cancelWork: { [weak self] in self?.handlers?.cancelWork() },
            confirmOptions: { [weak self] in self?.handlers?.confirmOptions() },
            cancelOptions: { [weak self] in self?.model?.phase = .choosing },
            done: { [weak self] choice in self?.handlers?.done(choice) }
        ))
        let host = WheelHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.isChoosing = { [weak model] in model?.phase == .choosing && model?.busy == false }
        host.onRingClick = { [weak self] p in self?.ringClick(p, releaseOnly: false) }
        host.onRingRelease = { [weak self] p in self?.ringClick(p, releaseOnly: true) }
        panel.contentView = host
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        installMonitors()
        // Trigger the entrance animation on the next runloop turn so SwiftUI sees the change.
        DispatchQueue.main.async { model.appeared = true }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "Forma. \(model.actions.count) options for \(model.hubTitle). Use arrow keys to choose.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func dismiss(animated: Bool = true) {
        autoCloseTask?.cancel()
        removeMonitors()
        guard let panel else { return }
        self.panel = nil
        let wasModel = model
        model = nil
        if animated && !(wasModel?.reduceMotion ?? true) {
            wasModel?.appeared = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        } else {
            panel.orderOut(nil)
        }
        handlers?.dismissed()
    }

    /// Hide the wheel but let a running conversion continue in the background.
    func detachIfWorking() -> Bool {
        if case .working = model?.phase { dismiss(); return true }
        return false
    }

    // MARK: Selection

    func select(index: Int) {
        guard let model, model.actions.indices.contains(index), model.phase == .choosing, !model.busy else { return }
        let action = model.actions[index]
        switch action {
        case .more:
            model.stage = .overflow
            model.hovered = nil
            model.keyboardFocus = model.keyboardFocus == nil ? nil : 0
        case .back:
            model.stage = .primary
            model.hovered = nil
            model.keyboardFocus = model.keyboardFocus == nil ? nil : model.plan.primary.count - 1
        default:
            handlers?.select(action)
        }
    }

    private func ringClick(_ p: CGPoint, releaseOnly: Bool) {
        guard let model else { return }
        let g = RadialGeometry(count: model.actions.count, outerRadius: model.diameter / 2, innerRadius: model.diameter * 0.215)
        switch g.region(dx: p.x, dy: p.y) {
        case .segment(let i): select(index: i)
        case .outside where !releaseOnly: dismiss()
        default: break
        }
    }

    /// Press–drag–release: releasing the right button over a segment selects it.
    func handleRightMouseUp(at point: NSPoint) -> Bool {
        guard let panel, let model, model.phase == .choosing, Date().timeIntervalSince(shownAt) > 0.25 else { return false }
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let g = RadialGeometry(count: model.actions.count, outerRadius: model.diameter / 2, innerRadius: model.diameter * 0.215)
        if case .segment(let i) = g.region(dx: point.x - c.x, dy: -(point.y - c.y), slack: 0) {
            select(index: i)
            return true
        }
        return false
    }

    func scheduleAutoClose(after seconds: Double = 8) {
        autoCloseTask?.cancel()
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, let panel = self.panel else { return }
            if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                self.scheduleAutoClose(after: 3)
            } else {
                self.dismiss()
            }
        }
    }

    // MARK: Keyboard & outside clicks

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }) { monitors.append(m) }
        // Clicks in other apps dismiss the wheel (no permission needed for mouse monitors).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.shownAt) > 0.15 else { return }
                if case .working = self.model?.phase { _ = self.detachIfWorking() } else { self.dismiss() }
            }
        }) { monitors.append(m) }
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                // Losing focus to our own save panel or editor is fine; losing it elsewhere closes a pristine wheel.
                if model.phase == .choosing && NSApp.modalWindow == nil && !(NSApp.keyWindow is NSSavePanel) {
                    self.dismiss()
                }
            }
        }
        resignObserver = token
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Returns true when the key was handled.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard let model, e.window === panel || e.window == nil else { return false }
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        if !flags.isEmpty && e.keyCode != 53 { return false }
        let g = RadialGeometry(count: model.actions.count, outerRadius: 1, innerRadius: 0)

        switch model.phase {
        case .options:
            if e.keyCode == 53 { model.phase = .choosing; return true }
            return false // let the card's buttons (Return) handle it
        case .working:
            if e.keyCode == 53 { handlers?.cancelWork(); return true }
            return true
        case .done, .failed:
            if e.keyCode == 53 { dismiss(); return true }
            return false // card buttons own their shortcuts
        case .choosing:
            if model.busy { return true }
        }

        switch e.keyCode {
        case 53: // escape
            if model.stage == .overflow { model.stage = .primary; model.keyboardFocus = nil } else { dismiss() }
        case 124, 125: // → ↓
            model.hovered = nil
            model.keyboardFocus = g.step(from: model.keyboardFocus, by: 1)
        case 123, 126: // ← ↑
            model.hovered = nil
            model.keyboardFocus = g.step(from: model.keyboardFocus, by: -1)
        case 48: // tab
            model.hovered = nil
            model.keyboardFocus = g.step(from: model.keyboardFocus, by: e.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76, 49: // return, enter, space
            if let i = model.highlighted { select(index: i) } else { model.keyboardFocus = 0 }
        default:
            if let chars = e.charactersIgnoringModifiers, let n = Int(chars), (1...model.actions.count).contains(n) {
                select(index: n - 1)
            } else {
                return false
            }
        }
        return true
    }
}
