import JustContinueCore
import Foundation
import Observation
import ServiceManagement

/// App-level state: user settings (persisted), the engine, notifications, plan usage.
@MainActor
@Observable
final class AppModel {
    let engine: ResumeEngine
    let notifications = NotificationController()
    /// Hidden test switches (⌥ while opening the menu).
    let debug = DebugOptions()

    /// Writes a detailed log for bug reports. Off by default.
    var detailedLogging: Bool {
        didSet {
            defaults.set(detailedLogging, forKey: Keys.detailedLogging)
            DiagnosticLog.shared.setEnabled(detailedLogging)
        }
    }

    /// Installed check that respects debug overrides; agents that aren't installed are never shown.
    func isInstalled(_ agent: AgentKind) -> Bool {
        let override = agent == .claude ? debug.claudeInstalled : debug.codexInstalled
        return override ?? agent.isInstalled
    }

    /// Usage to show, after debug overrides and the installed check.
    var visibleClaudeUsage: AgentUsage? { debug.demoUsage?.claude ?? (debug.hideUsage || !isInstalled(.claude) ? nil : claudeUsage) }
    var visibleCodexUsage: AgentUsage? { debug.demoUsage?.codex ?? (debug.hideUsage || !isInstalled(.codex) ? nil : codexUsage) }

    /// Turn on sessions started from now on. Off by default.
    var autoEnableNew: Bool {
        didSet {
            autoEnableSince = autoEnableNew ? Date() : nil
            save()
        }
    }
    private(set) var autoEnableSince: Date?
    /// The message typed into the session, followed by Return.
    var message: String { didSet { save() } }
    var idleMinutes: Int { didSet { save() } }
    var resetDelaySeconds: Int { didSet { save() } }
    /// Also keep the display on while the Mac is kept awake.
    var keepDisplayOn: Bool { didSet { save() } }
    /// How "ready" and "couldn't resume" messages appear. Banner by default: it stays until
    /// dismissed, where a system notification is easy to miss.
    enum AlertStyle: String, CaseIterable { case banner, system }
    var alertStyle: AlertStyle {
        didSet {
            defaults.set(alertStyle.rawValue, forKey: Keys.alertStyle)
            if alertStyle == .system { notifications.requestPermission() }
        }
    }
    /// Also continue Claude Code sessions, which otherwise continue on their own. Off by default.
    var continueClaudeSessions: Bool = UserDefaults.standard.bool(forKey: Keys.continueClaudeSessions) {
        didSet {
            defaults.set(continueClaudeSessions, forKey: Keys.continueClaudeSessions)
            continueClaude.value = continueClaudeSessions
            Task { await engine.tick() }
        }
    }
    @ObservationIgnored let continueClaude = Locked(UserDefaults.standard.bool(forKey: Keys.continueClaudeSessions))
    @ObservationIgnored let hiddenClaudeWaiting = Locked(false)

