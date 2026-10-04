import AppKit
import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    public var ok: Bool { status == 0 }
}

enum Shell {
    /// Runs a program and waits at most `timeout` seconds. Blocks; call off the main thread.
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 5) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(status: -1, output: "", error: "\(error)")
        }
        // Drain both pipes in the background, so a full pipe can't block the child
        // and a hung child can't block us past the timeout.
        let outData = PipeReader(out), errData = PipeReader(err)
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return CommandResult(status: -2, output: "", error: "timed out after \(Int(timeout))s")
        }
        return CommandResult(status: process.terminationStatus,
                             output: outData.text(), error: errData.text())
    }
}

/// Reads a pipe to the end on a background queue.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
    }

    /// The trimmed output. Waits briefly in case the pipe is still open (e.g. a grandchild holds it).
    func text() -> String {
        guard done.wait(timeout: .now() + 1) == .success else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppleScript {
    /// Runs AppleScript via osascript. The script is passed on stdin, never interpolated into argv.
    static func run(_ source: String, timeout: TimeInterval = 8) -> CommandResult {
        Shell.run("/usr/bin/osascript", ["-"], input: source, timeout: timeout)
    }

    /// Quotes a Swift string as an AppleScript string literal.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

public enum TerminalBundle {
    public static let iTerm = "com.googlecode.iterm2"
    public static let terminal = "com.apple.Terminal"
    public static let ghostty = "com.mitchellh.ghostty"
}
