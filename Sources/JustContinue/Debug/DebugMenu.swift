#if DEBUG || DEBUG_MENU
import AppKit
import JustContinueCore

/// The hidden Debug submenu. Compiled only into debug builds or builds made with
/// `DEBUG_MENU=1 scripts/build-app.sh`, and shown only while ⌥ is held when the menu opens.
@MainActor
enum DebugMenu {
    static func item(model: AppModel) -> NSMenuItem {
        let debug = model.debug
        let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: "Simulate"))
        menu.addItem(action("Session Hitting Its Limit (Resets in 1 Min)") { debug.add(.limitSoon); refresh(model) })
        menu.addItem(action("Session with a Weekly Limit") { debug.add(.weeklyLimit); refresh(model) })
        menu.addItem(action("Session in an Unsupported Terminal") { debug.add(.unsupported); refresh(model) })
        menu.addItem(action("Session in Ambiguous Ghostty Tabs") { debug.add(.ambiguousGhostty); refresh(model) })
        if debug.hasSimulatedSessions {
            menu.addItem(action("Remove Simulated Sessions") { debug.removeSimulatedSessions(); refresh(model) })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Pretend"))
        menu.addItem(toggle("Claude Code Isn't Installed", debug.claudeInstalled == false) { debug.claudeInstalled = debug.claudeInstalled == false ? nil : false })
        menu.addItem(toggle("Codex Isn't Installed", debug.codexInstalled == false) { debug.codexInstalled = debug.codexInstalled == false ? nil : false })
        menu.addItem(toggle("No Usage Data", debug.hideUsage) { debug.hideUsage.toggle() })
        menu.addItem(toggle("Terminal Access Is Denied", debug.terminalAccessDenied) {
            debug.terminalAccessDenied.toggle()
            refresh(model)
        })
        menu.addItem(toggle("Stale Terminal Denial (Reset Fixes It)", debug.staleDenial == .allowedAfterReset) {
            debug.staleDenial = debug.staleDenial == .allowedAfterReset ? nil : .allowedAfterReset
        })
        menu.addItem(toggle("Stale Terminal Denial (Reset Doesn't Help)", debug.staleDenial == .stillDenied) {
            debug.staleDenial = debug.staleDenial == .stillDenied ? nil : .stillDenied
        })
        menu.addItem(toggle("Notifications Are Off", debug.notificationsOff) { debug.notificationsOff.toggle() })
        menu.addItem(toggle("I'm Away", debug.activity == .away) { debug.activity = debug.activity == .away ? nil : .away; model.engine.evaluate() })
        menu.addItem(toggle("I'm Using My Mac", debug.activity == .active) { debug.activity = debug.activity == .active ? nil : .active; model.engine.evaluate() })

        menu.addItem(.separator())
        menu.addItem(toggle("Dry Run (Never Type)", model.dryRun) { model.dryRun.toggle() })
        menu.addItem(action("Start as First Launch") {
            // Everything a new user sees once: lid notice and both menu hints.
            model.lidNoticeDismissed = false
            model.hasToggledSession = false
            model.hasPressedOption = false
        })
        menu.addItem(action("Show Test Banner") {
            model.notifications.banner.show(title: "Codex is ready to continue", body: "Simulated session",
                                            action: .init(title: "Continue Now") {})
        })
        menu.addItem(action("Diagnostic Report…") { model.openDiagnostics?() })
        if debug.isActive || model.dryRun {
            menu.addItem(.separator())
            menu.addItem(action("Reset All Debug Options") {
                debug.removeSimulatedSessions()
                debug.claudeInstalled = nil
                debug.codexInstalled = nil
                debug.hideUsage = false
                debug.notificationsOff = false
                debug.terminalAccessDenied = false
                debug.staleDenial = nil
                debug.activity = nil
                model.dryRun = false
                refresh(model)
            })
        }

        item.submenu = menu
        return item
    }

    private static func refresh(_ model: AppModel) {
        Task { await model.engine.tick() }
    }

    private static func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, run: run)
    }

    private static func toggle(_ title: String, _ on: Bool, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, run: run)
        item.state = on ? .on : .off
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
#endif
