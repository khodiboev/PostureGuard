import AppKit
import QuartzCore

/// A soft, pulsing red glow around the edges of every screen.
/// The windows ignore the mouse, so you can keep working while it's on.
@MainActor
final class GlowOverlay {
    private var windows: [NSWindow] = []
    private var visible = false

    func show(message: String) {
        if !visible { rebuild() }        // pick up any monitor changes
        visible = true
        for window in windows {
            (window.contentView as? GlowView)?.message = message
            animate(window, to: 1, duration: 0.6)
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        for window in windows {
            animate(window, to: 0, duration: 0.4)
        }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.alphaValue = 0
            window.contentView = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            return window
        }
    }

    private func animate(_ window: NSWindow, to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        }
    }
}

final class GlowView: NSView {
    private let edge = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()

    var message: String = "" {
        didSet {
            label.stringValue = message
            layoutPill()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // A thick red line on the screen edge with a big red shadow = a glow that fades inward
        edge.path = CGPath(rect: bounds, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.systemRed.cgColor
        edge.lineWidth = 16
        edge.shadowColor = NSColor.systemRed.cgColor
        edge.shadowRadius = 45
        edge.shadowOpacity = 1
        edge.shadowOffset = .zero
        layer?.addSublayer(edge)

        // Gentle pulse, like breathing
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.45
        pulse.toValue = 1.0
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        edge.add(pulse, forKey: "pulse")

        // Small message at the bottom center
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        pill.layer?.cornerRadius = 18
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        pill.addSubview(label)
        addSubview(pill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func layoutPill() {
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 36)
        pill.frame = NSRect(x: (bounds.width - size.width) / 2, y: 70, width: size.width, height: size.height)
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
    }
}

/// A small card in the middle of the screen you're using, shown during calibration
@MainActor
final class CalibrationHUD {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 540, height: 160)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 24, y: 28, width: size.width - 48, height: size.height - 56)
        background.addSubview(label)

        panel.contentView = background
        panel.orderFrontRegardless()
    }

    func show(_ text: String) {
        label.stringValue = text
    }

    func close() {
        panel.orderOut(nil)
    }
}
