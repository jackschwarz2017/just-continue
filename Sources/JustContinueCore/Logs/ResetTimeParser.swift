import Foundation

/// Fallback for when a log has no machine-readable reset timestamp.
/// Understands the messages the agents show, e.g.
///   Claude: "You've hit your session limit · resets 1:30pm (Europe/Berlin)"
///   Codex:  "...or try again at 2:38 PM."
///   Claude Code's own wait: "Usage limit reached · continuing automatically at 5:50pm · esc to cancel"
/// The messages have no date, so the result is the next occurrence after `reference`.
public enum ResetTimeParser {
    // NSRegularExpression is thread-safe.
    private static let regex = try! NSRegularExpression(
        pattern: #"(?:resets|try again at|continuing automatically at)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s?m\.?(?:\s*\(([A-Za-z_]+/[A-Za-z_/+-]+|UTC|GMT)\))?"#,
        options: [.caseInsensitive])

    public static func parse(_ message: String, after reference: Date, timeZone defaultZone: TimeZone = .current) -> Date? {
        let ns = message as NSString
        guard let m = regex.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)) else { return nil }

        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard var hour = group(1).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        let pm = group(3)?.lowercased() == "p"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        let zone = group(4).flatMap(TimeZone.init(identifier:)) ?? defaultZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        // Allow a minute of slack so "resets 1:30pm" logged at 13:30:20 doesn't jump a day.
        if date < reference.addingTimeInterval(-60) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
}
