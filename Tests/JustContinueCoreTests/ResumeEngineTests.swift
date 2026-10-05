import Foundation
import Testing
@testable import JustContinueCore

// MARK: - Fakes

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class FakeDiscovery: SessionDiscovering, @unchecked Sendable {
    let sessions = Box<[AgentSession]>([])
    func scan(previous: [SessionKey: TerminalLocation]) -> [AgentSession] { sessions.value }
    let beforeRevalidate = Box<(@Sendable () -> Void)?>(nil)
    let validationFailure = Box<SessionValidation?>(nil)
    func revalidate(_ session: AgentSession) -> SessionValidation {
        beforeRevalidate.value?()
        if let failure = validationFailure.value { return failure }
        return sessions.value.first { $0.id == session.id }.map(SessionValidation.valid)
            ?? .failed(reason: "Agent process is no longer available", retryable: false)
    }
}

final class FakeInput: InputSending, @unchecked Sendable {
    let sent = Box<[(String, TerminalLocation)]>([])
    func send(_ text: String, to location: TerminalLocation) -> Result<Void, InputError> {
        sent.value.append((text, location))
        return .success(())
    }
}

final class FakeActivity: ActivityMonitoring, @unchecked Sendable {
    let idle = Box<TimeInterval>(0)
    let locked = Box(false)
    var idleSeconds: TimeInterval { idle.value }
    var isScreenLocked: Bool { locked.value }
}

final class FakeSleep: SleepPreventing {
    var held = false
    var display = false
    func set(system: Bool, display: Bool) {
        held = system
        self.display = system && display
    }
}

@MainActor
final class FakeNotifier: Notifying {
    var ready: [(String, Bool)] = []
    var resumed: [String] = []
    var failed: [String] = []
    func notifyReady(_ session: AgentSession, canType: Bool) { ready.append((session.name, canType)) }
    func notifyResumed(_ session: AgentSession) { resumed.append(session.name) }
    func notifyFailed(_ session: AgentSession, reason: String) { failed.append(reason) }
}

// MARK: - Harness

@MainActor
final class Harness {
    let discovery = FakeDiscovery()
    let input = FakeInput()
    let activity = FakeActivity()
    let sleep = FakeSleep()
    let notifier = FakeNotifier()
    let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
    let engine: ResumeEngine

    static let key = SessionKey(pid: 42, startTime: 1_799_990_000)
    static let location = TerminalLocation(kind: .iTerm, identifier: "/dev/ttys004", title: "proj (claude)")

    init(settings: EngineSettings = EngineSettings()) {
        let clock = self.clock
        engine = ResumeEngine(settings: settings, discovery: discovery, input: input, activity: activity,
                              sleep: sleep, now: { clock.value })
        engine.setNotifier(notifier)
    }

    var resetAt: Date { clock.value.addingTimeInterval(3600) }

    func session(_ state: LogState, resumability: Resumability = .ready(Harness.location), key: SessionKey = Harness.key) -> AgentSession {
        AgentSession(id: key, agent: .claude, tty: "ttys004", cwd: "/proj", agentSessionID: "S", name: "proj",
                     logURL: nil, logState: state, resumability: resumability)
    }

    func limited(loggedAt: Date? = nil, resetAt: Date? = nil) -> LogState {
        .limited(LimitEvent(resetAt: resetAt ?? self.resetAt, message: "limit", loggedAt: loggedAt ?? clock.value))
    }

    func show(_ sessions: AgentSession...) async {
        discovery.sessions.value = sessions
        await engine.tick()
        await settle()
    }

    func advance(_ seconds: TimeInterval) async {
        clock.value = clock.value.addingTimeInterval(seconds)
        await engine.tick()
        await settle()
    }

