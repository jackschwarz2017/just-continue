import AppKit
import SwiftUI

/// Native settings window with toolbar tabs, like System Settings-era apps.
/// The window resizes to each tab's content.
@MainActor
final class SettingsWindow {
    private(set) var window: NSWindow!
    private let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            // Each tab reports its content height; the window follows it with its top edge fixed.
            // Pinned to the top: if the window is momentarily taller than the content, the content
            // stays at the top instead of being centred (which looked like a jump).
            let reported = tab.view.environment(model).background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }).onPreferenceChange(ContentHeightKey.self) { [weak self] height in
                MainActor.assumeIsolated { self?.contentHeightChanged(height, in: tab) }
            }
            let host = NSHostingController(rootView: AnyView(
                reported.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
            host.sizingOptions = .preferredContentSize
            host.title = tab.title  // the tab window shows the selected child's title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        updateTitle()
        window.center()
    }

    var selected: SettingsTab {
        get { SettingsTab(rawValue: tabs.selectedTabViewItemIndex) ?? .general }
        set {
            tabs.selectedTabViewItemIndex = newValue.rawValue
            updateTitle()
        }
    }

    private func updateTitle() { window.title = selected.title }

    /// Resizes the window to the selected tab's content, keeping the top edge where it is.
    private func contentHeightChanged(_ height: CGFloat, in tab: SettingsTab) {
        guard let window, tab == selected, height > 0 else { return }  // heights can arrive before the window exists
        let content = window.contentRect(forFrameRect: window.frame)
        let chrome = window.frame.height - content.height  // title bar and toolbar
        let newHeight = (height + chrome).rounded()
        guard abs(newHeight - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: false)
    }

    /// The selected tab's content view (for the debug UI test).
    var currentView: NSView? { tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
