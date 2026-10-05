import JustContinueCore
import Foundation
import Observation

/// Thread-safe value holder for state shared with background scans.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Hidden test switches (hold ⌥ while opening the menu). Nothing here is persisted,
/// and simulated sessions can never be typed into: they have no real terminal behind them.
@MainActor
@Observable
final class DebugOptions {
    enum Activity { case away, active }

    var claudeInstalled: Bool?
    var codexInstalled: Bool?
    var hideUsage = false
    /// Made-up usage (`--demo` screenshots).
    var demoUsage: (claude: AgentUsage, codex: AgentUsage)?
    var terminalAccessDenied = false { didSet { deniedOverride.value = terminalAccessDenied } }
    @ObservationIgnored let deniedOverride = Locked(false)
    var notificationsOff = false
    var activity: Activity? { didSet { activityOverride.value = activity } }

    /// Shared with the scanning thread.
    @ObservationIgnored let simulated = Locked<[AgentSession]>([])
    @ObservationIgnored let activityOverride = Locked<Activity?>(nil)
    /// Test runs show only simulated sessions, so they can never touch real ones.
    @ObservationIgnored let hideRealSessions = Locked(false)
    @ObservationIgnored private var nextID: Int32 = 1

    nonisolated static let simulatedPrefix = "simulated:"

    var hasSimulatedSessions: Bool { !simulated.value.isEmpty }

    enum Scenario { case limitSoon, weeklyLimit, unsupported, ambiguousGhostty }

    /// A session whose limit resets in `seconds` (the menu uses 60).
    func addLimit(in seconds: TimeInterval, agent: AgentKind = .codex) {
        add(.limitSoon)
        var sessions = simulated.value
        guard var last = sessions.popLast(), case .limited(var limit) = last.logState else { return }
        limit.resetAt = Date().addingTimeInterval(seconds)
        last.logState = .limited(limit)
        last.agent = agent
        sessions.append(last)
        simulated.value = sessions
    }

    func add(_ scenario: Scenario) {
        let id = nextID
        nextID += 1
        let key = SessionKey(pid: -1000 - id, startTime: Date().timeIntervalSince1970)
        let now = Date()
        let location = TerminalLocation(kind: .iTerm, identifier: "\(Self.simulatedPrefix)\(id)", title: "Simulated")
        let session: AgentSession
        switch scenario {
        case .limitSoon:
            session = make(key, .codex, "Simulated · limit in 1 min",
                           .limited(LimitEvent(resetAt: now.addingTimeInterval(60), window: "primary", message: "Simulated limit", loggedAt: now)),
                           .ready(location))
        case .weeklyLimit:
            session = make(key, .claude, "Simulated · weekly limit",
                           .limited(LimitEvent(resetAt: now.addingTimeInterval(3 * 86400), window: "seven_day", message: "Simulated weekly limit", loggedAt: now)),
                           .ready(location))
        case .unsupported:
            session = make(key, .claude, "Simulated · in Warp", .running, .unsupported(hostName: "Warp"))
        case .ambiguousGhostty:
            session = make(key, .codex, "Simulated · two Ghostty tabs", .running, .ambiguous(.ghostty))
        }
        simulated.value.append(session)
    }

    func removeSimulatedSessions() { simulated.value = [] }

    /// Realistic-looking sessions for README screenshots (`--render <dir> --demo`).
    func addDemoSessions() {
        let now = Date()
        func location(_ kind: TerminalKind, _ n: Int) -> TerminalLocation {
            TerminalLocation(kind: kind, identifier: "\(Self.simulatedPrefix)demo-\(n)", title: "Demo")
        }
        func key(_ n: Int) -> SessionKey { SessionKey(pid: -2000 - Int32(n), startTime: now.timeIntervalSince1970) }
        let limit = LimitEvent(resetAt: now.addingTimeInterval(47 * 60), window: "primary", message: "Usage limit reached", loggedAt: now)
        let calendar = Calendar.current
        let thursday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 5), matchingPolicy: .nextTime)
        func usage(_ fiveHour: Double, _ weekly: Double, resetIn: TimeInterval) -> AgentUsage {
            AgentUsage(fiveHour: .init(kind: .fiveHour, usedPercent: fiveHour, resetsAt: now.addingTimeInterval(resetIn)),
                       weekly: .init(kind: .weekly, usedPercent: weekly, resetsAt: thursday), updatedAt: now)
        }
        demoUsage = (claude: usage(64, 21, resetIn: 3 * 3600 + 12 * 60), codex: usage(100, 38, resetIn: 47 * 60))
        simulated.value += [
            make(key(1), .codex, "Migrate billing to Stripe", .limited(limit), .ready(location(.iTerm, 1))),
            make(key(2), .claude, "Fix flaky login tests", .running, .ready(location(.iTerm, 2))),
            make(key(3), .codex, "api-server", .running, .ready(location(.tmux, 3))),
        ]
    }

    private func make(_ key: SessionKey, _ agent: AgentKind, _ name: String, _ state: LogState, _ r: Resumability) -> AgentSession {
        AgentSession(id: key, agent: agent, tty: "simulated", cwd: "/tmp/simulated", agentSessionID: "simulated-\(key.pid)",
                     name: name, logURL: nil, logState: state, resumability: r)
    }

    var isActive: Bool {
        claudeInstalled != nil || codexInstalled != nil || hideUsage || terminalAccessDenied || notificationsOff || activity != nil || hasSimulatedSessions
    }
}

