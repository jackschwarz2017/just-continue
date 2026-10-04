import AppKit
import SwiftUI

/// A text-field-looking shortcut recorder: click it, press the keys.
/// Esc cancels, Delete clears, and the ✕ button clears too.
struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: GlobalHotKey.Shortcut?
    /// Lets the app pause the global shortcut while recording, so pressing it records instead of firing.
    var onRecording: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onChange = { shortcut = $0 }
        field.onRecording = onRecording
        field.shortcut = shortcut
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.onChange = { shortcut = $0 }
        field.onRecording = onRecording
        if field.shortcut != shortcut { field.shortcut = shortcut }
    }
}

final class ShortcutRecorderField: NSTextField {
    var onChange: (GlobalHotKey.Shortcut?) -> Void = { _ in }
    var onRecording: (Bool) -> Void = { _ in }
    var shortcut: GlobalHotKey.Shortcut? { didSet { refresh() } }

    private(set) var isRecording = false { didSet { refresh(); onRecording(isRecording) } }
    private let clearButton = ShortcutClearButton()

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        focusRingType = .default
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setAccessibilityRole(.textField)
        setAccessibilityHelp("Click, then press a keyboard shortcut")

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: super.intrinsicContentSize.height) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { isRecording = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    /// Shortcuts with ⌘ arrive here before keyDown; capture them while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:  // Esc
            window?.makeFirstResponder(nil)
        case 51, 117:  // Delete
            set(nil)
        default:
            if let new = GlobalHotKey.Shortcut(event: event) { set(new) } else { NSSound.beep() }
        }
    }

    private func set(_ new: GlobalHotKey.Shortcut?) {
        shortcut = new
        onChange(new)
        window?.makeFirstResponder(nil)
    }

    @objc private func clear() { set(nil) }

    /// While recording, the current shortcut stays visible (dimmed) so it never looks cleared.
    private func refresh() {
        stringValue = isRecording ? "" : (shortcut?.display ?? "")
        placeholderString = isRecording ? (shortcut?.display ?? "Press shortcut…") : "Click to record"
        clearButton.isHidden = isRecording || shortcut == nil
    }

    /// Leaving without pressing keys keeps the old shortcut, including when the tab changes,
    /// the window closes or loses focus. (Recording pauses the global shortcut, so it must end.)
    private func endRecording() {
        guard isRecording else { return }
        if window?.firstResponder === self || window?.firstResponder === currentEditor() {
            window?.makeFirstResponder(nil)
        }
        isRecording = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowEnded), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowEnded() { endRecording() }
}

/// The shortcut recorder uses an AppKit button, so it needs its own tracking area.
private final class ShortcutClearButton: NSButton {
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { contentTintColor = .controlAccentColor }
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .tertiaryLabelColor
    }
}
