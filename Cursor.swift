import AppKit
enum Cursor {
    static func pos() -> CGPoint {
        NSEvent.mouseLocation
    }
    static func smoothMove(to t: CGPoint) {
        let from = pos()
        let steps = 48
        for i in 1...steps {
            let e = Double(i) / Double(steps)
            let k = e * e * (3 - 2 * e)
            let p = CGPoint(x: from.x + (t.x - from.x) * k, y: from.y + (t.y - from.y) * k)
            if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                ev.post(tap: .cgSessionEventTap)
            }
            Thread.sleep(forTimeInterval: 0.008)
        }
    }
    static func click(at t: CGPoint) {
        smoothMove(to: t)
        if let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: t, mouseButton: .left) {
            d.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 0.06)
        if let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: t, mouseButton: .left) {
            u.post(tap: .cgSessionEventTap)
        }
    }
}
