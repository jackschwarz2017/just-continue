import Foundation
import Testing
@testable import JustContinueCore

// Fixtures are synthetic, shaped after real Claude Code 2.1 / Codex 0.160 logs.

private func entries(_ lines: [String]) -> [[String: Any]] { lines.compactMap(JSONLines.parse) }

enum ClaudeFixture {
    static let user = #"{"type":"user","isSidechain":false,"timestamp":"2026-09-14T10:00:00.000Z","message":{"role":"user","content":"do the thing"}}"#
    static let reply = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-09-14T10:00:05.000Z","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"On it."}]}}"#
    static let limit = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-09-14T11:28:17.150Z","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 1:30pm (Europe/Berlin)"}]},"quotaLimits":{"status":"rejected","resetsAt":1789385400,"rateLimitType":"five_hour"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}"#
    static let limitNoTimestamp = #"{"type":"assistant","timestamp":"2026-09-14T11:28:17.150Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 1:30pm (Europe/Berlin)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}"#
    static let localCommand = #"{"type":"system","subtype":"local_command","timestamp":"2026-09-14T11:40:00.000Z"}"#
    static let attachment = #"{"type":"attachment","timestamp":"2026-09-14T11:40:01.000Z"}"#
    static let sidechainReply = #"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-14T11:41:00.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"subagent"}]}}"#
}

@Suite struct ClaudeLogTests {
    @Test func limitedWithExactResetTime() throws {
        let state = ClaudeLog.state(entries: entries([ClaudeFixture.user, ClaudeFixture.reply, ClaudeFixture.limit]))
        let limit = try #require(state.limit)
        #expect(limit.resetAt == Date(timeIntervalSince1970: 1789385400))
        #expect(limit.window == "five_hour")
        #expect(limit.message.contains("resets 1:30pm"))
    }

    @Test func noiseAfterLimitDoesNotCountAsResumed() {
        let state = ClaudeLog.state(entries: entries([ClaudeFixture.limit, ClaudeFixture.localCommand, ClaudeFixture.attachment, ClaudeFixture.user, ClaudeFixture.sidechainReply]))
        #expect(state.limit != nil)
    }

    @Test func realReplyAfterLimitMeansRunning() {
        #expect(ClaudeLog.state(entries: entries([ClaudeFixture.limit, ClaudeFixture.user, ClaudeFixture.reply])) == .running)
    }

    @Test func noLimitMeansRunning() {
        #expect(ClaudeLog.state(entries: entries([ClaudeFixture.user, ClaudeFixture.reply])) == .running)
    }

    @Test func claudeCodesOwnWaitIsRecognisedButNotOurs() throws {
        let waiting = #"{"type":"system","subtype":"informational","timestamp":"2026-10-03T15:20:00.000Z","content":"Usage limit reached · continuing automatically at 5:50pm · esc to cancel"}"#
        let reset = #"{"type":"system","subtype":"informational","timestamp":"2026-10-03T15:50:30.000Z","content":"Usage limit reset · continuing automatically"}"#
        let cancelled = #"{"type":"system","subtype":"informational","timestamp":"2026-10-03T15:21:00.000Z","content":"Automatic continue cancelled"}"#
        let limit = try #require(ClaudeLog.state(entries: entries([ClaudeFixture.user, waiting])).limit)
        #expect(limit.continuedByAgent)
        #expect(limit.resetAt != nil)
        #expect(ClaudeLog.state(entries: entries([ClaudeFixture.user, waiting, reset])) == .running)
        #expect(ClaudeLog.state(entries: entries([ClaudeFixture.user, waiting, cancelled])) == .running)
    }

    @Test func emptyLogIsUnknown() {
        #expect(ClaudeLog.state(entries: []) == .unknown)
    }

    @Test func fallsBackToMessageText() throws {
        let limit = try #require(ClaudeLog.state(entries: entries([ClaudeFixture.limitNoTimestamp])).limit)
        // 1:30pm Berlin (CEST, UTC+2) on the day it was logged = 11:30 UTC.
        #expect(limit.resetAt == ISO8601.date("2026-09-14T11:30:00Z"))
    }
}

enum CodexFixture {
    static let started = #"{"timestamp":"2026-10-03T07:34:40.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
    static let tokens99 = #"{"timestamp":"2026-10-03T08:49:11.832Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1791031091},"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1791617891}}}}"#
    static let tokens100 = #"{"timestamp":"2026-10-03T08:49:19.202Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1791031091},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":1791617891}}}}"#
    static let tokensWeeklyOut = #"{"timestamp":"2026-10-03T08:49:19.202Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40.0,"resets_at":1791031091},"secondary":{"used_percent":100.0,"resets_at":1791617891}}}}"#
    static let premiumNull = #"{"timestamp":"2026-10-03T08:49:20.195Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#
    static let limit = #"{"timestamp":"2026-10-03T08:49:20.202Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 2:38 PM.","codex_error_info":"usage_limit_exceeded"}}}"#
    static let normalComplete = #"{"timestamp":"2026-10-03T08:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#
    static let lateItem = #"{"timestamp":"2026-10-03T09:03:48.999Z","type":"event_msg","payload":{"type":"item_completed"}}"#
}

