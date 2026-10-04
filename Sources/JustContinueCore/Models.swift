import Foundation

public enum AgentKind: String, Sendable, Codable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Identity of a running agent process. pids are reused, so the start time is part of it.
public struct SessionKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let pid: Int32
    public let startTime: TimeInterval

    public init(pid: Int32, startTime: TimeInterval) {
        self.pid = pid
        self.startTime = startTime
    }

    public var description: String { "\(pid)@\(Int(startTime))" }
}

public struct LimitEvent: Sendable, Equatable {
    /// When the limit resets. Nil if neither the log nor the message contained it.
    public var resetAt: Date?
    /// e.g. "five_hour", "seven_day" (Claude) or "primary", "secondary" (Codex).
    public var window: String?
    /// The human-readable message the agent showed.
    public var message: String
    /// When the limit event was logged.
    public var loggedAt: Date?
    /// The agent itself is waiting and will continue on its own (Claude Code's automatic continue).
    /// Just Continue never types into such a session; it only keeps the Mac awake.
    public var continuedByAgent: Bool

    public init(resetAt: Date?, window: String? = nil, message: String, loggedAt: Date? = nil, continuedByAgent: Bool = false) {
        self.resetAt = resetAt
        self.window = window
        self.message = message
        self.loggedAt = loggedAt
        self.continuedByAgent = continuedByAgent
    }

    /// True for the weekly window (Claude `seven_day`, Codex `secondary`), whose reset can be days away.
    public var isWeekly: Bool {
        if let window { return window == "seven_day" || window == "secondary" || window.contains("week") }
        return message.lowercased().contains("weekly")
    }
}

public enum LogState: Sendable, Equatable {
    /// No log found or it couldn't be parsed.
    case unknown
    case running
    case limited(LimitEvent)

    public var limit: LimitEvent? {
        if case .limited(let e) = self { return e }
        return nil
    }
}

public enum TerminalKind: String, Sendable, Codable {
    case tmux
    case iTerm
    case terminalApp
    case ghostty

    public var displayName: String {
        switch self {
        case .tmux: "tmux"
        case .iTerm: "iTerm2"
        case .terminalApp: "Terminal"
        case .ghostty: "Ghostty"
        }
    }
}

/// Where a session can be typed into. `identifier` is stable for the life of the tab/pane:
/// a tty path for Terminal.app and iTerm2, a pane id for tmux, a terminal id for Ghostty.
public struct TerminalLocation: Hashable, Sendable {
    public var kind: TerminalKind
    public var identifier: String
    public var title: String?

    public init(kind: TerminalKind, identifier: String, title: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
    }

    /// Same tab/pane, ignoring the title (agents animate their titles).
    public func isSameTarget(as other: TerminalLocation) -> Bool {
        kind == other.kind && identifier == other.identifier
    }
}

public enum Resumability: Sendable, Equatable {
    case ready(TerminalLocation)
    /// Running in a terminal Just Continue can't type into, e.g. "Warp".
    case unsupported(hostName: String?)
    /// Several Ghostty terminals match and we refuse to guess.
    case ambiguous(TerminalKind)

    public var location: TerminalLocation? {
        if case .ready(let l) = self { return l }
        return nil
    }
}

public struct AgentSession: Sendable, Identifiable, Equatable {
    public var id: SessionKey
    public var agent: AgentKind
    public var tty: String
    public var cwd: String?
    /// Agent's own session/thread id, from its log.
    public var agentSessionID: String?
    /// Human-readable name (Claude session name, Codex thread name, or folder).
    public var name: String
    public var logURL: URL?
    public var logState: LogState
    public var resumability: Resumability
    /// The agent's version, when known (Claude Code writes it to its session file).
    public var agentVersion: String?

    public init(id: SessionKey, agent: AgentKind, tty: String, cwd: String?, agentSessionID: String?,
                name: String, logURL: URL?, logState: LogState, resumability: Resumability, agentVersion: String? = nil) {
        self.id = id
        self.agent = agent
        self.tty = tty
        self.cwd = cwd
        self.agentSessionID = agentSessionID
        self.name = name
        self.logURL = logURL
        self.logState = logState
        self.resumability = resumability
        self.agentVersion = agentVersion
    }

    public var folderName: String? { cwd.map { ($0 as NSString).lastPathComponent } }
}

extension AgentKind {
    /// Whether the agent's CLI is installed (binary in a usual location, or its data folder exists).
    /// GUI apps get a minimal PATH, so known install locations are checked directly.
    public var isInstalled: Bool {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let binaries: [String]
        let dataDir: String
        switch self {
        case .claude:
            binaries = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            dataDir = "\(home)/.claude/projects"
        case .codex:
            binaries = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
            dataDir = "\(home)/.codex/sessions"
        }
        return binaries.contains { fm.isExecutableFile(atPath: $0) } || fm.fileExists(atPath: dataDir)
    }
}
