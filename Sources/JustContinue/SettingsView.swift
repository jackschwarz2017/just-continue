import AppKit
import JustContinueCore
import SwiftUI

/// Settings tabs, shown in a native toolbar-style tab window (`SettingsWindow`).
enum SettingsTab: Int, CaseIterable {
    case general, continuing, usage, terminals, troubleshooting

    var title: String {
        switch self {
        case .general: "General"
        case .continuing: "Continuing"
        case .usage: "Usage"
        case .terminals: "Terminals"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .continuing: "text.cursor"
        case .usage: "gauge.with.dots.needle.50percent"
        case .terminals: "terminal"
        case .troubleshooting: "stethoscope"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .general: GeneralTab()
        case .continuing: ContinuingTab()
        case .usage: UsageTab()
        case .terminals: TerminalsTab()
        case .troubleshooting: TroubleshootingTab()
        }
    }
}

/// Shared look for every tab: grouped form, large controls, fixed width, height fits content.
private struct TabForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .controlSize(.large)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabForm {
                if Lid.hasLid {
                    Section { LidWarning() }
                }
                Section {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    if let error = model.launchAtLoginError {
                        Text(error).foregroundStyle(.red)
                    }
                    Toggle(isOn: $model.autoEnableNew) {
                        Text("Continue new sessions automatically")
                        Text("Sessions you start from now on are turned on.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent {
                            ShortcutField(shortcut: $model.shortcut) { model.isRecordingShortcut = $0 }
                                .frame(width: 160)
                        } label: {
                            Text("Shortcut to open the menu")
                            Text(model.isRecordingShortcut ? "Press the new shortcut. Esc keeps the current one." : "Click the field, then press keys.")
                        }
                        if let warning = shortcutWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker(selection: $model.alertStyle) {
                        Text("Banner").tag(AppModel.AlertStyle.banner)
                        Text("System notification").tag(AppModel.AlertStyle.system)
                    } label: {
                        Text("Alerts")
                        Text(model.alertStyle == .banner ? "Stays on screen until you close it." : "Appears in Notification Center.")
                    }
                }
                if model.isInstalled(.claude) {
                    ClaudeHandoffSection()
                }
            }
            VStack(spacing: 10) {
                HStack(spacing: 3) {
                    Text("Made with ❤️ and 🤖 by").foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://www.jackschwarz.com/")!) { SettingsLinkLabel("Jack Schwarz") }
                        .buttonStyle(.link)
                }
                .font(.footnote)
                HStack(spacing: 12) {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(Color.secondary)
                    Link(destination: URL(string: "https://github.com/jackschwarz2017/just-continue")!) {
                        SettingsLinkLabel("GitHub")
                    }
                    Link(destination: URL(string: "https://github.com/sponsors/jackschwarz2017")!) {
                        SettingsLinkLabel("Sponsor")
                    }
                }
                .font(.callout)
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    /// Shortcut conflicts we can detect. The user can keep the shortcut anyway.
    private var shortcutWarning: String? {
        guard let shortcut = model.shortcut else { return nil }
        if model.shortcutRegistrationFailed { return "Another app already uses this shortcut. Choose a different one." }
        return ShortcutConflicts.check(shortcut)
    }
}

/// Claude Code continues sessions itself; Just Continue leaves them alone unless asked.
private struct ClaudeHandoffSection: View {
    @Environment(AppModel.self) private var model
    private let builtInOn = ClaudeBuiltInContinue.isEnabled()

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.continueClaudeSessions) {
                Text("Continue Claude Code sessions too")
                Text(builtInOn ? "Claude Code resumes automatically. Enable to let Just Continue handle it too." : "Claude Code’s auto-continue is off. Just Continue handles these sessions.")
                Link(destination: ClaudeBuiltInContinue.docsURL) { SettingsLinkLabel("Learn more") }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
            .disabled(!builtInOn)
        } header: {
            Text("Claude Code")
        }
    }
}

