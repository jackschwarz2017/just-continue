import AppKit
import JustContinueCore
import Observation

/// The menu-bar item, a native NSMenu. From top to bottom:
/// lid notice (until dismissed) · plan usage · "Continue <session>" for sessions whose reset passed ·
/// sessions grouped by terminal · Continue All Sessions (2+ sessions) · Keep Mac Awake / Keep Screen On ·
/// one-time hints · Settings… · Quit.
///
/// Session and toggle rows are views, so clicking them doesn't close the menu. Holding ⌥ gives
/// session rows a submenu with more actions. No icons; information is never shown as disabled
/// (greyed-out) items, which are hard to read.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: (SettingsTab?) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Re-apply state to the in-place rows after a toggle, without rebuilding.
    private var rowRefreshers: [() -> Void] = []
    /// Session rows, for swapping with their ⌥ versions while the menu is open.
    private var sessionRows: [(key: SessionKey, item: NSMenuItem, view: MenuRowView)] = []
    private var optionShown = false
    private var modifierTimer: Timer?
    private weak var clickHint: NSMenuItem?
    private weak var optionHint: NSMenuItem?
    private weak var hintSeparator: NSMenuItem?

    /// Fixed section order; unsupported apps follow alphabetically.
    static let sectionOrder = [TerminalKind.iTerm, .terminalApp, .ghostty, .tmux].map(\.displayName)

    #if DEBUG || DEBUG_MENU
    /// For `--render --with-debug-menu`.
    var forceDebugMenu = false
    #endif

    init(model: AppModel, openSettings: @escaping (SettingsTab?) -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "Just Continue"
        observeIcon()
    }

    // MARK: Icon

    private func observeIcon() {
        withObservationTracking {
            updateIcon(armed: model.engine.showsMenuBarDot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    /// The app's Lucide glyph, with a dot while any session is set to continue or the Mac is kept awake.
    private func updateIcon(armed: Bool) {
        statusItem.button?.image = AppGlyph.menuBarImage(badge: armed)
        iconHasBadge = armed
    }

    /// For the scenario test.
    private(set) var iconHasBadge = false

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        if model.showUsage {
            model.refreshClaudeUsage()
            model.refreshCodexUsage()
        }
        model.refreshTerminalAccess()
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        startWatchingOption()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        modifierTimer?.invalidate()
        modifierTimer = nil
    }

    // MARK: Build

    func rebuild() {
        menu.removeAllItems()
        rowRefreshers = []
        sessionRows = []
        optionShown = false
        defer {
            reserveStateColumn(menu)
            pinRowWidths()
        }
        let rows = model.engine.rows

        if Lid.hasLid, !model.lidNoticeDismissed {
            // A view-based item: clicking it doesn't close the menu.
            let lid = NSMenuItem()
            let separator = NSMenuItem.separator()
            lid.view = MenuNoticeView(title: "Keep the lid open", subtitle: "Closing it puts your Mac to sleep · Click to hide") { [weak self] in
                self?.model.lidNoticeDismissed = true
                self?.menu.removeItem(lid)
                self?.menu.removeItem(separator)
            }
            menu.addItem(lid)
            menu.addItem(separator)
        }

        if !model.terminalsNeedingAccess.isEmpty {
            let notice = NSMenuItem()
            let names = model.terminalsNeedingAccess.map(\.name).joined(separator: ", ")
            notice.view = MenuNoticeView(title: "Allow terminal access to continue", subtitle: "\(names) · Open Settings") { [weak self] in
                self?.menu.cancelTracking()
                DispatchQueue.main.async { self?.openSettings(.terminals) }
            }
            menu.addItem(notice)
            menu.addItem(.separator())
        }

        if model.showUsage { addUsage() }

        let ready = rows.filter(\.isReadyToContinue)
        if !ready.isEmpty {
            separatorIfNeeded()
            for row in ready {
                let item = action("Continue \(Format.short(row.session.name, max: 34))", #selector(continueNow(_:)), key: row.id)
                menu.addItem(item)
            }
        }

        separatorIfNeeded()
        if rows.isEmpty {
            let names = AgentKind.allCases.filter(model.isInstalled).map(\.displayName)
            let agents = names.isEmpty ? "Claude Code or Codex" : names.joined(separator: " or ")
            menu.addItem(.sectionHeader(title: model.engine.lastScan == nil ? "Looking for sessions…" : "No \(agents) sessions running"))
        }
        let groups = Dictionary(grouping: rows, by: \.sectionTitle)
        let titles = groups.keys.sorted { a, b in
            let ia = Self.sectionOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.sectionOrder.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
        for (n, title) in titles.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            let sorted = groups[title]!.sorted { $0.session.name.localizedCaseInsensitiveCompare($1.session.name) == .orderedAscending }
            for row in sorted { sessionItems(row).forEach(menu.addItem) }
        }

        // Only worth offering when there's more than one session to turn on.
        if rows.filter(\.canEnable).count > 1 {
            menu.addItem(.separator())
            menu.addItem(toggleRow({ [unowned self] in
                .init(title: "Continue All Sessions", subtitle: nil, checked: self.model.engine.allEnabled)
            }, twoLines: false, { [unowned self] in
                self.model.engine.setAllEnabled(!self.model.engine.allEnabled)
                if !self.model.hasToggledSession {
                    self.model.hasToggledSession = true
                    self.removeHint(self.clickHint)
                }
            }))
        }

        menu.addItem(.separator())
        menu.addItem(toggleRow({ [unowned self] in
            .init(title: "Keep Mac Awake", subtitle: nil, checked: self.model.engine.isKeepingAwake)
        }, twoLines: false, { [unowned self] in self.toggleKeepAwake() }))
        menu.addItem(toggleRow({ [unowned self] in
            .init(title: "Keep Screen On", subtitle: nil, checked: self.model.keepDisplayOn)
        }, twoLines: false, { [unowned self] in self.model.keepDisplayOn.toggle() }))

        addHints(hasSessions: !rows.isEmpty)

        #if DEBUG || DEBUG_MENU
        if NSEvent.modifierFlags.contains(.option) || forceDebugMenu {
            menu.addItem(.separator())
            menu.addItem(DebugMenu.item(model: model))
        }
        #endif

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // A custom selector, so macOS doesn't add its automatic Quit icon.
        let quit = NSMenuItem(title: "Quit Just Continue", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Every view row gets the same fixed width for as long as the menu is open.
    private func pinRowWidths() {
        let rows = menu.items.compactMap { $0.view as? FixedWidthMenuRow }
        let width = max(300, rows.map(\.idealWidth).max() ?? 0).rounded(.up)
        rows.forEach { $0.pin(width: width) }
    }

    /// Without this, ticking the first item adds a checkmark column and every row shifts right.
    /// An empty "off" image keeps that column in place permanently.
    private func reserveStateColumn(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader && item.view == nil {
            item.offStateImage = Self.blankStateImage
            if let sub = item.submenu { reserveStateColumn(sub) }
        }
    }

    /// Transparent, the size of the system checkmark.
    static let blankStateImage: NSImage = {
        let size = NSImage(named: NSImage.menuOnStateTemplateName)?.size ?? NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        return image
    }()

    private func separatorIfNeeded() {
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
    }

    // MARK: Usage

    private func addUsage() {
        // Agents that aren't installed are never shown.
        if !model.showClaudeUsage {
            // Hidden by the user.
        } else if let usage = model.visibleClaudeUsage {
            addUsage(title: "Claude Code", usage: usage)
            if model.debug.demoUsage == nil, model.claudeUsageConnectionLost { addClaudeReconnectItem() }
        } else if model.isInstalled(.claude), !model.debug.hideUsage {
            menu.addItem(.sectionHeader(title: "Claude Code"))
            let setUp = ClaudeStatusLineSetup.isSetUp()
            if !setUp && model.claudeUsageConnectionWanted {
                addClaudeReconnectItem()
            } else {
                let item = NSMenuItem(title: setUp ? "Usage appears after your next message" : "Show Usage…",
                                      action: #selector(showUsageSettings), keyEquivalent: "")
                item.target = self
                setSubtitle(item, setUp ? "Claude Code updates it as you work" : "Connect in Settings")
                menu.addItem(item)
            }
        }
        if model.showCodexUsage {
            if let usage = model.visibleCodexUsage {
                addUsage(title: "Codex", usage: usage)
            } else if model.isInstalled(.codex), !model.debug.hideUsage {
                menu.addItem(.sectionHeader(title: "Codex"))
                let item = NSMenuItem(title: "Usage unavailable", action: #selector(showUsageSettings), keyEquivalent: "")
                item.target = self
                setSubtitle(item, model.codexUsageMessage)
                menu.addItem(item)
            }
        }
    }

    /// Shown when the user connected Claude Code before but its status line was replaced since.
    private func addClaudeReconnectItem() {
        let item = NSMenuItem(title: "Usage Disconnected…", action: #selector(showUsageSettings), keyEquivalent: "")
        item.target = self
        setSubtitle(item, "Status line changed · Reconnect in Settings")
        menu.addItem(item)
    }

    /// Usage rows are text only: readable, not clickable.
    private func addUsage(title agentTitle: String, usage: AgentUsage) {
        menu.addItem(.sectionHeader(title: agentTitle))
        let now = Date()
        for window in [usage.fiveHour, usage.weekly].compactMap({ $0 }) {
            let percent = window.percent(at: now).map { Int($0.rounded()) }
            let name = window.kind == .fiveHour ? "5-hour" : "Weekly"
            let age = usage.updatedAt.map { now.timeIntervalSince($0) } ?? .infinity
            let stale = age > 5 * 60
            let title: String
            var subtitle: String
            if let percent {
                title = "\(name) · \(stale ? "Last seen " : "")\(percent)% used"
                subtitle = window.resetsAt.map { "Resets \(Format.time($0))" } ?? "Reset time unknown"
                if stale { subtitle = usage.updatedAt.map { "Updated \(Format.time($0))" } ?? "Update time unknown" }
            } else {
                title = "\(name) · Usage unavailable"
                subtitle = usage.source == .liveAccount ? "Waiting for an account update" : "Use \(agentTitle) on this Mac to refresh"
            }
            let item = NSMenuItem()
            item.view = MenuNoticeView(title: title, subtitle: subtitle)
            menu.addItem(item)
        }
    }

    // MARK: Sessions

    /// One click toggles the session and the menu stays open. Holding ⌥ swaps the rows for items
    /// with a submenu of the other actions, so a row never both toggles and opens a submenu.
    private func sessionItems(_ row: SessionRow) -> [NSMenuItem] {
        let key = row.id
        let item = NSMenuItem()
        let view = MenuRowView(content: sessionContent(row), onClick: { [weak self] in
            self?.clickSession(key)
        })
        item.view = view
        sessionRows.append((key, item, view))
        rowRefreshers.append { [weak self, weak view] in
            guard let self, let view, let current = self.model.engine.rows.first(where: { $0.id == key }) else { return }
            view.apply(self.sessionContent(current))
        }
        return [item]
    }

    private func sessionContent(_ row: SessionRow) -> MenuRowView.Content {
        let needsAccess = model.terminalNeedingAccess(for: row) != nil
        return .init(title: Format.short(row.session.name),
                     subtitle: needsAccess ? "Allow terminal access to continue" : row.subtitle,
                     checked: row.enabled, enabled: row.canEnable && !needsAccess)
    }

    private func clickSession(_ key: SessionKey) {
        guard let row = model.engine.rows.first(where: { $0.id == key }) else { return }
        if model.terminalNeedingAccess(for: row) != nil {
            menu.cancelTracking()
            DispatchQueue.main.async { self.openSettings(.terminals) }
            return
        }
        guard row.canEnable else {
            // Explaining needs an alert; close the menu first.
            menu.cancelTracking()
            DispatchQueue.main.async { self.explain(row) }
            return
        }
        model.engine.setEnabled(key, !row.enabled)
        if !model.hasToggledSession {
            model.hasToggledSession = true
            removeHint(clickHint)
        }
        refreshRows()
    }

    private func refreshRows() { rowRefreshers.forEach { $0() } }

    /// One-time hints at the bottom, just above Settings…; removing rows there doesn't move any
    /// row above them, so they can disappear immediately without shifting what's under the pointer.
    private func addHints(hasSessions: Bool) {
        guard hasSessions, !model.hasToggledSession || !model.hasPressedOption else { return }
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        hintSeparator = separator
        if !model.hasToggledSession {
            let hint = NSMenuItem()
            hint.view = MenuNoticeView(title: "Click a session to continue it automatically",
                                       subtitle: "It types “\(model.engine.settings.continuationText)” when the limit resets")
            menu.addItem(hint)
            clickHint = hint
        }
        if !model.hasPressedOption {
            let hint = NSMenuItem()
            hint.view = MenuNoticeView(title: "Hold ⌥ for more options", subtitle: "Continue now, show in terminal, reveal in Finder")
            menu.addItem(hint)
            optionHint = hint
        }
    }

    private func removeHint(_ hint: NSMenuItem?) {
        guard let hint, let i = menu.items.firstIndex(of: hint) else { return }
        menu.removeItem(at: i)
        if clickHint == nil && optionHint == nil, let separator = hintSeparator, let j = menu.items.firstIndex(of: separator) {
            menu.removeItem(at: j)
        }
    }

    // MARK: ⌥ for more options

    /// Watches ⌥ while the menu is open (menus run their own event loop, so poll the modifier state).
    private func startWatchingOption() {
        modifierTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOptionMode() }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    private func updateOptionMode() {
        let held = NSEvent.modifierFlags.contains(.option)
        guard held != optionShown else { return }
        optionShown = held
        if held, !model.hasPressedOption {
            model.hasPressedOption = true
            removeHint(optionHint)
        }
        // Same rows, different content: no items are swapped, so nothing moves.
        for entry in sessionRows {
            let row = model.engine.rows.first { $0.id == entry.key }
            entry.item.submenu = held ? row.map(moreSubmenu) : nil
            entry.view.optionMode = held
        }
        // macOS only opens a submenu when the pointer enters a row. If it's already on one, post a
        // "moved" event at the same spot so the menu re-checks and opens it right away.
        if held, let window = sessionRows.first(where: { $0.view.isHovered })?.view.window,
           let nudge = NSEvent.mouseEvent(with: .mouseMoved, location: window.mouseLocationOutsideOfEventStream,
                                          modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 0, pressure: 0) {
            NSApp.postEvent(nudge, atStart: false)
        }
    }


    /// Only actions. Unavailable ones are left out.
    private func moreSubmenu(_ row: SessionRow) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        if row.isReadyToContinue {
            sub.addItem(action("Continue Now", #selector(continueNow(_:)), key: row.id))
        }
        switch row.session.resumability {
        case .ready(let location):
            if location.kind != .tmux {
                sub.addItem(action("Show in \(location.kind.displayName)", #selector(show(_:)), key: row.id))
            }
        case .unsupported(let host?):
            sub.addItem(action("Show in \(host)", #selector(showHostApp(_:)), key: row.id))
            sub.addItem(action("How to Enable…", #selector(explainUnsupported(_:)), key: row.id))
        case .unsupported, .ambiguous:
            sub.addItem(action("How to Enable…", #selector(explainUnsupported(_:)), key: row.id))
        }
        if row.session.cwd != nil {
            sub.addItem(action("Reveal in Finder", #selector(revealInFinder(_:)), key: row.id))
        }
        return sub
    }

    // MARK: Keep awake

    /// An in-place toggle row whose content is recomputed after every click.
    private func toggleRow(_ content: @escaping () -> MenuRowView.Content, twoLines: Bool = true, _ toggle: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let view = MenuRowView(content: content(), twoLines: twoLines, onClick: { [weak self] in
            toggle()
            self?.refreshRows()
        })
        item.view = view
        rowRefreshers.append { [weak view] in view?.apply(content()) }
        return item
    }

    // MARK: Item helpers

    private func action(_ title: String, _ selector: Selector, key: SessionKey) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = KeyBox(key)
        return item
    }

    private func setSubtitle(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) {
            item.subtitle = text
        } else {
            item.title += " — \(text)"
        }
    }

    // MARK: Actions

    private func row(_ sender: NSMenuItem) -> SessionRow? {
        guard let key = (sender.representedObject as? KeyBox)?.key else { return nil }
        return model.engine.rows.first { $0.id == key }
    }

    @objc private func continueNow(_ sender: NSMenuItem) {
        guard let row = row(sender) else { return }
        model.engine.continueNow(row.id)
    }

    @objc private func show(_ sender: NSMenuItem) {
        guard let location = row(sender)?.session.resumability.location else { return }
        Task.detached { _ = TerminalInput.show(location) }
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let cwd = row(sender)?.session.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    @objc private func showHostApp(_ sender: NSMenuItem) {
        guard let row = row(sender), case .unsupported(let host?) = row.session.resumability else { return }
        NSWorkspace.shared.runningApplications.first { $0.localizedName == host }?.activate()
    }

    @objc private func explainUnsupported(_ sender: NSMenuItem) {
        guard let row = row(sender) else { return }
        explain(row)
    }

    private func explain(_ row: SessionRow) {
        if model.terminalNeedingAccess(for: row) != nil { openSettings(.terminals); return }
        let alert = NSAlert()
        switch row.session.resumability {
        case .ambiguous:
            alert.messageText = "Can't tell which tab this is"
            alert.informativeText = "Several Ghostty tabs are open in \(row.session.folderName ?? "this folder"). Close the extra tab, or run the agent in tmux."
        case .unsupported(let host):
            let name = host ?? "this terminal"
            alert.messageText = "Can't type into \(name)"
            alert.informativeText = "Run the agent inside tmux in \(name). It then appears under tmux and can continue automatically."
        case .ready:
            return
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func toggleKeepAwake() {
        if model.engine.rows.contains(where: \.enabled) {
            menu.cancelTracking()
            let alert = NSAlert()
            alert.messageText = "Stays on while sessions continue automatically"
            alert.informativeText = "Sessions can only continue while your Mac is awake. Turn off Continue Automatically for all sessions to let it sleep."
            alert.addButton(withTitle: "OK")
            DispatchQueue.main.async {
                NSApp.activate()
                alert.runModal()
            }
            return
        }
        if model.engine.isKeepingAwake {
            // The screen can't stay on while the Mac sleeps, so this turns Keep Screen On off too.
            model.keepAwakeManually = false
            model.keepDisplayOn = false
        } else {
            model.keepAwakeManually = true
        }
    }

    @objc private func showSettings() { openSettings(nil) }

    @objc private func showUsageSettings() { openSettings(.usage) }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Opens the menu from the keyboard shortcut. If the status item is hidden (e.g. behind the
    /// notch on a crowded menu bar), the menu opens at the mouse pointer instead.
    func open() {
        NSApp.activate()
        if let button = statusItem.button, let window = button.window,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            button.performClick(nil)
        } else {
            rebuild()
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    #if DEBUG
    /// Pops the real menu up at a fixed spot for a screenshot (`--open-menu`), closes it after `seconds`.
    /// (The status item itself may be hidden behind the notch on a crowded menu bar.)
    func openForScreenshot(closeAfter seconds: TimeInterval) {
        guard let screen = NSScreen.main else { return }
        // Capture the composited menu over a neutral backdrop. Capturing the translucent
        // menu window alone can turn its material into a flat grey surface.
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        backdrop.backgroundColor = .white
        backdrop.isReleasedWhenClosed = false
        backdrop.orderFrontRegardless()
        defer { backdrop.close() }
        NSApp.activate()
        menu.appearance = NSAppearance(named: .aqua)
        let point = NSPoint(x: screen.frame.minX + 100, y: screen.frame.maxY - 60)
        let captureTimer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let frame = self?.menu.items.compactMap({ $0.view?.window?.frame }).first,
                      let desktopTop = NSScreen.screens.first?.frame.maxY else { return }
                let padding: CGFloat = 16
                print("MENU_RECT \(Int(frame.minX - padding)),\(Int(desktopTop - frame.maxY - padding)),\(Int(frame.width + padding * 2)),\(Int(frame.height + padding * 2))")
                fflush(stdout)
            }
        }
        RunLoop.main.add(captureTimer, forMode: .common)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rebuild()
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// True if the menu-bar button shows the app's SVG glyph (not an SF Symbol), for the scenario test.
    var statusIconIsAppGlyph: Bool {
        guard let image = statusItem.button?.image else { return false }
        // A drawing that renders the SVG glyph (with or without the dot), not an SF Symbol.
        return image.accessibilityDescription?.hasPrefix("Just Continue") == true
    }

    /// In-place row with this title, for the debug scenario test.
    func rowView(_ title: String) -> MenuRowView? {
        menu.items.compactMap { $0.view as? MenuRowView }.first { $0.content.title == title }
    }

    /// The built menu, for the debug scenario test.
    var builtMenu: NSMenu {
        rebuild()
        return menu
    }

    /// Frames of view rows and their subviews, for layout debugging.
    func dumpFrames() -> String {
        rebuild()
        return menu.items.compactMap { item -> String? in
            guard let v = item.view else { return nil }
            v.layoutSubtreeIfNeeded()
            let subs = v.subviews.map { "\(type(of: $0)) \(Int($0.frame.minX))+\(Int($0.frame.width))\($0.isHidden ? " hidden" : "")" }.joined(separator: ", ")
            return "\(type(of: v)) w=\(Int(v.frame.width)) h=\(Int(v.frame.height)) [\(subs)]"
        }.joined(separator: "\n")
    }

    /// Text dump of the menu, including submenus, for `--render`.
    func dump() -> String {
        rebuild()
        func lines(_ menu: NSMenu, indent: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [indent + "──────────"] }
                if item.isSectionHeader { return [indent + "[\(item.title)]"] }
                var line = indent + "\(item.state == .on ? "✓" : " ") "
                if item.image != nil { line += "◦ " }
                line += item.title
                if !item.isEnabled { line += "   (DISABLED)" }
                if !item.keyEquivalent.isEmpty { line += "   ⌘\(item.keyEquivalent.uppercased())" }
                if item.submenu != nil { line += "   ▸" }
                var out = [line]
                if #available(macOS 14.4, *), let s = item.subtitle { out.append(indent + "      " + s) }
                if let sub = item.submenu { out += lines(sub, indent: indent + "        ") }
                return out
            }
        }
        return lines(menu, indent: "").joined(separator: "\n")
    }
    #endif
}

private final class KeyBox: NSObject {
    let key: SessionKey
    init(_ key: SessionKey) { self.key = key }
}
