import AppKit
final class JevApp: NSObject, NSApplicationDelegate {
    let popup = PopupPanel()
    var lastCmd: TimeInterval = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popup.input.target = self
        popup.input.action = #selector(send(_:))
        popup.center()
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKey()
        popup.makeFirstResponder(popup.input)
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard e.modifierFlags.contains(.command), e.keyCode == 55 || e.keyCode == 54 else { return }
            let now = Date().timeIntervalSince1970
            if now - (self?.lastCmd ?? 0) < 0.4 { self?.toggle() }
            self?.lastCmd = now
        }
    }
    @objc func send(_ s: NSTextField) {
        popup.ask(s.stringValue)
    }
    func toggle() {
        if popup.isVisible {
            popup.orderOut(nil)
        } else {
            popup.center()
            popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