@Suite struct CodexLogTests {
    @Test func limitedUsesExhaustedWindowReset() throws {
        let state = CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.tokens99, CodexFixture.tokens100, CodexFixture.premiumNull, CodexFixture.limit]))
        let limit = try #require(state.limit)
        #expect(limit.resetAt == Date(timeIntervalSince1970: 1791031091))
        #expect(limit.window == "primary")
    }

    @Test func weeklyWindowExhausted() throws {
        let limit = try #require(CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.tokensWeeklyOut, CodexFixture.limit])).limit)
        #expect(limit.resetAt == Date(timeIntervalSince1970: 1791617891))
        #expect(limit.window == "secondary")
    }

    @Test func noWindowAt100PicksTheFullestNotTheLatestReset() throws {
        let limit = try #require(CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.tokens99, CodexFixture.limit])).limit)
        #expect(limit.window == "primary")
        #expect(limit.resetAt == Date(timeIntervalSince1970: 1791031091))
    }

    @Test func lateBackgroundItemDoesNotCountAsResumed() {
        let state = CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.tokens100, CodexFixture.limit, CodexFixture.lateItem]))
        #expect(state.limit != nil)
    }

    @Test func newTurnAfterLimitMeansRunning() {
        #expect(CodexLog.state(entries: entries([CodexFixture.tokens100, CodexFixture.limit, CodexFixture.started])) == .running)
    }

    @Test func normalCompletionIsRunning() {
        #expect(CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.normalComplete])) == .running)
    }

    @Test func fallsBackToMessageText() throws {
        let limit = try #require(CodexLog.state(entries: entries([CodexFixture.started, CodexFixture.limit])).limit)
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let expected = ResetTimeParser.parse("try again at 2:38 PM", after: ISO8601.date("2026-10-03T08:49:20Z")!, timeZone: .current)
        #expect(limit.resetAt == expected)
        _ = berlin
    }

    @Test func subagentRolloutsAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("rollout-a.jsonl")
        let sub = dir.appendingPathComponent("rollout-b.jsonl")
        try #"{"type":"session_meta","payload":{"id":"A","cwd":"/p","timestamp":"2026-10-03T07:34:38Z","source":"cli"}}"#.write(to: main, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"B","cwd":"/p","timestamp":"2026-10-03T07:40:00Z","source":{"subagent":{"other":"guardian"}}}}"#.write(to: sub, atomically: true, encoding: .utf8)
        #expect(CodexLog.rollout(url: main, modifiedAt: Date())?.id == "A")
        #expect(CodexLog.rollout(url: sub, modifiedAt: Date()) == nil)
    }

    @Test func matchesRolloutCreatedRightAfterProcessStart() {
        let start = ISO8601.date("2026-10-03T07:34:36Z")!
        func r(_ id: String, _ cwd: String, _ started: String, modified: String) -> CodexLog.Rollout {
            CodexLog.Rollout(url: URL(fileURLWithPath: "/\(id)"), id: id, cwd: cwd, startedAt: ISO8601.date(started)!, modifiedAt: ISO8601.date(modified)!)
        }
        let candidates = [
            r("other-dir", "/x", "2026-10-03T07:34:37Z", modified: "2026-10-03T09:00:00Z"),
            r("mine", "/p", "2026-10-03T07:34:38Z", modified: "2026-10-03T08:49:20Z"),
            r("later", "/p", "2026-10-03T08:10:00Z", modified: "2026-10-03T09:10:00Z"),
        ]
        #expect(CodexLog.match(cwd: "/p", processStart: start, candidates: candidates, excluding: [])?.id == "mine")
        // If "mine" is claimed by another process, fall back to the most recently written one in /p.
        #expect(CodexLog.match(cwd: "/p", processStart: start, candidates: candidates.sorted { $0.modifiedAt > $1.modifiedAt }, excluding: ["mine"])?.id == "later")
    }
}

@Suite struct ResetTimeParserTests {
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func claudeFormatWithZone() {
        let ref = ISO8601.date("2026-09-14T09:28:17Z")!  // 11:28 Berlin
        #expect(ResetTimeParser.parse("resets 1:30pm (Europe/Berlin)", after: ref) == ISO8601.date("2026-09-14T11:30:00Z"))
    }