    /// Plan usage at the top of the menu. On by default.
    var showUsage: Bool { didSet { save() } }
    /// Per-agent usage in the menu, so users can show just one. On by default.
    var showClaudeUsage: Bool = UserDefaults.standard.object(forKey: Keys.showClaudeUsage) as? Bool ?? true {
        didSet { defaults.set(showClaudeUsage, forKey: Keys.showClaudeUsage) }
    }
    var showCodexUsage: Bool = UserDefaults.standard.object(forKey: Keys.showCodexUsage) as? Bool ?? true {
        didSet { defaults.set(showCodexUsage, forKey: Keys.showCodexUsage) }
    }
    /// Global shortcut that opens the menu. Nil = none.
    var shortcut: GlobalHotKey.Shortcut? {
        didSet {
            if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Keys.shortcut)
            } else {
                defaults.set(Data(), forKey: Keys.shortcut)  // empty = explicitly none
            }
            onShortcutChange?(shortcut)
        }
    }
    @ObservationIgnored var onShortcutChange: ((GlobalHotKey.Shortcut?) -> Void)?
    /// Opens the diagnostic report window (set by the app delegate).
    @ObservationIgnored var openDiagnostics: (() -> Void)?
    /// True while the shortcut field is recording; the global shortcut is paused meanwhile.
    var isRecordingShortcut = false { didSet { onShortcutChange?(isRecordingShortcut ? nil : shortcut) } }
    /// Set when another app already registered the shortcut globally.
    var shortcutRegistrationFailed = false
    var launchAtLoginError: String?

    /// "Keep Mac Awake" in the menu: stay awake even with no session enabled. Not persisted.
    var keepAwakeManually = false { didSet { apply() } }

    /// The menu's "Click a session to continue it" hint hides after the first toggle.
    var hasToggledSession: Bool = UserDefaults.standard.bool(forKey: Keys.hasToggledSession) {
        didSet { defaults.set(hasToggledSession, forKey: Keys.hasToggledSession) }
    }

    /// The menu's "Hold ⌥ for more options" hint hides once ⌥ was pressed with the menu open.
    var hasPressedOption: Bool = UserDefaults.standard.bool(forKey: Keys.hasPressedOption) {
        didSet { defaults.set(hasPressedOption, forKey: Keys.hasPressedOption) }
    }

    /// The menu's "Keep the lid open" item hides for good once clicked.
    var lidNoticeDismissed: Bool = UserDefaults.standard.bool(forKey: Keys.lidNoticeDismissed) {
        didSet { defaults.set(lidNoticeDismissed, forKey: Keys.lidNoticeDismissed) }
    }

    private(set) var claudeUsage: AgentUsage?
    private(set) var codexUsage: AgentUsage?
    private var usageTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Keys.idleMinutes: 3, Keys.resetDelaySeconds: 60, Keys.autoEnableNew: false,
                              Keys.message: "continue", Keys.keepDisplayOn: false, Keys.dryRun: false, Keys.showUsage: true])
        autoEnableNew = d.bool(forKey: Keys.autoEnableNew)
        autoEnableSince = d.object(forKey: Keys.autoEnableSince) as? Date
        message = d.string(forKey: Keys.message) ?? "continue"
        idleMinutes = d.integer(forKey: Keys.idleMinutes)
        resetDelaySeconds = d.integer(forKey: Keys.resetDelaySeconds)
        keepDisplayOn = d.bool(forKey: Keys.keepDisplayOn)
        showUsage = d.bool(forKey: Keys.showUsage)
        detailedLogging = d.bool(forKey: Keys.detailedLogging)
        alertStyle = AlertStyle(rawValue: d.string(forKey: Keys.alertStyle) ?? "") ?? .banner
        if let data = d.data(forKey: Keys.shortcut) {
            shortcut = data.isEmpty ? nil : try? JSONDecoder().decode(GlobalHotKey.Shortcut.self, from: data)
        } else {
            shortcut = .standard
        }

        // Simulated debug sessions run through the real engine but are never typed into.
        let debug = self.debug
        let continueClaude = self.continueClaude, hiddenClaudeWaiting = self.hiddenClaudeWaiting
        let real = ClaudeHandoffDiscovery(inner: SessionDiscovery(), continueClaude: continueClaude, hiddenWaiting: hiddenClaudeWaiting)
        engine = ResumeEngine(discovery: DebugDiscovery(real: real, simulated: debug.simulated, hideReal: debug.hideRealSessions),
                              input: DebugInput(real: TerminalInputSender(), simulated: debug.simulated),
                              activity: DebugActivity(real: SystemActivity(), override: debug.activityOverride))
        engine.settings = engineSettings
        engine.logSink = { DiagnosticLog.shared.write($0) }
        // Claude Code's own continue needs an awake Mac.
        // Includes visible sessions that Claude Code is about to continue itself.
        engine.keepAwakeAlso = { [weak engine] in
            hiddenClaudeWaiting.value || engine?.rows.contains { $0.session.logState.limit?.continuedByAgent == true } == true
        }
        DiagnosticLog.shared.setEnabled(detailedLogging)
        notifications.engine = engine
        notifications.pretendDisabled = { [weak debug] in debug?.notificationsOff ?? false }
        notifications.prefersSystem = { [weak self] in self?.alertStyle == .system }
        engine.setNotifier(notifications)
        notifications.setUp(requestPermission: alertStyle == .system)
    }

    /// Log what would be typed instead of typing. In the Debug menu; also
    ///   defaults write dev.justcontinue.JustContinue dryRun -bool true
    var dryRun: Bool {
        get { access(keyPath: \.dryRun); return defaults.bool(forKey: Keys.dryRun) }
        set { withMutation(keyPath: \.dryRun) { defaults.set(newValue, forKey: Keys.dryRun) }; apply() }
    }

    var engineSettings: EngineSettings {
        var s = EngineSettings()
        s.continuationText = Self.sendable(message)
        s.dryRun = dryRun
        s.idleThreshold = TimeInterval(max(1, idleMinutes) * 60)
        s.resetDelay = TimeInterval(min(max(0, resetDelaySeconds), 600))
        s.keepAwake = true  // Always on while a session is enabled.
        s.keepAwakeManually = keepAwakeManually
        s.keepDisplayOn = keepDisplayOn
        s.autoEnableNew = autoEnableNew
        s.autoEnableSince = autoEnableSince
        return s
    }

    /// The message as one line: a Return in the middle would submit half of it.
    static func sendable(_ message: String) -> String {
        let oneLine = message.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return oneLine.isEmpty ? "continue" : oneLine
    }

    private func save() {
        defaults.set(autoEnableNew, forKey: Keys.autoEnableNew)
        defaults.set(autoEnableSince, forKey: Keys.autoEnableSince)
        defaults.set(message, forKey: Keys.message)
        defaults.set(idleMinutes, forKey: Keys.idleMinutes)
        defaults.set(resetDelaySeconds, forKey: Keys.resetDelaySeconds)
        defaults.set(keepDisplayOn, forKey: Keys.keepDisplayOn)
        defaults.set(showUsage, forKey: Keys.showUsage)
        apply()
    }

    private func apply() {
        engine.settings = engineSettings
        engine.evaluate()
    }

    /// Plan usage for the menu, refreshed every 30 s. Claude Code's file is also re-read whenever the
    /// menu opens (`refreshClaudeUsage`), so a status-line update shows right away.
    func startUsageUpdates() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let (claude, codex) = await Task.detached { (UsageReader.claude(), UsageReader.codex()) }.value
                self?.claudeUsage = claude
                self?.codexUsage = codex
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One small file read; cheap enough to do as the menu opens.
    func refreshClaudeUsage() {
        claudeUsage = UsageReader.claude()
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Couldn't change: \(error.localizedDescription)"
            }
        }
    }

    enum Keys {
        static let autoEnableNew = "autoEnableNew"
        static let autoEnableSince = "autoEnableSince"
        static let message = "continuationText"
        static let idleMinutes = "idleMinutes"
        static let resetDelaySeconds = "resetDelaySeconds"
        static let keepDisplayOn = "keepDisplayOn"
        static let dryRun = "dryRun"
        static let lidNoticeDismissed = "lidNoticeDismissed"
        static let hasToggledSession = "hasToggledSession"
        static let hasPressedOption = "hasPressedOption"
        static let showUsage = "showUsage"
        static let showClaudeUsage = "showClaudeUsage"
        static let showCodexUsage = "showCodexUsage"
        static let continueClaudeSessions = "continueClaudeSessions"
        static let shortcut = "shortcut"
        static let detailedLogging = "detailedLogging"
        static let alertStyle = "alertStyle"
    }
}
