import AppKit
final class OverlayWindow: NSWindow {
    var point = NSZeroPoint
    var label = ""
    let ring = RingView(frame: .zero)
    init() {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        level = .screenSaver
        ring.frame = contentLayoutRect
        ring.autoresizingMask = [.width, .height]
        contentView = ring
    }
    func show(at p: NSPoint, label l: String) {
        ring.point = p
        ring.label = l
        ring.needsDisplay = true
        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.orderOut(nil) }
    }
    func hide() {
        orderOut(nil)
    }
}
final class RingView: NSView {
    var point = NSZeroPoint
    var label = ""
    override func draw(_ r: NSRect) {
        let accent = NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.48, alpha: 1)
        accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 42, y: point.y - 42, width: 84, height: 84)).fill()
        accent.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: point.x - 40, y: point.y - 40, width: 80, height: 80))
        path.setLineDash([8, 6], count: 2, phase: 0)
        path.lineWidth = 3
        path.stroke()
        let text = label as NSString
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: textAttributes)
        let pill = NSRect(x: point.x - textSize.width / 2 - 14, y: point.y + 54, width: textSize.width + 28, height: 28)
        NSColor(calibratedWhite: 0.08, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
        accent.withAlphaComponent(0.65).setStroke()
        let border = NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14)
        border.lineWidth = 1
        border.stroke()
        text.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 7), withAttributes: textAttributes)
    }
}
