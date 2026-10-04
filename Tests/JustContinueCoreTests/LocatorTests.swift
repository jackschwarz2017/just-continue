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
