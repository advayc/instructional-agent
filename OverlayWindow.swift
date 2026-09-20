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
        NSColor.yellow.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: point.x - 40, y: point.y - 40, width: 80, height: 80))
        path.setLineDash([8, 6], count: 2, phase: 0)
        path.lineWidth = 4
        path.stroke()
        (label as NSString).draw(at: NSPoint(x: point.x - 30, y: point.y + 50))
    }
}
