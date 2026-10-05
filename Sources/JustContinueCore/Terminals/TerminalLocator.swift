import Foundation

/// Finds the tab or pane an agent process runs in.
public enum TerminalLocator {
    /// - Parameters:
    ///   - tty: the agent's controlling tty, e.g. "ttys003".
    ///   - cwd: the agent's working directory (used for Ghostty, which exposes no tty).
    ///   - previous: the location found on an earlier scan, so a Ghostty match stays stable
    ///     once it has been resolved unambiguously.
    ///   - hostAppName: name of the GUI app found in the process ancestry, for messages.
    public static func locate(tty: String, cwd: String?, snapshot: TerminalSnapshot,
                              previous: TerminalLocation?, hostAppName: String?) -> Resumability {
        if let previous, snapshot.failures[previous.kind] != nil {
            return .ready(previous) // revalidation must still obtain a successful fresh query
        }
        // tmux first: an agent inside tmux is on the pane's tty, not the outer tab's.
        if let pane = snapshot.tmuxPanes[tty] {
            return .ready(TerminalLocation(kind: .tmux, identifier: pane.identifier, title: pane.title))
        }
        if let s = snapshot.iTermSessions[tty] {
            return .ready(TerminalLocation(kind: .iTerm, identifier: s.identifier, title: s.title))
        }
        if let t = snapshot.terminalTabs[tty] {
            return .ready(TerminalLocation(kind: .terminalApp, identifier: t.identifier, title: t.title))
        }
        if hostAppName == "Ghostty" {
            return locateGhostty(cwd: cwd, snapshot: snapshot, previous: previous)
        }
        return .unsupported(hostName: hostAppName)
    }

    static func locateGhostty(cwd: String?, snapshot: TerminalSnapshot, previous: TerminalLocation?) -> Resumability {
        guard snapshot.ghosttyVersion != nil else { return .unsupported(hostName: "Ghostty (needs 1.3 or later)") }
        guard let cwd else { return .ambiguous(.ghostty) }
        let candidates = snapshot.ghosttyTerminals.filter { normalize($0.workingDirectory) == normalize(cwd) }
        if let previous, previous.kind == .ghostty, let same = candidates.first(where: { $0.identifier == previous.identifier }) {
            return .ready(TerminalLocation(kind: .ghostty, identifier: same.identifier, title: same.title))
        }
        guard candidates.count == 1, let only = candidates.first else { return .ambiguous(.ghostty) }
        return .ready(TerminalLocation(kind: .ghostty, identifier: only.identifier, title: only.title))
    }

    static func normalize(_ path: String?) -> String? {
        guard var p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("file://"), let url = URL(string: p) { p = url.path }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Name of the first GUI app (`*.app`) in the process ancestry, e.g. "Ghostty" or "Warp".
    public static func hostAppName(pid: Int32, parents: [Int32: Int32]) -> String? {
        var current = parents[pid]
        var hops = 0
        while let p = current, p > 1, hops < 32 {
            if let path = ProcessTable.executablePath(pid: p), let range = path.range(of: ".app/Contents/MacOS/") {
                let appPath = String(path[..<range.lowerBound])
                return (appPath as NSString).lastPathComponent
            }
            current = parents[p]
            hops += 1
        }
        return nil
    }
}
