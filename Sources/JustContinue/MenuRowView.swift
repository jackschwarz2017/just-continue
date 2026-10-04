import AppKit

/// Shared sizing for view-based menu rows, so every row in a menu has one fixed width.
protocol FixedWidthMenuRow: NSView {
    /// Width the row would like for its text.
    var idealWidth: CGFloat { get }
    /// Pins the row to `width`; text truncates instead of resizing the menu.
    func pin(width: CGFloat)
}

/// A menu row that looks native (checkmark, title, subtitle, hover highlight) but toggles in place
/// without closing the menu. With ⌥ held it shows a chevron and opens a submenu instead.
/// The row itself is never replaced while the menu is open, so nothing shifts.
final class MenuRowView: NSView, FixedWidthMenuRow {
    struct Content: Equatable {
        var title: String
        var subtitle: String?
        var checked: Bool
        var enabled = true
    }

    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let chevron = NSImageView()
    private var pinnedWidth: CGFloat?
    private var hovered = false { didSet { needsDisplay = true; updateColors() } }
    /// The pointer is over this row.
    var isHovered: Bool { hovered }

    private(set) var content: Content
    /// ⌥ is held: show "More options" and a chevron; clicks open the submenu instead of toggling.
    var optionMode = false { didSet { if optionMode != oldValue { render() } } }
    private let onClick: () -> Void

    /// Rows that never have a subtitle (e.g. Continue All Sessions) stay one line tall.
    private let twoLines: Bool

    init(content: Content, twoLines: Bool = true, onClick: @escaping () -> Void) {
        self.content = content
        self.twoLines = twoLines
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 40))

        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.lineBreakMode = .byTruncatingTail
        for field in [titleField, subtitleField] {
            field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            field.alignment = .left
        }
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false

        for view in [checkmark, titleField, chevron] + (twoLines ? [subtitleField] : []) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Same position as AppKit's checkmark (measured).
            checkmark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MenuNoticeView.textInset - 9.5),
            checkmark.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            // Both lines pinned edge to edge, left-aligned; they truncate if the row is too narrow.
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuNoticeView.textInset),
            titleField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            // Fixed size: otherwise the (often hidden) chevron stretches and squeezes the text.
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if twoLines {
            NSLayoutConstraint.activate([
                subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
                subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
                subtitleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        } else {
            titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4).isActive = true
        }
        render()
        // Height is set once from the layout; it never changes afterwards (two lines or one).
        setFrameSize(NSSize(width: frame.width, height: fittingSize.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Updates the row in place (the menu isn't rebuilt while open). Width never changes here.
    func apply(_ new: Content) {
        content = new
        render()
    }

    private func render() {
        titleField.stringValue = content.title
        // Always two lines, so the row's height is the same in every state.
        subtitleField.stringValue = optionMode ? "More options" : (content.subtitle ?? " ")
        checkmark.isHidden = !content.checked
        chevron.isHidden = !optionMode
        updateColors()
        setAccessibilityRole(optionMode ? .menuItem : .checkBox)
        setAccessibilityLabel(content.title)
        setAccessibilityValue(content.checked)
        setAccessibilityHelp(optionMode ? "More options" : content.subtitle)

    }

    var idealWidth: CGFloat {
        let title = (content.title as NSString).size(withAttributes: [.font: titleField.font!]).width
        let subtitle = ((content.subtitle ?? "") as NSString).size(withAttributes: [.font: subtitleField.font!]).width
        return MenuNoticeView.textInset + max(title, subtitle) + 40
    }

    /// The width comes from the frame only: a width constraint on the row itself conflicts with
    /// the frame NSMenu gives it, and AppKit then drops other constraints.
    func pin(width: CGFloat) {
        pinnedWidth = width
        setFrameSize(NSSize(width: width, height: frame.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if !optionMode { onClick() } }
    override func accessibilityPerformPress() -> Bool {
        guard !optionMode else { return false }
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: MenuNoticeView.highlightInset, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    private func updateColors() {
        let primary: NSColor = hovered ? .selectedMenuItemTextColor : (!content.enabled && !optionMode ? .secondaryLabelColor : .labelColor)
        titleField.textColor = primary
        subtitleField.textColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
        checkmark.contentTintColor = primary
        chevron.contentTintColor = hovered ? .selectedMenuItemTextColor : .labelColor
    }
}
