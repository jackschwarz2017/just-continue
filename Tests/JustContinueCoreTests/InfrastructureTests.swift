import Foundation
import Testing
@testable import JustContinueCore

@Suite struct ShellTests {
    @Test func timesOutInsteadOfHanging() {
        let start = Date()
        let r = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        #expect(r.status == -2)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func handlesOutputLargerThanThePipeBuffer() {
        let input = String(repeating: "x", count: 300_000)
        let r = Shell.run("/bin/cat", [], input: input)
        #expect(r.ok)
        #expect(r.output.count == input.count)
    }
}

@Suite struct CacheTests {
    @Test func fileCacheRecomputesOnlyWhenTheFileChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let cache = FileCache<Int>()
        var computed = 0
        _ = cache.value(for: url) { computed += 1; return 1 }
        _ = cache.value(for: url) { computed += 1; return 1 }
        #expect(computed == 1)

        try "two, longer".write(to: url, atomically: true, encoding: .utf8)
        _ = cache.value(for: url) { computed += 1; return 2 }
        #expect(computed == 2)
    }

    @Test func failedTerminalQueryIsNotCached() {
        let cache = SnapshotCache()
        var captures = 0
        let key = SessionKey(pid: 1, startTime: 1)
        let now = Date()
        let capture = {
            captures += 1
            var snapshot = TerminalSnapshot()
            snapshot.recordFailure(CommandResult(status: -2, output: "", error: "timeout"), for: .iTerm)
            return snapshot
        }
        _ = cache.snapshot(for: [key], now: now, capture: capture)
        _ = cache.snapshot(for: [key], now: now.addingTimeInterval(5), capture: capture)
        #expect(captures == 2)
    }

    @Test func snapshotIsReusedWhileTheSameSessionsRun() {
        let cache = SnapshotCache()
        var captures = 0
        let capture = { captures += 1; return TerminalSnapshot() }
        let a = SessionKey(pid: 1, startTime: 1), b = SessionKey(pid: 2, startTime: 2)
        let now = Date()
        _ = cache.snapshot(for: [a], now: now, capture: capture)
        _ = cache.snapshot(for: [a], now: now.addingTimeInterval(10), capture: capture)
        #expect(captures == 1)
        _ = cache.snapshot(for: [a, b], now: now.addingTimeInterval(11), capture: capture)
        #expect(captures == 2, "a new session")
        _ = cache.snapshot(for: [a, b], now: now.addingTimeInterval(11 + SnapshotCache.maxAge), capture: capture)
        #expect(captures == 3, "too old")
    }
}

@Suite struct SafetyTests {
    @Test func idsFromLogsMustBePlainFileNames() {
        #expect(JSONLines.isSafeFileName("0199a1b2-3c4d-7e8f-9a0b-1c2d3e4f5a6b"))
        #expect(!JSONLines.isSafeFileName("../../etc/passwd"))
        #expect(!JSONLines.isSafeFileName("a/b"))
        #expect(!JSONLines.isSafeFileName(""))
    }

    @Test func connectWritesThroughASymlinkedSettingsFile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let dotfiles = home.appendingPathComponent("dotfiles/settings.json")
        try fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"model":"opus"}"#.write(to: dotfiles, atomically: true, encoding: .utf8)
        let link = home.appendingPathComponent(".claude/settings.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        try ClaudeStatusLineSetup.connect(home: home)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == dotfiles.path)
        #expect(ClaudeStatusLineSetup.currentCommand(home: home) == ClaudeStatusLineSetup.silentTee)
    }

    @MainActor @Test func detailedLogLeavesOutSessionNamesAndTheMessage() async {
        var settings = EngineSettings()
        settings.continuationText = "secret instructions"
        let h = Harness(settings: settings)
        var lines: [String] = []
        h.engine.logSink = { lines.append($0) }
        await h.show(h.session(h.limited()))
        h.engine.setEnabled(Harness.key, true)
        h.activity.locked.value = true
        await h.advance(3700)
        #expect(h.input.sent.value.map(\.0) == ["secret instructions"])
        #expect(!lines.isEmpty)
        #expect(!lines.contains { $0.contains("proj") || $0.contains("secret") }, "\(lines)")
    }
}
