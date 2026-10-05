import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Whether the user is at the Mac. Reads idle time only, never input contents.
public protocol ActivityMonitoring: Sendable {
    var idleSeconds: TimeInterval { get }
    var isScreenLocked: Bool { get }
}

public struct SystemActivity: ActivityMonitoring {
    public init() {}

    public var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    public var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Holds power assertions while keeping the Mac awake.
/// System sleep is always prevented; display sleep only if the user asked for it.
public final class SleepPreventer: @unchecked Sendable {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private let lock = NSLock()

    public init() {}

    public func set(system: Bool, display: Bool) {
        lock.withLock {
            update(&systemID, hold: system, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Just Continue: waiting to resume sessions")
            update(&displayID, hold: system && display, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Just Continue: keeping the screen on")
        }
    }

    private func update(_ id: inout IOPMAssertionID, hold: Bool, type: String, reason: String) {
        if hold, id == 0 {
            var new: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &new) == kIOReturnSuccess {
                id = new
            }
        } else if !hold, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    deinit {
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        if displayID != 0 { IOPMAssertionRelease(displayID) }
    }
}

/// Laptop lid state. A closed lid sleeps the Mac regardless of power assertions
/// (unless in clamshell mode with power and an external display), so we warn about it.
public enum Lid {
    /// Nil on Macs without a lid.
    public static var isClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return value
    }

    public static var hasLid: Bool { isClosed != nil }
}