    @Test func claudeHourOnly() {
        let ref = ISO8601.date("2026-09-23T18:00:00Z")!  // 20:00 Berlin → next morning
        #expect(ResetTimeParser.parse("You've hit your weekly limit · resets 9am (Europe/Berlin)", after: ref) == ISO8601.date("2026-09-24T07:00:00Z"))
    }

    @Test func codexFormatUsesLocalZone() {
        let ref = ISO8601.date("2026-10-03T08:49:20Z")!
        #expect(ResetTimeParser.parse("…or try again at 2:38 PM.", after: ref, timeZone: berlin) == ISO8601.date("2026-10-03T12:38:00Z"))
    }

    @Test func rollsOverToNextDay() {
        let ref = ISO8601.date("2026-10-03T22:00:00Z")!  // midnight Berlin
        #expect(ResetTimeParser.parse("try again at 2:38 AM", after: ref, timeZone: berlin) == ISO8601.date("2026-10-04T00:38:00Z"))
    }

    @Test func noonAndMidnight() {
        let ref = ISO8601.date("2026-10-03T06:00:00Z")!
        #expect(ResetTimeParser.parse("resets 12pm (Europe/Berlin)", after: ref) == ISO8601.date("2026-10-03T10:00:00Z"))
        #expect(ResetTimeParser.parse("resets 12am (Europe/Berlin)", after: ref) == ISO8601.date("2026-10-03T22:00:00Z"))
    }

    @Test func unrelatedText() {
        #expect(ResetTimeParser.parse("everything is fine", after: Date()) == nil)
    }
}

@Suite struct AgentIdentifierTests {
    @Test(arguments: [
        (["claude"], nil, AgentKind?.some(.claude)),
        (["claude", "--resume", "abc"], nil, .claude),
        (["claude", "-p", "hi"], nil, nil),
        (["2.1.288"], "/Users/x/.local/share/claude/versions/2.1.288", .claude),
        (["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], nil, .claude),
        (["codex"], nil, .codex),
        (["codex", "resume"], nil, .codex),
        (["/opt/homebrew/bin/codex", "app-server", "--listen", "unix://"], nil, nil),
        (["codex", "exec", "do it"], nil, nil),
        (["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"], nil, .codex),
        (["zsh"], nil, nil),
    ] as [([String], String?, AgentKind?)])
    func identify(args: [String], path: String?, expected: AgentKind?) {
        #expect(AgentIdentifier.identify(arguments: args, executablePath: path) == expected)
    }
}

@Suite struct UsageTests {
    @Test func claudeReadsStatusLineInput() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1791031091},"seven_day":{"used_percentage":18.5,"resets_at":1791617891}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let usage = try #require(UsageReader.claude(file: file))
        #expect(usage.fiveHour?.usedPercent == 42)
        #expect(usage.weekly?.usedPercent == 18.5)
        #expect(usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1791031091))
    }

    @Test func expiredSnapshotDoesNotInventZeroUsage() {
        let w = AgentUsage.Window(kind: .fiveHour, usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 100))
        #expect(w.percent(at: Date(timeIntervalSince1970: 50)) == 80)
        #expect(w.percent(at: Date(timeIntervalSince1970: 100)) == nil)
        #expect(w.percent(at: Date(timeIntervalSince1970: 150)) == nil)
    }

    @Test func statusLineSuggestion() {
        #expect(ClaudeStatusLineSetup.suggestedCommand(current: "bash ~/.claude/statusline.sh") == "tee ~/.claude/justcontinue-usage.json | bash ~/.claude/statusline.sh")
        #expect(ClaudeStatusLineSetup.suggestedCommand(current: nil) == "tee ~/.claude/justcontinue-usage.json > /dev/null")
    }
}

