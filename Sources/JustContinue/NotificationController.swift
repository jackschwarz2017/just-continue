import JustContinueCore
import Foundation
import UserNotifications

/// Posts notifications and handles "Continue now".
/// The action runs in the background: it types into the session without opening any window.
@MainActor
final class NotificationController: NSObject, Notifying {
    weak var engine: ResumeEngine?
    /// Used when system notifications are off or unavailable.
    let banner = BannerController()
    /// Debug: behave as if notifications were turned off.
    var pretendDisabled: () -> Bool = { false }
    /// The user chose system notifications over the banner.
    var prefersSystem: () -> Bool = { false }
    /// Last known authorization; refreshed before each notification.
    private var authorized = false

    nonisolated static let readyCategory = "SESSION_READY"
    nonisolated static let continueAction = "CONTINUE_NOW"

    /// UNUserNotificationCenter needs a real app bundle; `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func setUp(requestPermission: Bool) {
        guard let center else { return }
        center.delegate = self
        let continueNow = UNNotificationAction(identifier: Self.continueAction, title: "Continue now", options: [])
        let category = UNNotificationCategory(identifier: Self.readyCategory, actions: [continueNow], intentIdentifiers: [])
        center.setNotificationCategories([category])
        if requestPermission { self.requestPermission() }
        refreshAuthorization()
    }

    /// Only asked when the user picks system notifications.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshAuthorization() }
        }
    }

    private func refreshAuthorization() {
        center?.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self.authorized = ok }
        }
    }

    /// The banner, unless the user chose system notifications and they're allowed.
    private var useBanner: Bool { !prefersSystem() || pretendDisabled() || center == nil || !authorized }

    func notifyReady(_ session: AgentSession, canType: Bool) {
        if useBanner {
            let key = session.id
            banner.show(title: "\(session.agent.displayName) is ready to continue",
                        body: canType ? session.name : "\(session.name): type continue to go on",
                        action: canType ? .init(title: "Continue Now") { [weak self] in self?.engine?.continueNow(key) } : nil)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(session.agent.displayName) is ready to continue"
        if canType {
            content.body = session.name
            content.categoryIdentifier = Self.readyCategory
            content.userInfo = ["pid": Int(session.id.pid), "start": session.id.startTime]
        } else {
            content.body = "\(session.name): type continue to go on"
        }
        post(content, id: "ready-\(session.id)")
    }

    func notifyResumed(_ session: AgentSession) {
        if useBanner { banner.show(title: "Continued \(session.name)", body: session.agent.displayName); return }
        let content = UNMutableNotificationContent()
        content.title = "Continued \(session.name)"
        content.body = session.agent.displayName
        post(content, id: "resumed-\(session.id)")
    }

    func notifyFailed(_ session: AgentSession, reason: String) {
        if useBanner { banner.show(title: "Couldn't continue \(session.name)", body: reason, persistent: true); return }
        let content = UNMutableNotificationContent()
        content.title = "Couldn't continue \(session.name)"
        content.body = reason
        post(content, id: "failed-\(session.id)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        refreshAuthorization()
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.continueAction else { return }
        let info = response.notification.request.content.userInfo
        guard let pid = info["pid"] as? Int, let start = info["start"] as? Double else { return }
        await MainActor.run {
            engine?.continueNow(SessionKey(pid: Int32(pid), startTime: start))
        }
    }
}
