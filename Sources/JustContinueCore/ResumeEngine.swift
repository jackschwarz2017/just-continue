import Foundation
import Observation

public protocol InputSending: Sendable {
    func send(_ text: String, to location: TerminalLocation) -> Result<Void, InputError>
}

public struct TerminalInputSender: InputSending {
    public init() {}
    public func send(_ text: String, to location: TerminalLocation) -> Result<Void, InputError> {
        TerminalInput.send(text, to: location)
    }
}

public protocol SleepPreventing: AnyObject {
    func set(system: Bool, display: Bool)
}

extension SleepPreventer: SleepPreventing {}

@MainActor
public protocol Notifying: AnyObject {
    /// The limit has reset. `canType` is false when we can't type into this terminal.
    func notifyReady(_ session: AgentSession, canType: Bool)
    func notifyResumed(_ session: AgentSession)
    func notifyFailed(_ session: AgentSession, reason: String)
}

public struct EngineSettings: Sendable, Equatable {
    public var continuationText = "continue"
    /// No input for this long counts as "away".
    public var idleThreshold: TimeInterval = 180
    /// Extra wait after the reset time.
    public var resetDelay: TimeInterval = 60
    public var keepAwake = true
    /// Keep the Mac awake even with no session enabled ("Keep Mac Awake" in the menu).
    public var keepAwakeManually = false
    /// Also keep the display on (and so unlocked by idle) while keeping awake.
    public var keepDisplayOn = false
    /// Turn on sessions that start after `autoEnableSince`. Off by default.
    public var autoEnableNew = false
    public var autoEnableSince: Date?
    /// Log what would be sent instead of typing.
    public var dryRun = false

    public init() {}
}

public struct PendingResume: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting for `fireAt`.
        case waiting
        /// Reset reached but the user is at the Mac (or we can't type); notification shown.
        case askedUser
        /// Sending right now.
        case sending
        /// Sent; waiting for the log to show the agent working again.
        case verifying(sentAt: Date)
    }

    public var limit: LimitEvent
    public var fireAt: Date
    var quotaRestoredAt: Date?
    public var attempts = 0
    public var phase = Phase.waiting
    /// Distinguishes a pending send from one cancelled and scheduled again.
    var sendID = UUID()
}

public enum Outcome: Equatable, Sendable {
    case resumed(Date)
    case dryRun(Date)
    case failed(String)
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public var session: AgentSession
    public var enabled: Bool
    public var pending: PendingResume?
    public var outcome: Outcome?
    /// A limit event we already finished with (resumed, failed or dry-run), so it isn't scheduled again.
    var handledLimit: LimitEvent?

    public var id: SessionKey { session.id }
}

public struct ActivityEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let text: String
}

/// Decides when to resume which session.
@MainActor
@Observable
public final class ResumeEngine {
    public private(set) var rows: [SessionRow] = []
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var isKeepingAwake = false
    public private(set) var lastScan: Date?
    public var settings: EngineSettings

    /// Retry delays after a send that didn't take.
    public static let retryDelays: [TimeInterval] = [120, 300, 600]
    /// How long to wait for the log to show activity after sending.
    public static let verifyWindow: TimeInterval = 45

    @ObservationIgnored let discovery: SessionDiscovering
    @ObservationIgnored let input: InputSending
    @ObservationIgnored let activityMonitor: ActivityMonitoring
    @ObservationIgnored let sleep: SleepPreventing
    @ObservationIgnored weak var notifier: Notifying?
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var codexAccountUsage: AgentUsage?
    @ObservationIgnored private var claudeUsage: AgentUsage?
    @ObservationIgnored private var claudeRestoredAt: Date?
    /// Receives every activity line (for the detailed log).
    @ObservationIgnored public var logSink: ((String) -> Void)?
    /// Extra reason to keep the Mac awake, e.g. a Claude Code session waiting to continue on its own.
    @ObservationIgnored public var keepAwakeAlso: (() -> Bool)?
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(settings: EngineSettings = EngineSettings(),
                discovery: SessionDiscovering = SessionDiscovery(),
                input: InputSending = TerminalInputSender(),
                activity: ActivityMonitoring = SystemActivity(),
                sleep: SleepPreventing = SleepPreventer(),
                notifier: Notifying? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.discovery = discovery
        self.input = input
        self.activityMonitor = activity
        self.sleep = sleep
        self.notifier = notifier
        self.now = now
    }

    public func setNotifier(_ notifier: Notifying) { self.notifier = notifier }

    // MARK: - Loop

