import Foundation

/// Lists running Claude Code / Codex sessions with their log state and terminal location.
public protocol SessionDiscovering: Sendable {
    func scan(previous: [SessionKey: TerminalLocation]) -> [AgentSession]
    /// Fresh, single-session check right before typing.
    func revalidate(_ session: AgentSession) -> AgentSession?
}

public struct SessionDiscovery: SessionDiscovering {
    let claude: ClaudeLog
    let codex: CodexLog
    private let snapshots = SnapshotCache()

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        claude = ClaudeLog(home: home)
        codex = CodexLog(home: home)
    }

    struct Candidate {
        var entry: ProcessEntry
        var agent: AgentKind
        var cwd: String?
    }

    public func scan(previous: [SessionKey: TerminalLocation]) -> [AgentSession] {
        let table = ProcessTable.all()
        let parents = Dictionary(table.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })

        var candidates: [Candidate] = []
        for entry in table where entry.tty != nil {
            let args = ProcessTable.arguments(pid: entry.pid)
            guard let agent = AgentIdentifier.identify(arguments: args, executablePath: ProcessTable.executablePath(pid: entry.pid)) else { continue }
            candidates.append(Candidate(entry: entry, agent: agent, cwd: ProcessTable.currentDirectory(pid: entry.pid)))
        }
        // Wrappers (e.g. a node launcher whose child is the real agent on the same tty) count once: keep the child.
        let all = candidates
        candidates.removeAll { c in all.contains { $0.entry.ppid == c.entry.pid && $0.entry.tty == c.entry.tty } }
        guard !candidates.isEmpty else { return [] }

        let snapshot = snapshots.snapshot(for: Set(candidates.map(\.entry.key)))
        let oldestCodex = candidates.filter { $0.agent == .codex }.map(\.entry.startTime).min()
        let rollouts = oldestCodex.map { codex.recentRollouts(since: Date(timeIntervalSince1970: $0)) } ?? []
        var claimed = Set<String>()

        // Oldest first, so each Codex process claims its own rollout before later ones look.
        return candidates.sorted { $0.entry.startTime < $1.entry.startTime }.map { c in
            build(c, snapshot: snapshot, parents: parents, previous: previous[c.entry.key], rollouts: rollouts, claimed: &claimed)
        }
    }

    func build(_ c: Candidate, snapshot: TerminalSnapshot, parents: [Int32: Int32], previous: TerminalLocation?,
               rollouts: [CodexLog.Rollout], claimed: inout Set<String>) -> AgentSession {
        var sessionID: String?
        var name: String?
        var logURL: URL?
        var state = LogState.unknown
        var cwd = c.cwd
        var version: String?

        switch c.agent {
        case .claude:
            if let meta = claude.meta(pid: c.entry.pid) {
                sessionID = meta.sessionID
                name = meta.name
                version = meta.version
                cwd = cwd ?? meta.cwd
                logURL = claude.transcript(sessionID: meta.sessionID)
            }
            if let logURL { state = claude.state(of: logURL) }
        case .codex:
            if let cwd, let r = CodexLog.match(cwd: cwd, processStart: Date(timeIntervalSince1970: c.entry.startTime), candidates: rollouts, excluding: claimed) {
                claimed.insert(r.id)
                sessionID = r.id
                logURL = r.url
                name = codex.threadName(id: r.id)
                state = codex.state(of: r.url)
            }
        }

        let tty = c.entry.tty ?? ""
        let host = TerminalLocator.hostAppName(pid: c.entry.pid, parents: parents)
        let resumability = TerminalLocator.locate(tty: tty, cwd: cwd, snapshot: snapshot, previous: previous, hostAppName: host)
        let folder = cwd.map { ($0 as NSString).lastPathComponent }
        return AgentSession(id: c.entry.key, agent: c.agent, tty: tty, cwd: cwd, agentSessionID: sessionID,
                            name: name?.isEmpty == false ? name! : (folder ?? c.agent.displayName),
                            logURL: logURL, logState: state, resumability: resumability, agentVersion: version)
    }

    public func revalidate(_ session: AgentSession) -> AgentSession? {
        guard let entry = ProcessTable.entry(pid: session.id.pid), abs(entry.startTime - session.id.startTime) < 1,
              entry.tty == session.tty else { return nil }
        var fresh = session
        if let url = session.logURL {
            fresh.logState = session.agent == .claude ? claude.state(of: url) : codex.state(of: url)
        }
        // A Claude session id can change inside one process (e.g. /clear); the old log is then stale.
        if session.agent == .claude, let meta = claude.meta(pid: entry.pid), meta.sessionID != session.agentSessionID {
            return nil
        }
        let snapshot = TerminalSnapshot.capture()
        let parents = Dictionary(ProcessTable.all().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        let host = session.resumability.location?.kind == .ghostty ? "Ghostty" : TerminalLocator.hostAppName(pid: entry.pid, parents: parents)
        fresh.resumability = TerminalLocator.locate(tty: session.tty, cwd: session.cwd, snapshot: snapshot,
                                                    previous: session.resumability.location, hostAppName: host)
        guard let old = session.resumability.location, let new = fresh.resumability.location, new.isSameTarget(as: old) else { return nil }
        return fresh
    }
}

/// Asking terminals for their tabs runs AppleScript, which is slow. While the same sessions are
/// running, the snapshot is reused for up to `maxAge`. Typing always takes a fresh one (`revalidate`).
final class SnapshotCache: @unchecked Sendable {
    static let maxAge: TimeInterval = 30
    private var cached: (keys: Set<SessionKey>, takenAt: Date, snapshot: TerminalSnapshot)?
    private let lock = NSLock()

    func snapshot(for keys: Set<SessionKey>, now: Date = Date(), capture: () -> TerminalSnapshot = TerminalSnapshot.capture) -> TerminalSnapshot {
        if let c = lock.withLock({ cached }), c.keys == keys, now.timeIntervalSince(c.takenAt) < Self.maxAge {
            return c.snapshot
        }
        let fresh = capture()
        lock.withLock { cached = (keys, now, fresh) }
        return fresh
    }
}
