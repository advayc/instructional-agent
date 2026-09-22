import AppKit
import CoreGraphics
import Foundation

struct GuideRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class PopupPanel: NSPanel {
    let appIcon = NSImageView(frame: .zero)
    let context = NSTextField(labelWithString: "macOS")
    let titleText = NSTextField(labelWithString: "Show me how to do it")
    let box = NSView(frame: .zero)
    let hint = NSTextField(labelWithString: "Describe the task")
    let input = NSTextField(frame: .zero)
    let pasteButton = NSButton(frame: .zero)
    let status = NSTextField(labelWithString: "Type something to do — Enter runs it.")
    private let dragHint = NSTextField(labelWithString: "Drag to move")
    var dragAt = NSZeroPoint

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 276),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        if !setFrameUsingName("JevPromptPanel") {
            center()
        } else if contentView?.bounds.height ?? 0 < 276 {
            setContentSize(NSSize(width: 640, height: 276))
        }
        setFrameAutosaveName("JevPromptPanel")
        guard let cv = contentView else { return }

        cv.wantsLayer = true
        cv.layer?.cornerRadius = 22
        cv.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: cv.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        cv.addSubview(effect)

        appIcon.image = NSImage(named: "Jev") ?? NSImage(named: NSImage.applicationIconName)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.frame = NSRect(x: 34, y: 221, width: 23, height: 23)
        cv.addSubview(appIcon)

        context.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        context.textColor = .secondaryLabelColor
        context.frame = NSRect(x: 65, y: 222, width: 300, height: 20)
        cv.addSubview(context)

        dragHint.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        dragHint.textColor = .tertiaryLabelColor
        dragHint.alignment = .right
        dragHint.frame = NSRect(x: 470, y: 223, width: 136, height: 17)
        cv.addSubview(dragHint)

        titleText.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleText.textColor = .labelColor
        titleText.frame = NSRect(x: 32, y: 183, width: 440, height: 29)
        cv.addSubview(titleText)

        // Transparent drag handle LAST so it sits above the header labels
        // (which otherwise swallow mouseDown). Labels stay visible through
        // it; there are no buttons in the header to block.
        let headerDrag = WindowDragHandleView(frame: NSRect(x: 0, y: 176, width: 640, height: 100))
        headerDrag.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(headerDrag)

        box.frame = NSRect(x: 24, y: 92, width: 592, height: 82)
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(box)

        hint.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 19, y: 53, width: 500, height: 17)
        box.addSubview(hint)

        input.font = NSFont.systemFont(ofSize: 16)
        input.textColor = .labelColor
        input.drawsBackground = false
        input.isBordered = false
        input.focusRingType = .none
        input.placeholderString = "e.g. open Excel, play SICKO MODE on Spotify"
        input.frame = NSRect(x: 17, y: 16, width: 500, height: 28)
        input.autoresizingMask = [.width]
        box.addSubview(input)

        pasteButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
        pasteButton.bezelStyle = .inline
        pasteButton.isBordered = false
        pasteButton.imageScaling = .scaleProportionallyDown
        pasteButton.target = self
        pasteButton.action = #selector(paste)
        pasteButton.frame = NSRect(x: 532, y: 17, width: 42, height: 38)
        pasteButton.autoresizingMask = [.minXMargin]
        box.addSubview(pasteButton)

        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 32, y: 8, width: 576, height: 28)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        cv.addSubview(status)

        updateTheme()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            input.stringValue = text
        }
        makeFirstResponder(input)
    }

    @objc func themeChanged() {
        updateTheme()
    }

    func updateTheme() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        box.layer?.backgroundColor = (dark
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
        ).cgColor
    }

    func updateContext(_ appName: String, icon: NSImage?) {
        context.stringValue = appName
        appIcon.image = icon ?? NSImage(named: "Jev") ?? NSImage(named: NSImage.applicationIconName)
    }

    func preparingAction() {
        input.isEnabled = false
        pasteButton.isEnabled = false
        status.stringValue = "Doing that now…"
    }

    func preparingAnswer() {
        input.isEnabled = false
        pasteButton.isEnabled = false
        status.stringValue = "Thinking…"
    }

    func showAnswer(_ text: String) {
        input.stringValue = ""
        input.isEnabled = true
        pasteButton.isEnabled = true
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        status.stringValue = String(clean.prefix(280))
    }

    func showAnswerProgress(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        status.stringValue = String(clean.prefix(280))
    }

    func reset(message: String = "Type something to do — Enter runs it.") {
        input.stringValue = ""
        input.isEnabled = true
        pasteButton.isEnabled = true
        status.stringValue = message
    }

    /// Leave the person's task in place when macOS has detached this build
    /// from its privacy grant. This is a recoverable setup problem, not a
    /// reason for the prompt to appear to vanish.
    func showSetupIssue(_ message: String) {
        input.isEnabled = true
        pasteButton.isEnabled = true
        status.stringValue = message
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        var currentFrame = frame
        currentFrame.origin.x += event.locationInWindow.x - dragAt.x
        currentFrame.origin.y += event.locationInWindow.y - dragAt.y
        setFrame(currentFrame, display: true)
    }

    func requestAnswer(
        task: String,
        frontmostApp: String,
        progress: @escaping (String) -> Void,
        done: @escaping (Result<String, GuideRequestError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            let system = """
            You are jev, a fast macOS assistant. User is on a Mac, frontmost app is \(frontmostApp). Assume macOS always, never ask which OS. Answer short and actionable: exact menu paths, keys, clicks when relevant. No fluff. Keep under 280 characters, plain text, no markdown headers.
            """
            self.postTextStream(
                [["role": "system", "content": system], ["role": "user", "content": task]],
                progress: progress
            ) { response in
                let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, !clean.lowercased().hasPrefix("request failed"), clean != "missing API key" else {
                    done(.failure(GuideRequestError(message: "Jev could not get an answer. Check connection and try again.")))
                    return
                }
                done(.success(clean))
            }
        }
    }

    private func post(_ messages: [[String: Any]], done: @escaping (String) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        let key = environment["AI_GATEWAY_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["AI_GATEWAY_API_KEY_BACKUP"]
            ?? ""
        guard !key.isEmpty else {
            DispatchQueue.main.async { done("missing API key") }
            return
        }

        let model = environment["AI_GATEWAY_MODEL"] ?? "vmc/jev"
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 22
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "reasoning_effort": "minimal",
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // A guide cannot be used until its JSON object is complete. Buffering
        // avoids duplicating SSE chunks while preserving the same model route.
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var text = "request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))"
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                text = content
            }
            DispatchQueue.main.async { done(text) }
        }.resume()
    }

    /// Text answers can be shown as tokens arrive. Guide plans deliberately
    /// stay on the buffered JSON path above, because a partial plan must never
    /// control which on-screen target Jev highlights.
    private func postTextStream(
        _ messages: [[String: Any]],
        progress: @escaping (String) -> Void,
        done: @escaping (String) -> Void
    ) {
        let environment = ProcessInfo.processInfo.environment
        let key = environment["AI_GATEWAY_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["AI_GATEWAY_API_KEY_BACKUP"]
            ?? ""
        guard !key.isEmpty else {
            DispatchQueue.main.async { done("missing API key") }
            return
        }

        let model = environment["AI_GATEWAY_MODEL"] ?? "vmc/jev"
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 22
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "reasoning_effort": "minimal",
            "stream": true
        ])

        let delegate = TextStreamDelegate(progress: progress, done: done)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: request).resume()
    }
}

