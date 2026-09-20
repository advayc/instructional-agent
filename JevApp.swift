import AppKit
final class JevApp: NSObject, NSApplicationDelegate {
    let popup = PopupPanel()
    let overlay = OverlayWindow()
    var lastCmd: TimeInterval = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, _, _, _ in nil }, userInfo: nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func togglePopup() {
        popup.isVisible ? popup.orderOut(nil) : popup.center()
    }
    func highlight(at p: NSPoint, label l: String) {
        overlay.show(at: p, label: l)
    }
}
let app = NSApplication.shared
let delegate = JevApp()
app.delegate = delegate
app.run()
