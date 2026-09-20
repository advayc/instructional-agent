import AppKit
final class OverlayWindow: NSWindow {
    var point = NSZeroPoint
    var label = ""
    init() {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        level = .screenSaver
    }
    func show(at p: NSPoint, label l: String) {
        point = p
        label = l
        orderFrontRegardless()
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
