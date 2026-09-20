import AppKit

final class JevApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let popup = PopupPanel()
    let overlay = OverlayWindow()
    private var lastCmd: TimeInterval = 0
    private var lastExternalAppName = "macOS"
    private var guide: GuideSession?
    private var isLoadingNextStep = false
    private var advancementWork: DispatchWorkItem?
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(systemSymbolName: "location.north.line.fill", accessibilityDescription: "Jev")
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

    /// Keep credentials out of the bundle. A development build can read the
    /// ignored .env beside Jev.app; a distributed build should inject the key
    /// through its launch environment or a Keychain-backed configuration.
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
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalAppName = app.localizedName ?? "macOS"
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalAppName = app.localizedName ?? "macOS"
        }
    }

    private func installEventMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleLocalKey(event) ?? event
        }
        if let local { eventMonitors.append(local) }

        let guideEvents = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleGuideInput(event)
            }
        }
        if let guideEvents { eventMonitors.append(guideEvents) }

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

    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            if guide != nil {
                cancelGuide(showPrompt: true)
            } else {
                toggle(hide: true)
            }
            return nil
        }
        if isManualAdvance(event) {
            advanceCurrentStep()
            return nil
        }
        return event
    }

    private func isManualAdvance(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 124 && event.modifierFlags.contains(.option)
    }

    @objc func send(_ sender: NSTextField) {
        let task = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        startGuide(task: task)
    }

    private func startGuide(task: String) {
        cancelGuide(showPrompt: false)
        let newGuide = GuideSession(task: task)
        guide = newGuide
        popup.preparingGuide()
        popup.orderOut(nil)
        overlay.showThinking(at: NSEvent.mouseLocation)
        requestNextStep(for: newGuide)
    }

    private func requestNextStep(for session: GuideSession) {
        guard guide?.id == session.id, !isLoadingNextStep else { return }
        isLoadingNextStep = true
        overlay.showThinking(at: session.targetOnScreen ?? NSEvent.mouseLocation)
        popup.nextGuideStep(
            task: session.task,
            completedCaptions: session.completedCaptions,
            frontmostApp: lastExternalAppName
        ) { [weak self] result in
            guard let self, self.guide?.id == session.id else { return }
            self.isLoadingNextStep = false
            switch result {
            case .success(let step):
                self.present(step, for: session)
            case .failure(let error):
                self.failGuide(error.message)
            }
        }
    }

    private func present(_ step: GuideStep, for session: GuideSession) {
        guard guide?.id == session.id else { return }
        advancementWork?.cancel()
        advancementWork = nil

        if step.isDone {
            finishGuide(session, caption: step.caption)
            return
        }
        if step.actionKind == .click && step.validTarget == nil {
            failGuide("Jev could not see the control to point at. Bring it into view and try again.")
            return
        }

        session.currentStep = step
        session.targetOnScreen = step.validTarget.flatMap(screenPoint(for:))
        overlay.present(caption: step.caption, at: session.targetOnScreen)

        if step.actionKind == .wait {
            scheduleAdvance(after: 0.9)
        }
    }

    private func screenPoint(for target: GuideTarget) -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.frame
        return NSPoint(
            x: frame.minX + frame.width * target.x / 1000,
            y: frame.minY + frame.height * (1 - target.y / 1000)
        )
    }

    private func handleGuideInput(_ event: NSEvent) {
        guard let session = guide,
              let step = session.currentStep,
              !isLoadingNextStep else { return }

        if isManualAdvance(event) {
            advanceCurrentStep()
            return
        }

        switch step.actionKind {
        case .click:
            guard event.type == .leftMouseDown, let target = session.targetOnScreen else { return }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - target.x
            let dy = mouse.y - target.y
            if dx * dx + dy * dy <= 110 * 110 {
                scheduleAdvance(after: 0.35)
            }
        case .type:
            guard event.type == .keyDown else { return }
            // Wait for a short pause, so a whole typed phrase stays one step.
            scheduleAdvance(after: 0.85)
        case .shortcut:
            guard event.type == .keyDown else { return }
            scheduleAdvance(after: 0.4)
        case .scroll:
            guard event.type == .scrollWheel else { return }
            scheduleAdvance(after: 0.45)
        case .wait, .done, .unknown:
            break
        }
    }

    private func scheduleAdvance(after delay: TimeInterval) {
        advancementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.advanceCurrentStep()
        }
        advancementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func advanceCurrentStep() {
        guard let session = guide,
              let step = session.currentStep,
              !isLoadingNextStep else { return }
        advancementWork?.cancel()
        advancementWork = nil
        session.completedCaptions.append(step.caption)
        if session.completedCaptions.count > 12 {
            session.completedCaptions.removeFirst(session.completedCaptions.count - 12)
        }
        session.currentStep = nil
        isLoadingNextStep = true
        overlay.showThinking(at: session.targetOnScreen ?? NSEvent.mouseLocation)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.guide?.id == session.id else { return }
            self.isLoadingNextStep = false
            self.requestNextStep(for: session)
        }
    }

    private func finishGuide(_ session: GuideSession, caption: String) {
        guard guide?.id == session.id else { return }
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        overlay.showCompletion(caption)
        popup.reset()
    }

    private func failGuide(_ message: String) {
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        overlay.dismiss()
        showPrompt(message: message)
    }

    private func cancelGuide(showPrompt: Bool) {
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        overlay.dismiss()
        popup.reset()
        if showPrompt {
            self.showPrompt()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        popup.orderOut(nil)
        return false
    }

    private func showPrompt(message: String? = nil) {
        if let message {
            popup.reset(message: message)
        }
        popup.updateContext(lastExternalAppName)
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKey()
        popup.makeFirstResponder(popup.input)
    }

    private func toggle(hide: Bool = false) {
        if guide != nil {
            cancelGuide(showPrompt: !hide)
            return
        }
        if popup.isVisible {
            popup.orderOut(nil)
        } else if !hide {
            showPrompt()
        }
    }
}
