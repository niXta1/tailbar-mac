import AppKit

/// Fixed reference geometry in points, shared by the toolbar and menu.
/// NSSwitch's intrinsic size changes with Tahoe toolbar context and can draw
/// outside a SwiftUI .frame. Keep NSButton's keyboard/action/accessibility
/// behavior, but draw the track inside our own explicit bounds.
final class ConnectionToggle: NSButton {
    static let referenceSize = NSSize(width: 54, height: 24)
    override var intrinsicContentSize: NSSize { Self.referenceSize }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.referenceSize))
        setButtonType(.switch)
        title = ""
        isBordered = false
        focusRingType = .exterior
        setAccessibilityLabel(L("Tailscale connection"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: bounds.midX - 27, y: bounds.midY - 12, width: 54, height: 24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        let on = state == .on
        let trackColor = on ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.32)
        trackColor.withAlphaComponent(isEnabled ? (on ? 1 : 0.32) : 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 12, yRadius: 12).fill()
        let thumb = NSRect(x: track.minX + (on ? 20 : 2), y: track.minY + 2, width: 32, height: 20)
        NSColor(white: isHighlighted ? 0.86 : 0.96, alpha: isEnabled ? 1 : 0.65).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}
