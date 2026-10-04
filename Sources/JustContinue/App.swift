import AppKit
import JustContinueCore
import SwiftUI

@main
enum Main {
    @MainActor static let delegate = AppDelegate()

    @MainActor static func main() {
        // `JustContinue --list-sessions` prints what discovery sees, for debugging and bug reports.
        if CommandLine.arguments.contains("--list-sessions") {
            for s in SessionDiscovery().scan(previous: [:]) {
                print("\(s.agent.displayName)\tpid \(s.id.pid)\t\(s.tty)\t\(s.folderName ?? "-")\t\(s.name)\t\(s.logState)\t\(s.resumability)")
            }
            exit(0)
        }
        // No automatic action icons in menus (macOS 26); this menu has no icons at all.
        UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.mainMenu = makeMainMenu()
        app.delegate = delegate
        app.run()
    }
}

/// Never shown (menu-bar app), but text fields only get ⌘X/C/V/A/Z and ⌘W/⌘Q when a main menu
/// with those key equivalents exists.
@MainActor
private func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        main.addItem(item)
    }
    func item(_ title: String, _ action: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }
    submenu("Just Continue", [item("Quit Just Continue", "terminate:", "q")])
    submenu("Edit", [
        item("Undo", "undo:", "z"), item("Redo", "redo:", "z", [.command, .shift]), .separator(),
        item("Cut", "cut:", "x"), item("Copy", "copy:", "c"), item("Paste", "paste:", "v"),
        item("Select All", "selectAll:", "a"),
    ])
    submenu("Window", [item("Close", "performClose:", "w")])
    return main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel!
    private var menu: StatusMenuController!
    private var hotKey: GlobalHotKey!
    private var settings: SettingsWindow?
    private var settingsWindow: NSWindow? { settings?.window }
    private var diagnosticsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        menu = StatusMenuController(model: model) { [weak self] tab in self?.showSettings(tab: tab) }
        #if DEBUG
        if DebugSnapshot.runIfRequested(model: model, menu: menu) { return }
        if let i = CommandLine.arguments.firstIndex(of: "--show-settings") {
            // Opens the real settings window on a tab and prints its window number, for screenshots.
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? "general"
            showSettings(tab: SettingsTab.allCases.first { $0.title.lowercased() == name } ?? .general)
            Task {
                try? await Task.sleep(for: .seconds(1))
                print("WINDOW \(self.settingsWindow?.windowNumber ?? 0)")
                fflush(stdout)
                try? await Task.sleep(for: .seconds(12))
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--scenario-test") {
            ScenarioTest.run(model: model, menu: menu) { ok in exit(ok ? 0 : 1) }
            return
        }
        if CommandLine.arguments.contains("--ui-test") {
            NSApp.activate()
            showSettings()
            if let settings {
                SettingsUITest.run(model: model, settings: settings) { ok in exit(ok ? 0 : 1) }
            }
            return
        }
        #endif
        model.openDiagnostics = { [weak self] in self?.showDiagnostics() }
        model.engine.start()
        model.startUsageUpdates()
        hotKey = GlobalHotKey { [weak self] in self?.menu.open() }
        model.shortcutRegistrationFailed = !hotKey.register(model.shortcut)
        model.onShortcutChange = { [weak self] shortcut in
            guard let self else { return }
            self.model.shortcutRegistrationFailed = !self.hotKey.register(shortcut)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.engine.stop()
    }

    func showDiagnostics() {
        guard !model.isCreatingReport else { return }
        model.isCreatingReport = true
        Task {
            defer { model.isCreatingReport = false }
            let report = await DiagnosticReport.make(model: model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticsView(report: report)))
            window.title = "Diagnostic Report"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            diagnosticsWindow = window
            bringToFront(window)
        }
    }

    func showSettings(tab: SettingsTab? = nil) {
        if settings == nil { settings = SettingsWindow(model: model) }
        if let tab { settings?.selected = tab }
        bringToFront(settingsWindow)
    }

    /// A menu-bar app isn't frontmost, and macOS may ignore a polite activation request, which would
    /// leave typing going to the previous app. Ask firmly, then make the window key.
    func bringToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
