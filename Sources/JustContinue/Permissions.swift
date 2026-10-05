import AppKit
import JustContinueCore
import CoreServices
import Foundation

/// Automation (Apple Events) permission per terminal. macOS can't show the consent prompt
/// while the screen is locked, so users grant it up front in Settings.
enum AutomationPermission: Equatable, Sendable {
    case granted, denied, notDetermined, notRunning, unknown(OSStatus)

    var needsAccess: Bool { self == .denied || self == .notDetermined }

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied — allow in System Settings › Privacy & Security › Automation"
        case .notDetermined: "Not yet allowed"
        case .notRunning: "Not running (open it to check)"
        case .unknown(let s): "Unknown (\(s))"
        }
    }

    /// Blocks while the consent prompt is shown when `ask` is true; call off the main thread.
    static func check(bundleID: String, ask: Bool) -> AutomationPermission {
        var address = AEAddressDesc()
        let data = Data(bundleID.utf8)
        let created = data.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, data.count, &address) }
        guard created == noErr else { return .unknown(OSStatus(created)) }
        defer { AEDisposeDesc(&address) }
        let status = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown(status)
        }
    }

    /// Clears this app's Automation decisions for every terminal, e.g. a denial left over from an
    /// earlier build that System Settings no longer lists. Returns false if `tccutil` fails.
    static func resetAll() -> Bool {
        guard let ourID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", ourID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

struct ScriptableTerminal: Identifiable, Sendable {
    let name: String
    let bundleID: String
    var note: String? = nil
    var id: String { bundleID }

    var displayName: String { note.map { "\(name) (\($0))" } ?? name }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    static let all = [
        ScriptableTerminal(name: "iTerm2", bundleID: TerminalBundle.iTerm),
        ScriptableTerminal(name: "Terminal", bundleID: TerminalBundle.terminal),
        ScriptableTerminal(name: "Ghostty", bundleID: TerminalBundle.ghostty, note: "1.3 or later"),
    ]
}
