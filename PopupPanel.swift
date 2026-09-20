import AppKit
final class PopupPanel: NSPanel {
    let context = NSTextField(labelWithString: "")
    let input = NSTextField(frame: .zero)
    let output = NSTextView(frame: .zero)
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        center()
        guard let cv = contentView else { return }
        context.font = NSFont.systemFont(ofSize: 13)
        context.textColor = .secondaryLabelColor
        context.stringValue = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        context.frame = NSRect(x: 20, y: 216, width: 600, height: 18)
        context.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(context)
        input.placeholderString = "What should I do?"
        input.font = NSFont.systemFont(ofSize: 20)
        input.frame = NSRect(x: 20, y: 166, width: 600, height: 42)
        input.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(input)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 600, height: 136))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        output.isEditable = false
        output.font = NSFont.systemFont(ofSize: 14)
        scroll.documentView = output
        cv.addSubview(scroll)
    }
    func ask(_ prompt: String) {
        let env = ProcessInfo.processInfo.environment
        let key = env["AI_GATEWAY_API_KEY"].flatMap({ $0.isEmpty ? nil : $0 }) ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
        let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
        let system = "You are jev, a fast macOS assistant. User is on a Mac, frontmost app is \(front). Assume macOS always, never ask which OS. Answer short and actionable: exact menu paths, keys, clicks. No fluff. For setting changes, list precise steps."
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]])
        output.string = "…"
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            var text = "request failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)). Check key in .env, rebuild."
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let t = msg["content"] as? String { text = t }
            DispatchQueue.main.async { self?.output.string = text }
        }.resume()
    }
}
