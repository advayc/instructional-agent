import AppKit

/// A click-through layer: it never changes the desktop, it only draws the
/// cursor and the instruction that follows it.
final class OverlayWindow: NSWindow {
    private let marker = GuideMarkerView(frame: .zero)
    private var timer: Timer?
    private var hideAt: Date?

    init() {
        let desktop = OverlayWindow.desktopFrame()
        super.init(contentRect: desktop, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        marker.frame = contentLayoutRect
        marker.autoresizingMask = [.width, .height]
        contentView = marker
    }

    func showThinking(at screenPoint: NSPoint) {
        hideAt = nil
        let point = localPoint(from: screenPoint)
        marker.present(caption: "Finding the next control…", from: point, to: point, showsCursor: false)
        orderFrontRegardless()
        ensureTimer()
    }

    func present(caption: String, at screenPoint: NSPoint?) {
        hideAt = nil
        let fallback = localPoint(from: NSEvent.mouseLocation)
        let destination = screenPoint.map(localPoint(from:)) ?? fallback
        let origin = marker.hasPlacedCursor ? marker.point : fallback
        marker.present(caption: caption, from: origin, to: destination, showsCursor: screenPoint != nil)
        orderFrontRegardless()
        ensureTimer()
    }

    func showCompletion(_ caption: String) {
        let point = marker.hasPlacedCursor ? marker.point : localPoint(from: NSEvent.mouseLocation)
        marker.present(caption: caption, from: point, to: point, showsCursor: false)
        hideAt = Date().addingTimeInterval(1.7)
        orderFrontRegardless()
        ensureTimer()
    }

    func dismiss() {
        hideAt = nil
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    private static func desktopFrame() -> NSRect {
        var frame = NSScreen.screens.first?.frame ?? .zero
        for screen in NSScreen.screens.dropFirst() {
            frame = frame.union(screen.frame)
        }
        return frame
    }

    private func localPoint(from screenPoint: NSPoint) -> NSPoint {
        NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let next = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        let animationIsRunning = marker.tick()
        if let hideAt, Date() >= hideAt {
            dismiss()
        } else if !animationIsRunning && hideAt == nil {
            timer?.invalidate()
            timer = nil
        }
    }
}

private final class GuideMarkerView: NSView {
    var point = NSZeroPoint
    private var origin = NSZeroPoint
    private var destination = NSZeroPoint
    private var caption = ""
    private var displayedCaption = ""
    private var beganAt = Date()
    private var showsCursor = false
    private(set) var hasPlacedCursor = false
    private var bubbleOpacity: CGFloat = 0
    private var cursorOpacity: CGFloat = 0

    func present(caption: String, from: NSPoint, to: NSPoint, showsCursor: Bool) {
        self.caption = caption
        displayedCaption = ""
        origin = from
        destination = to
        point = from
        self.showsCursor = showsCursor
        hasPlacedCursor = showsCursor || hasPlacedCursor
        bubbleOpacity = 0
        cursorOpacity = 0
        beganAt = Date()
        needsDisplay = true
    }

    /// Returns whether a visual transition still needs frames.
    @discardableResult
    func tick() -> Bool {
        let elapsed = Date().timeIntervalSince(beganAt)
        let travel = CGFloat(min(1, elapsed / 0.16))
        let eased = travel * travel * (3 - 2 * travel)
        point = NSPoint(
            x: origin.x + (destination.x - origin.x) * eased,
            y: origin.y + (destination.y - origin.y) * eased
        )
        bubbleOpacity = CGFloat(min(1, elapsed / 0.08))
        cursorOpacity = showsCursor ? CGFloat(min(1, elapsed / 0.07)) : 0

        let letters = min(caption.count, Int(max(0, elapsed - 0.035) / 0.007))
        displayedCaption = String(caption.prefix(letters))
        needsDisplay = true
        return travel < 1 || letters < caption.count
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bubbleOpacity > 0 else { return }

        drawCaption()
        if cursorOpacity > 0 {
            drawCursor()
        }
    }

    private func drawCaption() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let maxTextWidth: CGFloat = 330
        let textBounds = (caption as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let bubbleWidth = max(155, min(maxTextWidth + 42, ceil(textBounds.width) + 42))
        let bubbleHeight = max(40, ceil(textBounds.height) + 22)
        let safeBounds = bounds.insetBy(dx: 14, dy: 14)
        var x = point.x - bubbleWidth / 2
        var y = point.y + 40
        x = min(max(safeBounds.minX, x), max(safeBounds.minX, safeBounds.maxX - bubbleWidth))
        if y + bubbleHeight > safeBounds.maxY {
            y = point.y - bubbleHeight - 34
        }
        y = max(safeBounds.minY, y)
        let bubble = NSRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34 * bubbleOpacity)
        shadow.shadowBlurRadius = 15
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        let path = NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.055, alpha: 0.94 * bubbleOpacity).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let accent = NSBezierPath(roundedRect: NSRect(x: bubble.minX + 13, y: bubble.minY + 12, width: 3, height: bubble.height - 24), xRadius: 1.5, yRadius: 1.5)
        NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.16, alpha: bubbleOpacity).setFill()
        accent.fill()

        let textRect = NSRect(x: bubble.minX + 27, y: bubble.minY + 11, width: bubble.width - 38, height: bubble.height - 20)
        (displayedCaption as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCursor() {
        let pointer = NSBezierPath()
        pointer.move(to: point)
        pointer.line(to: NSPoint(x: point.x + 1, y: point.y - 34))
        pointer.line(to: NSPoint(x: point.x + 9, y: point.y - 25))
        pointer.line(to: NSPoint(x: point.x + 14, y: point.y - 33))
        pointer.line(to: NSPoint(x: point.x + 19, y: point.y - 30))
        pointer.line(to: NSPoint(x: point.x + 14, y: point.y - 22))
        pointer.line(to: NSPoint(x: point.x + 25, y: point.y - 22))
        pointer.close()
        pointer.lineJoinStyle = .round

        NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.16, alpha: 0.98 * cursorOpacity).setFill()
        pointer.fill()
        NSColor.white.withAlphaComponent(0.96 * cursorOpacity).setStroke()
        pointer.lineWidth = 2
        pointer.stroke()
    }
}
