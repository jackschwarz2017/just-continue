import AppKit
import JustContinueCore
import SwiftUI

/// Optional detailed log in ~/Library/Logs/JustContinue. Off by default.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/JustContinue/diagnostics.log")
    private let queue = DispatchQueue(label: "diagnostic-log")
    private let enabled = Locked(false)
    static let maxBytes = 1_000_000
    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) static let timestamp = ISO8601DateFormatter()

    func setEnabled(_ on: Bool) {
        enabled.value = on
        if on { write("Detailed logging on") }
    }

    func write(_ line: String) {
        guard enabled.value else { return }
        let stamp = Self.timestamp.string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let url = self.url
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > Self.maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func tail(lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(lines).map(String.init))
    }
}

/// A plain-text report for bug reports. Session and folder names and home paths are replaced
/// with placeholders; the user sees the full text before copying or saving it.
@MainActor
enum DiagnosticReport {
    static func make(model: AppModel) async -> String {
        let rows = model.engine.rows
        var redact = Redactor()
        for (i, row) in rows.enumerated() {
            redact.add(row.session.name, as: "session-\(i + 1)")
            if let cwd = row.session.cwd { redact.add(cwd, as: "folder-\(i + 1)") }
            if let folder = row.session.folderName { redact.add(folder, as: "folder-\(i + 1)") }
        }

        let permissions = await Task.detached {
            ScriptableTerminal.all.map { t in (t.name, t.isInstalled, t.isInstalled ? AutomationPermission.check(bundleID: t.bundleID, ask: false) : nil) }
        }.value

        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var out: [String] = []
        out.append("Just Continue diagnostic report")
        out.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("App: \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "-"))")
        out.append("macOS: \(os) · Mac: \(hardwareModel()) · Lid: \(Lid.hasLid ? (Lid.isClosed == true ? "closed" : "open") : "none")")
        out.append("")
        out.append("Agents: Claude Code \(model.isInstalled(.claude) ? "installed" : "not installed"), Codex \(model.isInstalled(.codex) ? "installed" : "not installed")")
        out.append("Terminals:")
        for (name, installed, permission) in permissions {
            out.append("  \(name): \(installed ? "installed" : "not installed")\(permission.map { ", automation \($0)" } ?? "")")
        }
        out.append("  tmux: \(Tmux.path ?? "not found")")
        out.append("")
        let s = model.engineSettings
        out.append("Settings: autoEnableNew=\(s.autoEnableNew) messageLength=\(s.continuationText.count) waitBeforeSending=\(Int(s.resetDelay))s idle=\(Int(s.idleThreshold))s keepScreenOn=\(s.keepDisplayOn) showUsage=\(model.showUsage) shortcut=\(model.shortcut?.display ?? "none") dryRun=\(s.dryRun)")
        out.append("Power: keepingAwake=\(model.engine.isKeepingAwake) manual=\(s.keepAwakeManually)")
        out.append("Usage: claude=\(model.claudeUsage != nil ? "yes" : "no") (statusLine connected=\(ClaudeStatusLineSetup.isSetUp())) codex=\(model.codexUsage != nil ? "yes" : "no")")
        if model.debug.isActive { out.append("Debug overrides active") }
        out.append("")
        out.append("Sessions (\(rows.count)):")
        for row in rows {
            let location = row.session.resumability.location.map { "\($0.kind.displayName)" } ?? "\(row.session.resumability)"
            out.append("  \(redact(row.session.name)) (session \(row.id)) · \(row.session.agent.displayName) · \(location) · \(row.enabled ? "on" : "off") · \(row.status.text)\(row.pending.map { " · pending \($0.phase), attempts \($0.attempts)" } ?? "")")
        }
        out.append("")
        out.append("Activity (newest first):")
        for entry in model.engine.activity.prefix(100) {
            out.append("  \(DiagnosticLog.timestamp.string(from: entry.date)) \(redact(entry.text))")
        }
        let detailed = DiagnosticLog.shared.tail(lines: 400)
        if !detailed.isEmpty {
            out.append("")
            out.append("Detailed log (last \(detailed.count) lines):")
            out += detailed.map { "  " + redact($0) }
        }
        return out.joined(separator: "\n")
    }

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    struct Redactor {
        private var replacements: [(String, String)] = [(NSHomeDirectory(), "~"), (NSUserName(), "user")]

        mutating func add(_ value: String, as placeholder: String) {
            guard value.count >= 3, !replacements.contains(where: { $0.0 == value }) else { return }
            replacements.append((value, placeholder))
            // Longest first, so a folder path wins over its last component.
            replacements.sort { $0.0.count > $1.0.count }
        }

        func callAsFunction(_ text: String) -> String {
            replacements.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
    }
}

/// Shows the report before anything leaves the Mac.
struct DiagnosticsView: View {
    let report: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project names and folders are replaced with placeholders. Check the report, then copy it into your bug report.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        copied = false
                    }
                } label: {
                    if copied { Label("Copied", systemImage: "checkmark") } else { Text("Copy Report") }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 640, height: 520)
    }
}
