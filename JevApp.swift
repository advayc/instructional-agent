import AppKit
import CoreGraphics

final class JevApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let popup = PopupPanel()
    let overlay = OverlayWindow()
    private var lastCmd: TimeInterval = 0
    private var lastExternalAppName = "macOS"
    private var lastExternalApplication: NSRunningApplication?
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
        if let app = NSWorkspace.shared.frontmostApplication {
            rememberExternalApp(app)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.rememberExternalApp(app)
        }
    }

    private func rememberExternalApp(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = app
        lastExternalAppName = app.localizedName ?? "macOS"
    }

    private func activateGuideTarget() {
        guard let application = lastExternalApplication, !application.isTerminated else { return }
        application.activate(options: [])
    }

    private func captureSnapshot() -> GuideDesktopSnapshot? {
        GuideDesktopSnapshot.capture(for: lastExternalApplication, fallbackName: lastExternalAppName)
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
            advanceCurrentStep(force: true)
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
        guard requestInputMonitoringIfNeeded() else {
            // CGRequestListenEventAccess presents the system prompt for this
            // signed Jev app. Do not start a guide that cannot observe the
            // person's actions; that would look like a stalled model loop.
            showPrompt(message: "Input Monitoring is needed to follow your clicks. Enable Jev in the Apple prompt, then send the task again.")
            return
        }
        cancelGuide(showPrompt: false)
        let newGuide = GuideSession(task: task)
        guide = newGuide
        popup.preparingGuide()
        popup.orderOut(nil)
        activateGuideTarget()
        overlay.showThinking(at: NSEvent.mouseLocation)

        // Let the previous app become frontmost before taking the first live AX
        // snapshot or screen capture. This avoids the guide pointing at Jev's
        // own task field instead of the app the person wanted help with.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.requestPlan(for: newGuide, mode: .initial)
        }
    }

    private func requestInputMonitoringIfNeeded() -> Bool {
        guard #available(macOS 10.15, *) else { return true }
        if CGPreflightListenEventAccess() {
            return true
        }
        _ = CGRequestListenEventAccess()
        return false
    }

    private func requestPlan(for session: GuideSession, mode: GuidePlanningMode) {
        guard guide?.id == session.id, !isLoadingNextStep else { return }
        if mode == .replan && session.replanCount >= 2 {
            pauseGuide("I could not find a new live control after two corrections, so the task is paused instead of looping.")
            return
        }
        if mode == .verify && session.verificationAttempts >= 2 {
            pauseGuide("I could not verify the result from the visible state. The task is paused instead of guessing that it finished.")
            return
        }

        if mode == .verify {
            session.verificationAttempts += 1
        }
        isLoadingNextStep = true
        let snapshot = captureSnapshot()
        session.currentSnapshot = snapshot
        overlay.showThinking(at: session.targetOnScreen ?? NSEvent.mouseLocation)
        popup.requestGuidePlan(
            task: session.task,
            completedCaptions: session.completedCaptions,
            verification: session.verification,
            frontmostApp: lastExternalAppName,
            snapshot: snapshot,
            mode: mode
        ) { [weak self] result in
            guard let self, self.guide?.id == session.id else { return }
            self.isLoadingNextStep = false
            switch result {
            case .success(let plan):
                self.accept(plan, for: session, mode: mode)
            case .failure(let error):
                self.failGuide(error.message)
            }
        }
    }

    private func accept(_ plan: GuidePlan, for session: GuideSession, mode: GuidePlanningMode) {
        guard guide?.id == session.id else { return }
        switch plan.planStatus {
        case .complete:
            finishGuide(session, caption: plan.cleanCompletionCaption)
        case .blocked:
            pauseGuide(plan.cleanReason ?? "No safe next action is visible in the current app.")
        case .needsAgent:
            pauseGuide(plan.cleanReason ?? "The visible state needs a judgment Jev cannot safely make.")
        case .active:
            let steps = plan.sanitizedSteps
            guard !steps.isEmpty else {
                pauseGuide("Jev did not receive a concrete next action, so it stopped instead of retrying the same request.")
                return
            }
            if mode == .replan || mode == .verify {
                session.replanCount += 1
            }
            if !plan.sanitizedVerification.isEmpty {
                session.verification = plan.sanitizedVerification
            }
            session.completionCaption = plan.cleanCompletionCaption
            session.steps = steps
            session.nextStepIndex = 0
            session.planSnapshotRevision = session.currentSnapshot?.revision
            presentNextPlannedStep(for: session)
        }
    }

    private func presentNextPlannedStep(for session: GuideSession) {
        guard guide?.id == session.id, !isLoadingNextStep else { return }
        guard session.actionCount < 15 else {
            pauseGuide("The guide reached its 15-action safety limit before it could verify the result.")
            return
        }
        guard session.nextStepIndex < session.steps.count else {
            requestPlan(for: session, mode: .verify)
            return
        }

        let step = session.steps[session.nextStepIndex]
        guard session.canPresent(step) else {
            pauseGuide("The same unresolved instruction returned twice. The task is paused instead of repeating it again.")
            return
        }

        let snapshot = captureSnapshot()
        session.currentSnapshot = snapshot
        let liveTarget = snapshot?.resolve(step)
        let fallbackTarget = canUseCoordinateFallback(step, session: session, snapshot: snapshot)
            ? step.validTarget.flatMap(screenPoint(for:))
            : nil

        if step.needsPointer, liveTarget == nil, fallbackTarget == nil {
            requestPlan(for: session, mode: .replan)
            return
        }

        session.currentStep = step
        session.targetOnScreen = liveTarget?.point ?? fallbackTarget
        session.targetBoundsOnScreen = liveTarget?.bounds
        session.currentTargetGuard = liveTarget?.guardToken
        session.currentSnapshotRevision = snapshot?.revision
        overlay.present(caption: step.trimmedCaption, at: session.targetOnScreen)

        if step.actionKind == .wait {
            scheduleAdvance(after: 0.18)
        }
    }

    private func canUseCoordinateFallback(
        _ step: GuideStep,
        session: GuideSession,
        snapshot: GuideDesktopSnapshot?
    ) -> Bool {
        guard step.validTarget != nil, session.nextStepIndex == 0 else { return false }
        guard let expected = session.planSnapshotRevision else { return true }
        return expected == snapshot?.revision
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
            advanceCurrentStep(force: true)
            return
        }

        switch step.actionKind {
        case .click:
            guard event.type == .leftMouseDown, isMouseNearCurrentTarget(event, session: session) else { return }
            scheduleAdvance(after: 0.08)
        case .type:
            guard event.type == .keyDown else { return }
            // Reset after every keypress, then move on quickly once the person
            // pauses. This keeps a phrase as one tutorial action.
            scheduleAdvance(after: 0.34)
        case .shortcut:
            guard event.type == .keyDown else { return }
            scheduleAdvance(after: 0.10)
        case .scroll:
            guard event.type == .scrollWheel else { return }
            scheduleAdvance(after: 0.12)
        case .wait, .done, .unknown:
            break
        }
    }

    private func isMouseNearCurrentTarget(_ event: NSEvent, session: GuideSession) -> Bool {
        let mouse = event.locationInWindow == .zero ? NSEvent.mouseLocation : NSEvent.mouseLocation
        if let bounds = session.targetBoundsOnScreen {
            return bounds.insetBy(dx: -52, dy: -52).contains(mouse)
        }
        guard let target = session.targetOnScreen else { return false }
        let dx = mouse.x - target.x
        let dy = mouse.y - target.y
        return dx * dx + dy * dy <= 105 * 105
    }

    private func scheduleAdvance(after delay: TimeInterval) {
        advancementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.advanceCurrentStep()
        }
        advancementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func advanceCurrentStep(force: Bool = false) {
        guard let session = guide,
              let step = session.currentStep,
              !isLoadingNextStep else { return }
        advancementWork?.cancel()
        advancementWork = nil
        isLoadingNextStep = true

        let beforeRevision = session.currentSnapshotRevision
        settleAfterInteraction(step: step, session: session) { [weak self] snapshot in
            guard let self, self.guide?.id == session.id else { return }
            self.isLoadingNextStep = false
            let stateChanged: Bool
            if let beforeRevision, let after = snapshot?.revision {
                stateChanged = beforeRevision != after
            } else {
                // Without Accessibility we cannot make a false assertion about
                // state. Continue through the bounded plan and verify at the end.
                stateChanged = true
            }

            if self.requiresObservableChange(step) && !stateChanged && !force {
                self.handleNoProgress(for: session, step: step)
                return
            }

            session.noProgressAttempts = 0
            session.recordCompletion(of: step)
            session.currentStep = nil
            session.nextStepIndex += 1
            session.currentSnapshot = snapshot
            session.targetBoundsOnScreen = nil
            session.currentTargetGuard = nil
            session.currentSnapshotRevision = snapshot?.revision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.presentNextPlannedStep(for: session)
            }
        }
    }

    private func requiresObservableChange(_ step: GuideStep) -> Bool {
        switch step.actionKind {
        case .click, .type, .scroll, .wait:
            return true
        case .shortcut, .done, .unknown:
            return false
        }
    }

    /// Mirrors arc-cua's runtime-owned settling: Jev waits just long enough for
    /// the UI to become structurally stable instead of assigning arbitrary long
    /// pauses to the model after every instruction.
    private func settleAfterInteraction(
        step: GuideStep,
        session: GuideSession,
        completion: @escaping (GuideDesktopSnapshot?) -> Void
    ) {
        let minimum: TimeInterval = step.actionKind == .type ? 0.30 : 0.12
        let timeout: TimeInterval = step.actionKind == .type ? 0.78 : 0.44
        let started = Date()
        var latest: GuideDesktopSnapshot?
        var lastRevision: String?
        var stableFrames = 0

        func poll() {
            guard self.guide?.id == session.id else { return }
            latest = self.captureSnapshot()
            if latest?.revision == lastRevision {
                stableFrames += 1
            } else {
                lastRevision = latest?.revision
                stableFrames = 0
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= minimum && (stableFrames >= 1 || elapsed >= timeout) {
                completion(latest)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: poll)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: poll)
    }

    private func handleNoProgress(for session: GuideSession, step: GuideStep) {
        session.noProgressAttempts += 1
        if session.noProgressAttempts >= 2 {
            pauseGuide("I could not confirm a visible change after two attempts. The task is paused instead of looping.")
            return
        }
        let targetName = step.normalizedTargetText ?? "that marked control"
        overlay.present(caption: "I did not see a change — try \(targetName) once more.", at: session.targetOnScreen)
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

    private func pauseGuide(_ message: String) {
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        overlay.showCompletion("Paused — \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.showPrompt(message: message)
        }
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
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberExternalApp(frontmost)
        }
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
