import Foundation

/// Claude Code's on-disk state.
///
/// - `~/.claude/sessions/<pid>.json` maps a running process to its session.
/// - `~/.claude/projects/<project>/<sessionId>.jsonl` is the transcript. A usage limit is an
///   entry with `"error": "rate_limit"` and a `quotaLimits.resetsAt` epoch timestamp.
public struct ClaudeLog: Sendable {
    public struct Meta: Sendable, Equatable {
        public var sessionID: String
        public var name: String?
        public var cwd: String?
        public var version: String?
    }

    public let home: URL
    private static let states = FileCache<LogState>()

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home.appendingPathComponent(".claude")
    }

    public func meta(pid: Int32) -> Meta? {
        let url = home.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url), let obj = JSONLines.parse(data),
              let sid = obj["sessionId"] as? String, JSONLines.isSafeFileName(sid) else { return nil }
        return Meta(sessionID: sid, name: obj["name"] as? String, cwd: obj["cwd"] as? String, version: obj["version"] as? String)
    }

    public func transcript(sessionID: String) -> URL? {
        let projects = home.appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let file = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    public func state(of url: URL) -> LogState {
        Self.states.value(for: url) { Self.state(entries: JSONLines.tail(of: url)) }
    }

    /// Limited iff the last rate-limit entry has no real (non-synthetic) assistant reply after it.
    /// Local commands, attachments and system entries don't count as a resume.
    static func state(entries: [JSONObject]) -> LogState {
        guard !entries.isEmpty else { return .unknown }
        var limitIndex: Int?
        for (i, e) in entries.enumerated().reversed() {
            if (e["isSidechain"] as? Bool) == true { continue }
            // Claude Code's own automatic continue logs informational lines instead of a rate_limit
            // entry: "Usage limit reached · continuing automatically at 5:50pm · esc to cancel",
            // then "Usage limit reset · continuing automatically" (or "Automatic continue cancelled").
            if let text = systemText(e) {
                if text.hasPrefix("Usage limit reached · continuing automatically") {
                    let loggedAt = ISO8601.date(e["timestamp"])
                    return .limited(LimitEvent(resetAt: ResetTimeParser.parse(text, after: loggedAt ?? Date()),
                                               message: text, loggedAt: loggedAt, continuedByAgent: true))
                }
                if text.hasPrefix("Usage limit reset") || text.hasPrefix("Automatic continue cancelled") {
                    return .running  // continuing now, or the user chose not to: either way, not ours to type into
                }
            }
            if isRateLimit(e) { limitIndex = i; break }
            if isRealAssistantReply(e) { return .running }
        }
        guard let i = limitIndex else { return .running }
        return .limited(limitEvent(from: entries[i]))
    }

    /// Text of an informational system entry, if this is one.
    static func systemText(_ e: JSONObject) -> String? {
        guard (e["type"] as? String) == "system" else { return nil }
        if let s = e["content"] as? String { return s }
        if let s = e[path: "message", "content"] as? String { return s }
        return ((e[path: "message", "content"] as? [JSONObject]) ?? (e["content"] as? [JSONObject]))?.first?["text"] as? String
    }

    static func isRateLimit(_ e: JSONObject) -> Bool {
        guard (e["type"] as? String) == "assistant" else { return false }
        if (e["error"] as? String) == "rate_limit" { return true }
        return (e["isApiErrorMessage"] as? Bool) == true && (e["apiErrorStatus"] as? Int) == 429
    }

    static func isRealAssistantReply(_ e: JSONObject) -> Bool {
        guard (e["type"] as? String) == "assistant", (e["isApiErrorMessage"] as? Bool) != true else { return false }
        return (e[path: "message", "model"] as? String) != "<synthetic>"
    }

    static func limitEvent(from e: JSONObject) -> LimitEvent {
        let text = ((e[path: "message", "content"] as? [JSONObject])?.compactMap { $0["text"] as? String }.joined(separator: " ")) ?? ""
        let loggedAt = ISO8601.date(e["timestamp"])
        var reset = epochDate(e[path: "quotaLimits", "resetsAt"])
        if reset == nil {
            reset = ResetTimeParser.parse(text, after: loggedAt ?? Date())
        }
        return LimitEvent(resetAt: reset, window: e[path: "quotaLimits", "rateLimitType"] as? String,
                          message: text.isEmpty ? "Usage limit reached" : text, loggedAt: loggedAt)
    }
}