@Suite struct ClaudeStatusLineSetupTests {
    func tempHome(settings: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        if let settings { try settings.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8) }
        return home
    }

    @Test func connectAndDisconnectKeepExistingStatusLine() throws {
        let home = try tempHome(settings: #"{"model":"opus","statusLine":{"type":"command","command":"bash ~/.claude/sl.sh","padding":0}}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        try ClaudeStatusLineSetup.connect(home: home)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == "tee ~/.claude/justcontinue-usage.json | bash ~/.claude/sl.sh")
        #expect(ClaudeStatusLineSetup.isSetUp(home: home))
        try ClaudeStatusLineSetup.connect(home: home)  // idempotent
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == "tee ~/.claude/justcontinue-usage.json | bash ~/.claude/sl.sh")

        try ClaudeStatusLineSetup.disconnect(home: home)
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let obj = try #require(JSONLines.parse(data))
        #expect(obj[path: "statusLine", "command"] as? String == "bash ~/.claude/sl.sh")
        #expect(obj[path: "statusLine", "padding"] as? Int == 0)
        #expect(obj["model"] as? String == "opus")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.justcontinue-backup").path))
    }

    @Test func withoutStatusLineUsesSilentTeeAndRemovesItAgain() throws {
        let home = try tempHome(settings: #"{"model":"opus"}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        try ClaudeStatusLineSetup.connect(home: home)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == ClaudeStatusLineSetup.silentTee)
        try ClaudeStatusLineSetup.disconnect(home: home)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == nil)
    }

    @Test func connectReplacesLegacyAutoResumeTee() throws {
        let home = try tempHome(settings: #"{"statusLine":{"type":"command","command":"tee ~/.claude/autoresume-usage.json | bash ~/.claude/sl.sh"}}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!ClaudeStatusLineSetup.isSetUp(home: home))
        try ClaudeStatusLineSetup.connect(home: home)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == "tee ~/.claude/justcontinue-usage.json | bash ~/.claude/sl.sh")
        try ClaudeStatusLineSetup.disconnect(home: home)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == "bash ~/.claude/sl.sh")
    }

    @Test func legacySilentTeeBecomesCurrentSilentTee() {
        #expect(ClaudeStatusLineSetup.suggestedCommand(current: "tee ~/.claude/autoresume-usage.json > /dev/null") == ClaudeStatusLineSetup.silentTee)
        #expect(ClaudeStatusLineSetup.suggestedCommand(current: "") == ClaudeStatusLineSetup.silentTee)
    }

    @Test(arguments: [false, true])
    func failedBackupLeavesSettingsUnchanged(disconnect: Bool) throws {
        let original = #"{"model":"opus","statusLine":{"type":"command","command":"tee ~/.claude/justcontinue-usage.json > /dev/null"}}"#
        let home = try tempHome(settings: original)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        // A dangling symlink makes fileExists false but prevents copyItem from creating the backup.
        try FileManager.default.createSymbolicLink(at: settings.appendingPathExtension("justcontinue-backup"),
                                                  withDestinationURL: home.appendingPathComponent("missing"))
        #expect(throws: ClaudeStatusLineSetup.SetupError.self) {
            if disconnect { try ClaudeStatusLineSetup.disconnect(home: home) }
            else { try ClaudeStatusLineSetup.connect(home: home) }
        }
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    }

    @Test func refusesToRewriteUnparseableSettings() throws {
        let home = try tempHome(settings: "{ not json")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: ClaudeStatusLineSetup.SetupError.self) { try ClaudeStatusLineSetup.connect(home: home) }
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == "{ not json")
    }
}

@Suite struct ClaudeBuiltInContinueTests {
    func session(_ version: String?, reset: TimeInterval? = nil, agent: AgentKind = .claude) -> AgentSession {
        let state: LogState = reset.map { .limited(LimitEvent(resetAt: Date().addingTimeInterval($0), message: "x")) } ?? .running
        return AgentSession(id: SessionKey(pid: 1, startTime: 1), agent: agent, tty: "t", cwd: nil, agentSessionID: nil,
                            name: "n", logURL: nil, logState: state, resumability: .unsupported(hostName: nil), agentVersion: version)
    }

    @Test func versions() {
        #expect(ClaudeBuiltInContinue.supports(version: "2.1.288"))
        #expect(ClaudeBuiltInContinue.supports(version: "2.1.234"))
        #expect(!ClaudeBuiltInContinue.supports(version: "2.1.233"))
        #expect(ClaudeBuiltInContinue.supports(version: "3.0.0"))
        #expect(!ClaudeBuiltInContinue.supports(version: nil))
    }

    @Test func whoHandlesWhat() {
        #expect(ClaudeBuiltInContinue.handles(session("2.1.288"), enabled: true))
        #expect(!ClaudeBuiltInContinue.handles(session("2.1.288"), enabled: false), "switched off by the user")
        #expect(!ClaudeBuiltInContinue.handles(session("2.1.100"), enabled: true), "too old")
        #expect(ClaudeBuiltInContinue.handles(session("2.1.288", reset: 3600), enabled: true))
        #expect(!ClaudeBuiltInContinue.handles(session("2.1.288", reset: 3 * 86400), enabled: true), "weekly limit days away")
        #expect(!ClaudeBuiltInContinue.handles(session("9.9.9", agent: .codex), enabled: true), "Codex has no built-in continue")
    }

    @Test func settingSwitchedOff() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ClaudeBuiltInContinue.isEnabled(home: home), "unset means on")
        try #"{"autoContinueAtUsageLimit": false}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        #expect(!ClaudeBuiltInContinue.isEnabled(home: home))
    }
}
