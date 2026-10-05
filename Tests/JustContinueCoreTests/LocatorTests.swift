import Testing
@testable import JustContinueCore

@Suite struct TerminalLocatorTests {
    func snapshot() -> TerminalSnapshot {
        var s = TerminalSnapshot()
        s.tmuxPanes["ttys010"] = .init(identifier: "%3", title: "main:0.1", workingDirectory: nil)
        s.iTermSessions["ttys000"] = .init(identifier: "/dev/ttys000", title: "rodin (codex)", workingDirectory: nil)
        s.iTermSessions["ttys011"] = .init(identifier: "/dev/ttys011", title: "tmux attach", workingDirectory: nil)
        s.terminalTabs["ttys005"] = .init(identifier: "/dev/ttys005", title: "", workingDirectory: nil)
        s.ghosttyVersion = "1.3.1"
        s.ghosttyTerminals = [
            .init(identifier: "G1", title: "api", workingDirectory: "/work/api"),
            .init(identifier: "G2", title: "web", workingDirectory: "/work/web"),
            .init(identifier: "G3", title: "web 2", workingDirectory: "/work/web/"),
        ]
        return s
    }

    @Test func tmuxWinsOverOuterTerminal() {
        let r = TerminalLocator.locate(tty: "ttys010", cwd: nil, snapshot: snapshot(), previous: nil, hostAppName: "iTerm")
        #expect(r.location == TerminalLocation(kind: .tmux, identifier: "%3", title: "main:0.1"))
    }

    @Test func iTermAndTerminalByTTY() {
        #expect(TerminalLocator.locate(tty: "ttys000", cwd: nil, snapshot: snapshot(), previous: nil, hostAppName: nil).location?.kind == .iTerm)
        #expect(TerminalLocator.locate(tty: "ttys005", cwd: nil, snapshot: snapshot(), previous: nil, hostAppName: nil).location?.kind == .terminalApp)
    }

    @Test func ghosttyUniqueWorkingDirectory() {
        let r = TerminalLocator.locate(tty: "ttys020", cwd: "/work/api", snapshot: snapshot(), previous: nil, hostAppName: "Ghostty")
        #expect(r.location?.identifier == "G1")
    }

    @Test func ghosttyAmbiguousRefusesToGuess() {
        let r = TerminalLocator.locate(tty: "ttys021", cwd: "/work/web", snapshot: snapshot(), previous: nil, hostAppName: "Ghostty")
        #expect(r == .ambiguous(.ghostty))
    }

    @Test func ghosttyKeepsEarlierUnambiguousMatch() {
        let previous = TerminalLocation(kind: .ghostty, identifier: "G3")
        let r = TerminalLocator.locate(tty: "ttys021", cwd: "/work/web", snapshot: snapshot(), previous: previous, hostAppName: "Ghostty")
        #expect(r.location?.identifier == "G3")
    }

    @Test func ghosttyWithoutScriptingIsUnsupported() {
        var s = snapshot()
        s.ghosttyVersion = nil
        let r = TerminalLocator.locate(tty: "ttys021", cwd: "/work/api", snapshot: s, previous: nil, hostAppName: "Ghostty")
        #expect(r == .unsupported(hostName: "Ghostty (needs 1.3 or later)"))
    }

    @Test func otherTerminalsAreUnsupported() {
        let r = TerminalLocator.locate(tty: "ttys030", cwd: "/x", snapshot: snapshot(), previous: nil, hostAppName: "Warp")
        #expect(r == .unsupported(hostName: "Warp"))
    }

    @Test func appleScriptLiteralEscapes() {
        #expect(AppleScript.literal(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }
}

@Suite struct SessionValidationTests {
    func session(_ location: TerminalLocation?) -> AgentSession {
        AgentSession(id: SessionKey(pid: 42, startTime: 100), agent: .codex, tty: "ttys000", cwd: nil,
                     agentSessionID: nil, name: "test", logURL: nil, logState: .unknown,
                     resumability: location.map(Resumability.ready) ?? .unsupported(hostName: "iTerm2"))
    }

    @Test func failedQueryKeepsDisplayTargetButDoesNotValidateIt() {
        let target = TerminalLocation(kind: .iTerm, identifier: "/dev/ttys000")
        var snapshot = TerminalSnapshot()
        snapshot.recordFailure(CommandResult(status: -2, output: "", error: "timeout"), for: .iTerm)
        let located = TerminalLocator.locate(tty: "ttys000", cwd: nil, snapshot: snapshot,
                                            previous: target, hostAppName: nil)
        #expect(located.location == target)
        guard case .failed(let reason, let retryable) = SessionDiscovery.validateTarget(session(located.location), previous: target, snapshot: snapshot) else {
            Issue.record("A cached target must not authorize input after a query failure")
            return
        }
        #expect(reason == "iTerm2: query timed out")
        #expect(retryable)
    }

    @Test func missingTabNeverAuthorizesInputButCanBeCheckedAgain() {
        let target = TerminalLocation(kind: .iTerm, identifier: "/dev/ttys000")
        guard case .failed(let reason, let retryable) = SessionDiscovery.validateTarget(session(nil), previous: target, snapshot: TerminalSnapshot()) else {
            Issue.record("Missing tab should fail validation")
            return
        }
        #expect(reason == "iTerm2 tab or pane was not found")
        #expect(retryable)
    }

    @Test func changedTargetRefusesInputAndTitleChangeIsAllowed() {
        let target = TerminalLocation(kind: .iTerm, identifier: "/dev/ttys000", title: "old")
        var changed = target
        changed.title = "new"
        guard case .valid = SessionDiscovery.validateTarget(session(changed), previous: target, snapshot: TerminalSnapshot()) else {
            Issue.record("Animated titles must not invalidate the tab")
            return
        }
        changed.identifier = "/dev/ttys001"
        guard case .failed(_, false) = SessionDiscovery.validateTarget(session(changed), previous: target, snapshot: TerminalSnapshot()) else {
            Issue.record("Changed target must be rejected")
            return
        }
    }

    @Test func tmuxWithoutServerIsAnEmptySnapshot() {
        var snapshot = TerminalSnapshot()
        snapshot.recordFailure(CommandResult(status: 1, output: "", error: "no server running on /tmp/tmux/default"), for: .tmux)
        #expect(snapshot.failures.isEmpty)
    }

    @Test func permissionDenialIsNotRetried() {
        var snapshot = TerminalSnapshot()
        snapshot.recordFailure(CommandResult(status: 1, output: "", error: "Not authorized (-1743)"), for: .iTerm)
        #expect(snapshot.failures[.iTerm]?.retryable == false)
    }
}
