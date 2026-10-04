import Foundation

/// A snapshot of account-wide plan usage for one agent, with its source and collection time.
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

        /// A reset invalidates the snapshot; it cannot tell us what another device has used since.
        public func percent(at now: Date) -> Double? {
            if let resetsAt, resetsAt <= now { return nil }
            return usedPercent
        }
    }

    public enum Source: Sendable { case localSnapshot, liveAccount }
    public var source: Source
    public var fiveHour: Window?
    public var weekly: Window?
    /// When the numbers were recorded.
    public var updatedAt: Date?

    public init(fiveHour: Window? = nil, weekly: Window? = nil, updatedAt: Date?, source: Source = .localSnapshot) {
        self.source = source
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
            guard let w = limits[key] as? JSONObject, let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { return nil }
            return .init(kind: kind, usedPercent: used, resetsAt: epochDate(w["resets_at"]))
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let usage = AgentUsage(fiveHour: window("five_hour", .fiveHour), weekly: window("seven_day", .weekly), updatedAt: modified)
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
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
