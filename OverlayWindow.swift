import AppKit
final class OverlayWindow: NSWindow {
    let mark = MarkView(frame: .zero)
    var timer: Timer?
    init() {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        level = .screenSaver
        mark.frame = contentLayoutRect
        mark.autoresizingMask = [.width, .height]
        contentView = mark
    }
    func show(at p: NSPoint, label l: String) {
        mark.label = l
        mark.target = p
        if !mark.placed {
            mark.point = p
            mark.placed = true
        }
        mark.needsDisplay = true
        orderFrontRegardless()
        timer?.invalidate()
        let end = Date().addingTimeInterval(6)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if Date() > end { t.invalidate(); self.orderOut(nil); return }
            let m = self.mark
            m.point = CGPoint(x: m.point.x + (m.target.x - m.point.x) * 0.18, y: m.point.y + (m.target.y - m.point.y) * 0.18)
            m.needsDisplay = true
        }
    }
    func hide() {
        timer?.invalidate()
        orderOut(nil)
    }
}
final class MarkView: NSView {
    var point = NSZeroPoint
    var target = NSZeroPoint
    var placed = false
    var label = ""
    override func draw(_ r: NSRect) {
        let font = NSFont.boldSystemFont(ofSize: 17)
        let ts = (label as NSString).size(withAttributes: [.font: font])
        let pw = ts.width + 32
        let ph: CGFloat = 38
        let px = point.x - pw / 2
        let py = point.y + 48
        let pill = NSBezierPath(roundedRect: NSRect(x: px, y: py, width: pw, height: ph), xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.15, alpha: 0.95).setFill()
        pill.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (label as NSString).draw(in: NSRect(x: px, y: py + 9, width: pw, height: 22), withAttributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style])
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: point.x, y: point.y))
        arrow.line(to: NSPoint(x: point.x, y: point.y - 30))
        arrow.line(to: NSPoint(x: point.x + 7.5, y: point.y - 22.5))
        arrow.line(to: NSPoint(x: point.x + 11, y: point.y - 29))
        arrow.line(to: NSPoint(x: point.x + 14, y: point.y - 27.5))
        arrow.line(to: NSPoint(x: point.x + 10.5, y: point.y - 21))
        arrow.line(to: NSPoint(x: point.x + 17, y: point.y - 21))
        arrow.close()
        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.15, alpha: 0.85).setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 2
        arrow.stroke()
    }
}