    public func start(interval: TimeInterval = 5) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        sleep.set(system: false, display: false)
        isKeepingAwake = false
    }

    public func tick() async {
        await refresh()
        evaluate()
    }

    public func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let previous = Dictionary(rows.compactMap { r in r.session.resumability.location.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let discovery = self.discovery
        let sessions = await Task.detached { discovery.scan(previous: previous) }.value
        apply(sessions)
    }

    public func refreshTerminalLocations() async {
        discovery.invalidateTerminalCache()
        await refresh()
    }

    /// Live account availability can supersede an old Codex limit message (e.g. a reset card).
    public func updateCodexAccountUsage(_ usage: AgentUsage?) {
        codexAccountUsage = usage
        evaluate()
    }

    /// Claude has local snapshots only: require an observed full-to-available transition.
    public func updateClaudeUsage(_ usage: AgentUsage?) {
        if let usage, let updatedAt = usage.updatedAt,
           let previous = claudeUsage, let previousAt = previous.updatedAt, updatedAt > previousAt,
           [previous.fiveHour, previous.weekly].compactMap({ $0 }).contains(where: { $0.usedPercent >= 100 }),
           windowsAvailable(usage, at: now()) {
            claudeRestoredAt = updatedAt
        } else if usage == nil || usage.map({ !windowsAvailable($0, at: now()) }) == true {
            claudeRestoredAt = nil
        }
        claudeUsage = usage
        evaluate()
    }

    private func quotaAvailable(for session: AgentSession, at time: Date) -> Bool {
        guard let limit = session.logState.limit, let loggedAt = limit.loggedAt else { return false }
        let usage: AgentUsage?
        switch session.agent {
        case .codex:
            guard limit.window == "primary" || limit.window == "secondary",
                  codexAccountUsage?.source == .liveAccount else { return false }
            usage = codexAccountUsage
        case .claude:
            guard let restoredAt = claudeRestoredAt, restoredAt > loggedAt else { return false }
            usage = claudeUsage
        }
        guard let usage, let updatedAt = usage.updatedAt, updatedAt > loggedAt,
              (0...120).contains(time.timeIntervalSince(updatedAt)) else { return false }
        return windowsAvailable(usage, at: time)
    }

    private func windowsAvailable(_ usage: AgentUsage, at time: Date) -> Bool {
        // Require both windows: resetting the short window cannot unblock a full weekly quota.
        guard let fiveHour = usage.fiveHour, let weekly = usage.weekly else { return false }
        return [fiveHour, weekly].allSatisfy { window in
            guard let reset = window.resetsAt, reset > time,
                  let percent = window.percent(at: time) else { return false }
            return percent.isFinite && (0..<100).contains(percent)
        }
    }

    // MARK: - User actions

    public func setEnabled(_ key: SessionKey, _ enabled: Bool) {
        guard let i = index(key) else { return }
        rows[i].enabled = enabled
        if !enabled {
            rows[i].pending = nil
        }
        log("\(enabled ? "Enabled" : "Disabled") \(rows[i].session.name)", about: rows[i].session)
        evaluate()
    }

    /// "Continue All Sessions" in the menu: turn every session we can type into on, or all off.
    public func setAllEnabled(_ enabled: Bool) {
        for i in rows.indices where rows[i].session.resumability.location != nil && rows[i].enabled != enabled {
            rows[i].enabled = enabled
            if !enabled { rows[i].pending = nil }
        }
        log(enabled ? "Turned on all sessions" : "Turned off all sessions")
        evaluate()
    }

    /// True when there's at least one session we can type into and all of them are on.
    public var allEnabled: Bool {
        let typable = rows.filter { $0.session.resumability.location != nil }
        return !typable.isEmpty && typable.allSatisfy(\.enabled)
    }

    /// "Continue now", from the menu or a notification. Sends regardless of activity.
    public func continueNow(_ key: SessionKey) {
        guard let i = index(key) else { return }
        if rows[i].pending == nil, let limit = rows[i].session.logState.limit {
            rows[i].pending = PendingResume(limit: limit, fireAt: now())
        }
        guard rows[i].pending != nil else { return }
        attemptResume(at: i, userInitiated: true)
    }

    // MARK: - Merge

    func apply(_ sessions: [AgentSession]) {
        lastScan = now()
        let byKey = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows where byKey[row.id] == nil {
            log("\(row.session.name) closed", about: row.session)
        }
        var updated: [SessionRow] = []
        for session in sessions {
            if var row = rows.first(where: { $0.id == session.id }) {
                row.session = session
                updated.append(row)
            } else {
                let auto = settings.autoEnableNew && session.resumability.location != nil
                    && settings.autoEnableSince.map { session.id.startTime >= $0.timeIntervalSince1970 } == true
                if auto { log("Auto-enabled new session \(session.name)", about: session) }
                updated.append(SessionRow(session: session, enabled: auto))
            }
        }
        rows = updated
    }

    // MARK: - Decisions

    public func evaluate() {
        let t = now()
        for i in rows.indices where rows[i].enabled {
            let limit = rows[i].session.logState.limit

            // The agent continues by itself (Claude Code's automatic continue): never type.
            if limit?.continuedByAgent == true {
                rows[i].pending = nil
                continue
            }
            if rows[i].pending == nil, let limit, limit != rows[i].handledLimit {
                // Also covers enabling a session whose reset already passed: it fires below, right away.
                schedule(at: i, limit: limit)
            }
            guard var pending = rows[i].pending else { continue }

            switch pending.phase {
            case .sending:
                continue

            case .waiting, .askedUser:
                guard let limit else {
                    log("\(rows[i].session.name) continued without Just Continue", about: rows[i].session)
                    rows[i].pending = nil
                    continue
                }
                if limit.loggedAt != pending.limit.loggedAt, let reset = limit.resetAt {
                    pending.limit = limit
                    pending.quotaRestoredAt = nil
                    pending.fireAt = reset.addingTimeInterval(settings.resetDelay)
                    pending.phase = .waiting
                    rows[i].pending = pending
                }
                if pending.attempts == 0, let reset = limit.resetAt {
                    if quotaAvailable(for: rows[i].session, at: t) {
                        if pending.quotaRestoredAt == nil {
                            pending.quotaRestoredAt = t
                            log("Quota is available again for \(rows[i].session.name)", about: rows[i].session)
                        }
                        pending.fireAt = min(reset.addingTimeInterval(settings.resetDelay),
                                             pending.quotaRestoredAt!.addingTimeInterval(settings.resetDelay))
                    } else if pending.quotaRestoredAt != nil {
                        pending.quotaRestoredAt = nil
                        pending.fireAt = reset.addingTimeInterval(settings.resetDelay)
                        pending.phase = .waiting
                    }
                    rows[i].pending = pending
                }
                if t >= pending.fireAt { attemptResume(at: i, userInitiated: false) }

            case .verifying(let sentAt):
                guard let limit else {
                    rows[i].pending = nil
                    rows[i].outcome = .resumed(sentAt)
                    rows[i].handledLimit = pending.limit
                    log("Continued \(rows[i].session.name)", about: rows[i].session)
                    notifier?.notifyResumed(rows[i].session)
                    continue
                }
                guard t.timeIntervalSince(sentAt) >= Self.verifyWindow else { continue }
                // Still limited after sending: either a fresh limit (reset not over yet) or the input didn't submit.
                if pending.attempts > Self.retryDelays.count {
                    fail(at: i, reason: "Still limited after \(pending.attempts) attempts")
                } else {
                    let delay = Self.retryDelays[pending.attempts - 1]
                    pending.limit = limit
                    pending.fireAt = t.addingTimeInterval(delay)
                    pending.quotaRestoredAt = nil
                    pending.phase = .waiting
                    rows[i].pending = pending
                    log("\(rows[i].session.name) still limited; retrying in \(Int(delay / 60)) min", about: rows[i].session)
                }
            }
        }
        updateSleep()
    }

    func schedule(at i: Int, limit: LimitEvent) {
        guard let reset = limit.resetAt else {
            // No reset time anywhere: don't guess; tell the user once.
            rows[i].handledLimit = limit
            rows[i].outcome = .failed("Couldn't read the reset time")
            log("\(rows[i].session.name): limit reached but no reset time found", about: rows[i].session)
            notifier?.notifyFailed(rows[i].session, reason: "Couldn't read the reset time from the limit message.")
            return
        }
        rows[i].pending = PendingResume(limit: limit, fireAt: reset.addingTimeInterval(settings.resetDelay))
        rows[i].outcome = nil
        log("\(rows[i].session.name) hit its limit; continuing at \(Self.timeFormatter.string(from: reset))", about: rows[i].session)
    }

    func attemptResume(at i: Int, userInitiated: Bool) {
        guard var pending = rows[i].pending, pending.phase != .sending else { return }
        let session = rows[i].session

        guard session.resumability.location != nil else {
            if pending.phase != .askedUser {
                pending.phase = .askedUser
                rows[i].pending = pending
                log("\(session.name) is ready to continue (can't type into this terminal)", about: session)
                notifier?.notifyReady(session, canType: false)
            }
            return
        }

        if !userInitiated {
            let away = activityMonitor.isScreenLocked || activityMonitor.idleSeconds >= settings.idleThreshold
            if !away {
                // Never type or take focus while the user is working.
                if pending.phase != .askedUser {
                    pending.phase = .askedUser
                    rows[i].pending = pending
                    log("\(session.name) is ready; you're active, so asking instead of typing", about: session)
                    notifier?.notifyReady(session, canType: true)
                }
                return
            }
        }

        pending.phase = .sending
        pending.sendID = UUID()
        let sendID = pending.sendID
        rows[i].pending = pending
        let text = settings.continuationText
        let dryRun = settings.dryRun
        let discovery = self.discovery
        let input = self.input
        let key = session.id

        Task {
            // Terminal revalidation can take seconds. Recheck permission to send after it finishes.
            let fresh = await Task.detached { discovery.revalidate(session) }.value
            guard let current = self.index(key),
                  self.rows[current].pending?.sendID == sendID,
                  self.rows[current].pending?.phase == .sending else { return }
            if !userInitiated {
                guard self.rows[current].enabled else { return }
                if let fresh, let freshLimit = fresh.logState.limit, freshLimit != self.rows[current].pending?.limit {
                    // A new limit arrived while revalidating; never send against the previous one.
                    self.rows[current].session = fresh
                    self.rows[current].pending = nil
                    self.evaluate()
                    return
                }
                if self.rows[current].pending?.quotaRestoredAt != nil,
                   let fresh, fresh.logState.limit != nil, !self.quotaAvailable(for: fresh, at: self.now()) {
                    self.rows[current].pending?.phase = .waiting
                    self.evaluate()
                    return
                }
                let away = self.activityMonitor.isScreenLocked || self.activityMonitor.idleSeconds >= self.settings.idleThreshold
                if !away {
                    self.rows[current].pending?.phase = .askedUser
                    self.notifier?.notifyReady(self.rows[current].session, canType: true)
                    return
                }
            }
            let result: SendResult = await Task.detached {
                guard let fresh else { return .failed("Session changed or closed") }
                guard fresh.logState.limit != nil else { return .alreadyContinued }
                guard let target = fresh.resumability.location else { return .failed("Terminal tab not found") }
                if dryRun { return .sent(fresh) }
                switch input.send(text, to: target) {
                case .success: return .sent(fresh)
                case .failure(let error): return .failed(error.description)
                }
            }.value
            guard let current = self.index(key), self.rows[current].pending?.sendID == sendID else { return }
            self.finishSend(key: key, result: result, dryRun: dryRun)
        }
    }

    enum SendResult: Sendable {
        case sent(AgentSession)
        case alreadyContinued
        case failed(String)
    }

    func finishSend(key: SessionKey, result: SendResult, dryRun: Bool) {
        guard let i = index(key), var pending = rows[i].pending else { return }
        switch result {
        case .sent(let fresh):
            rows[i].session = fresh
            if dryRun {
                rows[i].pending = nil
                rows[i].handledLimit = pending.limit
                rows[i].outcome = .dryRun(now())
                log("Dry run: would have typed into \(fresh.name) (\(fresh.resumability.location?.kind.displayName ?? "?"))", about: fresh)
            } else {
                pending.attempts += 1
                pending.phase = .verifying(sentAt: now())
                rows[i].pending = pending
                log("Typed the message into \(fresh.name) (attempt \(pending.attempts))", about: fresh)
            }
        case .alreadyContinued:
            rows[i].pending = nil
            rows[i].handledLimit = pending.limit
            log("\(rows[i].session.name) had already continued", about: rows[i].session)
        case .failed(let reason):
            fail(at: i, reason: reason)
        }
        updateSleep()
    }

    func fail(at i: Int, reason: String) {
        let pending = rows[i].pending
        rows[i].pending = nil
        rows[i].handledLimit = pending?.limit
        rows[i].outcome = .failed(reason)
        log("Couldn't continue \(rows[i].session.name): \(reason)", about: rows[i].session)
        notifier?.notifyFailed(rows[i].session, reason: reason)
    }

    public func updateSleep() {
        // Awake as soon as any session is set to auto-resume, not only while a reset is pending.
        let hold = settings.keepAwakeManually || (keepAwakeAlso?() ?? false)
            || (settings.keepAwake && rows.contains(where: \.enabled))
        sleep.set(system: hold, display: settings.keepDisplayOn)
        if hold != isKeepingAwake {
            isKeepingAwake = hold
            log(hold ? "Keeping the Mac awake" : "No longer keeping the Mac awake")
        }
    }

    // MARK: - Helpers

    func index(_ key: SessionKey) -> Int? { rows.firstIndex { $0.id == key } }

    /// Adds a line to the activity list and `logSink`. The session's name is replaced by its process
    /// id: these lines end up in diagnostic reports.
    func log(_ text: String, about session: AgentSession? = nil) {
        let text = session.map { text.replacingOccurrences(of: $0.name, with: "session \($0.id)") } ?? text
        logSink?(text)
        activity.insert(ActivityEntry(date: now(), text: text), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

}
