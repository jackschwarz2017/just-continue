import AppKit

/// A menu row with a title and subtitle that doesn't close the menu when clicked.
/// With `onClick` it highlights on hover (the lid notice); without, it's plain text (usage rows),
/// readable where a disabled item would be greyed out.
final class MenuNoticeView: NSView, FixedWidthMenuRow {
    private let titleField: NSTextField
    private let subtitleField: NSTextField
    private let onClick: (() -> Void)?
    private var pinnedWidth: CGFloat?
    private var hovered = false { didSet { needsDisplay = true; updateColors() } }

    /// Where AppKit draws item titles when the state (checkmark) column is reserved, as it always
    /// is in this menu (measured on macOS 26).
    static let textInset: CGFloat = 29.5
    static let highlightInset: CGFloat = 5

    init(title: String, subtitle: String, onClick: (() -> Void)? = nil) {
        titleField = NSTextField(labelWithString: title)
        subtitleField = NSTextField(labelWithString: subtitle)
        self.onClick = onClick
        super.init(frame: .zero)

        titleField.font = .menuFont(ofSize: 0)
        subtitleField.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        // Both lines pinned edge to edge, left-aligned; they truncate if the row is too narrow.
        for field in [titleField, subtitleField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            subtitleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        updateColors()
        // Menus size view items from their frame; let the width follow the menu.
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            field.alignment = .left
        }
        let size = fittingSize
        frame = NSRect(x: 0, y: 0, width: max(idealWidth, 240), height: size.height)
        setAccessibilityRole(onClick == nil ? .staticText : .menuItem)
        setAccessibilityLabel("\(title). \(subtitle)")
    }

    required init?(coder: NSCoder) { fatalError() }

    var idealWidth: CGFloat {
        let title = (titleField.stringValue as NSString).size(withAttributes: [.font: titleField.font!]).width
        let subtitle = (subtitleField.stringValue as NSString).size(withAttributes: [.font: subtitleField.font!]).width
        return Self.textInset + max(title, subtitle) + 24
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

    override func mouseEntered(with event: NSEvent) { if onClick != nil { hovered = true } }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.highlightInset, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    private func updateColors() {
        titleField.textColor = hovered ? .selectedMenuItemTextColor : .labelColor
        subtitleField.textColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
    }
}
