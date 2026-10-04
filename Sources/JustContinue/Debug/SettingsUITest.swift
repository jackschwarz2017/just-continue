#if DEBUG
import AppKit
import Carbon.HIToolbox

/// `JustContinue --ui-test`: opens Settings and drives its text fields with real key events
/// (typing, ⌘A, ⌘V through the main menu, Tab, recording a shortcut), then checks the model.
/// Restores the original values afterwards. Debug builds only.
@MainActor
enum SettingsUITest {
    static func run(model: AppModel, settings: SettingsWindow, done: @escaping (Bool) -> Void) {
        let window: NSWindow = settings.window
        Task { @MainActor in
            let saved = (model.message, model.resetDelaySeconds, model.idleMinutes, model.shortcut)
            var results: [(String, Bool, String)] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) { results.append((name, ok, detail)); print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)") }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(800))
            print("  app active: \(NSApp.isActive), key window: \(window.isKeyWindow)")
            guard NSApp.isActive, window.isKeyWindow else {
                // macOS won't hand focus to a background launch while someone is using another app;
                // keyboard tests would then fail for reasons unrelated to the app.
                print("NOT RUN: couldn't take keyboard focus (another app is in use). Run again while the Mac is idle.")
                done(false)
                return
            }

            // 1. Message (Continuing tab): select all, type.
            settings.selected = .continuing
            try? await Task.sleep(for: .milliseconds(400))
            var root = window.contentView!
            if let field = find(NSTextView.self, in: root), field.isEditable {
                window.makeFirstResponder(field)
                send(window, key: kVK_ANSI_A, chars: "a", mods: .command)
                type(window, "keep going")
                try? await Task.sleep(for: .milliseconds(300))
                check("message: type", model.message == "keep going", "model.message = \"\(model.message)\"")

                // 2. Paste over a selection with ⌘V (needs the Edit menu).
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("pasted text", forType: .string)
                send(window, key: kVK_ANSI_A, chars: "a", mods: .command)
                send(window, key: kVK_ANSI_V, chars: "v", mods: .command)
                try? await Task.sleep(for: .milliseconds(300))
                check("message: ⌘A ⌘V", model.message == "pasted text", "model.message = \"\(model.message)\"")
                // Empty falls back to "continue" when sending; Reset restores the text.
                send(window, key: kVK_ANSI_A, chars: "a", mods: .command)
                send(window, key: kVK_Delete, chars: "\u{7f}", mods: [])
                try? await Task.sleep(for: .milliseconds(200))
                check("message: empty sends continue", model.message.isEmpty && model.engine.settings.continuationText == "continue", "message = \"\(model.message)\", sends \"\(model.engine.settings.continuationText)\"")
                // Line breaks become spaces.
                type(window, "line one")
                send(window, key: kVK_Return, chars: "\r", mods: [])
                type(window, "line two")
                try? await Task.sleep(for: .milliseconds(200))
                check("message: line breaks sent as spaces", model.engine.settings.continuationText == "line one line two", "sends \"\(model.engine.settings.continuationText)\"")
                // (Reset is a SwiftUI button, unreachable without VoiceOver attached; checked by screenshot.)
                model.message = "continue"
            } else {
                check("message text area found", false, "no editable text view")
            }

            // 3. Number field: replace 60 with 90 by typing.
            if let field = editableFields(in: root).first(where: { $0.stringValue == "\(model.resetDelaySeconds)" }) {
                focus(field, in: window)
                send(window, key: kVK_ANSI_A, chars: "a", mods: .command)
                type(window, "90")
                try? await Task.sleep(for: .milliseconds(300))
                check("wait before sending: type 90", model.resetDelaySeconds == 90, "model = \(model.resetDelaySeconds)")
                // Out of range is corrected on leaving the field.
                send(window, key: kVK_ANSI_A, chars: "a", mods: .command)
                type(window, "9999")
                window.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(300))
                check("wait before sending: 9999 rejected", model.resetDelaySeconds == 90 && field.stringValue == "90", "model = \(model.resetDelaySeconds), field = \"\(field.stringValue)\"")
            } else {
                check("number field found", false, "no field showing \(model.resetDelaySeconds)")
            }

