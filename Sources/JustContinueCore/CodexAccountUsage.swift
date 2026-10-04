import Foundation

/// Reads account-wide usage through Codex's documented app-server API. Codex owns sign-in and
/// token refresh; this app never reads credentials or starts a conversation.
public enum CodexAccountUsage {
    public enum ReadError: Error, Equatable, Sendable {
        case cliNotFound, signInRequired, unavailable, timedOut

        public var message: String {
            switch self {
            case .cliNotFound: "Install the Codex CLI to show usage."
            case .signInRequired: "Sign in to Codex with ChatGPT to show usage."
            case .unavailable: "Couldn't refresh Codex usage. Try again shortly."
            case .timedOut: "Codex usage took too long to respond."
            }
        }
    }

    public static func fetch() -> Result<AgentUsage, ReadError> {
        guard let executable = executablePath() else { return .failure(.cliNotFound) }
        return fetch(executable: executable, arguments: ["app-server", "--listen", "stdio://"])
    }

    static func executablePath() -> String? {
        let home = NSHomeDirectory()
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin"]
        return directories.map { $0 + "/codex" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking, bounded request; call off the main thread. Parameters support isolated tests.
    static func fetch(executable: String, arguments: [String], timeout: TimeInterval = 20) -> Result<AgentUsage, ReadError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // npm launchers need node even when Finder gave the app a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                                 "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                                + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inbox = RPCInbox()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        output.fileHandleForReading.readabilityHandler = { handle in
            inbox.receive(handle.availableData)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            try? output.fileHandleForReading.close()
        }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            func send(_ object: JSONObject) throws {
                var data = try JSONSerialization.data(withJSONObject: object)
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": "just_continue", "title": "Just Continue", "version": "0.1.0"
            ]]])
            guard let initialized = inbox.response(id: 1, deadline: deadline) else {
                return .failure(Date() >= deadline ? .timedOut : .unavailable)
            }
            guard initialized["result"] != nil else { return .failure(.unavailable) }
            try send(["method": "initialized", "params": [:]])
            try send(["id": 2, "method": "account/rateLimits/read"])
            guard let response = inbox.response(id: 2, deadline: deadline) else {
                return .failure(Date() >= deadline ? .timedOut : .unavailable)
            }
            if let error = response["error"] as? JSONObject {
                // Never surface arbitrary server messages, which can contain local account details.
                let message = (error["message"] as? String ?? "").lowercased()
                return .failure(message.contains("auth") || message.contains("sign in") || message.contains("login")
                                ? .signInRequired : .unavailable)
            }
            guard let result = response["result"] as? JSONObject,
                  let usage = parse(result: result, now: Date()) else { return .failure(.unavailable) }
            return .success(usage)
        } catch {
            return .failure(.unavailable)
        }
    }

    static func parse(result: JSONObject, now: Date) -> AgentUsage? {
        let byID = result["rateLimitsByLimitId"] as? JSONObject
        let legacy = result["rateLimits"] as? JSONObject
        // Do not substitute a model-specific quota (e.g. premium) for the Codex account bucket.
        let limits = (byID?["codex"] as? JSONObject) ?? legacy.flatMap { value in
            let id = value["limitId"] as? String
            return id == nil || id == "codex" ? value : nil
        }
        guard let limits else { return nil }
        var usage = AgentUsage(updatedAt: now, source: .liveAccount)
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? JSONObject,
                  let percent = window["usedPercent"] as? NSNumber,
                  percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue) else { continue }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            // Some accounts return only a weekly bucket in primary. Identify it by duration.
            let kind: AgentUsage.Window.Kind
            switch minutes {
            case 300: kind = .fiveHour
            case 10080: kind = .weekly
            case nil: kind = key == "primary" ? .fiveHour : .weekly
            default: continue
            }
            let value = AgentUsage.Window(kind: kind, usedPercent: percent.doubleValue,
                                          resetsAt: epochDate(window["resetsAt"]))
            if kind == .fiveHour { usage.fiveHour = value } else { usage.weekly = value }
        }
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }
}

/// Buffers JSONL on the pipe callback, then lets the request thread await its own response IDs.
/// Notifications, malformed lines, early exit, and oversized output cannot hang the caller.
private final class RPCInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    func receive(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard !closed else { return }
        guard !data.isEmpty else { closed = true; return }
        guard buffer.count + data.count < 1_048_576, lines.count < 256 else { closed = true; return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<end]))
            buffer.removeSubrange(...end)
        }
    }

    func response(id: Int, deadline: Date) -> JSONObject? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            while !lines.isEmpty {
                guard let object = JSONLines.parse(lines.removeFirst()), (object["id"] as? Int) == id else { continue }
                return object
            }
            if closed || !condition.wait(until: deadline) { return nil }
        }
    }
}