/// Adds simulated sessions to real discovery.
struct DebugDiscovery: SessionDiscovering {
    let real: SessionDiscovering
    let simulated: Locked<[AgentSession]>
    let hideReal: Locked<Bool>
    let denied: Locked<Bool>

    private var deniedSession: AgentSession {
        AgentSession(id: SessionKey(pid: -9999, startTime: 1), agent: .codex, tty: "simulated",
                     cwd: "/tmp/simulated", agentSessionID: "simulated-denied", name: "Simulated · terminal access denied",
                     logURL: nil, logState: .running, resumability: .unsupported(hostName: "Terminal"))
    }

    func scan(previous: [SessionKey: TerminalLocation]) -> [AgentSession] {
        if denied.value { return [deniedSession] }
        return (hideReal.value ? [] : real.scan(previous: previous)) + simulated.value
    }

    func invalidateTerminalCache() { real.invalidateTerminalCache() }

    func revalidate(_ session: AgentSession) -> SessionValidation {
        guard !denied.value else { return .failed(reason: "Terminal access denial is being simulated", retryable: false) }
        if session.id.pid < 0 {
            return simulated.value.first { $0.id == session.id }.map(SessionValidation.valid)
                ?? .failed(reason: "Simulated session closed", retryable: false)
        }
        return hideReal.value ? .failed(reason: "Real sessions hidden", retryable: false) : real.revalidate(session)
    }
}

/// Never types into simulated sessions; "sending" to one just marks it as running again.
struct DebugInput: InputSending {
    let real: InputSending
    let denied: Locked<Bool>
    let simulated: Locked<[AgentSession]>

    func send(_ text: String, to location: TerminalLocation) -> Result<Void, InputError> {
        guard !denied.value else { return .failure(InputError(description: "Terminal access denial is being simulated.")) }
        guard location.identifier.hasPrefix(DebugOptions.simulatedPrefix) else { return real.send(text, to: location) }
        var sessions = simulated.value
        if let i = sessions.firstIndex(where: { $0.resumability.location?.identifier == location.identifier }) {
            sessions[i].logState = .running
            simulated.value = sessions
        }
        return .success(())
    }
}

/// Lets "Pretend I'm Away / Active" override real idle detection.
struct DebugActivity: ActivityMonitoring {
    let real: ActivityMonitoring
    let override: Locked<DebugOptions.Activity?>

    var idleSeconds: TimeInterval {
        switch override.value {
        case .away: 24 * 3600
        case .active: 0
        case nil: real.idleSeconds
        }
    }

    var isScreenLocked: Bool { override.value == nil ? real.isScreenLocked : false }
}


/// Leaves Claude Code sessions to Claude Code's own automatic continue unless the user wants Just
/// Continue to handle them too. Sessions it hides never reach the engine, so they're never
/// typed into; a hidden session that is waiting for a reset still keeps the Mac awake.
struct ClaudeHandoffDiscovery: SessionDiscovering {
    let inner: SessionDiscovering
    let continueClaude: Locked<Bool>
    /// Output: a hidden Claude Code session is limited and waiting for its reset.
    let hiddenWaiting: Locked<Bool>

    func scan(previous: [SessionKey: TerminalLocation]) -> [AgentSession] {
        let all = inner.scan(previous: previous)
        guard !continueClaude.value else {
            hiddenWaiting.value = false
            return all
        }
        let builtIn = ClaudeBuiltInContinue.isEnabled()
        let hidden = all.filter { ClaudeBuiltInContinue.handles($0, enabled: builtIn) }
        hiddenWaiting.value = hidden.contains { $0.logState.limit != nil }  // includes Claude Code's own wait
        return all.filter { !ClaudeBuiltInContinue.handles($0, enabled: builtIn) }
    }

    func invalidateTerminalCache() { inner.invalidateTerminalCache() }
    func revalidate(_ session: AgentSession) -> SessionValidation { inner.revalidate(session) }
}
