import Foundation
import Testing
@testable import JustContinueCore

struct CodexAccountUsageTests {
    @Test func prefersAccountBucketAndRecognizesWeeklyPrimary() throws {
        let usage = try #require(CodexAccountUsage.parse(result: [
            "rateLimits": ["limitId": "premium", "primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": ["primary": [
                "usedPercent": 42, "windowDurationMins": 10080, "resetsAt": 2_000_000_000
            ]]]
        ], now: Date()))
        #expect(usage.source == .liveAccount)
        #expect(usage.fiveHour == nil)
        #expect(usage.weekly?.usedPercent == 42)
    }

    @Test func rejectsUnrelatedOrInvalidQuotas() {
        for limits: [String: Any] in [
            ["limitId": "premium", "primary": ["usedPercent": 10]],
            ["primary": ["usedPercent": -1]],
            ["primary": ["usedPercent": 101]],
            ["primary": ["usedPercent": 20, "windowDurationMins": 60]],
            [:]
        ] {
            #expect(CodexAccountUsage.parse(result: ["rateLimits": limits], now: Date()) == nil)
        }
    }

    @Test func handshakeHandlesNotificationsAndSplitResponse() throws {
        let script = #"""
        read -r init
        case "$init" in *initialize*) ;; *) exit 1;; esac
        printf '%s\n' '{"method":"notice"}' '{"id":1,"result":{}}'
        read -r initialized
        read -r request
        case "$request" in *rateLimits*) ;; *) exit 2;; esac
        printf '%s' '{"id":2,"result":{"rateLimits":{"primary":'
        printf '%s\n' '{"usedPercent":37,"windowDurationMins":300}}}}'
        """#
        let usage = try CodexAccountUsage.fetch(executable: "/bin/sh", arguments: ["-c", script], timeout: 2).get()
        #expect(usage.fiveHour?.usedPercent == 37)
    }

    @Test func reportsSignInFailureWithoutServerDetails() {
        let script = #"""
        read -r init
        printf '%s\n' '{"id":1,"result":{}}'
        read -r initialized
        read -r request
        printf '%s\n' '{"id":2,"error":{"message":"Authentication required: private details"}}'
        """#
        guard case .failure(let error) = CodexAccountUsage.fetch(executable: "/bin/sh", arguments: ["-c", script], timeout: 2) else {
            Issue.record("Expected sign-in failure"); return
        }
        #expect(error == .signInRequired)
        #expect(!error.message.contains("private details"))
    }

    @Test func boundsUnresponsiveProcess() {
        let start = Date()
        // A shell builtin blocks without creating an orphan child process.
        let result = CodexAccountUsage.fetch(executable: "/bin/sh", arguments: ["-c", "read -r first; read -r second"], timeout: 0.1)
        guard case .failure(let error) = result else { Issue.record("Expected timeout"); return }
        #expect(error == .timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func handlesEarlyExit() {
        guard case .failure = CodexAccountUsage.fetch(executable: "/bin/sh", arguments: ["-c", "read -r first; exit 0"], timeout: 1) else {
            Issue.record("Expected unavailable usage"); return
        }
    }
}
