import AppKit
import ApplicationServices
import FormaCore

/// Watches for Shift + right-click on Finder items using a CGEvent tap.
///
/// This is the only way to react to Shift + right-click without modifying Finder, and it
/// requires the Accessibility permission (an *active* tap can swallow the click so Finder's
/// own menu doesn't also appear). The tap is opt-in and never installed without permission.
/// When the clicked item can't be identified with certainty, the event passes through
/// untouched and Finder behaves normally.
@MainActor
final class EventTapManager {
    static let shared = EventTapManager()

    /// Called with the resolved files and the click location (Cocoa screen coordinates).
    var onShiftRightClick: ((FinderItemResolver.Resolution, NSPoint) -> Void)?
    /// Called on right-mouse-up while a wheel is open; returns true if it consumed the release
    /// (press–drag–release selection).
    var onRightMouseUp: ((NSPoint) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowNextRightUp = false
    private(set) var lastFailure: String?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            lastFailure = "Accessibility permission is required."
            return false
        }
        let mask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: eventTapCallback, userInfo: refcon) else {
            lastFailure = "macOS refused to create the event tap."
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lastFailure = nil
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Converts a Quartz (top-left origin) point into Cocoa (bottom-left origin) coordinates.
    static func cocoaPoint(fromQuartz p: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .rightMouseDown:
            let flags = event.flags
            let wantsShiftOnly = flags.contains(.maskShift) && flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl])
            guard wantsShiftOnly, SettingsManager.shared.shiftRightClickEnabled else { return Unmanaged.passUnretained(event) }
            let location = event.location
            guard let resolution = FinderItemResolver.resolve(at: location) else {
                return Unmanaged.passUnretained(event) // not a Finder file, or not certain: let Finder handle it
            }
            swallowNextRightUp = true
            let cocoa = Self.cocoaPoint(fromQuartz: location)
            DispatchQueue.main.async { [weak self] in self?.onShiftRightClick?(resolution, cocoa) }
            return nil
        case .rightMouseUp:
            let cocoa = Self.cocoaPoint(fromQuartz: event.location)
            if swallowNextRightUp {
                swallowNextRightUp = false
                DispatchQueue.main.async { [weak self] in _ = self?.onRightMouseUp?(cocoa) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// The tap is installed on the main run loop, so the callback runs on the main thread.
private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
    let input = UncheckedBox(event)
    let result = MainActor.assumeIsolated { UncheckedBox(manager.handle(type: type, event: input.value)) }
    return result.value
}
