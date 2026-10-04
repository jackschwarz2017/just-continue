import Foundation

public struct InputError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(description: String) { self.description = description }
}

/// Types into a located tab/pane without focusing it.
public enum TerminalInput {
    /// Pause between the text and Enter, so TUIs with paste detection see a real keypress.
    static let enterDelay: TimeInterval = 0.3

    public static func send(_ text: String, to location: TerminalLocation) -> Result<Void, InputError> {
        let r: CommandResult
        switch location.kind {
        case .tmux:
            guard let tmux = Tmux.path else { return .failure(InputError(description: "tmux not found")) }
            let typed = Shell.run(tmux, ["send-keys", "-t", location.identifier, "-l", text])
            guard typed.ok else { return .failure(InputError(description: "tmux: \(typed.error)")) }
            Thread.sleep(forTimeInterval: enterDelay)
            r = Shell.run(tmux, ["send-keys", "-t", location.identifier, "Enter"])

        case .iTerm:
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(AppleScript.literal(location.identifier)) then
                                tell s to write text \(AppleScript.literal(text)) newline no
                                delay \(enterDelay)
                                tell s to write text "" newline yes
                                return "sent"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "not found"
            """)

        case .terminalApp:
            // `do script` sends text and Return together; Terminal.app has no way to split them.
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(AppleScript.literal(location.identifier)) then
                            do script \(AppleScript.literal(text)) in t
                            return "sent"
                        end if
                    end repeat
                end repeat
            end tell
            return "not found"
            """)

        case .ghostty:
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.ghostty)"
                repeat with t in terminals
                    if (id of t) is \(AppleScript.literal(location.identifier)) then
                        input text \(AppleScript.literal(text)) to t
                        delay \(enterDelay)
                        send key "enter" to t
                        return "sent"
                    end if
                end repeat
            end tell
            return "not found"
            """)
        }

        if !r.ok { return .failure(InputError(description: r.error.isEmpty ? "exit \(r.status)" : r.error)) }
        if location.kind != .tmux, r.output != "sent" {
            return .failure(InputError(description: "\(location.kind.displayName) tab is gone"))
        }
        return .success(())
    }

    /// Brings the tab to the front. Only ever called from an explicit user action ("Show in …").
    /// tmux panes aren't tied to one terminal window, so they can't be shown this way.
    public static func show(_ location: TerminalLocation) -> Bool {
        let r: CommandResult
        switch location.kind {
        case .tmux:
            return false
        case .iTerm:
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(AppleScript.literal(location.identifier)) then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "shown"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case .terminalApp:
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(AppleScript.literal(location.identifier)) then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "shown"
                        end if
                    end repeat
                end repeat
            end tell
            """)
        case .ghostty:
            r = AppleScript.run("""
            tell application id "\(TerminalBundle.ghostty)"
                repeat with t in terminals
                    if (id of t) is \(AppleScript.literal(location.identifier)) then
                        focus t
                        activate
                        return "shown"
                    end if
                end repeat
            end tell
            """)
        }
        return r.ok && r.output == "shown"
    }
}
