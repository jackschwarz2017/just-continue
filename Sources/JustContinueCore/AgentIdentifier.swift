import Foundation

/// Decides whether a process is an interactive Claude Code / Codex session.
public enum AgentIdentifier {
    /// Codex subcommands that are not interactive sessions.
    static let codexNonInteractive: Set<String> = ["app-server", "exec", "e", "mcp", "mcp-server", "login", "logout", "proto", "completion", "apply", "sandbox"]
    static let scriptHosts: Set<String> = ["node", "bun", "deno"]

    public static func identify(arguments argv: [String], executablePath: String?) -> AgentKind? {
        guard let first = argv.first else { return nil }
        var args = argv
        var name = (first as NSString).lastPathComponent

        // npm-installed CLIs may run as `node /path/to/claude ...`.
        if scriptHosts.contains(name), argv.count > 1 {
            let script = argv[1]
            args = Array(argv.dropFirst())
            if script.contains("@anthropic-ai/claude-code") { name = "claude" }
            else if script.contains("@openai/codex") { name = "codex" }
            else { name = (script as NSString).lastPathComponent }
        }

        // Claude Code's native binary lives at ~/.local/share/claude/versions/<version>.
        if name != "claude", name != "codex", let path = executablePath, path.contains("/claude/versions/") {
            name = "claude"
        }

        let rest = Array(args.dropFirst())
        switch name {
        case "claude":
            // Headless runs are not sessions anyone can type into.
            if rest.contains(where: { $0 == "-p" || $0 == "--print" }) { return nil }
            return .claude
        case "codex":
            if let sub = rest.first(where: { !$0.hasPrefix("-") }), codexNonInteractive.contains(sub) { return nil }
            return .codex
        default:
            return nil
        }
    }
}