struct ContinuingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabForm {
            Section("When a limit resets") {
                MessageRow(message: $model.message)
                NumberRow(title: "Wait before sending",
                          detail: "After the limit resets, waits this long, then sends the message.",
                          value: $model.resetDelaySeconds, range: 0...600, step: 15, unit: "sec")
                NumberRow(title: "Continue after I'm idle for",
                          detail: "Never types while you're using your Mac.",
                          value: $model.idleMinutes, range: 1...60, step: 1, unit: "min")
            }
        }
    }
}

struct UsageTab: View {
    var body: some View {
        TabForm { UsageSection() }
    }
}

struct TerminalsTab: View {
    var body: some View {
        TabForm { SupportedTerminalsSection() }
    }
}

struct TroubleshootingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabForm {
            Section {
                Toggle(isOn: $model.detailedLogging) {
                    Text("Detailed logging")
                    Text("Keeps a log to help fix problems.")
                }
                HStack {
                    Text("Diagnostic report")
                    Spacer()
                    Button(model.isCreatingReport ? "Creating Report…" : "Create Report…") { model.openDiagnostics?() }
                        .settingsButtonHover()
                        .disabled(model.isCreatingReport)
                }
                HStack {
                    Text("Report a bug")
                    Spacer()
                    Button("Open an Issue…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jackschwarz2017/just-continue/issues/new/choose")!)
                    }
                    .settingsButtonHover()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review the report before sharing it in a GitHub issue. Project and folder names are replaced; nothing is sent automatically.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    AcknowledgementsLink()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A small link to the third-party licences.
private struct AcknowledgementsLink: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { SettingsLinkLabel("Acknowledgements") }
            .buttonStyle(.link)
            .controlSize(.small)
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Acknowledgements").font(.headline)
                ScrollView {
                    Text(AppGlyph.acknowledgements)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { showing = false }.keyboardShortcut(.defaultAction).settingsButtonHover()
                }
            }
            .padding(20)
            .frame(width: 460, height: 360)
        }
    }
}

/// A warning, not a setting: icon, bold title, explanation.
private struct LidWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep the lid open").bold()
                Text("Closing it puts your Mac to sleep, so sessions can't continue.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The message as a text area that grows with its text (3 to 8 lines, then scrolls).
/// Empty means "continue"; Reset puts "continue" back.
private struct MessageRow: View {
    @Binding var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Message")
                Spacer()
                Button("Reset") { message = "continue" }
                    .settingsButtonHover()
                    .disabled(message == "continue")
            }
            ZStack(alignment: .topLeading) {
                // Invisible copy of the text sizes the editor to its content.
                Text(message.isEmpty ? " " : message + " ")
                    .font(.body)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .opacity(0)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                TextEditor(text: $message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.vertical, 8)
                if message.isEmpty {
                    Text("continue")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: 150)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Typed into the session, followed by Return. Line breaks are sent as spaces; empty sends “continue”.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// Title, number field and stepper on one line, explanation underneath. The value updates as
/// you type; anything out of range is corrected when you leave the field.
private struct NumberRow: View {
    let title: String
    let detail: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, text: $text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($focused)
                    .onChange(of: text) { _, new in
                        let digits = new.filter(\.isNumber)
                        if digits != new { text = digits; return }
                        if let n = Int(digits), range.contains(n) { value = n }
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { text = "\(value)" } }
                    .onSubmit { text = "\(value)" }
                Stepper(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                        in: range, step: step)
                    .labelsHidden()
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, new in if !focused || Int(text) != new { text = "\(new)" } }
    }
}

