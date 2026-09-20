import AppKit
final class PopupPanel: NSPanel {
    let context = NSTextField(labelWithString: "")
    let input = NSTextField(frame: .zero)
    let output = NSTextView(frame: .zero)
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 150), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        backgroundColor = .clear
        center()
        input.placeholderString = "What should I do?"
        input.font = NSFont.systemFont(ofSize: 20)
        context.font = NSFont.systemFont(ofSize: 13)
        context.textColor = .secondaryLabelColor
        context.stringValue = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        contentView = NSStackView(views: [context, input, output])
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": prompt]]])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String else { return }
            DispatchQueue.main.async { self?.output.string = text }
        }.resume()
    }
}
