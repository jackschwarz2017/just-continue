import JustContinueCore
import Foundation

/// What a session is doing, as shown in the menu.
enum SessionStatus: Equatable {
    case unsupported, ambiguous
    case running, limited(Date?, weekly: Bool)
    case waiting(Date), ready, resuming
    /// Claude Code waits and continues by itself.
    case agentContinues(Date?)
    case resumed(Date), dryRun(Date), failed

    /// Monochrome SF Symbol; never colored.
    var symbol: String {
        switch self {
        case .unsupported, .ambiguous: "nosign"
        case .running: "play.circle"
        case .limited, .agentContinues: "pause.circle"
        case .waiting: "clock"
        case .ready: "bell"
        case .resuming: "arrow.clockwise"
        case .resumed, .dryRun: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// A few words.
    var text: String {
        switch self {
        case .unsupported: "Not supported in this terminal"
        case .ambiguous: "Can't tell which tab"
        case .running: "Running"
        case .limited(let reset, let weekly):
            "\(weekly ? "Weekly limit" : "Limit reached")" + (reset.map { " · resets \(Format.time($0))" } ?? "")
        case .waiting(let at): "Continues \(Format.when(at))"
        case .agentContinues(let at): at.map { "Claude Code continues \(Format.when($0))" } ?? "Claude Code continues on its own"
        case .ready: "Ready to continue"
        case .resuming: "Continuing…"
        case .resumed(let at): "Continued \(Format.when(at))"
        case .dryRun(let at): "Dry run \(Format.when(at))"
        case .failed: "Couldn't continue"
        }
    }
}

extension SessionRow {
    /// Menu section the session belongs to: its terminal, or the unsupported app's name.
    var sectionTitle: String {
        switch session.resumability {
        case .ready(let location): location.kind.displayName
        case .ambiguous(let kind): kind.displayName
        case .unsupported(let host): host ?? "Other"
        }
    }

    var canEnable: Bool { session.resumability.location != nil }

    var status: SessionStatus {
        switch session.resumability {
        case .unsupported: return .unsupported
        case .ambiguous: return .ambiguous
        case .ready: break
        }
        if let limit = session.logState.limit, limit.continuedByAgent { return .agentContinues(limit.resetAt) }
        if enabled, let pending {
            switch pending.phase {
            case .waiting: return .waiting(pending.fireAt)
            case .askedUser: return .ready
            case .sending, .verifying: return .resuming
            }
        }
        switch outcome {
        case .resumed(let date): return .resumed(date)
        case .dryRun(let date): return .dryRun(date)
        case .failed: return .failed
        case nil: break
        }
        if let limit = session.logState.limit {
            return (limit.resetAt ?? .distantFuture) <= Date() ? .ready : .limited(limit.resetAt, weekly: limit.isWeekly)
        }
        return .running
    }

    /// e.g. "Codex · Continues at 14:39"
    var subtitle: String { "\(session.agent.displayName) · \(status.text)" }

    /// True once the reset has passed and the user could resume right now.
    var isReadyToContinue: Bool { canEnable && status == .ready }

}

enum Format {
    /// "14:39", "tomorrow 09:00", "Thu 09:00", or a short date beyond a week.
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let t = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return t }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(t)" }
        if date > now, date.timeIntervalSince(now) < 7 * 86400 { return "\(weekday.string(from: date)) \(t)" }
        return dateAndTime.string(from: date)
    }

    // Formatters are expensive to create and the menu formats many dates.
    private static let clock = formatter { $0.dateStyle = .none; $0.timeStyle = .short }
    private static let weekday = formatter { $0.setLocalizedDateFormatFromTemplate("EEE") }
    private static let dateAndTime = formatter { $0.dateStyle = .short; $0.timeStyle = .short }

    private static func formatter(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        let f = DateFormatter()
        configure(f)
        return f
    }

    /// "at 14:39" today, otherwise "tomorrow 09:00" / "Thu 09:00".
    static func when(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? "at \(time(date, now: now))" : time(date, now: now)
    }

    /// Menu titles don't truncate on their own, so long names would widen the whole menu.
    static func short(_ s: String, max: Int = 42) -> String {
        guard s.count > max else { return s }
        let head = s.prefix(max * 2 / 3), tail = s.suffix(max / 3 - 1)
        return "\(head)…\(tail)"
    }
}
