#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `JustContinue --render <dir> [--enable-limited]` writes the menu as text
/// (menu.txt) and the settings window as PNGs, with live data and always in dry-run mode.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel, menu: StatusMenuController) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model.engine.settings.dryRun = true  // never type from a render run
            if args.contains("--deny-terminal-access") {
                model.debug.terminalAccessDenied = true
            }
            model.startUsageUpdates()
            if args.contains("--simulate") {
                // Simulated sessions only, for screenshots.
                model.debug.hideRealSessions.value = true
                model.debug.addLimit(in: 3600)
                model.debug.add(.weeklyLimit)
                model.debug.add(.unsupported)
            }
            if args.contains("--demo") {
                // Made-up sessions with realistic names, for README screenshots.
                model.debug.hideRealSessions.value = true
                model.debug.addDemoSessions()
            }
            await model.engine.refresh()
            if args.contains("--demo"), let first = model.engine.rows.first(where: { $0.session.logState.limit != nil }) {
                model.engine.setEnabled(first.id, true)
                model.hasToggledSession = true
                model.hasPressedOption = true
            }
            if args.contains("--simulate"), let first = model.engine.rows.first(where: { $0.session.logState.limit != nil }) {
                model.engine.setEnabled(first.id, true)
            }
            try? await Task.sleep(for: .seconds(1))
            if args.contains("--enable-limited") {
                for row in model.engine.rows where row.session.logState.limit != nil {
                    model.engine.setEnabled(row.id, true)
                }
            }
            menu.forceDebugMenu = args.contains("--with-debug-menu")
            if args.contains("--show-banner") {
                model.notifications.banner.show(title: "Codex is ready to continue", body: "Migrate billing to Stripe",
                                                action: .init(title: "Continue Now") {})
                if let screen = NSScreen.main {
                    print("SCREEN \(Int(screen.frame.width))")
                    fflush(stdout)
                }
                try? await Task.sleep(for: .seconds(4))
                exit(0)
            }
            if args.contains("--open-menu") {
                let seconds = args.firstIndex(of: "--menu-seconds").flatMap { Double(args[$0 + 1]) } ?? 4
                menu.openForScreenshot(closeAfter: seconds)  // blocks until the menu closes
                exit(0)
            }
            for (name, badge) in [("icon-plain", false), ("icon-badge", true)] {
                if let image = AppGlyph.menuBarImage(badge: badge) {
                    let big = NSImage(size: NSSize(width: image.size.width * 8, height: image.size.height * 8), flipped: false) { r in
                        NSColor.white.setFill(); r.fill()
                        image.draw(in: r)
                        return true
                    }
                    if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                    }
                }
            }
            try? menu.dumpFrames().write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
            try? menu.dump().write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for tab in SettingsTab.allCases {
                    render(tab.view.environment(model), appearance: appearance, to: dir.appendingPathComponent("settings-\(tab.title.lowercased())-\(name).png"))
                }
            }
            exit(0)
        }
        return true
    }

    static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
