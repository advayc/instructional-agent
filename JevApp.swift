import AppKit
final class JevApp: NSObject, NSApplicationDelegate {
    let popup = PopupPanel()
    let overlay = OverlayWindow()
    var lastCmd: TimeInterval = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Jev")
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Jev", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        loadEnv()
        popup.input.target = self
        popup.input.action = #selector(send(_:))
        popup.center()
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKey()
        popup.makeFirstResponder(popup.input)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.toggle(hide: true); return nil }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard e.modifierFlags.contains(.command), e.keyCode == 55 || e.keyCode == 54 else { return }
            let now = Date().timeIntervalSince1970
            if now - (self?.lastCmd ?? 0) < 0.4 { self?.toggle() }
            self?.lastCmd = now
        }
    }
    func loadEnv() {
        let e = ProcessInfo.processInfo.environment
        if !(e["AI_GATEWAY_API_KEY"] ?? "").isEmpty { return }
        guard let res = Bundle.main.resourcePath,
              let text = try? String(contentsOfFile: res + "/env", encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            setenv(String(kv[0]), String(kv[1]), 0)
        }
    }
    @objc func send(_ s: NSTextField) {
        let q = s.stringValue
        let lq = q.lowercased()
        if lq.contains("dark mode") || lq.contains("light mode") {
            let on = lq.contains("dark")
            runScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on ? "true" : "false")")
            overlay.show(at: NSEvent.mouseLocation, label: on ? "dark mode on" : "light mode on")
            popup.output.string = on ? "Dark mode on." : "Light mode on."
            return
        }
        popup.ask(q)
        overlay.show(at: NSEvent.mouseLocation, label: String(q.prefix(40)))
    }
    func runScript(_ src: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", src]
        try? p.run()
    }
    func toggle(hide: Bool = false) {
        if popup.isVisible {
            popup.orderOut(nil)
        } else if !hide {
            popup.center()
            popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            popup.makeFirstResponder(popup.input)
        }
    }
}