private final class WindowDragHandleView: NSView {
    var dragAt = NSZeroPoint
    override func mouseDown(with event: NSEvent) {
        dragAt = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        var f = window.frame
        f.origin.x += event.locationInWindow.x - dragAt.x
        f.origin.y += event.locationInWindow.y - dragAt.y
        window.setFrame(f, display: true)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let frame = window.contentView?.frame {
            let titleBarHeight: CGFloat = 28
            if point.y > frame.height - titleBarHeight { return nil }
        }
        return self
    }
}

/// Processes each complete SSE line once. Network callbacks can split a JSON
/// event across arbitrary byte boundaries, so retaining only the unconsumed
/// suffix avoids duplicated or corrupted text.
private final class TextStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var session: URLSession?
    private let progress: (String) -> Void
    private let done: (String) -> Void
    private var pending = Data()
    private var raw = Data()
    private var text = ""
    private var statusCode = 0
    private var didFinish = false

    init(progress: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        self.progress = progress
        self.done = done
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        raw.append(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            consume(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if !pending.isEmpty {
            consume(pending[...])
            pending.removeAll(keepingCapacity: false)
        }

        guard !didFinish else { return }

        if !text.isEmpty {
            finish(text)
        } else if let message = Self.message(from: raw) {
            finish(message)
        } else {
            let code = statusCode == 0 ? "" : " (\(statusCode))"
            finish("request failed\(code)")
        }
    }

    private func consume(_ line: Data.SubSequence) {
        guard let rawLine = String(data: line, encoding: .utf8) else { return }
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return }

        let payload = String(trimmed.dropFirst(6))
        if payload == "[DONE]" {
            finish(text.isEmpty ? "request failed (empty)" : text)
            return
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return
        }
        text += content
        let snapshot = text
        DispatchQueue.main.async { [progress] in progress(snapshot) }
    }

    private func finish(_ response: String) {
        guard !didFinish else { return }
        didFinish = true
        DispatchQueue.main.async { [done] in done(response) }
    }

    private static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }
}
