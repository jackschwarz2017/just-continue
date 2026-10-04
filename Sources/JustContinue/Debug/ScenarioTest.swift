#if DEBUG
import AppKit
import JustContinueCore

/// `JustContinue --scenario-test`: runs every Debug-menu case through the real engine, menu and
/// banner and checks the results. Simulated sessions are never typed into.
/// Restores everything it changed. Debug builds only.
@MainActor
enum ScenarioTest {
    static func run(model: AppModel, menu: StatusMenuController, done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let debug = model.debug
            let engine = model.engine
            let banner = model.notifications.banner
            let saved = (model.resetDelaySeconds, model.lidNoticeDismissed, model.dryRun, model.keepDisplayOn, model.hasToggledSession, model.hasPressedOption)
            var failures = 0, count = 0
            @MainActor func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                count += 1
                if !ok { failures += 1 }
                print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  — \(detail())")")
            }
            @MainActor func tick() async { await engine.tick() }
            @MainActor func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func row(_ name: String) -> SessionRow? { engine.rows.first { $0.session.name.hasPrefix(name) } }
            @MainActor func items() -> [NSMenuItem] { menu.builtMenu.items }
            @MainActor func item(_ title: String) -> NSMenuItem? { items().first { $0.title == title && !$0.isAlternate } }
            @MainActor func reset() async {
                debug.removeSimulatedSessions()
                debug.claudeInstalled = nil; debug.codexInstalled = nil
                debug.hideUsage = false; debug.notificationsOff = false; debug.activity = nil
                debug.terminalAccessDenied = false
                model.dryRun = false
                model.notifications.prefersSystem = { model.alertStyle == .system }
                banner.hide()
                for r in engine.rows where r.enabled { engine.setEnabled(r.id, false) }
                await tick()
            }

            debug.hideRealSessions.value = true  // never touch real sessions
            model.resetDelaySeconds = 0
            await reset()
            check("0 only simulated sessions in the test", engine.rows.allSatisfy { $0.id.pid < 0 }, "\(engine.rows.count) rows")
            check("0 menu-bar icon is the app glyph", menu.statusIconIsAppGlyph)

            // 1. Limit resets while away: types (simulated), verifies, reports.
            debug.activity = .away
            debug.addLimit(in: 3)
            await tick()
            guard let s1 = row("Simulated · limit") else { check("1 simulated session appears", false, "no row"); return done(false) }
            check("1 shows limit with reset time", s1.subtitle.contains("Limit reached · resets"), s1.subtitle)
            model.hasToggledSession = false
            _ = items()
            check("1 first-time hint shown", menu.builtMenu.items.contains { ($0.view as? MenuNoticeView) != nil && $0.view?.accessibilityLabel()?.hasPrefix("Click a session") == true })
            guard let s1Row = menu.rowView(s1.session.name) else { check("1 session row", false, "missing"); return done(false) }
            check("1 icon has no dot while nothing is on", !menu.iconHasBadge)
            // Clicking the row toggles it in place: the row updates without rebuilding the menu.
            _ = s1Row.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(100))
            check("1 icon shows the dot once a session is on", menu.iconHasBadge)
            check("1 click toggles in place", row("Simulated · limit")?.enabled == true && s1Row.content.checked, "enabled=\(String(describing: row("Simulated · limit")?.enabled)), checked=\(s1Row.content.checked)")
            check("1 hint goes away after first click", model.hasToggledSession && !menu.builtMenu.items.contains { $0.view?.accessibilityLabel()?.hasPrefix("Click a session") == true })
            check("1 waiting, Mac kept awake", row("Simulated · limit")?.subtitle.contains("Continues") == true && engine.isKeepingAwake, row("Simulated · limit")?.subtitle ?? "-")
            await settle(3.5); await tick(); await settle(0.5); await tick()
            check("1 continued after reset", { if case .resumed = row("Simulated · limit")?.outcome { return true }; return false }(), "\(String(describing: row("Simulated · limit")?.outcome))")
            check("1 banner says Continued", banner.currentTitle?.hasPrefix("Continued") == true, banner.currentTitle ?? "none")
            await reset()
            try? await Task.sleep(for: .milliseconds(100))
            check("1 dot goes away when nothing is on", !menu.iconHasBadge)

            // 2. User is active: asks with a banner instead of typing; Continue Now works.
            debug.activity = .active
            debug.addLimit(in: 2)
            await tick()
            if let s2 = row("Simulated · limit") {
                engine.setEnabled(s2.id, true)
                await settle(2.5); await tick()
                check("2 doesn't type while active", row("Simulated · limit")?.pending?.phase == .askedUser, "\(String(describing: row("Simulated · limit")?.pending?.phase))")
                check("2 ready banner with Continue Now", banner.currentTitle == "Codex is ready to continue" && banner.currentHasAction, banner.currentTitle ?? "none")
                check("2 menu offers Continue at the top", items().contains { $0.title.hasPrefix("Continue Simulated") })
                engine.continueNow(s2.id)
                await settle(0.5); await tick()
                check("2 Continue Now continues", { if case .resumed = row("Simulated · limit")?.outcome { return true }; return false }())
            }
            await reset()

            // 3. Weekly limit shows its day.
            debug.add(.weeklyLimit); await tick()
            check("3 weekly limit wording", row("Simulated · weekly")?.subtitle.contains("Weekly limit · resets") == true, row("Simulated · weekly")?.subtitle ?? "-")
            await reset()

            // 4./5. Unsupported terminal and ambiguous Ghostty can't be enabled; click explains.
            debug.add(.unsupported); debug.add(.ambiguousGhostty); await tick()
            if let u = row("Simulated · in Warp"), let g = row("Simulated · two Ghostty") {
                check("4 unsupported: can't enable, says why", !u.canEnable && u.subtitle.contains("Not supported"), u.subtitle)
                _ = items()
            check("4 row looks unavailable", menu.rowView(u.session.name)?.content.enabled == false)
                check("5 ambiguous Ghostty says so", !g.canEnable && g.subtitle.contains("Can't tell which tab"), g.subtitle)
            }
            await reset()

            // 6.–8. Agents not installed / no usage data hide the usage sections.
            let headers = { @MainActor in items().filter(\.isSectionHeader).map(\.title) }
            debug.claudeInstalled = false
            check("6 Claude not installed: no Claude section", !headers().contains("Claude Code"), "\(headers())")
            debug.claudeInstalled = nil; debug.codexInstalled = false
            check("7 Codex not installed: no Codex section", !headers().contains("Codex"), "\(headers())")
            debug.codexInstalled = nil; debug.hideUsage = true
            check("8 no usage data: no usage sections", !headers().contains("Codex") && !headers().contains("Claude Code"), "\(headers())")
            await reset()

            // 9. System notifications chosen but off: falls back to the banner.
            model.notifications.prefersSystem = { true }
            debug.notificationsOff = true
            debug.add(.weeklyLimit); await tick()
            if let w = row("Simulated · weekly") { model.notifications.notifyFailed(w.session, reason: "Test") }
            check("9 notifications off: banner used", banner.isVisible && banner.currentTitle?.hasPrefix("Couldn't continue") == true, banner.currentTitle ?? "none")
            await reset()

            // 10. Dry run never types.
            model.dryRun = true
            debug.activity = .away
            debug.addLimit(in: 1); await tick()
            if let d = row("Simulated · limit") {
                engine.setEnabled(d.id, true)
                await settle(1.5); await tick(); await settle(0.3)
                let r = row("Simulated · limit")
                check("10 dry run: outcome, nothing typed", { if case .dryRun = r?.outcome { return true }; return false }() && r?.session.logState.limit != nil, "\(String(describing: r?.outcome))")
            }
            await reset()

            // 11. First launch again: lid notice first, then both hints.
            model.lidNoticeDismissed = false
            model.hasToggledSession = false
            model.hasPressedOption = false
            debug.addLimit(in: 3600); await tick()
            let labels = items().compactMap { $0.view?.accessibilityLabel() }
            check("11 lid notice is the first item", !Lid.hasLid || items().first?.view is MenuNoticeView)
            check("11 both hints shown", labels.contains { $0.hasPrefix("Click a session") } && labels.contains { $0.hasPrefix("Hold ⌥") }, "\(labels)")
            await reset()

            // 12. Test banner.
            banner.show(title: "Test", body: "Banner", action: .init(title: "Continue Now") {})
            check("12 test banner visible", banner.isVisible)
            banner.hide()

            // 13. Continue All Sessions: only offered with more than one session that can be turned on.
            await reset()
            debug.addLimit(in: 3600); debug.add(.unsupported); await tick()
            _ = items()
            check("13 no Continue All with a single session", menu.rowView("Continue All Sessions") == nil)
            debug.addLimit(in: 3600); await tick()
            engine.setAllEnabled(true)
            let simulated = engine.rows.filter { $0.id.pid < 0 }
            check("13 Continue All turns on typable sessions only", simulated.filter(\.canEnable).allSatisfy(\.enabled) && !simulated.filter { !$0.canEnable }.contains(where: \.enabled))
            _ = items()
            check("13 menu row is checked", menu.rowView("Continue All Sessions")?.content.checked == true)
            engine.setAllEnabled(false)
            check("13 Continue All turns them off again", !engine.rows.contains(where: \.enabled))

            // 14. Diagnostic report replaces names.
            let report = await DiagnosticReport.make(model: model)
            check("14 report hides session names", !report.contains("Simulated · limit") && report.contains("session-"), "")
            await reset()

            // 15. Keep Mac Awake manually, Keep Screen On.
            _ = items()
            if let awake = menu.rowView("Keep Mac Awake") {
                _ = awake.accessibilityPerformPress()
                check("15 Keep Mac Awake toggles in place", engine.isKeepingAwake && awake.content.checked)
            }
            if let screen = menu.rowView("Keep Screen On") {
                let before = model.keepDisplayOn
                _ = screen.accessibilityPerformPress()
                check("15 Keep Screen On toggles in place", model.keepDisplayOn != before && screen.content.checked == model.keepDisplayOn)
                _ = screen.accessibilityPerformPress()
            }
            model.keepAwakeManually = false
            check("15 off again", !engine.isKeepingAwake || engine.rows.contains(where: \.enabled))

            await reset()
            model.recordTerminalAccess(.denied, for: TerminalBundle.terminal)
            check("16 denied terminal access shows reminder", items().contains {
                $0.view?.accessibilityLabel()?.hasPrefix("Allow terminal access to continue") == true
            })
            model.recordTerminalAccess(.granted, for: TerminalBundle.terminal)
            check("16 granted access removes reminder", !items().contains {
                $0.view?.accessibilityLabel()?.hasPrefix("Allow terminal access to continue") == true
            })
            let oldUsage = AgentUsage(fiveHour: .init(kind: .fiveHour, usedPercent: 80,
                resetsAt: Date().addingTimeInterval(-60)), weekly: .init(kind: .weekly, usedPercent: 35,
                resetsAt: Date().addingTimeInterval(86400)), updatedAt: Date().addingTimeInterval(-172800))
            let savedUsage = model.showUsage, savedClaude = model.showClaudeUsage, savedCodex = model.showCodexUsage
            model.showUsage = true; model.showClaudeUsage = true; model.showCodexUsage = true
            debug.demoUsage = (claude: oldUsage, codex: oldUsage)
            let usageLabels = items().compactMap { $0.view?.accessibilityLabel() }
            check("17 expired usage is unavailable", usageLabels.contains { $0.contains("5-hour · Usage unavailable") })
            check("17 old usage is labelled last seen", usageLabels.contains { $0.contains("Weekly · Last seen 35% used") })
            debug.demoUsage = nil
            model.showUsage = savedUsage; model.showClaudeUsage = savedClaude; model.showCodexUsage = savedCodex

            await reset()
            debug.terminalAccessDenied = true
            await tick()
            check("18 denied-access simulation isolates discovery", engine.rows.count == 1 && engine.rows.first?.id.pid == -9999)
            check("18 denied-access simulation shows reminder", items().contains {
                $0.view?.accessibilityLabel()?.hasPrefix("Allow terminal access to continue") == true
            })
            check("18 denied-access session cannot be enabled", engine.rows.first?.canEnable == false)
            let blockedInput = DebugInput(real: TerminalInputSender(), denied: debug.deniedOverride, simulated: debug.simulated)
            let blockedResult = blockedInput.send("continue", to: .init(kind: .iTerm, identifier: "simulated:blocked", title: "Test"))
            check("18 denied-access simulation blocks input", { if case .failure = blockedResult { return true }; return false }())
            debug.terminalAccessDenied = false
            await tick()
            check("18 disabling simulation removes its session", !engine.rows.contains { $0.id.pid == -9999 })

            // Restore.
            model.resetDelaySeconds = saved.0
            model.lidNoticeDismissed = saved.1
            model.dryRun = saved.2
            model.keepDisplayOn = saved.3
            model.hasToggledSession = saved.4
            model.hasPressedOption = saved.5
            print(failures == 0 ? "ALL PASSED (\(count))" : "FAILURES: \(failures) of \(count)")
            done(failures == 0)
        }
    }
}
#endif