/// "Show usage" plus, for Claude Code, Connect / Disconnect.
private struct UsageSection: View {
    @Environment(AppModel.self) private var model
    @State private var connected = ClaudeStatusLineSetup.isSetUp()
    @State private var changingConnection = false
    @State private var error: String?

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.showUsage) {
                Text("Show usage in the menu")
                Text("5-hour and weekly limits for your agents.")
            }
            if model.showUsage, model.isInstalled(.codex) {
                Toggle(isOn: $model.showCodexUsage) {
                    Text("Codex")
                    Text("Live usage through your Codex sign-in.")
                }
                if model.showCodexUsage {
                    HStack {
                        Text(model.codexUsageMessage).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isRefreshingCodexUsage ? "Refreshing…" : "Refresh") { model.refreshCodexUsage(force: true) }
                            .settingsButtonHover()
                            .disabled(model.isRefreshingCodexUsage)
                    }
                }
            }
            if model.showUsage, model.isInstalled(.claude) {
                Toggle("Claude Code", isOn: $model.showClaudeUsage)
            }
            if model.showUsage, model.isInstalled(.claude), model.showClaudeUsage {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code usage data")
                        Text(connected ? "Local snapshot · updates while you use Claude"
                             : connectionLost ? "Your Claude Code status line changed, so usage stopped updating"
                             : "Connect to read its usage")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(changingConnection ? (connected ? "Disconnecting…" : "Connecting…")
                           : connected ? "Disconnect" : connectionLost ? "Reconnect" : "Connect") { toggle() }
                        .settingsButtonHover()
                        .disabled(changingConnection)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        } footer: {
            if model.showUsage, model.isInstalled(.claude), model.showClaudeUsage, !connected {
                Text(connectionLost
                     ? "Something replaced the status line in ~/.claude/settings.json. Reconnect adds the small step back in front of your current status line, or turn off Claude Code above to hide this."
                     : "Claude Code only shares usage with its status line. Connect adds one small step to ~/.claude/settings.json; your status line looks the same.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { model.refreshCodexUsage() }
        .onChange(of: model.showUsage) { _, enabled in if enabled { model.refreshCodexUsage() } }
        .onChange(of: model.showCodexUsage) { _, enabled in if enabled { model.refreshCodexUsage() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !changingConnection { connected = ClaudeStatusLineSetup.isSetUp() }
            model.refreshCodexUsage()
        }
    }

    private var connectionLost: Bool { !connected && model.claudeUsageConnectionWanted }

    private func toggle() {
        guard !changingConnection else { return }
        changingConnection = true
        error = nil
        let disconnect = connected
        Task {
            let result = await Task.detached { () -> (Bool, String?) in
                do {
                    if disconnect { try ClaudeStatusLineSetup.disconnect() } else { try ClaudeStatusLineSetup.connect() }
                    return (ClaudeStatusLineSetup.isSetUp(), nil)
                } catch {
                    return (ClaudeStatusLineSetup.isSetUp(), String(describing: error))
                }
            }.value
            connected = result.0
            error = result.1
            if result.1 == nil { model.claudeUsageConnectionWanted = !disconnect }
            changingConnection = false
            model.refreshClaudeUsage()
        }
    }
}

/// The terminals Just Continue supports, and whether macOS lets it type into them.
private struct SupportedTerminalsSection: View {
    @Environment(AppModel.self) private var model
    @State private var statuses: [String: AutomationPermission] = [:]
    @State private var asking: String?
    @State private var checking = false
    @State private var stillDeniedAfterReset: Set<String> = []

    var body: some View {
        Section {
            ForEach(ScriptableTerminal.all) { terminal in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label { Text(terminal.displayName) } icon: { AppIcon(bundleID: terminal.bundleID) }
                        Spacer()
                        status(for: terminal)
                    }
                    if terminal.isInstalled, permission(for: terminal) == .denied {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allow Just Continue to control \(terminal.name) in Privacy & Security → Automation so it can continue your sessions.")
                                .foregroundStyle(.secondary)
                            if stillDeniedAfterReset.contains(terminal.bundleID) {
                                Text("macOS still denies access without asking. Your organization may manage this setting with a configuration profile; ask your IT administrator, or use tmux instead.")
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 4) {
                                    Text("Not listed there?").foregroundStyle(.secondary)
                                    Button { resetAndAsk(terminal) } label: {
                                        SettingsLinkLabel(asking == terminal.bundleID ? "Resetting…" : "Reset and Ask Again")
                                    }
                                    .buttonStyle(.link)
                                    .disabled(asking != nil || checking)
                                }
                            }
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Label { Text("tmux") } icon: { Image(systemName: "terminal").frame(width: 22) }
                Spacer()
                Text(Tmux.path == nil ? "Not installed" : "Ready").foregroundStyle(.secondary)
            }
        } header: {
            Text("Supported terminals")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if model.debug.terminalAccessDenied {
                    Text("Debug: Terminal access is simulated as denied. Turn off ‘Terminal Access Is Denied’ in the Debug menu to restore normal operation.")
                        .foregroundStyle(.orange)
                }
                if model.debug.staleDenial != nil {
                    Text("Debug: A stale Terminal denial is simulated. Reset and Ask Again won't change real permissions.")
                        .foregroundStyle(.orange)
                }
                Text("Allow access before you leave: macOS can't ask while the screen is locked. Other terminals work inside tmux.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onChange(of: model.debug.staleDenial) { stillDeniedAfterReset = [] }
    }

    private func permission(for terminal: ScriptableTerminal) -> AutomationPermission? {
        model.debug.simulatedAccess(for: terminal.bundleID) ?? statuses[terminal.bundleID]
    }

    @ViewBuilder
    private func status(for terminal: ScriptableTerminal) -> some View {
        if !terminal.isInstalled {
            Text("Not installed").foregroundStyle(.secondary)
        } else {
            switch permission(for: terminal) {
            case .granted:
                Text("Ready").foregroundStyle(.secondary)
            case .notDetermined:
                Button(asking == terminal.bundleID ? "Asking…" : "Allow Access") { ask(terminal) }
                    .settingsButtonHover()
                    .disabled(asking != nil || checking)
            case .denied:
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                .settingsButtonHover()
            case .notRunning:
                Text("Open \(terminal.name) to allow access").foregroundStyle(.secondary)
            case .unknown:
                Button(checking ? "Checking…" : "Check Again") { Task { await refresh() } }
                    .settingsButtonHover()
                    .disabled(checking || asking != nil)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func refresh() async {
        guard !checking, asking == nil else { return }
        checking = true
        defer { checking = false }
        for terminal in ScriptableTerminal.all where terminal.isInstalled {
            let id = terminal.bundleID
            let permission = await Task.detached { AutomationPermission.check(bundleID: id, ask: false) }.value
            statuses[id] = permission
            model.recordTerminalAccess(permission, for: id)
        }
    }

    private func ask(_ terminal: ScriptableTerminal) {
        guard asking == nil, !checking else { return }
        asking = terminal.bundleID
        let id = terminal.bundleID
        Task {
            let permission = await Task.detached { AutomationPermission.check(bundleID: id, ask: true) }.value
            statuses[id] = permission
            model.recordTerminalAccess(permission, for: id)
            asking = nil
        }
    }

    /// A denial System Settings doesn't list is usually a stale record from another build or copy
    /// of the app. Resetting clears it (for every terminal) so macOS can show the prompt again.
    private func resetAndAsk(_ terminal: ScriptableTerminal) {
        guard asking == nil, !checking else { return }
        asking = terminal.bundleID
        let id = terminal.bundleID
        if model.debug.staleDenial != nil, id == TerminalBundle.terminal {
            Task {
                if await model.debug.simulateStaleDenialReset() == .denied { stillDeniedAfterReset.insert(id) }
                asking = nil
            }
            return
        }
        Task {
            let permission = await Task.detached { () -> AutomationPermission in
                _ = AutomationPermission.resetAll()
                return AutomationPermission.check(bundleID: id, ask: true)
            }.value
            statuses[id] = permission
            model.recordTerminalAccess(permission, for: id)
            if permission == .denied { stillDeniedAfterReset.insert(id) }
            asking = nil
            await refresh()
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "terminal").frame(width: 22)
        }
    }
}

/// Adds hover feedback without replacing native button behavior or keyboard focus.
private struct SettingsButtonHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(isHovered && isEnabled ? 0.06 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered && isEnabled)
    }
}

/// Label for text links (`.buttonStyle(.link)` buttons and `Link`s): no underline until hovered,
/// like the inline Markdown links. Hover boxes are for bordered buttons only.
private struct SettingsLinkLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        // Set on every move: SwiftUI's pointerStyle(.link) misses some links (it left Sponsor
        // with the arrow), and AppKit's cursor updates would undo a one-time push.
        Text(title)
            .underline(isHovered && isEnabled)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovered = true
                    if isEnabled { NSCursor.pointingHand.set() }
                case .ended:
                    isHovered = false
                    NSCursor.arrow.set()
                }
            }
    }
}

private extension View {
    func settingsButtonHover() -> some View { modifier(SettingsButtonHover()) }
}
