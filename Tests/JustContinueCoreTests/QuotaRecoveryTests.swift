import Foundation
import Testing
@testable import JustContinueCore

@MainActor
struct QuotaRecoveryTests {
    func usage(_ h: Harness, five: Double = 0, weekly: Double = 30,
               source: AgentUsage.Source = .liveAccount, age: TimeInterval = 0) -> AgentUsage {
        AgentUsage(fiveHour: .init(kind: .fiveHour, usedPercent: five, resetsAt: h.clock.value.addingTimeInterval(3600)),
                   weekly: .init(kind: .weekly, usedPercent: weekly, resetsAt: h.clock.value.addingTimeInterval(86400)),
                   updatedAt: h.clock.value.addingTimeInterval(-age), source: source)
    }

    func prepare(_ h: Harness, agent: AgentKind = .codex) async {
        var session = h.session(.limited(LimitEvent(resetAt: h.resetAt, window: "primary", message: "limit", loggedAt: h.clock.value)))
        session.agent = agent
        await h.show(session)
        h.engine.setEnabled(Harness.key, true)
        await h.advance(10)
    }

    @Test func codexResetCardShortensWaitAndKeepsDelay() async {
        let h = Harness()
        await prepare(h)
        h.activity.locked.value = true
        h.engine.updateCodexAccountUsage(usage(h))
        let due = h.clock.value.addingTimeInterval(h.engine.settings.resetDelay)
        #expect(h.row?.pending?.fireAt == due)
        await h.advance(30)
        h.engine.updateCodexAccountUsage(usage(h))
        #expect(h.row?.pending?.fireAt == due, "polls must not keep postponing continuation")
        #expect(h.input.sent.value.isEmpty)
        await h.advance(30)
        #expect(h.input.sent.value.count == 1)
        await h.advance(ResumeEngine.verifyWindow)
        #expect(h.row?.pending?.fireAt == h.clock.value.addingTimeInterval(ResumeEngine.retryDelays[0]))
        await h.advance(ResumeEngine.retryDelays[0])
        #expect(h.input.sent.value.count == 2, "retry backoff must not depend on the old recovery reading")
    }

