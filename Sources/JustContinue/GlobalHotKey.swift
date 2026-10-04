import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon `RegisterEventHotKey`; needs no permission).
@MainActor
final class GlobalHotKey {
    struct Shortcut: Equatable, Codable {
        var keyCode: UInt32
        /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
        var modifiers: UInt32
        /// e.g. "⌃⌥⌘J"
        var display: String

        /// ⌃⌥R ("resume"). Two modifiers, and free in the apps developers use most: ⌥⌘J is Chrome's
        /// console, ⌃⌘J Xcode's jump to definition, ⌃⌥J/C window managers, ⌃⌥Space input sources.
        static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")

        /// Builds a shortcut from a key press; nil without at least one of ⌘ ⌥ ⌃ (plain keys would clash with typing).
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
            var carbon: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
            self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
        }

        init(keyCode: UInt32, modifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Registers `shortcut`, replacing any previous one. Nil unregisters.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x4A43_4E54), id: 1)  // 'JCNT'
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }
}

/// Finds out whether a shortcut is already taken. macOS has no way to list every
/// shortcut in every app's menus, so this covers macOS's own shortcuts and a few well-known ones;
/// shortcuts other apps register globally show up when registration fails.
enum ShortcutConflicts {
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// Well-known shortcuts in apps developers use, keyed by "modifiers-keyCode".
    static let known: [String: String] = [
        key(optionKey | cmdKey, kVK_ANSI_J): "Chrome (JavaScript console)",
        key(optionKey | cmdKey, kVK_ANSI_I): "Chrome and Safari (developer tools)",
        key(optionKey | cmdKey, kVK_ANSI_C): "Chrome (inspect element)",
        key(controlKey | cmdKey, kVK_ANSI_J): "Xcode (jump to definition)",
        key(controlKey | optionKey, kVK_ANSI_J): "Rectangle and Magnet (window layout)",
        key(controlKey | optionKey, kVK_ANSI_C): "Rectangle and Magnet (center window)",
        key(controlKey | optionKey, kVK_ANSI_U): "Rectangle and Magnet (window layout)",
        key(controlKey | optionKey, kVK_ANSI_I): "Rectangle and Magnet (window layout)",
        key(controlKey | optionKey, kVK_ANSI_K): "Rectangle and Magnet (window layout)",
        key(optionKey, kVK_Space): "Raycast and Alfred (launcher), if set up",
        key(cmdKey, kVK_Space): "Spotlight",
    ]

    private static func key(_ modifiers: Int, _ keyCode: Int) -> String { "\(modifiers)-\(keyCode)" }

    /// A short description of what else uses `shortcut`, or nil if nothing known does.
    static func check(_ shortcut: GlobalHotKey.Shortcut) -> String? {
        if isSystemShortcut(shortcut) { return "macOS uses this shortcut (System Settings › Keyboard › Shortcuts)." }
        if let app = known[key(Int(shortcut.modifiers & modifierMask), Int(shortcut.keyCode))] { return "Also used by \(app)." }
        return nil
    }

    /// Enabled macOS shortcuts (Spotlight, input sources, screenshots, Mission Control…).
    static func isSystemShortcut(_ shortcut: GlobalHotKey.Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
            return code == shortcut.keyCode && (mods & modifierMask) == (shortcut.modifiers & modifierMask)
        }
    }
}
