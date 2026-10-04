import Foundation

/// Claude Code's own automatic continue (v2.1.234+): a session waits for the limit to reset and
/// continues by itself, unless `autoContinueAtUsageLimit` is false. It won't wait for a reset more
/// than 24 h away (weekly limits), and needs the Mac awake. See `docsURL`.
public enum ClaudeBuiltInContinue {
    public static let docsURL = URL(string: "https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset")!
    public static let minimumVersion = "2.1.234"
    public static let maxAutomaticWait: TimeInterval = 24 * 3600

    /// True if `version` is at least 2.1.234.
    public static func supports(version: String?) -> Bool {
        guard let version else { return false }
        return compare(version, minimumVersion) != .orderedAscending
    }

    /// False only if the user or an admin switched it off (`autoContinueAtUsageLimit: false`).
    public static func isEnabled(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let files = [home.appendingPathComponent(".claude/settings.json"),
                     URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")]
        for file in files {
            if let data = try? Data(contentsOf: file), let obj = JSONLines.parse(data),
               (obj["autoContinueAtUsageLimit"] as? Bool) == false { return false }
        }
        return true
    }

    /// Whether Claude Code will continue this session on its own, so Just Continue can leave it alone.
    public static func handles(_ session: AgentSession, enabled: Bool, now: Date = Date()) -> Bool {
        guard session.agent == .claude, enabled, supports(version: session.agentVersion) else { return false }
        if let reset = session.logState.limit?.resetAt, reset.timeIntervalSince(now) > maxAutomaticWait {
            return false  // a weekly limit days away: Claude Code won't start the wait by itself
        }
        return true
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
