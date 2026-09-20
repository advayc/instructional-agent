import AppKit
final class PopupPanel: NSPanel {
    let appIcon = NSImageView(frame: .zero)
    let context = NSTextField(labelWithString: "")
    let box = NSView(frame: .zero)
    let hint = NSTextField(labelWithString: "What should I do?")
    let input = NSTextField(frame: .zero)
    let pasteButton = NSButton(frame: .zero)
    let output = NSTextView(frame: .zero)
    var dragAt = NSZeroPoint
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        alphaValue = 1.0
        center()
        guard let cv = contentView else { return }
        cv.wantsLayer = true
        cv.layer?.cornerRadius = 22
        cv.layer?.masksToBounds = true
        let fx = NSVisualEffectView(frame: cv.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.blendingMode = .behindWindow
        fx.material = .popover
        fx.state = .active
        cv.addSubview(fx)
        let app = NSWorkspace.shared.frontmostApplication
        appIcon.image = app?.icon ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        context.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        context.textColor = .secondaryLabelColor
        context.stringValue = app?.localizedName ?? "macOS"
        context.sizeToFit()
        let sx = (680 - (30 + 8 + context.frame.width)) / 2
        appIcon.frame = NSRect(x: sx, y: 322, width: 30, height: 30)
        cv.addSubview(appIcon)
        context.frame = NSRect(x: sx + 38, y: 324, width: context.frame.width, height: 24)
        cv.addSubview(context)
        box.frame = NSRect(x: 24, y: 176, width: 632, height: 122)
        box.wantsLayer = true
        box.layer?.cornerRadius = 18
        box.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(box)
        hint.font = NSFont.systemFont(ofSize: 14)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 22, y: 76, width: 588, height: 20)
        box.addSubview(hint)
        input.font = NSFont.systemFont(ofSize: 16)
        input.textColor = .labelColor
        input.drawsBackground = false
        input.isBordered = false
        input.focusRingType = .none
        input.frame = NSRect(x: 20, y: 22, width: 536, height: 30)
        input.autoresizingMask = [.width]
        box.addSubview(input)
        pasteButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
        pasteButton.bezelStyle = .inline
        pasteButton.isBordered = false
        pasteButton.imageScaling = .scaleProportionallyDown
        pasteButton.target = self
        pasteButton.action = #selector(paste)
        pasteButton.frame = NSRect(x: 566, y: 18, width: 44, height: 40)
        pasteButton.autoresizingMask = [.minXMargin]
        box.addSubview(pasteButton)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 20, width: 632, height: 140))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        output.isEditable = false
        output.font = NSFont.systemFont(ofSize: 14)
        output.textColor = .labelColor
        output.drawsBackground = false
        scroll.documentView = output
        cv.addSubview(scroll)
        updateTheme()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(themeChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }
    @objc func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            input.stringValue = s
        }
        makeFirstResponder(input)
    }
    @objc func themeChanged() {
        updateTheme()
    }
    func updateTheme() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        box.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.06)).cgColor
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func mouseDown(with e: NSEvent) {
        dragAt = e.locationInWindow
    }
    override func mouseDragged(with e: NSEvent) {
        var f = frame
        f.origin.x += e.locationInWindow.x - dragAt.x
        f.origin.y += e.locationInWindow.y - dragAt.y
        setFrame(f, display: true)
    }
    func screenshot() -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/screencapture"
        p.arguments = ["-x", "-t", "jpg", "/tmp/jev-screen.jpg"]
        try? p.run()
        p.waitUntilExit()
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/jev-screen.jpg")) else { return nil }
        return d.base64EncodedString()
    }
    func post(_ messages: [[String: Any]], done: @escaping (String) -> Void) {
        let env = ProcessInfo.processInfo.environment
        let key = env["AI_GATEWAY_API_KEY"].flatMap({ $0.isEmpty ? nil : $0 }) ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
        let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": messages])
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var text = "request failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)). Check key in .env, rebuild."
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let t = msg["content"] as? String { text = t }
            DispatchQueue.main.async { done(text) }
        }.resume()
    }
    func ask(_ prompt: String) {
        output.string = "…"
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
        let system = "You are jev, a fast macOS assistant. User is on a Mac, frontmost app is \(front). Assume macOS always, never ask which OS. Answer short and actionable: exact menu paths, keys, clicks. No fluff."
        var user: [[String: Any]] = [["type": "text", "text": prompt]]
        if let b64 = screenshot() {
            user.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
        }
        post([["role": "system", "content": system], ["role": "user", "content": user]]) { [weak self] text in
            self?.output.string = text
        }
    }
    func locate(_ desc: String, done: @escaping (CGPoint?) -> Void) {
        guard let b64 = screenshot(), let screen = NSScreen.main else { done(nil); return }
        let f = screen.frame
        let system = "You see a macOS screenshot. Find the UI element: \(desc). Reply ONLY with JSON like {\"x\":500,\"y\":300} where x,y are 0-1000 from top-left. No other text."
        let user: [[String: Any]] = [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]]
        post([["role": "system", "content": system], ["role": "user", "content": user]]) { text in
            guard let d = text.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Double],
                  let x = j["x"], let y = j["y"] else { done(nil); return }
            done(CGPoint(x: f.origin.x + f.width * x / 1000, y: f.origin.y + f.height * (1 - y / 1000)))
        }
    }
}
