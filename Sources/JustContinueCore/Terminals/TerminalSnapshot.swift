import Foundation

/// Everything the supported terminals report about their tabs, gathered in one pass.
/// Terminals that aren't running are skipped, never launched.
public struct TerminalSnapshot: Sendable {
    public struct Tab: Sendable, Equatable {
        public var identifier: String  // tty path, tmux pane id, or Ghostty terminal id
        public var title: String
        public var workingDirectory: String?
    }

    /// Keyed by tty name without "/dev/" (e.g. "ttys003").
    public var tmuxPanes: [String: Tab] = [:]
    public var iTermSessions: [String: Tab] = [:]
    public var terminalTabs: [String: Tab] = [:]
    public var ghosttyTerminals: [Tab] = []
    public var ghosttyVersion: String?

    public init() {}

    static let separator = "\u{1F}"  // unit separator, won't appear in titles

    public static func capture() -> TerminalSnapshot {
        var snap = TerminalSnapshot()

        if let tmux = Tmux.path {
            let r = Shell.run(tmux, ["list-panes", "-a", "-F", "#{pane_tty}\(separator)#{pane_id}\(separator)#{session_name}:#{window_index}.#{pane_index} #{pane_title}"])
            if r.ok {
                for line in r.output.split(separator: "\n") {
                    let f = line.components(separatedBy: separator)
                    guard f.count == 3 else { continue }
                    snap.tmuxPanes[ttyName(f[0])] = Tab(identifier: f[1], title: f[2], workingDirectory: nil)
                }
            }
        }

        if AppleScript.isRunning(bundleID: TerminalBundle.iTerm) {
            let r = AppleScript.run("""
            set sep to (ASCII character 31)
            set out to ""
            tell application id "\(TerminalBundle.iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set out to out & (tty of s) & sep & (name of s) & linefeed
                        end repeat
                    end repeat
                end repeat
            end tell
            return out
            """)
            for (tty, title) in pairs(r) { snap.iTermSessions[ttyName(tty)] = Tab(identifier: tty, title: title, workingDirectory: nil) }
        }

        if AppleScript.isRunning(bundleID: TerminalBundle.terminal) {
            let r = AppleScript.run("""
            set sep to (ASCII character 31)
            set out to ""
            tell application id "\(TerminalBundle.terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (tty of t) & sep & (custom title of t) & linefeed
                    end repeat
                end repeat
            end tell
            return out
            """)
            for (tty, title) in pairs(r) { snap.terminalTabs[ttyName(tty)] = Tab(identifier: tty, title: title, workingDirectory: nil) }
        }

        if AppleScript.isRunning(bundleID: TerminalBundle.ghostty) {
            let r = AppleScript.run("""
            set sep to (ASCII character 31)
            tell application id "\(TerminalBundle.ghostty)"
                set out to (version as text) & linefeed
                repeat with t in terminals
                    set wd to ""
                    try
                        set wd to (working directory of t) as text
                    end try
                    set out to out & (id of t) & sep & (name of t) & sep & wd & linefeed
                end repeat
            end tell
            return out
            """)
            if r.ok {
                var lines = r.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if !lines.isEmpty { snap.ghosttyVersion = lines.removeFirst() }
                for line in lines {
                    let f = line.components(separatedBy: separator)
                    guard f.count == 3 else { continue }
                    snap.ghosttyTerminals.append(Tab(identifier: f[0], title: f[1], workingDirectory: f[2].isEmpty ? nil : f[2]))
                }
            }
        }
        return snap
    }

    static func ttyName(_ path: String) -> String {
        path.hasPrefix("/dev/") ? String(path.dropFirst(5)) : path
    }

    private static func pairs(_ r: CommandResult) -> [(String, String)] {
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: separator)
            return f.count == 2 ? (f[0], f[1]) : nil
        }
    }
}

public enum Tmux {
    /// GUI apps get a minimal PATH, so look in the usual install locations.
    public static let path: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
