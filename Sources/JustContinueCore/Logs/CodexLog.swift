import Foundation

/// Codex CLI's on-disk state.
///
/// - `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: one file per thread. The first line is
///   `session_meta` with `cwd`, `timestamp` and `id`.
/// - A usage limit is `event_msg`/`task_complete` with `error.codex_error_info == "usage_limit_exceeded"`.
///   `event_msg`/`token_count` entries carry `rate_limits.{primary,secondary}.resets_at`.
/// - A new turn starts with `event_msg`/`task_started`.
public struct CodexLog: Sendable {
    public struct Rollout: Sendable, Equatable {
        public var url: URL
        public var id: String
        public var cwd: String
        public var startedAt: Date
        public var modifiedAt: Date
    }

    public let home: URL
    private static let states = FileCache<LogState>()
    /// Rollout headers never change, so they're kept by path. Only found ones are kept:
    /// a brand-new file may not have its header yet.
    private static let headers = HeaderCache()
    private static let threadNames = FileCache<[String: String]>()

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home.appendingPathComponent(".codex")
    }

    /// Interactive (non-subagent) rollouts modified since `since`, newest first.
    public func recentRollouts(since: Date, lookbackDays: Int = 30) -> [Rollout] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions")
        let calendar = Calendar.current
        var result: [Rollout] = []
        for offset in 0...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime >= since.addingTimeInterval(-5),
                      let rollout = Self.rollout(url: file, modifiedAt: mtime) else { continue }
                result.append(rollout)
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func rollout(url: URL, modifiedAt: Date) -> Rollout? {
        guard var rollout = headers.get(url.path) ?? header(url: url, modifiedAt: modifiedAt) else { return nil }
        headers.set(url.path, rollout)
        rollout.modifiedAt = modifiedAt
        return rollout
    }

    static func header(url: URL, modifiedAt: Date) -> Rollout? {
        guard let first = JSONLines.firstLine(of: url), (first["type"] as? String) == "session_meta",
              let payload = first["payload"] as? JSONObject,
              let id = payload["id"] as? String, JSONLines.isSafeFileName(id), let cwd = payload["cwd"] as? String else { return nil }
        // Subagent threads (e.g. guardian reviews) share the cwd but aren't what the user typed into.
        if payload["source"] is JSONObject { return nil }
        let started = ISO8601.date(payload["timestamp"]) ?? ISO8601.date(first["timestamp"]) ?? modifiedAt
        return Rollout(url: url, id: id, cwd: cwd, startedAt: started, modifiedAt: modifiedAt)
    }

    /// Picks the rollout for a process: same cwd, created just after the process started;
    /// otherwise (e.g. `codex resume`) the most recently written one in that cwd.
    public static func match(cwd: String, processStart: Date, candidates: [Rollout], excluding claimed: Set<String>) -> Rollout? {
        let sameDir = candidates.filter { $0.cwd == cwd && !claimed.contains($0.id) }
        if let created = sameDir
            .filter({ $0.startedAt.timeIntervalSince(processStart) > -5 && $0.startedAt.timeIntervalSince(processStart) < 120 })
            .min(by: { abs($0.startedAt.timeIntervalSince(processStart)) < abs($1.startedAt.timeIntervalSince(processStart)) }) {
            return created
        }
        return sameDir.first { $0.modifiedAt >= processStart }
    }

    public func threadName(id: String) -> String? {
        let url = home.appendingPathComponent("session_index.jsonl")
        let names = Self.threadNames.value(for: url) {
            var names: [String: String] = [:]
            for entry in JSONLines.tail(of: url, maxBytes: 256 * 1024) {
                if let id = entry["id"] as? String, let name = entry["thread_name"] as? String { names[id] = name }
            }
            return names
        }
        return names[id]
    }

    public func state(of url: URL) -> LogState {
        Self.states.value(for: url) { Self.state(entries: JSONLines.tail(of: url)) }
    }

    static func state(entries: [JSONObject]) -> LogState {
        guard !entries.isEmpty else { return .unknown }
        for (i, e) in entries.enumerated().reversed() {
            guard (e["type"] as? String) == "event_msg", let payload = e["payload"] as? JSONObject else { continue }
            switch payload["type"] as? String {
            case "task_started":
                return .running
            case "task_complete", "error":
                guard let event = limitEvent(entries: entries, at: i) else { return .running }
                return .limited(event)
            default:
                continue
            }
        }
        return .running
    }

    static func limitEvent(entries: [JSONObject], at index: Int) -> LimitEvent? {
        let e = entries[index]
        let payload = e["payload"] as? JSONObject ?? [:]
        let error = payload["error"] as? JSONObject
        let info = (error?["codex_error_info"] as? String) ?? (payload["codex_error_info"] as? String) ?? ""
        let message = (error?["message"] as? String) ?? (payload["message"] as? String) ?? ""
        guard info.contains("usage_limit") || message.contains("hit your usage limit") else { return nil }
        let loggedAt = ISO8601.date(e["timestamp"])

        // The most recent token_count before the limit tells which window ran out and when it resets.
        var reset: Date?
        var window: String?
        for prior in entries[..<index].reversed() {
            guard let limits = prior[path: "payload", "rate_limits"] as? JSONObject else { continue }
            let windows = ["primary", "secondary"].compactMap { name -> (String, Double, Date)? in
                guard let w = limits[name] as? JSONObject, let at = epochDate(w["resets_at"]) else { return nil }
                return (name, (w["used_percent"] as? NSNumber)?.doubleValue ?? 0, at)
            }
            guard !windows.isEmpty else { continue }  // e.g. a "premium" entry with null windows
            // The exhausted window blocks; if several are, the later reset wins. If none reads 100%
            // (the counter can lag), the fullest window is the likely blocker.
            let exhausted = windows.filter { $0.1 >= 100 }
            let blocking = exhausted.isEmpty ? windows.max(by: { $0.1 < $1.1 }) : exhausted.max(by: { $0.2 < $1.2 })
            if let w = blocking {
                window = w.0
                reset = w.2
            }
            break
        }
        if reset == nil {
            reset = ResetTimeParser.parse(message, after: loggedAt ?? Date())
        }
        return LimitEvent(resetAt: reset, window: window,
                          message: message.isEmpty ? "Usage limit reached" : message, loggedAt: loggedAt)
    }
}

private final class HeaderCache: @unchecked Sendable {
    private var rollouts: [String: CodexLog.Rollout] = [:]
    private let lock = NSLock()

    func get(_ path: String) -> CodexLog.Rollout? { lock.withLock { rollouts[path] } }

    func set(_ path: String, _ rollout: CodexLog.Rollout) {
        lock.withLock {
            if rollouts.count >= 2048 { rollouts.removeAll() }
            rollouts[path] = rollout
        }
    }
}