            // 4. Shortcut (General tab): click the field, press ⌃⌥K.
            settings.selected = .general
            try? await Task.sleep(for: .milliseconds(400))
            root = window.contentView!
            if let recorder = find(ShortcutRecorderField.self, in: root) {
                recorder.mouseDown(with: mouseEvent(window))
                check("shortcut: recording starts", recorder.isRecording && model.isRecordingShortcut, "recording = \(recorder.isRecording)")
                send(window, key: kVK_ANSI_K, chars: "k", mods: [.control, .option])
                try? await Task.sleep(for: .milliseconds(200))
                check("shortcut: ⌃⌥K recorded", model.shortcut?.display == "⌃⌥K", "model.shortcut = \(model.shortcut?.display ?? "none")")
                check("shortcut: recording stops", !recorder.isRecording && !model.isRecordingShortcut, "recording = \(recorder.isRecording)")
                // ⌘ combos arrive via performKeyEquivalent.
                recorder.mouseDown(with: mouseEvent(window))
                send(window, key: kVK_ANSI_J, chars: "j", mods: [.command, .shift])
                try? await Task.sleep(for: .milliseconds(200))
                check("shortcut: ⇧⌘J recorded", model.shortcut?.display == "⇧⌘J", "model.shortcut = \(model.shortcut?.display ?? "none")")
                // Plain keys are refused, Esc cancels.
                recorder.mouseDown(with: mouseEvent(window))
                send(window, key: kVK_ANSI_X, chars: "x", mods: [])
                send(window, key: kVK_Escape, chars: "\u{1b}", mods: [])
                check("shortcut: plain key refused, Esc cancels", model.shortcut?.display == "⇧⌘J" && !recorder.isRecording, "model.shortcut = \(model.shortcut?.display ?? "none")")
                // Clicking shows the current shortcut (dimmed), never an empty field.
                recorder.mouseDown(with: mouseEvent(window))
                check("shortcut: stays visible while recording", recorder.placeholderString == "⇧⌘J", "placeholder = \(recorder.placeholderString ?? "-")")
                // Switching tabs mid-recording keeps it and ends recording.
                settings.selected = .continuing
                try? await Task.sleep(for: .milliseconds(300))
                check("shortcut: tab switch keeps it", model.shortcut?.display == "⇧⌘J" && !model.isRecordingShortcut, "shortcut = \(model.shortcut?.display ?? "none"), recording = \(model.isRecordingShortcut)")
                settings.selected = .general
                try? await Task.sleep(for: .milliseconds(300))
                if let again = find(ShortcutRecorderField.self, in: window.contentView!) {
                    again.mouseDown(with: mouseEvent(window))
                    window.performClose(nil)
                    try? await Task.sleep(for: .milliseconds(300))
                    check("shortcut: closing window keeps it", model.shortcut?.display == "⇧⌘J" && !model.isRecordingShortcut, "shortcut = \(model.shortcut?.display ?? "none"), recording = \(model.isRecordingShortcut)")
                }
            } else {
                check("shortcut field found", false, "")
            }

            // Restore.
            model.message = saved.0
            model.resetDelaySeconds = saved.1
            model.idleMinutes = saved.2
            model.shortcut = saved.3
            let ok = results.allSatisfy(\.1)
            print(ok ? "ALL PASSED (\(results.count))" : "FAILURES: \(results.filter { !$0.1 }.count) of \(results.count)")
            done(ok)
        }
    }

    // MARK: Helpers

    static func editableFields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = view as? NSTextField, f.isEditable, !(f is ShortcutRecorderField) { out.append(f) }
        for sub in view.subviews { out += editableFields(in: sub) }
        return out
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let v = view as? T, match(v) { return v }
        for sub in view.subviews { if let v = find(type, in: sub, where: match) { return v } }
        return nil
    }

    static func focus(_ field: NSTextField, in window: NSWindow) {
        window.makeFirstResponder(field)
    }

    /// Goes through NSApplication like real typing, so ⌘ shortcuts reach the main menu.
    static func send(_ window: NSWindow, key: Int, chars: String, mods: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(key)) else { continue }
            NSApp.sendEvent(event)
        }
    }

    static func type(_ window: NSWindow, _ text: String) {
        for ch in text { send(window, key: 0, chars: String(ch), mods: []) }
    }

    static func mouseEvent(_ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
#endif