    /// Waits for an in-flight send to finish.
    func settle() async {
        for _ in 0..<200 {
            if !engine.rows.contains(where: { $0.pending?.phase == .sending }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var row: SessionRow? { engine.rows.first }
}

// MARK: - Tests

@MainActor
@Suite struct ResumeEngineTests {
    @Test func sessionsAreOffByDefault() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-600))))
        h.activity.locked.value = true
        await h.advance(10)
        #expect(h.row?.enabled == false)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.sleep.held == false)
    }

    @Test func waitsForResetThenTypesWhenLocked() async {
        let h = Harness()
        let limit = h.limited()
        await h.show(h.session(limit))
        h.engine.setEnabled(Harness.key, true)
        #expect(h.row?.pending?.fireAt == h.resetAt.addingTimeInterval(60))
        #expect(h.sleep.held)

        h.activity.locked.value = true
        await h.advance(3600)  // reset reached, but the 60 s delay hasn't passed
        #expect(h.input.sent.value.isEmpty)

        await h.advance(61)
        #expect(h.input.sent.value.map(\.0) == ["continue"])
        #expect(h.input.sent.value.first?.1 == Harness.location)

        // The agent picks up: the log shows activity again.
        discoveryShows(h, .running)
        await h.advance(5)
        #expect(h.row?.pending == nil)
        if case .resumed = h.row?.outcome {} else { Issue.record("expected resumed, got \(String(describing: h.row?.outcome))") }
        #expect(h.notifier.resumed == ["proj"])
        #expect(h.sleep.held, "stays awake while the session is still enabled")
        h.engine.setEnabled(Harness.key, false)
        #expect(h.sleep.held == false)
    }

    @Test func asksInsteadOfTypingWhileUserIsActive() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.idle.value = 5
        h.engine.setEnabled(Harness.key, true)
        await h.advance(5)
        await h.advance(5)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.notifier.ready.count == 1)  // asked once, not on every tick
        #expect(h.notifier.ready.first?.1 == true)

        // User ignores the notification and walks away: resume after the idle threshold.
        h.activity.idle.value = 200
        await h.advance(5)
        #expect(h.input.sent.value.count == 1)
    }

    @Test(arguments: [false, true])
    func disablingDuringRevalidationCancelsSend(all: Bool) async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.locked.value = true
        h.discovery.beforeRevalidate.value = {
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                if all { h.engine.setAllEnabled(false) }
                else { h.engine.setEnabled(Harness.key, false) }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
        h.engine.setEnabled(Harness.key, true)
        await h.settle()
        // Allow the cancelled background revalidation to return to the engine.
        try? await Task.sleep(for: .milliseconds(50))
        h.discovery.beforeRevalidate.value = nil
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending == nil)
    }

    @Test func becomingActiveDuringRevalidationAsksInsteadOfSending() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.locked.value = true
        h.discovery.beforeRevalidate.value = { h.activity.locked.value = false }
        h.engine.setEnabled(Harness.key, true)
        await h.settle()
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.phase == .askedUser)
        #expect(h.notifier.ready.count == 1)
        h.discovery.beforeRevalidate.value = nil
        h.activity.idle.value = 200
        await h.advance(5)
        #expect(h.input.sent.value.count == 1)
    }

    @Test func continueNowTypesEvenWhileActive() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.idle.value = 1
        h.engine.continueNow(Harness.key)
        await h.settle()
        #expect(h.input.sent.value.count == 1)
    }

    @Test func unsupportedTerminalOnlyNotifies() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120)), resumability: .unsupported(hostName: "Warp")))
        h.activity.locked.value = true
        h.engine.setEnabled(Harness.key, true)
        await h.advance(5)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.notifier.ready.map(\.1) == [false])
    }

    @Test func closedSessionIsDropped() async {
        let h = Harness()
        await h.show(h.session(h.limited()))
        h.engine.setEnabled(Harness.key, true)
        #expect(h.sleep.held)
        await h.show()
        #expect(h.engine.rows.isEmpty)
        #expect(h.sleep.held == false)
        h.activity.locked.value = true
        await h.advance(4000)
        #expect(h.input.sent.value.isEmpty)
    }

    @Test func awakeWhileAnySessionIsEnabledOrManually() async {
        let h = Harness()
        await h.show(h.session(.running))
        #expect(h.sleep.held == false)
        h.engine.setEnabled(Harness.key, true)
        #expect(h.sleep.held, "enabled but not limited still keeps the Mac awake")
        h.engine.setEnabled(Harness.key, false)
        #expect(h.sleep.held == false)
        h.engine.settings.keepAwakeManually = true
        h.engine.updateSleep()
        #expect(h.sleep.held)
    }

    @Test func neverTypesWhileTheAgentContinuesItself() async {
        let h = Harness()
        let waiting = LogState.limited(LimitEvent(resetAt: h.clock.value.addingTimeInterval(-60), message: "Claude Code waits",
                                                 loggedAt: h.clock.value, continuedByAgent: true))
        await h.show(h.session(waiting))
        h.activity.locked.value = true
        h.engine.setEnabled(Harness.key, true)
        await h.advance(600)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending == nil)
    }

    @Test func manualResumeCancelsPending() async {
        let h = Harness()
        await h.show(h.session(h.limited()))
        h.engine.setEnabled(Harness.key, true)
        discoveryShows(h, .running)
        await h.advance(5)
        #expect(h.row?.pending == nil)
        h.activity.locked.value = true
        await h.advance(4000)
        #expect(h.input.sent.value.isEmpty)
    }

    @Test func retriesWithBackoffThenGivesUp() async {
        let h = Harness()
        let limit = h.limited(resetAt: h.clock.value.addingTimeInterval(-120))
        await h.show(h.session(limit))
        h.activity.locked.value = true
        h.engine.setEnabled(Harness.key, true)
        await h.settle()
        #expect(h.input.sent.value.count == 1)

        // Log never changes: still limited after each attempt.
        for (n, delay) in ResumeEngine.retryDelays.enumerated() {
            await h.advance(ResumeEngine.verifyWindow)
            #expect(h.input.sent.value.count == n + 1, "no immediate resend")
            await h.advance(delay)
            #expect(h.input.sent.value.count == n + 2)
        }
        await h.advance(ResumeEngine.verifyWindow)
        #expect(h.row?.pending == nil)
        #expect(h.notifier.failed.count == 1)
        // The same limit event is not scheduled again.
        await h.advance(3600)
        #expect(h.input.sent.value.count == ResumeEngine.retryDelays.count + 1)
    }

    @Test func dryRunNeverTypes() async {
        var settings = EngineSettings()
        settings.dryRun = true
        let h = Harness(settings: settings)
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.locked.value = true
        h.engine.setEnabled(Harness.key, true)
        await h.settle()
        #expect(h.input.sent.value.isEmpty)
        if case .dryRun = h.row?.outcome {} else { Issue.record("expected dry run outcome") }
    }

    @Test func missingResetTimeDoesNotGuess() async {
        let h = Harness()
        await h.show(h.session(.limited(LimitEvent(resetAt: nil, message: "limit", loggedAt: h.clock.value))))
        h.activity.locked.value = true
        h.engine.setEnabled(Harness.key, true)
        await h.advance(20_000)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.notifier.failed.count == 1)
    }

    @Test func continueAllTurnsTypableSessionsOnAndOff() async {
        let h = Harness()
        let a = h.session(.running, key: SessionKey(pid: 1, startTime: 1_799_990_000))
        let b = h.session(.running, key: SessionKey(pid: 2, startTime: 1_799_990_100))
        let warp = h.session(.running, resumability: .unsupported(hostName: "Warp"), key: SessionKey(pid: 3, startTime: 1_799_990_200))
        await h.show(a, b, warp)
        #expect(h.engine.allEnabled == false)
        h.engine.setAllEnabled(true)
        #expect(h.engine.rows.map(\.enabled) == [true, true, false])
        #expect(h.engine.allEnabled)
        h.engine.setAllEnabled(false)
        #expect(h.engine.rows.map(\.enabled) == [false, false, false])
    }

    @Test func newSessionsAutoEnableOnlyAfterTheSettingWasTurnedOn() async {
        var settings = EngineSettings()
        settings.autoEnableNew = true
        settings.autoEnableSince = Date(timeIntervalSince1970: 1_799_995_000)
        let h = Harness(settings: settings)
        let older = h.session(.running, key: SessionKey(pid: 1, startTime: 1_799_990_000))
        let newer = h.session(.running, key: SessionKey(pid: 2, startTime: 1_799_999_000))
        let newerWarp = h.session(.running, resumability: .unsupported(hostName: "Warp"), key: SessionKey(pid: 3, startTime: 1_799_999_500))
        await h.show(older, newer, newerWarp)
        #expect(h.engine.rows.map(\.enabled) == [false, true, false])
    }

    @Test func keepScreenOnAlsoKeepsTheMacAwake() async {
        var settings = EngineSettings()
        settings.keepDisplayOn = true
        let h = Harness(settings: settings)
        await h.show()
        #expect(h.sleep.held, "no sessions at all, but the screen is kept on")
        #expect(h.sleep.display)
        #expect(h.engine.isKeepingAwake)
        await h.show()
        #expect(h.sleep.held && h.sleep.display, "later scans don't release it")
        h.engine.settings.keepDisplayOn = false
        h.engine.updateSleep()
        #expect(h.sleep.held == false)
        #expect(h.sleep.display == false)
    }

    @Test func keepingAwakeLeavesTheScreenOptional() async {
        let h = Harness()
        await h.show()
        h.engine.settings.keepAwakeManually = true
        await h.show()
        #expect(h.sleep.held, "no sessions at all")
        #expect(h.sleep.display == false)
        await h.show(h.session(.running))
        h.engine.setEnabled(Harness.key, true)
        h.engine.settings.keepAwakeManually = false
        h.engine.updateSleep()
        #expect(h.sleep.held, "an enabled session keeps it awake")
        #expect(h.sleep.display == false)
    }

    @Test func doesNotTypeIfSessionChangedBeforeSending() async {
        let h = Harness()
        await h.show(h.session(h.limited(resetAt: h.clock.value.addingTimeInterval(-120))))
        h.activity.locked.value = true
        // Revalidation sees a different process (e.g. pid reused): nothing matches the key.
        h.discovery.sessions.value = []
        h.engine.setEnabled(Harness.key, true)
        await h.settle()
        #expect(h.input.sent.value.isEmpty)
        if case .failed = h.row?.outcome {} else { Issue.record("expected failure outcome") }
    }

    private func discoveryShows(_ h: Harness, _ state: LogState) {
        h.discovery.sessions.value = [h.session(state)]
    }
}
