import AppKit
import ApplicationServices
import CoreGraphics

/// Jev executes macOS actions. Type plaintext, Enter shows what will run,
/// Enter again runs it, Esc cancels. No visual guide, no vision calls.
final class JevApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let popup = PopupPanel()
    let overlay = OverlayWindow()
    private var lastCmd: TimeInterval = 0
    private var lastExternalAppName = "macOS"
    private var lastExternalApplication: NSRunningApplication?
    private var eventMonitors: [Any] = []
    private var isResolving = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(named: "Jev") ?? NSImage(named: NSImage.applicationIconName)
        installMenu()
        loadEnv()
        observeFrontmostApp()

        popup.input.target = self
        popup.input.action = #selector(send(_:))
        popup.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            popup.standardWindowButton(button)?.isHidden = false
        }
        showPrompt()
        installEventMonitors()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Jev", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
    }

    private func loadEnv() {
        let environment = ProcessInfo.processInfo.environment
        let hasKey = !(environment["AI_GATEWAY_API_KEY"] ?? "").isEmpty
            || !(environment["AI_GATEWAY_API_KEY_BACKUP"] ?? "").isEmpty
        guard !hasKey else { return }

        let appFolder = Bundle.main.bundleURL.deletingLastPathComponent()
        let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Jev", isDirectory: true)
        let candidates = [
            supportFolder?.appendingPathComponent(".env"),
            appFolder.appendingPathComponent(".env")
        ].compactMap { $0 }

        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let pair = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                setenv(pair[0], pair[1], 0)
            }
            return
        }
    }

    private func observeFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            rememberExternalApp(app)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.rememberExternalApp(app)
        }
    }

    private func rememberExternalApp(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.localizedName != "universalAccessAuthWarn" else { return }
        lastExternalApplication = app
        lastExternalAppName = app.localizedName ?? "macOS"
        popup.updateContext(lastExternalAppName, icon: app.icon)
    }

    private func installEventMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleLocalKey(event) ?? event
        }
        if let local { eventMonitors.append(local) }

        if #available(macOS 10.15, *), CGPreflightListenEventAccess() {
            let command = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard event.modifierFlags.contains(.command), (event.keyCode == 55 || event.keyCode == 54) else { return }
                let now = Date().timeIntervalSince1970
                if now - (self?.lastCmd ?? 0) < 0.4 {
                    DispatchQueue.main.async { self?.toggle() }
                }
                self?.lastCmd = now
            }
            if let command { eventMonitors.append(command) }
        }
    }

    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            toggle(hide: true)
            return nil
        }
        return event
    }

    // MARK: - Parse → execute immediately

    @objc func send(_ sender: NSTextField) {
        let task = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !isResolving else { return }
        if let cmd = Actions.parseLocal(task) {
            execute(cmd)
            return
        }
        if isGeneralQuestion(task) {
            answer(task)
            return
        }
        resolveRemote(task)
    }

    private func resolveRemote(_ task: String) {
        isResolving = true
        popup.preparingAction()
        popup.status.stringValue = "On it…"
        Actions.requestPlan(task: task) { [weak self] steps in
            guard let self else { return }
            self.isResolving = false
            if let steps {
                self.executePlan(steps)
            } else {
                self.answer(task)
            }
        }
    }

    /// Runs plan steps in order with progress. Single-step plans behave
    /// exactly like a direct execution.
    private func executePlan(_ steps: [PendingCommand]) {
        guard steps.count > 1 else {
            if let first = steps.first { execute(first) }
            return
        }
        popup.preparingAction()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var messages: [String] = []
            for (i, step) in steps.enumerated() {
                let n = i + 1
                DispatchQueue.main.sync {
                    self?.popup.status.stringValue = "Step \(n)/\(steps.count)…"
                }
                switch step {
                case .timer(let seconds, let label):
                    messages.append(label)
                    DispatchQueue.main.sync { self?.startTimer(seconds: seconds) }
                case .action(let action):
                    messages.append(action.run())
                }
                guard self != nil else { return }
            }
            let combined = messages.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String(combined.prefix(280))
            DispatchQueue.main.async {
                guard let self else { return }
                self.popup.reset(message: message)
                self.overlay.showCompletion(message)
                self.popup.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                self.popup.makeKey()
                self.popup.makeFirstResponder(self.popup.input)
            }
        }
    }

    private func execute(_ cmd: PendingCommand) {
        switch cmd {
        case .timer(let seconds, _):
            startTimer(seconds: seconds)
            return
        case .action(let action):
            popup.preparingAction()
            popup.status.stringValue = "Doing: \(action.summary)…"
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let message = action.run()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.popup.reset(message: message)
                    self.overlay.showCompletion(message)
                    self.popup.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                    self.popup.makeKey()
                    self.popup.makeFirstResponder(self.popup.input)
                }
            }
        }
    }

    private func startTimer(seconds: TimeInterval) {
        let label: String
        if seconds >= 3600 { label = String(format: "Timer for %.1f hr started.", seconds / 3600) }
        else if seconds >= 60 { label = String(format: "Timer for %.0f min started.", seconds / 60) }
        else { label = String(format: "Timer for %.0f sec started.", seconds) }
        popup.reset(message: label)
        overlay.showCompletion(label)
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            NSSound.beep()
            let done = "Done — your timer finished."
            self.overlay.showCompletion(done)
            self.popup.reset(message: done)
            self.popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Chat fallback for non-actionable input

    private func answer(_ task: String) {
        popup.preparingAnswer()
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.requestAnswer(
            task: task,
            frontmostApp: lastExternalAppName,
            progress: { [weak self] text in self?.popup.showAnswerProgress(text) }
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text): self.popup.showAnswer(text)
            case .failure(let error): self.popup.showSetupIssue(error.message)
            }
            self.popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            self.popup.makeKey()
            self.popup.makeFirstResponder(self.popup.input)
        }
    }

    private func isGeneralQuestion(_ task: String) -> Bool {
        let lower = Actions.normalize(task).lowercased()
        let actionWords = ["open", "launch", "start ", "quit ", "close ",
                           "play", "pause", "resume", "skip", "mute", "unmute", "volume",
                           "dark mode", "light mode", "timer", "alarm", "remind",
                           "bookmark", "new tab", "terminal", "opencode", "spotify",
                           "search", "google", "chrome", "song", "track",
                           "book", "order", "buy", "website", "site", "visit", "go to",
                           "price", "flight", "login", "fill", "youtube", "gmail",
                           "amazon", "github", "maps", "drive", "calendar"]
        if actionWords.contains(where: { lower.contains($0) }) { return false }
        if lower.hasSuffix("?") { return true }
        let starters = ["what ", "what's ", "whats ", "who ", "why ", "how ", "when ", "where ",
                        "explain ", "define ", "summarize ", "summarise ", "tell me ", "write ",
                        "draft ", "compose ", "calculate ", "convert ", "translate "]
        if starters.contains(where: { lower.hasPrefix($0) }) { return true }
        return true
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        popup.orderOut(nil)
        return false
    }

    private func showPrompt(message: String? = nil) {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberExternalApp(frontmost)
        }
        if let message {
            popup.reset(message: message)
        }
        popup.updateContext(lastExternalAppName, icon: lastExternalApplication?.icon)
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKey()
        popup.makeFirstResponder(popup.input)
    }

    private func toggle(hide: Bool = false) {
        if popup.isVisible {
            popup.orderOut(nil)
        } else if !hide {
            showPrompt()
        }
    }
}