    @Test func recoveryAsksWhileActive() async {
        let h = Harness()
        await prepare(h)
        h.engine.updateCodexAccountUsage(usage(h))
        await h.advance(60)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.phase == .askedUser)
    }

    @Test func ignoresStaleLocalIncompleteAndBlockedCodexUsage() async {
        let h = Harness()
        await prepare(h)
        let original = h.row?.pending?.fireAt
        var incomplete = usage(h); incomplete.weekly = nil
        var expired = usage(h); expired.fiveHour?.resetsAt = h.clock.value
        for sample in [usage(h, age: 121), usage(h, source: .localSnapshot), usage(h, weekly: 100),
                       usage(h, five: 100), usage(h, age: 20), incomplete, expired] {
            h.engine.updateCodexAccountUsage(sample)
            #expect(h.row?.pending?.fireAt == original)
        }
    }

    @Test func lostAvailabilityRestoresOriginalWait() async {
        let h = Harness()
        await prepare(h)
        let original = h.row?.pending?.fireAt
        h.engine.updateCodexAccountUsage(usage(h))
        #expect(h.row?.pending?.fireAt != original)
        h.engine.updateCodexAccountUsage(nil)
        #expect(h.row?.pending?.fireAt == original)
        h.engine.updateCodexAccountUsage(usage(h))
        h.engine.updateCodexAccountUsage(usage(h, weekly: 100))
        #expect(h.row?.pending?.fireAt == original)
    }

    @Test func claudeRequiresObservedRecovery() async {
        let h = Harness()
        await prepare(h, agent: .claude)
        let original = h.row?.pending?.fireAt
        h.engine.updateClaudeUsage(usage(h, source: .localSnapshot))
        #expect(h.row?.pending?.fireAt == original)
        h.engine.updateClaudeUsage(usage(h, five: 100, source: .localSnapshot))
        await h.advance(10)
        h.engine.updateClaudeUsage(usage(h, source: .localSnapshot))
        #expect(h.row?.pending?.fireAt == h.clock.value.addingTimeInterval(60))
        h.activity.locked.value = true
        await h.advance(60)
        #expect(h.input.sent.value.count == 1)
    }

    @Test func disabledSessionDoesNotResumeFromRecovery() async {
        let h = Harness()
        await prepare(h)
        h.engine.setEnabled(Harness.key, false)
        h.engine.updateCodexAccountUsage(usage(h))
        h.activity.locked.value = true
        await h.advance(60)
        #expect(h.row?.pending == nil)
        #expect(h.input.sent.value.isEmpty)
    }
    @Test func newLimitDuringRevalidationCancelsEarlySend() async {
        let h = Harness()
        await prepare(h)
        h.engine.updateCodexAccountUsage(usage(h))
        h.activity.locked.value = true
        let sessions = h.discovery.sessions
        let newDate = h.clock.value.addingTimeInterval(60)
        h.discovery.beforeRevalidate.value = {
            var values = sessions.value
            values[0].logState = .limited(LimitEvent(resetAt: newDate.addingTimeInterval(7200),
                window: "secondary", message: "new weekly limit", loggedAt: newDate))
            sessions.value = values
        }
        await h.advance(60)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.limit.window == "secondary")
        #expect(h.row?.pending?.fireAt == newDate.addingTimeInterval(7260))
    }

    @Test func expiredRecoveryEvidenceDoesNotSend() async {
        let h = Harness()
        await prepare(h)
        let original = h.row?.pending?.fireAt
        h.engine.updateCodexAccountUsage(usage(h))
        h.activity.locked.value = true
        await h.advance(121)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.fireAt == original)
    }

    @Test func claudeBuiltInContinueIsStillLeftAlone() async {
        let h = Harness()
        await prepare(h, agent: .claude)
        var sessions = h.discovery.sessions.value
        var limit = sessions[0].logState.limit!
        limit.continuedByAgent = true
        sessions[0].logState = .limited(limit)
        h.discovery.sessions.value = sessions
        await h.engine.tick()
        h.engine.updateClaudeUsage(usage(h, five: 100, source: .localSnapshot))
        await h.advance(10)
        h.engine.updateClaudeUsage(usage(h, source: .localSnapshot))
        h.activity.locked.value = true
        await h.advance(60)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending == nil)
    }

    @Test func queryTimeoutRetriesWithoutLosingQuotaRecoveryOrTypingEarly() async {
        let h = Harness()
        await prepare(h)
        h.activity.idle.value = 1000 // awake, screen on, and away; no lock required
        h.engine.updateCodexAccountUsage(usage(h))
        h.discovery.validationFailure.value = .failed(reason: "iTerm2: query timed out", retryable: true)
        await h.advance(60)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.validationFailures == 1)
        #expect(h.row?.outcome == nil)
        #expect(h.notifier.failed.isEmpty)
        h.discovery.validationFailure.value = nil
        h.engine.updateCodexAccountUsage(usage(h))
        await h.advance(29)
        #expect(h.input.sent.value.isEmpty, "quota updates must not override query retry delay")
        await h.advance(1)
        #expect(h.input.sent.value.count == 1)
    }

    @Test func queryRetriesAreBoundedAndExplainFailure() async {
        let h = Harness()
        await prepare(h)
        h.activity.locked.value = true
        h.engine.updateCodexAccountUsage(usage(h))
        h.discovery.validationFailure.value = .failed(reason: "iTerm2: query timed out", retryable: true)
        await h.advance(60)
        for _ in 0..<3 {
            h.engine.updateCodexAccountUsage(usage(h))
            await h.advance(30)
        }
        #expect(h.row?.pending == nil)
        #expect(h.notifier.failed == ["iTerm2: query timed out"])
        await h.advance(60)
        #expect(h.notifier.failed.count == 1)
        #expect(h.input.sent.value.isEmpty)
    }

    @Test func activityAndDisableStillPreventQueryRetryFromSending() async {
        let h = Harness()
        await prepare(h)
        h.activity.locked.value = true
        h.engine.updateCodexAccountUsage(usage(h))
        h.discovery.validationFailure.value = .failed(reason: "iTerm2: query timed out", retryable: true)
        await h.advance(60)
        h.discovery.validationFailure.value = nil
        h.activity.locked.value = false
        await h.advance(30)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending?.phase == .askedUser)
        h.engine.setEnabled(Harness.key, false)
        h.activity.locked.value = true
        await h.advance(60)
        #expect(h.input.sent.value.isEmpty)
        #expect(h.row?.pending == nil)
    }

    @Test func changedSessionFailsWithoutRetrying() async {
        let h = Harness()
        await prepare(h)
        h.activity.locked.value = true
        h.engine.updateCodexAccountUsage(usage(h))
        h.discovery.validationFailure.value = .failed(reason: "Agent terminal changed", retryable: false)
        await h.advance(60)
        #expect(h.row?.pending == nil)
        #expect(h.notifier.failed == ["Agent terminal changed"])
        #expect(h.input.sent.value.isEmpty)
    }

}
