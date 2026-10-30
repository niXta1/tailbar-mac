import AppKit

final class MenuConnectionHeader: NSView {
    private let onToggle: () -> Void
    private let titleLabel = NSTextField(labelWithString: "Tailbar")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    private var highlighted = false
    private var enabled: Bool
    init(state: String, connected: Bool, enabled: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        self.enabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 40))
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.frame = NSRect(x: 16, y: 21, width: 290, height: 18)
        subtitleLabel.stringValue = state
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 16, y: 5, width: 290, height: 17)
        let toggle = ConnectionToggle()
        toggle.frame = NSRect(x: 310, y: 8, width: 54, height: 24)
        toggle.state = connected ? .on : .off
        toggle.isEnabled = enabled
        toggle.setAccessibilityLabel(L("Tailscale connection"))
        toggle.target = self
        toggle.action = #selector(change)
        toggle.autoresizingMask = [.minXMargin]
        addSubview(titleLabel); addSubview(subtitleLabel); addSubview(toggle)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tailbar: Tailscale \(state)")
        setAccessibilityEnabled(enabled)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { setMenuHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setMenuHighlighted(false) }
    func setMenuHighlighted(_ value: Bool) {
        highlighted = value && enabled
        titleLabel.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        subtitleLabel.textColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func mouseUp(with event: NSEvent) { if enabled { onToggle() } }
    override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; onToggle(); return true }
    @objc private func change() { if enabled { onToggle() } }
}
