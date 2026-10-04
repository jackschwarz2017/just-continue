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
            VStack(spacing: 6) {
                Text("Made with ❤️ and 🤖 by [Jack Schwarz](https://www.jackschwarz.com/)")
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
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
                Text(.init("\(builtInOn ? "Claude Code resumes automatically. Enable to let Just Continue handle it too." : "Claude Code’s auto-continue is off. Just Continue handles these sessions.") [Learn more](\(ClaudeBuiltInContinue.docsURL.absoluteString))"))
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
                    Button("Create Report…") { model.openDiagnostics?() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 14) {
                    Text("You see the report before sharing it. Project and folder names are replaced.")
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
        Button("Acknowledgements") { showing = true }
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
                    Button("Done") { showing = false }.keyboardShortcut(.defaultAction)
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
    @State private var error: String?

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.showUsage) {
                Text("Show usage in the menu")
                Text("5-hour and weekly limits for your agents.")
            }
            if model.showUsage, model.isInstalled(.codex) {
                Toggle("Codex", isOn: $model.showCodexUsage)
            }
            if model.showUsage, model.isInstalled(.claude) {
                Toggle("Claude Code", isOn: $model.showClaudeUsage)
            }
            if model.showUsage, model.isInstalled(.claude), model.showClaudeUsage {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code usage data")
                        Text(connected ? "Connected" : "Connect to read its usage")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(connected ? "Disconnect" : "Connect") { toggle() }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        } footer: {
            if model.showUsage, model.isInstalled(.claude), model.showClaudeUsage, !connected {
                Text("Claude Code only shares usage with its status line. Connect adds one small step to ~/.claude/settings.json; your status line looks the same.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connected = ClaudeStatusLineSetup.isSetUp()
        }
    }

    private func toggle() {
        do {
            if connected { try ClaudeStatusLineSetup.disconnect() } else { try ClaudeStatusLineSetup.connect() }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        connected = ClaudeStatusLineSetup.isSetUp()
    }
}

/// The terminals Just Continue supports, and whether macOS lets it type into them.
private struct SupportedTerminalsSection: View {
    @State private var statuses: [String: AutomationPermission] = [:]
    @State private var asking: String?

    var body: some View {
        Section {
            ForEach(ScriptableTerminal.all) { terminal in
                HStack {
                    Label { Text(terminal.displayName) } icon: { AppIcon(bundleID: terminal.bundleID) }
                    Spacer()
                    status(for: terminal)
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
            Text("Allow access before you leave: macOS can't ask while the screen is locked. Other terminals work inside tmux.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private func status(for terminal: ScriptableTerminal) -> some View {
        if !terminal.isInstalled {
            Text("Not installed").foregroundStyle(.secondary)
        } else {
            switch statuses[terminal.bundleID] {
            case .granted:
                Text("Ready").foregroundStyle(.secondary)
            case .notDetermined:
                Button(asking == terminal.bundleID ? "Asking…" : "Allow Access") { ask(terminal) }
                    .disabled(asking != nil)
            case .denied:
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            case .notRunning:
                Text("Open \(terminal.name) to allow access").foregroundStyle(.secondary)
            case .unknown, nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func refresh() async {
        for terminal in ScriptableTerminal.all where terminal.isInstalled {
            let id = terminal.bundleID
            statuses[id] = await Task.detached { AutomationPermission.check(bundleID: id, ask: false) }.value
        }
    }

    private func ask(_ terminal: ScriptableTerminal) {
        asking = terminal.bundleID
        let id = terminal.bundleID
        Task {
            statuses[id] = await Task.detached { AutomationPermission.check(bundleID: id, ask: true) }.value
            asking = nil
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
