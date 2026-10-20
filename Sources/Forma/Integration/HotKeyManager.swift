import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask).
struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥⌘K — free in Finder and most apps; configurable in Settings › Shortcuts.
    static let defaultKey = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        // Require at least one of ⌘ ⌥ ⌃ so plain typing is never captured.
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        default: break
        }
        let fkeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let f = fkeys[Int(code)] { return f }
        // Translate through the current keyboard layout so AZERTY etc. show the right glyph.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers one system-wide hotkey through Carbon's RegisterEventHotKey.
/// This needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    private init() {}

    func register(_ key: HotKey?) {
        unregister()
        guard let key else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x464F524D), id: 1) // 'FORM'
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Forma: couldn't register hotkey \(key.displayString) (status \(status)); it may be in use by another app.")
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    var isRegistered: Bool { ref != nil }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotKeyManager.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
