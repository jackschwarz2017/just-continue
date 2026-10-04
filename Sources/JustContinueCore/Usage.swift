import Foundation

/// Account-wide plan usage for one agent.
public struct AgentUsage: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public enum Kind: Sendable { case fiveHour, weekly }
        public var kind: Kind
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
            self.kind = kind
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }

        /// After the reset time the logged percentage is stale; the window has started over.
        public func percent(at now: Date) -> Double {
            if let resetsAt, resetsAt <= now { return 0 }
            return usedPercent
        }
    }

    public var fiveHour: Window?
    public var weekly: Window?
    /// When the numbers were recorded.
    public var updatedAt: Date?

    public init(fiveHour: Window?, weekly: Window?, updatedAt: Date?) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
    }
}

public enum UsageReader {
    /// Where the Claude Code status line copies its input (see README, "Claude Code usage").
    public static func claudeUsageFile(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".claude/justcontinue-usage.json")
    }

    /// Claude Code passes `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` to status-line
    /// commands. Users opt in by teeing that input to `claudeUsageFile`.
    public static func claude() -> AgentUsage? {
        claude(file: claudeUsageFile())
    }

    public static func claude(file: URL) -> AgentUsage? {
        guard let data = try? Data(contentsOf: file), let obj = JSONLines.parse(data),
              let limits = obj["rate_limits"] as? JSONObject else { return nil }
        func window(_ key: String, _ kind: AgentUsage.Window.Kind) -> AgentUsage.Window? {
            guard let w = limits[key] as? JSONObject, let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return .init(kind: kind, usedPercent: used, resetsAt: epochDate(w["resets_at"]))
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let usage = AgentUsage(fiveHour: window("five_hour", .fiveHour), weekly: window("seven_day", .weekly), updatedAt: modified)
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }

    /// Codex logs `rate_limits.{primary,secondary}` in `token_count` events on every turn.
    /// The newest one across all rollouts is the account's current usage.
    public static func codex(home: URL = URL(fileURLWithPath: NSHomeDirectory()), lookbackDays: Int = 14) -> AgentUsage? {
        let root = home.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        let calendar = Calendar.current
        var files: [(URL, Date)] = []
        for offset in 0...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                if let m = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { files.append((file, m)) }
            }
        }
        // Newest files first; the first one with rate limits wins.
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            if let usage = codexUsage(entries: JSONLines.tail(of: file, maxBytes: 256 * 1024)) { return usage }
        }
        return nil
    }

    static func codexUsage(entries: [JSONObject]) -> AgentUsage? {
        for e in entries.reversed() {
            guard let limits = e[path: "payload", "rate_limits"] as? JSONObject else { continue }
            func window(_ key: String, _ kind: AgentUsage.Window.Kind) -> AgentUsage.Window? {
                guard let w = limits[key] as? JSONObject, let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                return .init(kind: kind, usedPercent: used, resetsAt: epochDate(w["resets_at"]))
            }
            let usage = AgentUsage(fiveHour: window("primary", .fiveHour), weekly: window("secondary", .weekly),
                                   updatedAt: ISO8601.date(e["timestamp"]))
            if usage.fiveHour != nil || usage.weekly != nil { return usage }  // skip e.g. "premium" entries with null windows
        }
        return nil
    }
}

/// Connects Claude Code's status line to Just Continue: puts a `tee` in front of the
/// status-line command so its input, which includes plan usage, is also saved to `claudeUsageFile`.
/// Only runs when the user clicks Connect / Disconnect in Settings.
public enum ClaudeStatusLineSetup {
    public static let teePrefix = "tee ~/.claude/justcontinue-usage.json | "
    public static let silentTee = "tee ~/.claude/justcontinue-usage.json > /dev/null"

    public struct SetupError: Error, CustomStringConvertible {
        public var description: String
    }

    static func settingsURL(_ home: URL) -> URL { home.appendingPathComponent(".claude/settings.json") }

    /// The user's current status-line command, if any.
    public static func currentCommand(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        guard let data = try? Data(contentsOf: settingsURL(home)), let obj = JSONLines.parse(data) else { return nil }
        return obj[path: "statusLine", "command"] as? String
    }

    public static func isSetUp(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        guard let command = currentCommand(home: home) else { return false }
        return command.contains("justcontinue-usage.json")
    }

    /// The command to use instead: the existing one with the tee in front, or a silent tee.
    public static func suggestedCommand(current: String?) -> String {
        guard let current, !current.isEmpty else { return silentTee }
        return teePrefix + current
    }

    /// The original command, with our tee removed. Nil means there was no status line before.
    static func originalCommand(from command: String) -> String? {
        if command == silentTee { return nil }
        return command.hasPrefix(teePrefix) ? String(command.dropFirst(teePrefix.count)) : command
    }

    public static func connect(home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        try edit(home: home) { settings in
            guard !isSetUp(home: home) else { return }
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            statusLine["type"] = "command"
            statusLine["command"] = suggestedCommand(current: statusLine["command"] as? String)
            settings["statusLine"] = statusLine
        }
    }

    public static func disconnect(home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        try edit(home: home) { settings in
            guard var statusLine = settings["statusLine"] as? [String: Any], let command = statusLine["command"] as? String else { return }
            if let original = originalCommand(from: command) {
                statusLine["command"] = original
                settings["statusLine"] = statusLine
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }
        try? FileManager.default.removeItem(at: UsageReader.claudeUsageFile(home: home))
    }

    /// Reads, changes and writes settings.json. Refuses to touch a file it can't parse,
    /// and keeps a one-time backup of the original next to it.
    static func edit(home: URL, _ change: (inout [String: Any]) -> Void) throws {
        // Write through a symlink (e.g. settings kept in a dotfiles repo) instead of replacing it.
        let url = settingsURL(home).resolvingSymlinksInPath()
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let obj = JSONLines.parse(data) else {
                throw SetupError(description: "Couldn't read ~/.claude/settings.json, so it was left unchanged.")
            }
            settings = obj
            let backup = url.appendingPathExtension("justcontinue-backup")
            if !fm.fileExists(atPath: backup.path) {
                do { try fm.copyItem(at: url, to: backup) }
                catch {
                    throw SetupError(description: "Couldn't back up ~/.claude/settings.json, so it was left unchanged. \(error.localizedDescription)")
                }
            }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        change(&settings)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
