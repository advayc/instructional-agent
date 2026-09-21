import AppKit
import ApplicationServices
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
    private var passiveObservationWork: DispatchWorkItem?
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var canObserveGlobalInput = false
    private var globalMonitorsInstalled = false
    private let cursor = CursorDriver()
    private var isExecutingApprovedStep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(named: "Jev") ?? NSImage(named: NSImage.applicationIconName)
        installMenu()
        loadEnv()
        observeFrontmostApp()

        popup.input.target = self
        popup.input.action = #selector(send(_:))
        popup.delegate = self
        popup.onApprovalChanged = { [weak self] enabled in
            self?.approvalChanged(enabled, userInitiated: true)
        }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            popup.standardWindowButton(button)?.isHidden = false
        }
        showPrompt()
        installEventMonitors()
        if popup.autoApprovalEnabled {
            approvalChanged(true, userInitiated: false)
        }
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
        // TCC’s own accessibility alert is a helper process, not the app the
        // person was working in. Keep the prior real target so Jev never
        // labels a tutorial with this internal process name or its generic icon.
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.localizedName != "universalAccessAuthWarn" else { return }
        lastExternalApplication = app
        lastExternalAppName = app.localizedName ?? "macOS"
        popup.updateContext(lastExternalAppName, icon: app.icon)
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

        // Input Monitoring improves click-following, but Jev's visual guide
        // must never be blocked by it. When unavailable, a screen/AX watcher
        // advances only after visible progress instead of prompting again.
        ensureGlobalMonitors()
    }

    /// Re-checks Input Monitoring live and installs global monitors on demand.
    /// The launch-time check goes stale when the person grants access while
    /// Jev is running, which made approval look broken until a reopen.
    private func ensureGlobalMonitors() {
        guard !globalMonitorsInstalled else { return }
        canObserveGlobalInput = hasInputMonitoringAccess()
        guard canObserveGlobalInput else { return }

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
        globalMonitorsInstalled = true
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

    private func approvalChanged(_ enabled: Bool, userInitiated: Bool) {
        guard enabled else {
            cursor.cancel()
            isExecutingApprovedStep = false
            return
        }
        guard GuideDesktopSnapshot.accessibilityIsAvailable else {
            if userInitiated { requestHandsFreePermissions() }
            popup.setAutoApprovalEnabled(false, persist: true)
            popup.showSetupIssue("Allow Jev in Accessibility before turning on Approve for me.")
            return
        }
        // Re-check live: a grant made while Jev runs must take effect
        // without a reopen.
        ensureGlobalMonitors()
        guard canObserveGlobalInput else {
            if userInitiated { requestHandsFreePermissions() }
            popup.setAutoApprovalEnabled(false, persist: true)
            popup.showSetupIssue("Allow Jev in Input Monitoring, then tap Approve for me again so Esc can stop an approved run instantly.")
            return
        }
        popup.status.stringValue = "Approval is on — Jev will complete routine on-screen steps for your next request."
    }

    /// The user explicitly pressed Approve for me, so it is appropriate to ask
    /// macOS for the two permissions that make the stop key and real input
    /// possible. The app never raises these dialogs merely by launching.
    private func requestHandsFreePermissions() {
        if !GuideDesktopSnapshot.accessibilityIsAvailable {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if #available(macOS 10.15, *), !hasInputMonitoringAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    private func isManualAdvance(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 124 && event.modifierFlags.contains(.option)
    }

    @objc func send(_ sender: NSTextField) {
        let task = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        if performNativeAction(task) { return }
        if performComputerUse(task) { return }
        // Anything naming a concrete app gets action or a visual guide —
        // never a prose how-to.
        if guideTargetAppName(for: task) != nil { startGuide(task: task); return }
        if performDirectAnswer(task) { return }
        startGuide(task: task)
    }

    /// General questions get a text answer in the popup instead of a
    /// click-guide inside whatever app happens to be frontmost.
    private func performDirectAnswer(_ task: String) -> Bool {
        guard isGeneralQuestion(task) else { return false }
        popup.preparingAnswer()
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        popup.requestAnswer(
            task: task,
            frontmostApp: lastExternalAppName,
            progress: { [weak self] text in
                self?.popup.showAnswerProgress(text)
            }
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.popup.showAnswer(text)
            case .failure(let error):
                self.popup.showSetupIssue(error.message)
            }
            self.popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            self.popup.makeKey()
            self.popup.makeFirstResponder(self.popup.input)
        }
        return true
    }

    private func isGeneralQuestion(_ task: String) -> Bool {
        let lower = task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let actionWords = ["click", "open", "turn on", "turn off", "enable", "disable",
                           "set ", "change ", "switch ", "timer", "alarm", "remind",
                           "mute", "unmute", "volume", "dark mode", "light mode",
                           "install", "download", "create file", "delete ", "move ",
                           "play", "search", "find ", "press", "song", "spotify", "pause",
                           "text ", "message ", "send ", "reply "]
        if actionWords.contains(where: { lower.contains($0) }) { return false }
        if lower.hasSuffix("?") { return true }
        let starters = ["what ", "what's ", "whats ", "who ", "why ", "how ", "when ", "where ",
                        "explain ", "define ", "summarize ", "summarise ", "tell me ", "write ",
                        "draft ", "compose ", "calculate ", "convert ", "translate "]
        if starters.contains(where: { lower.hasPrefix($0) }) { return true }
        // No actionable macOS verb → treat as chat, not a click-guide.
        if !actionWords.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    /// Real execution via arc-cua: "play SICKO MODE by Travis Scott on Spotify".
    /// Falls through to the visual guide when computer-use isn't set up.
    private func performComputerUse(_ task: String) -> Bool {
        guard let music = parseMusicTask(task) else { return false }
        guard arcCuaDir() != nil, typesafeKey() != nil else { return false }
        popup.preparingAction()
        popup.status.stringValue = "Playing \(music.title) on Spotify — hands off for a moment…"
        // Focus Spotify first so the run doesn't observe the wrong app.
        NSWorkspace.shared.launchApplication("Spotify")
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let message = self?.runComputerUse(music: music) ?? "Computer-use failed to start."
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
        return true
    }

    private struct MusicRequest { let title: String; let artist: String? }

    private func parseMusicTask(_ task: String) -> MusicRequest? {
        let lower = task.lowercased()
        guard lower.contains("spotif") || lower.contains("music") else { return nil }
        guard lower.contains("play") || lower.contains("search") || lower.contains("listen") else { return nil }
        var title: String?
        for pattern in ["\"([^\"]+)\"", "“([^”]+)”", "‘([^’]+)’"] {
            if let r = task.range(of: pattern, options: .regularExpression) {
                var t = String(task[r])
                t.removeFirst(); t.removeLast()
                title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if title == nil,
           let r = task.range(of: "(play|search for|listen to) (.+?) by ", options: [.regularExpression, .caseInsensitive]) {
            title = String(task[r]).components(separatedBy: " by ").first?
                .replacingOccurrences(of: "^(play|search for|listen to) ", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if title == nil {
            // "play SICKO MODE on Spotify" — no quotes, no artist. Strip the
            // verb and app name and treat the rest as the title.
            var rest = lower
            for verb in ["play ", "search for ", "search ", "listen to ", "listen "] {
                if let r = rest.range(of: verb) { rest = String(rest[r.upperBound...]); break }
            }
            for suffix in [" on spotify", " in spotify", " using spotify", " on music", " in music"] {
                if let r = rest.range(of: suffix) { rest = String(rest[..<r.lowerBound]) }
            }
            if let r = rest.range(of: " by ") { rest = String(rest[..<r.lowerBound]) }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty, rest.count < 80 { title = rest }
        }
        var artist: String?
        if let r = task.range(of: " by (.+?)( →|\u{2192}|\\.| on spotify|$)", options: [.regularExpression, .caseInsensitive]) {
            artist = String(task[r].dropFirst(4))
                .replacingOccurrences(of: "→", with: "")
                .replacingOccurrences(of: " on spotify", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        }
        guard let title, !title.isEmpty else { return nil }
        return MusicRequest(title: title, artist: artist?.isEmpty == true ? nil : artist)
    }

    private func arcCuaDir() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/jev/arc-cua")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(".venv/bin/python").path) ? dir : nil
    }

    private func typesafeKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !k.isEmpty { return k }
        // GUI apps don't source ~/.zshrc; read the export directly.
        guard let text = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("export TYPESAFE_API_KEY=") || t.hasPrefix("TYPESAFE_API_KEY=") else { continue }
            let v = t.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            let clean = v.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'")))
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private func runComputerUse(music: MusicRequest) -> String {
        guard let dir = arcCuaDir(), let key = typesafeKey() else {
            return "Computer-use isn't set up."
        }
        let query = ([music.title] + (music.artist.map { [$0] } ?? [])).joined(separator: " ")
        let byArtist = music.artist.map { " (artist \($0))" } ?? ""
        var args = ["examples/do.py",
                    "In Spotify: click Search, type the search query, then in the Songs results double-click the row titled '\(music.title)'\(byArtist) so it starts playing.",
                    "--app", "Spotify",
                    "--verify", "The Spotify now-playing bar shows '\(music.title)' as the current track.",
                    "--input", "search_query=\(query)",
                    "--input", "song=\(music.title)"]
        if let artist = music.artist {
            args += ["--input", "artist=\(artist)",
                     "--verify", "The Spotify now-playing bar shows artist '\(artist)'."]
        }
        args += ["--constraint", "Do not open the artist profile page.",
                 "--constraint", "Do not play a Top Song from an artist page — only the '\(music.title)' track row from search results.",
                 "--constraint", "Do not modify the library.",
                 "--constraint", "Do not add anything to a playlist.",
                 "--max-actions", "20",
                 "--no-wait"]
        let proc = Process()
        proc.executableURL = dir.appendingPathComponent(".venv/bin/python")
        proc.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = "src"
        environment["TYPESAFE_API_KEY"] = key
        proc.environment = environment
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            return "Could not start computer-use (\(error.localizedDescription))."
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Ground truth comes from Spotify itself, never the agent's judgment:
        // it previously played the artist's top song and called it done.
        if let now = spotifyNowPlaying(), nowPlaying(now, matches: music) {
            return "Playing \(now) on Spotify."
        }
        // Nothing playing: the found row may be selected but paused, so
        // Return starts it. Skip this when the wrong song is already playing.
        if spotifyNowPlaying() == nil {
            pressReturnForSpotify()
            if let now = spotifyNowPlaying(), nowPlaying(now, matches: music) {
                return "Playing \(now) on Spotify."
            }
        }
        if let now = spotifyNowPlaying() {
            return "Spotify is playing '\(now)' instead of '\(music.title)'. Say the exact title again and I'll retry."
        }
        if out.contains("SUBTASK_COMPLETE") {
            return "The run claimed success but Spotify shows nothing playing. Say the exact title again and I'll retry."
        }
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("status:") }) {
            let playing = spotifyNowPlaying().map { " Spotify shows '\($0)' playing." } ?? ""
            return "Spotify run ended — \(line).\(playing)"
        }
        return "Spotify run finished (exit \(proc.terminationStatus))."
    }

    /// The selected row often sits paused; Return starts playback.
    private func pressReturnForSpotify() {
        NSWorkspace.shared.launchApplication("Spotify")
        Thread.sleep(forTimeInterval: 0.5)
        NSAppleScript(source: "tell application \"System Events\" to keystroke return")?.executeAndReturnError(nil)
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// "Title — Artist" matches when the track contains the requested title
    /// and, when an artist was given, the artist as well.
    private func nowPlaying(_ now: String, matches music: MusicRequest) -> Bool {
        let text = now.lowercased()
        guard text.contains(music.title.lowercased()) else { return false }
        guard let artist = music.artist else { return true }
        return text.contains(artist.lowercased())
    }

    /// Deterministic check via AppleScript: "Title — Artist" or nil.
    private func spotifyNowPlaying() -> String? {
        guard let script = NSAppleScript(source:
            "tell application \"Spotify\" to get (name of current track) & \" — \" & (artist of current track)") else {
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Fast path for safe, reversible macOS actions. Unknown requests keep
    /// using the visual guide instead of allowing model-generated shell code.
    private func performNativeAction(_ task: String) -> Bool {
        let normalized = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.contains("do not"), !normalized.contains("don t") else { return false }

        let script: String
        let completion: String
        if normalized.contains("dark mode") {
            let enable = !normalized.contains("turn off dark mode") && !normalized.contains("disable dark mode")
            script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enable)"
            completion = enable ? "Dark mode is on." : "Light mode is on."
        } else if normalized.contains("light mode") {
            let dark = normalized.contains("turn off light mode") || normalized.contains("disable light mode")
            script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
            completion = dark ? "Dark mode is on." : "Light mode is on."
        } else if normalized == "unmute" || normalized.contains("unmute volume") || normalized.contains("unmute sound") {
            script = "set volume without output muted"
            completion = "Sound is unmuted."
        } else if normalized == "mute" || normalized.contains("mute volume") || normalized.contains("mute sound") {
            script = "set volume with output muted"
            completion = "Sound is muted."
        } else if let level = requestedVolume(in: normalized) {
            script = "set volume output volume \(level) without output muted"
            completion = "Volume is \(level)%."
        } else if let seconds = requestedDuration(in: task) {
            startNativeTimer(seconds: seconds, original: task)
            return true
        } else if let appName = requestedOpenApp(in: task) {
            openMacApp(named: appName, original: task)
            return true
        } else {
            return false
        }

        popup.preparingAction()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var error: NSDictionary?
            let succeeded = NSAppleScript(source: script)?.executeAndReturnError(&error) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    self.popup.reset(message: completion)
                    self.overlay.showCompletion(completion)
                } else {
                    let reason = error?[NSAppleScript.errorMessage] as? String ?? "macOS rejected the action."
                    self.popup.showSetupIssue(reason)
                }
                self.popup.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                self.popup.makeKey()
                self.popup.makeFirstResponder(self.popup.input)
            }
        }
        return true
    }

    private func requestedVolume(in task: String) -> Int? {
        guard task.contains("volume"),
              let match = task.range(of: #"\b\d{1,3}\b"#, options: .regularExpression),
              let level = Int(task[match]) else { return nil }
        return min(100, level)
    }

    /// "set a 5 min timer", "timer 10 seconds", "5 minute countdown" → seconds.
    private func requestedDuration(in task: String) -> TimeInterval? {
        let lower = task.lowercased()
        guard lower.contains("timer") || lower.contains("countdown") || lower.contains("alarm in")
            || lower.contains("alarm for") || lower.contains("set an alarm") || lower.contains("set alarm") else {
            return nil
        }
        guard let numMatch = lower.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        guard let value = Double(lower[numMatch]) else { return nil }
        let multiplier: Double
        if lower.contains("hour") || lower.contains(" hr") { multiplier = 3600 }
        else if lower.contains("min") { multiplier = 60 }
        else if lower.contains("sec") { multiplier = 1 }
        else { multiplier = 60 } // "timer 5" means 5 minutes
        let seconds = value * multiplier
        guard seconds >= 1, seconds <= 12 * 3600 else { return nil }
        return seconds
    }

    private func startNativeTimer(seconds: TimeInterval, original: String) {
        popup.preparingAction()
        let label: String
        if seconds >= 3600 {
            label = String(format: "Timer for %.1f hr started.", seconds / 3600)
        } else if seconds >= 60 {
            label = String(format: "Timer for %.0f min started.", seconds / 60)
        } else {
            label = String(format: "Timer for %.0f sec started.", seconds)
        }
        popup.reset(message: label)
        overlay.showCompletion(label)
        popup.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            NSSound.beep()
            let done = "Done — your \(Int(seconds / 60) > 0 ? "\(Int(seconds / 60))-minute " : "")timer finished."
            self.overlay.showCompletion(done)
            self.popup.reset(message: done)
            self.popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// "open Safari", "launch Notes", "start Spotify" → app name.
    private func requestedOpenApp(in task: String) -> String? {
        let lower = task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in ["open ", "launch ", "start ", "quit "] {
            guard lower.hasPrefix(verb) else { continue }
            var name = String(lower.dropFirst(verb.count))
            for filler in [" the ", " app", " application"] { name = name.replacingOccurrences(of: filler, with: " ") }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 40 else { return nil }
            if lower.hasPrefix("quit ") { return nil } // quitting stays a guided/safe op for now
            return name
        }
        return nil
    }

    private func openMacApp(named name: String, original: String) {
        popup.preparingAction()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let workspace = NSWorkspace.shared
            var opened = false
            if let running = workspace.runningApplications.first(where: {
                $0.localizedName?.lowercased() == name.lowercased()
            }) {
                opened = running.activate(options: [])
            } else {
                // `open -a` resolves by display name ("Safari", "System Settings", "Spotify").
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", name]
                opened = (try? proc.run()) != nil
                if opened { proc.waitUntilExit(); opened = proc.terminationStatus == 0 }
            }
            let message = opened ? "Opened \(name)." : "Could not find \(name). Try the exact app name."
            DispatchQueue.main.async {
                guard let self else { return }
                if opened {
                    self.popup.reset(message: message)
                    self.overlay.showCompletion(message)
                } else {
                    self.popup.showSetupIssue(message)
                }
                self.popup.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                self.popup.makeKey()
                self.popup.makeFirstResponder(self.popup.input)
            }
        }
    }

    /// Which macOS app should this task guide in? nil = stay in current app.
    /// Prevents system tasks (timer, settings, reminders…) from planning
    /// clicks inside an unrelated frontmost app like VSCode.
    private func guideTargetAppName(for task: String) -> String? {
        let lower = task.lowercased()
        // Explicit mention wins: "in Safari", "using Notes", "open Clock and…".
        let knownApps = ["safari", "chrome", "firefox", "arc", "mail", "calendar",
                         "reminders", "notes", "messages", "facetime", "photos",
                         "music", "spotify", "clock", "finder", "terminal",
                         "system settings", "settings", "app store", "preview",
                         "numbers", "pages", "keynote", "xcode", "slack", "discord"]
        for app in knownApps {
            if lower.contains(app) { return app == "settings" ? "System Settings" : app.capitalized }
        }
        if lower.contains("alarm") || lower.contains("stopwatch") { return "Clock" }
        if lower.contains("reminder") || lower.contains("todo ") || lower.contains("to-do") { return "Reminders" }
        if lower.contains("note ") || lower.contains("jot ") { return "Notes" }
        if lower.contains("email") || lower.contains("inbox") { return "Mail" }
        if lower.hasPrefix("text ") || lower.contains(" text ")
            || lower.hasPrefix("message ") || lower.contains(" message ")
            || lower.hasPrefix("send ") || lower.contains(" send ")
            || lower.hasPrefix("reply ") || lower.contains(" reply ") { return "Messages" }
        if lower.contains("event") || lower.contains("meeting") || lower.contains("schedule ") { return "Calendar" }
        if lower.contains("wifi") || lower.contains("wi-fi") || lower.contains("bluetooth")
            || lower.contains("wallpaper") || lower.contains("screensaver")
            || lower.contains("do not disturb") || lower.contains("focus mode")
            || lower.contains("apple id") || lower.contains("icloud")
            || lower.contains("battery") || lower.contains("display settings")
            || lower.contains("sound settings") { return "System Settings" }
        return nil
    }

    private func launchGuideApp(named name: String, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            if NSWorkspace.shared.runningApplications.contains(where: {
                $0.localizedName?.lowercased() == name.lowercased()
            }) {
                NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.lowercased() == name.lowercased()
                })?.activate(options: [])
            } else {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", name]
                try? proc.run()
                proc.waitUntilExit()
            }
            // Give the routed app time to become frontmost before snapshotting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: done)
        }
    }

    private func startGuide(task: String) {
        // Do this before hiding the card. If macOS has associated the Privacy
        // & Security switch with an older Jev signature, the old behavior hid
        // the only UI and made a denied request look like the app had quit.
        guard popup.canReadVisualGuideState else {
            popup.showSetupIssue("Jev cannot see this Mac from the current install. Re-enable this Jev in Privacy & Security, then try again.")
            popup.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            popup.makeKey()
            popup.makeFirstResponder(popup.input)
            return
        }

        cancelGuide(showPrompt: false)
        let newGuide = GuideSession(task: task)
        guide = newGuide
        popup.preparingGuide()
        popup.orderOut(nil)

        // Route to the right app instead of guiding inside whatever happens
        // to be frontmost (e.g. a timer must not plan clicks inside VSCode).
        if let routed = guideTargetAppName(for: task),
           routed.lowercased() != lastExternalAppName.lowercased() {
            overlay.showThinking(at: NSEvent.mouseLocation)
            launchGuideApp(named: routed) { [weak self] in
                guard let self, self.guide?.id == newGuide.id else { return }
                if let front = NSWorkspace.shared.frontmostApplication {
                    self.rememberExternalApp(front)
                }
                self.requestPlan(for: newGuide, mode: .initial)
            }
            return
        }

        activateGuideTarget()
        overlay.showThinking(at: NSEvent.mouseLocation)

        // Let the previous app become frontmost before taking the first live AX
        // snapshot or screen capture. This avoids the guide pointing at Jev's
        // own task field instead of the app the person wanted help with.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.requestPlan(for: newGuide, mode: .initial)
        }
    }

    private func hasInputMonitoringAccess() -> Bool {
        guard #available(macOS 10.15, *) else { return true }
        return CGPreflightListenEventAccess()
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
        if let expected = session.targetApplicationIdentifier,
           lastExternalApplication?.bundleIdentifier != expected {
            pauseGuide("The target app changed while Jev was working, so it stopped before acting in the wrong app.")
            return
        }
        if session.targetApplicationIdentifier == nil {
            session.targetApplicationIdentifier = lastExternalApplication?.bundleIdentifier
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
            mode: mode,
            approvalEnabled: popup.autoApprovalEnabled
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
            if mode == .replan {
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
        let stepNumber = session.nextStepIndex + 1
        let activityCaption = "\(stepNumber)/\(session.steps.count) · \(step.trimmedCaption)"
        overlay.present(caption: activityCaption, at: session.targetOnScreen)
        popup.showGuideProgress(
            step: step,
            index: stepNumber,
            total: session.steps.count,
            isHandsFree: popup.autoApprovalEnabled
        )

        if popup.autoApprovalEnabled {
            runApprovedStep(for: session)
            return
        }

        if step.actionKind == .wait {
            scheduleAdvance(after: 0.12)
        } else if !canObserveGlobalInput {
            observeVisibleProgress(for: session, baseline: snapshot)
        }
    }

    /// Executes one already-presented step. The model never supplies an
    /// executable selector: pointer actions are resolved once more from the
    /// current local AX tree, and coordinate-only screenshot targets remain
    /// visual-guide-only.
    private func runApprovedStep(for session: GuideSession) {
        guard guide?.id == session.id,
              let step = session.currentStep,
              popup.autoApprovalEnabled,
              !isLoadingNextStep,
              !isExecutingApprovedStep else { return }

        guard canObserveGlobalInput else {
            pauseGuide("Input Monitoring is required for hands-free work so Esc can stop it immediately.")
            return
        }
        if let expected = session.targetApplicationIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expected {
            pauseGuide("The target app is no longer in front, so I stopped before acting in the wrong app.")
            return
        }
        if let reason = AutoApprovalPolicy.blockedReason(for: step, task: session.task) {
            pauseGuide(reason)
            return
        }

        let freshSnapshot = captureSnapshot()
        let resolvedTarget: GuideResolvedTarget?
        switch step.actionKind {
        case .click, .type:
            guard let target = freshSnapshot?.resolve(step) else {
                requestPlan(for: session, mode: .replan)
                return
            }
            resolvedTarget = target
        case .scroll:
            resolvedTarget = freshSnapshot?.resolve(step)
        case .shortcut, .wait, .done, .unknown:
            resolvedTarget = nil
        }

        if let resolvedTarget {
            session.currentSnapshot = freshSnapshot
            session.targetOnScreen = resolvedTarget.point
            session.targetBoundsOnScreen = resolvedTarget.bounds
            session.currentTargetGuard = resolvedTarget.guardToken
            session.currentSnapshotRevision = freshSnapshot?.revision
            overlay.present(
                caption: "Jev · \(session.nextStepIndex + 1)/\(session.steps.count) · \(step.trimmedCaption)",
                at: resolvedTarget.point
            )
        }

        isExecutingApprovedStep = true
        cursor.perform(step, target: resolvedTarget) { [weak self] (result: ApprovedActionResult) in
            guard let self, self.guide?.id == session.id else { return }
            self.isExecutingApprovedStep = false
            switch result {
            case .success:
                self.advanceCurrentStep()
            case .blocked(let reason):
                self.pauseGuide(reason)
            case .failed(let reason):
                if session.replanCount < 2 {
                    self.popup.status.stringValue = "Checking the current screen again…"
                    self.requestPlan(for: session, mode: .replan)
                } else {
                    self.pauseGuide(reason)
                }
            }
        }
    }

    /// Fallback for the intentionally permission-light virtual cursor. With
    /// no Input Monitoring grant, poll only the local AX tree (or a compact
    /// screenshot fingerprint) until the person changes the target app.
    private func observeVisibleProgress(for session: GuideSession, baseline: GuideDesktopSnapshot?) {
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
        let started = Date()

        if let baselineRevision = baseline?.revision {
            pollAccessibilityProgress(for: session, baseline: baselineRevision, started: started)
        } else {
            popup.captureVisualFingerprint { [weak self] fingerprint in
                DispatchQueue.main.async {
                    guard let self,
                          self.guide?.id == session.id,
                          self.guide?.currentStep != nil,
                          let fingerprint else { return }
                    self.pollVisualProgress(for: session, baseline: fingerprint, started: started)
                }
            }
        }
    }

    private func pollAccessibilityProgress(for session: GuideSession, baseline: String, started: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.guide?.id == session.id,
                  self.guide?.currentStep != nil else { return }
            if let revision = self.captureSnapshot()?.revision, revision != baseline {
                self.advanceCurrentStep(force: true)
                return
            }
            self.continuePassiveObservation(for: session, started: started) {
                self.pollAccessibilityProgress(for: session, baseline: baseline, started: started)
            }
        }
        passiveObservationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func pollVisualProgress(for session: GuideSession, baseline: String, started: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.guide?.id == session.id,
                  self.guide?.currentStep != nil else { return }
            self.popup.captureVisualFingerprint { [weak self] fingerprint in
                DispatchQueue.main.async {
                    guard let self,
                          self.guide?.id == session.id,
                          self.guide?.currentStep != nil else { return }
                    if let fingerprint, fingerprint != baseline {
                        self.advanceCurrentStep(force: true)
                        return
                    }
                    self.continuePassiveObservation(for: session, started: started) {
                        self.pollVisualProgress(for: session, baseline: baseline, started: started)
                    }
                }
            }
        }
        passiveObservationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func continuePassiveObservation(
        for session: GuideSession,
        started: Date,
        next: @escaping () -> Void
    ) {
        guard Date().timeIntervalSince(started) < 40 else {
            pauseGuide("I could not see a change after 40 seconds. The cursor is still usable, but enable Input Monitoring and reopen Jev if you want it to follow each click automatically.")
            return
        }
        guard guide?.id == session.id, session.currentStep != nil else { return }
        next()
    }

    private func canUseCoordinateFallback(
        _ step: GuideStep,
        session: GuideSession,
        snapshot: GuideDesktopSnapshot?
    ) -> Bool {
        guard step.validTarget != nil else { return false }
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
              let step = session.currentStep else { return }

        // When Jev has keyboard focus in another app, Input Monitoring gives
        // the person an immediate system-wide stop key for a hands-free run.
        if event.type == .keyDown, event.keyCode == 53, isExecutingApprovedStep {
            cancelGuide(showPrompt: true)
            return
        }
        guard !isLoadingNextStep, !isExecutingApprovedStep else { return }

        if isManualAdvance(event) {
            advanceCurrentStep(force: true)
            return
        }

        switch step.actionKind {
        case .click:
            guard event.type == .leftMouseDown, isMouseNearCurrentTarget(event, session: session) else { return }
            scheduleAdvance(after: 0.04)
        case .type:
            guard event.type == .keyDown else { return }
            // Reset after every keypress, then move on quickly once the person
            // pauses. This keeps a phrase as one tutorial action.
            scheduleAdvance(after: 0.22)
        case .shortcut:
            guard event.type == .keyDown else { return }
            scheduleAdvance(after: 0.06)
        case .scroll:
            guard event.type == .scrollWheel else { return }
            scheduleAdvance(after: 0.08)
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
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
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
        let minimum: TimeInterval = step.actionKind == .type ? 0.18 : 0.06
        let timeout: TimeInterval = step.actionKind == .type ? 0.48 : 0.26
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: poll)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: poll)
    }

    private func handleNoProgress(for session: GuideSession, step: GuideStep) {
        session.noProgressAttempts += 1
        if session.noProgressAttempts >= 2 {
            pauseGuide("I could not confirm a visible change after two attempts. The task is paused instead of looping.")
            return
        }
        if popup.autoApprovalEnabled {
            popup.status.stringValue = "I did not see a change — retrying that approved step once."
            overlay.present(caption: "No visible change — retrying once.", at: session.targetOnScreen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.runApprovedStep(for: session)
            }
            return
        }
        let targetName = step.normalizedTargetText ?? "that marked control"
        overlay.present(caption: "I did not see a change — try \(targetName) once more.", at: session.targetOnScreen)
    }

    private func finishGuide(_ session: GuideSession, caption: String) {
        guard guide?.id == session.id else { return }
        cursor.cancel()
        isExecutingApprovedStep = false
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
        overlay.showCompletion(caption)
        popup.reset()
    }

    private func pauseGuide(_ message: String) {
        cursor.cancel()
        isExecutingApprovedStep = false
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
        overlay.showCompletion("Paused — \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.showPrompt(message: message)
        }
    }

    private func failGuide(_ message: String) {
        cursor.cancel()
        isExecutingApprovedStep = false
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
        overlay.dismiss()
        showPrompt(message: message)
    }

    private func cancelGuide(showPrompt: Bool) {
        cursor.cancel()
        isExecutingApprovedStep = false
        guide = nil
        isLoadingNextStep = false
        advancementWork?.cancel()
        advancementWork = nil
        passiveObservationWork?.cancel()
        passiveObservationWork = nil
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
        popup.updateContext(lastExternalAppName, icon: lastExternalApplication?.icon)
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
