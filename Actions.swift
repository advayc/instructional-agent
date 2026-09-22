import AppKit
import ApplicationServices
import Foundation

/// One confirmed thing Jev can do. Local parsers build these in microseconds;
/// the LLM fallback may only pick from the same allowlisted tools.
struct MacCommand {
    let summary: String
    let run: () -> String
}

enum PendingCommand {
    case action(MacCommand)
    case timer(seconds: TimeInterval, label: String)

    var summary: String {
        switch self {
        case .action(let cmd): return cmd.summary
        case .timer(_, let label): return label
        }
    }
}

enum Actions {
    // MARK: - Entry

    /// Fast local parse. Nil = no confident match, caller may try LLM or chat.
    static func parseLocal(_ raw: String) -> PendingCommand? {
        let task = normalize(raw)
        let lower = task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        if lower == "do not" || lower.contains("do not ") { return nil }

        if let cmd = parseTerminal(lower, original: task) { return .action(cmd) }
        if let cmd = parseSpotify(lower, original: task) { return .action(cmd) }
        if let cmd = parseApp(lower, original: task) { return .action(cmd) }
        if let cmd = Web.parse(lower, original: task) { return cmd }
        if let cmd = parseChrome(lower, original: task) { return .action(cmd) }
        if let cmd = parseSystem(lower, original: task) { return cmd }
        return nil
    }

    // MARK: - Input normalize ("can you open excel please" → "open excel")

    static func normalize(_ task: String) -> String {
        var s = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = ["please ", "can you ", "could you ", "would you ", "will you ",
                       "hey jev ", "hey ", "jev ", "ok jev "]
        let first = s.lowercased()
        for prefix in leading where first.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        var l = s.lowercased()
        for suffix in [" please", " for me", " thanks", " thank you"] where l.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            l = s.lowercased()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Apps

    static let aliases: [String: String] = [
        "excel": "Microsoft Excel", "word": "Microsoft Word", "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook", "teams": "Microsoft Teams",
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "spotify": "Spotify", "terminal": "Terminal",
        "iterm": "iTerm", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "finder": "Finder", "notes": "Notes", "calendar": "Calendar", "mail": "Mail",
        "messages": "Messages", "facetime": "FaceTime", "photos": "Photos", "music": "Music",
        "clock": "Clock", "reminders": "Reminders", "settings": "System Settings",
        "system settings": "System Settings", "system preferences": "System Settings",
        "app store": "App Store", "preview": "Preview", "numbers": "Numbers",
        "pages": "Pages", "keynote": "Keynote", "xcode": "Xcode", "slack": "Slack",
        "discord": "Discord", "zoom": "zoom.us", "safari": "Safari", "firefox": "Firefox",
        "arc": "Arc", "notion": "Notion", "obsidian": "Obsidian",
    ]

    private static func parseApp(_ lower: String, original: String) -> MacCommand? {
        for verb in ["open ", "launch ", "start "] {
            guard lower.hasPrefix(verb) else { continue }
            var name = String(lower.dropFirst(verb.count))
            for filler in [" the ", " app", " application"] { name = name.replacingOccurrences(of: filler, with: " ") }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 40, !name.contains("."),
                  !name.contains("bookmark"), !name.contains("tab"), !name.contains("terminal") else { return nil }
            let resolved = aliases[name] ?? name
            // Not installed and not running = not an app. Let the web layer try.
            guard aliases[name] != nil || isRunningApp(named: resolved) || knownApps().contains(resolved.lowercased()) else { return nil }
            return MacCommand(summary: "Open \(resolved)") { openApp(named: resolved) }
        }
        if lower.hasPrefix("quit ") {
            let name = String(lower.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 40 else { return nil }
            let resolved = aliases[name] ?? name
            guard aliases[name] != nil || isRunningApp(named: resolved) || knownApps().contains(resolved.lowercased()) else { return nil }
            return MacCommand(summary: "Quit \(resolved)") { quitApp(named: resolved) }
        }
        return nil
    }

    static func isRunningApp(named name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased() == name.lowercased()
        }
    }

    static var appIndex: Set<String>?
    static func knownApps() -> Set<String> {
        if let cached = appIndex { return cached }
        var s = Set<String>()
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                if item.hasSuffix(".app") {
                    s.insert(String(item.dropLast(4)).lowercased())
                } else if item == "Utilities",
                          let utils = try? FileManager.default.contentsOfDirectory(atPath: dir + "/Utilities") {
                    for u in utils where u.hasSuffix(".app") {
                        s.insert(String(u.dropLast(4)).lowercased())
                    }
                }
            }
        }
        appIndex = s
        return s
    }

    static func openApp(named name: String) -> String {
        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) {
            return running.activate(options: []) ? "Opened \(name)." : "Could not focus \(name)."
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", name]
        guard (try? proc.run()) != nil else { return "Could not find \(name)." }
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? "Opened \(name)." : "Could not find \(name). Try the exact app name."
    }

    static func quitApp(named name: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) {
            return running.terminate() ? "Quit \(name)." : "Could not quit \(name)."
        }
        return "\(name) is not running."
    }

    // MARK: - Terminal

    private static func parseTerminal(_ lower: String, original: String) -> MacCommand? {
        guard lower.contains("terminal") || lower.contains("iterm") else { return nil }
        let app = lower.contains("iterm") ? "iTerm" : "Terminal"
        // "open a new terminal with opencode running" / "terminal run X" / "open terminal"
        var command: String?
        for marker in [" with ", " running ", " run ", " execute "] {
            if let r = lower.range(of: marker) {
                let rest = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { command = rest }
                break
            }
        }
        if command == nil, let r = lower.range(of: "terminal ") {
            let rest = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty, !rest.hasPrefix("with ") { command = rest }
        }
        if let command, command.count < 300 {
            var clean = command.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
            // "with opencode running" means run opencode.
            if clean.hasSuffix(" running") { clean = String(clean.dropLast(8)) }
            return MacCommand(summary: "Open \(app), run: \(clean)") {
                openTerminal(app: app, command: clean)
            }
        }
        guard lower.contains("open") || lower.contains("new") || lower == "terminal" else { return nil }
        return MacCommand(summary: "Open a new \(app) window") { openTerminal(app: app, command: nil) }
    }

    static func openTerminal(app: String, command: String?) -> String {
        let script: String
        if let command {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = "tell application \"\(app)\" to do script \"\(escaped)\""
        } else {
            script = "tell application \"\(app)\" to do script \"\""
        }
        let (ok, err) = runAppleScript(script)
        NSWorkspace.shared.launchApplication(app)
        if ok { return command.map { "Terminal open, running: \($0)." } ?? "New Terminal window open." }
        return err ?? "Could not open \(app)."
    }

    // MARK: - Spotify (no vision, no python: URI search + keystrokes + state check)

    private static func parseSpotify(_ lower: String, original: String) -> MacCommand? {
        let mentions = lower.contains("spotif") || lower.contains("music") || lower.contains("song")
        if lower.contains("pause") && (mentions || lower.contains("pause the")) {
            return MacCommand(summary: "Pause Spotify") {
                runAppleScript("tell application \"Spotify\" to pause").0 ? "Spotify paused." : "Spotify is not running."
            }
        }
        if (lower.contains("resume") || lower.contains("unpause") || lower == "play") && mentions {
            return MacCommand(summary: "Resume Spotify") {
                runAppleScript("tell application \"Spotify\" to play").0 ? "Spotify playing." : "Spotify is not running."
            }
        }
        if mentions, lower.contains("next") && (lower.contains("song") || lower.contains("track")) {
            return MacCommand(summary: "Next track on Spotify") {
                runAppleScript("tell application \"Spotify\" to next track").0 ? "Skipped to next track." : "Spotify is not running."
            }
        }
        if mentions, lower.contains("previous") || lower.contains("last song") || lower.contains("go back") {
            return MacCommand(summary: "Previous track on Spotify") {
                runAppleScript("tell application \"Spotify\" to previous track").0 ? "Back to previous track." : "Spotify is not running."
            }
        }
        guard mentions, lower.contains("play") || lower.contains("search") || lower.contains("listen") else { return nil }
        guard let req = spotifyQuery(from: original) else { return nil }
        let byArtist = req.artist.map { " by \($0)" } ?? ""
        return MacCommand(summary: "Play \"\(req.title)\"\(byArtist) on Spotify") {
            spotifyPlay(title: req.title, artist: req.artist)
        }
    }

    /// Title plus optional artist. "Stand By Me" keeps working: the matcher
    /// checks words against the row, not the literal " by " split.
    static func spotifyQuery(from task: String) -> (title: String, artist: String?)? {
        for pattern in ["\"([^\"]+)\"", "“([^”]+)”"] {
            if let r = task.range(of: pattern, options: .regularExpression) {
                var t = String(task[r]); t.removeFirst(); t.removeLast()
                let title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                var artist: String?
                let after = String(task[r.upperBound...])
                if let br = after.range(of: " by ", options: .caseInsensitive) {
                    var a = String(after[br.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
                    for suffix in [" on spotify", " in spotify", " using spotify", " on music", " in music"] {
                        if let sr = a.range(of: suffix, options: .caseInsensitive) { a = String(a[..<sr.lowerBound]) }
                    }
                    a = a.trimmingCharacters(in: .whitespacesAndNewlines)
                    if a.count >= 3, a.count < 60 { artist = a }
                }
                return (title, artist)
            }
        }
        var rest = task
        for verb in ["play ", "search for ", "search ", "listen to ", "listen "] {
            if let r = rest.range(of: verb, options: .caseInsensitive) { rest = String(rest[r.upperBound...]); break }
        }
        for suffix in [" on spotify", " in spotify", " using spotify", " on music", " in music"] {
            if let r = rest.range(of: suffix, options: .caseInsensitive) { rest = String(rest[..<r.lowerBound]) }
        }
        var clean = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !clean.isEmpty, clean.count < 80 else { return nil }
        var artist: String?
        if let br = clean.range(of: " by ", options: .caseInsensitive) {
            let a = String(clean[br.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Single short words ("Stand By Me") are part of the title, not an artist.
            if a.count >= 3, a.count < 60 {
                artist = a
                clean = String(clean[..<br.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !clean.isEmpty else { return nil }
        return (clean, artist)
    }

    /// Search, then double-click the matching result row via Accessibility,
    /// verified against Spotify's own player state. Keystrokes are last resort.
    static func spotifyPlay(title: String, artist: String?) -> String {
        let searchText = ([title] + (artist.map { [$0] } ?? [])).joined(separator: " ")
        guard let encoded = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "spotify:search:\(encoded)") else {
            return "Could not search Spotify."
        }
        NSWorkspace.shared.open(url)
        if let spotify = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.spotify.client"
        }) {
            spotify.activate(options: [])
        } else {
            NSWorkspace.shared.launchApplication("Spotify")
        }
        Thread.sleep(forTimeInterval: 1.6)
        for row in spotifyCandidates(title: title, artist: artist) {
            guard axDoubleClick(row) else { continue }
            Thread.sleep(forTimeInterval: 1.2)
            if let now = spotifyNowPlaying(), trackMatches(now, title: title, artist: artist) {
                return "Playing \(now) on Spotify."
            }
        }
        if let now = spotifyNowPlaying(), trackMatches(now, title: title, artist: artist) {
            return "Playing \(now) on Spotify."
        }
        // ponytail: one keystroke fallback (Tab to results, Return plays top hit)
        _ = runAppleScript("tell application \"System Events\" to tell process \"Spotify\" to key code 48").0
        Thread.sleep(forTimeInterval: 0.5)
        _ = runAppleScript("tell application \"System Events\" to tell process \"Spotify\" to key code 36").0
        Thread.sleep(forTimeInterval: 1.2)
        if let now = spotifyNowPlaying(), trackMatches(now, title: title, artist: artist) {
            return "Playing \(now) on Spotify."
        }
        if spotifyState() == "playing", let now = spotifyNowPlaying() {
            return "Playing \(now) — closest match for \"\(title)\"."
        }
        return "Spotify search for \"\(title)\" is open but nothing is playing. Check the Spotify window."
    }

    static func trackMatches(_ now: String, title: String, artist: String?) -> Bool {
        let text = now.lowercased()
        let words = title.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty, words.allSatisfy({ text.contains($0) }) else { return false }
        if let artist {
            let awords = artist.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
            if !awords.isEmpty, !awords.allSatisfy({ text.contains($0) }) { return false }
        }
        return true
    }

    /// Accessibility rows in Spotify whose text holds the title (and artist).
    /// Bounded: 3s, 6000 nodes, first 5 hits in visual order.
    static func spotifyCandidates(title: String, artist: String?) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.spotify.client"
        }) else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let needT = title.lowercased(), needA = artist?.lowercased()
        let deadline = Date().addingTimeInterval(3.0)
        var found: [AXUIElement] = []
        var visited = 0
        func rowMatches(_ el: AXUIElement) -> Bool {
            var cap = 600
            let t = collectAXText(el, depth: 0, cap: &cap).lowercased()
            guard t.contains(needT) || needT.split(separator: " ").filter({ $0.count > 2 }).allSatisfy({ t.contains($0) }) else { return false }
            if let a = needA, !a.isEmpty {
                let awords = a.split(separator: " ").map(String.init).filter { $0.count > 2 }
                if !awords.isEmpty, !awords.allSatisfy({ t.contains($0) }) { return false }
            }
            return true
        }
        func walk(_ el: AXUIElement, depth: Int) {
            if found.count >= 5 || visited > 6000 || depth > 16 || Date() > deadline { return }
            visited += 1
            var roleRef: CFTypeRef?
            let role = (AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success)
                ? roleRef as? String : nil
            if role == "AXRow" || role == "AXCell" {
                if rowMatches(el) { found.append(el) }
                return
            }
            for attr in [kAXRowsAttribute, kAXChildrenAttribute] {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
                      let arr = ref as? NSArray else { continue }
                for case let child as AXUIElement in arr {
                    walk(child, depth: depth + 1)
                    if found.count >= 5 { return }
                }
            }
        }
        walk(root, depth: 0)
        return found
    }

    private static func collectAXText(_ el: AXUIElement, depth: Int, cap: inout Int) -> String {
        guard depth <= 4, cap > 0 else { return "" }
        var out = ""
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty {
                out += " " + s
                cap -= s.count
            }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? NSArray {
            for case let child as AXUIElement in arr.prefix(40) {
                out += " " + collectAXText(child, depth: depth + 1, cap: &cap)
                if cap <= 0 { break }
            }
        }
        return out
    }

    /// Double-click an AX row center. Returns false when position is unavailable.
    static func axDoubleClick(_ el: AXUIElement) -> Bool {
        var pRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef) == .success,
              let pVal = pRef else { return false }
        var pt = CGPoint.zero
        guard AXValueGetValue(pVal as! AXValue, .cgPoint, &pt) else { return false }
        var center = pt
        var sRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef) == .success,
           let sVal = sRef {
            var sz = CGSize.zero
            if AXValueGetValue(sVal as! AXValue, .cgSize, &sz) {
                center = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
            }
        }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        for _ in 0..<2 {
            guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else {
                return false
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.06)
        }
        return true
    }

    static func spotifyState() -> String? {
        let (ok, out) = runAppleScript("tell application \"Spotify\" to get player state as string")
        return ok ? out : nil
    }

    static func spotifyNowPlaying() -> String? {
        let (ok, out) = runAppleScript("tell application \"Spotify\" to get (name of current track) & \" — \" & (artist of current track)")
        guard ok, let out, !out.isEmpty else { return nil }
        return out
    }

    // MARK: - Chrome (local bookmark index, no vision)

    private static func parseChrome(_ lower: String, original: String) -> MacCommand? {
        if lower.contains("bookmark") {
            if let name = chromeBookmarkQuery(from: lower) {
                return MacCommand(summary: "Open bookmark: \(name)") { openChromeBookmark(named: name) }
            }
            return MacCommand(summary: "Open Chrome bookmarks") {
                openURL("chrome://bookmarks/", in: "Google Chrome") ? "Bookmarks open in Chrome." : "Could not open Chrome."
            }
        }
        if lower.contains("new tab") {
            let query = chromeSearchQuery(from: lower)
            if let query {
                return MacCommand(summary: "New Chrome tab: \(query)") { chromeNewTab(search: query) }
            }
            return MacCommand(summary: "New Chrome tab") { chromeNewTab(search: nil) }
        }
        if lower.contains("chrome") || lower.contains("google ") || lower.contains("search for") || lower.contains("look up") {
            if let query = chromeSearchQuery(from: lower) {
                return MacCommand(summary: "Search Google for \"\(query)\"") { chromeNewTab(search: query) }
            }
            if let url = bareURL(from: lower) {
                return MacCommand(summary: "Open \(url)") { openURL(url, in: "Google Chrome") ? "Opened \(url)." : "Could not open that page." }
            }
        } else if let url = bareURL(from: lower) {
            return MacCommand(summary: "Open \(url)") { openURL(url, in: "Google Chrome") ? "Opened \(url)." : "Could not open that page." }
        }
        return nil
    }

    static func chromeBookmarkQuery(from lower: String) -> String? {
        var rest = lower
        for strip in ["open my ", "open the ", "open ", "my ", "show my ", "show "] {
            if rest.hasPrefix(strip) { rest = String(rest.dropFirst(strip.count)); break }
        }
        for suffix in [" bookmark", " bookmarks", " on google chrome", " in chrome", " on chrome"] {
            if let r = rest.range(of: suffix) { rest = String(rest[..<r.lowerBound]) }
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, rest.count < 60,
              rest != "bookmarks", rest != "bookmark", rest != "my bookmarks" else { return nil }
        return rest
    }

    static func openChromeBookmark(named name: String) -> String {
        if let url = findBookmark(matching: name) {
            return openURL(url, in: "Google Chrome") ? "Opened \"\(name)\" in Chrome." : "Could not open that bookmark."
        }
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return openURL("chrome://bookmarks/?q=\(q)", in: "Google Chrome")
            ? "No exact match — bookmark search for \"\(name)\" is open."
            : "Could not open Chrome."
    }

    static func findBookmark(matching name: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return nil }
        let needle = name.lowercased()
        var best: (score: Int, url: String)?
        func walk(_ node: [String: Any]) {
            if let children = node["children"] as? [[String: Any]] {
                for child in children { walk(child) }
            } else if let url = node["url"] as? String, let title = node["name"] as? String {
                let t = title.lowercased()
                let score: Int? = t == needle ? 3 : t.hasPrefix(needle) ? 2 : t.contains(needle) ? 1 : nil
                if let score, score > (best?.score ?? 0) { best = (score, url) }
            }
        }
        for root in roots.values { if let node = root as? [String: Any] { walk(node) } }
        return best?.url
    }

    static func chromeSearchQuery(from lower: String) -> String? {
        var rest = lower
        for verb in ["search google for ", "google ", "search for ", "look up ", "look for ", "new tab ", "open "] {
            if let r = rest.range(of: verb) { rest = String(rest[r.upperBound...]); break }
        }
        for suffix in [" on google chrome", " in chrome", " on chrome", " in a new tab", " new tab"] {
            if let r = rest.range(of: suffix) { rest = String(rest[..<r.lowerBound]) }
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !rest.isEmpty, rest.count < 120, !rest.contains("bookmark") else { return nil }
        return rest
    }

    static func chromeNewTab(search query: String?) -> String {
        let url: String
        if let query, !query.isEmpty {
            if let direct = looksLikeURL(query) { url = direct }
            else { url = "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        } else {
            url = "chrome://newtab/"
        }
        return openURL(url, in: "Google Chrome") ? (query.map { "Opened: \($0)." } ?? "New tab open in Chrome.") : "Could not open Chrome."
    }

    static func bareURL(from lower: String) -> String? {
        let words = lower.split(separator: " ").map(String.init)
        for w in words where w.contains(".") && !w.contains("..") && w.count > 4 && w.count < 80 {
            if w.hasPrefix("http") { return w }
            let parts = w.split(separator: ".")
            if parts.count >= 2, parts.last!.count >= 2 { return "https://\(w)" }
        }
        return nil
    }

    static func looksLikeURL(_ s: String) -> String? {
        guard s.contains("."), !s.contains(" ") else { return nil }
        if s.hasPrefix("http") { return s }
        return "https://\(s)"
    }

    @discardableResult
    static func openURL(_ urlString: String, in app: String? = nil) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        if let app {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", app, urlString]
            guard (try? proc.run()) != nil else { return false }
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - System

    static func parseSystem(_ lower: String, original: String) -> PendingCommand? {
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.contains("do not"), !words.contains("don t") else { return nil }
        func hasWord(_ w: String) -> Bool {
            lower.range(of: "\\b\(w)\\b", options: .regularExpression) != nil
        }
        if words.contains("dark mode") {
            let enable = !words.contains("turn off dark mode") && !words.contains("disable dark mode")
            return .action(MacCommand(summary: enable ? "Turn on Dark Mode" : "Turn on Light Mode") {
                runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(enable)").0
                    ? (enable ? "Dark mode is on." : "Light mode is on.") : "macOS rejected the action."
            })
        }
        if words.contains("light mode") {
            let dark = words.contains("turn off light mode") || words.contains("disable light mode")
            return .action(MacCommand(summary: dark ? "Turn on Dark Mode" : "Turn on Light Mode") {
                runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)").0
                    ? (dark ? "Dark mode is on." : "Light mode is on.") : "macOS rejected the action."
            })
        }
        if hasWord("unmute") {
            return .action(MacCommand(summary: "Unmute sound") {
                runAppleScript("set volume without output muted").0 ? "Sound is unmuted." : "macOS rejected the action."
            })
        }
        if hasWord("mute") {
            return .action(MacCommand(summary: "Mute sound") {
                runAppleScript("set volume with output muted").0 ? "Sound is muted." : "macOS rejected the action."
            })
        }
        if words.contains("volume up") || words.contains("turn it up") || words.contains("louder") {
            return .action(MacCommand(summary: "Turn volume up") {
                runAppleScript("set volume output volume ((output volume of (get volume settings)) + 15) without output muted").0
                    ? "Volume up." : "macOS rejected the action."
            })
        }
        if words.contains("volume down") || words.contains("turn it down") || words.contains("quieter") {
            return .action(MacCommand(summary: "Turn volume down") {
                runAppleScript("set volume output volume ((output volume of (get volume settings)) - 15) without output muted").0
                    ? "Volume down." : "macOS rejected the action."
            })
        }
        if words.contains("max volume") || words.contains("full volume") {
            return .action(MacCommand(summary: "Set volume 100%") {
                runAppleScript("set volume output volume 100 without output muted").0
                    ? "Volume is 100%." : "macOS rejected the action."
            })
        }
        if words.contains("volume"), let m = lower.range(of: #"\b\d{1,3}\b"#, options: .regularExpression),
           let level = Int(lower[m]) {
            let clamped = min(100, level)
            return .action(MacCommand(summary: "Set volume \(clamped)%") {
                runAppleScript("set volume output volume \(clamped) without output muted").0
                    ? "Volume is \(clamped)%." : "macOS rejected the action."
            })
        }
        if let seconds = requestedDuration(in: original) {
            let label: String
            if seconds >= 3600 { label = String(format: "Timer for %.1f hr", seconds / 3600) }
            else if seconds >= 60 { label = String(format: "Timer for %.0f min", seconds / 60) }
            else { label = String(format: "Timer for %.0f sec", seconds) }
            return .timer(seconds: seconds, label: label)
        }
        return nil
    }

    static func requestedDuration(in task: String) -> TimeInterval? {
        let lower = task.lowercased()
        guard lower.contains("timer") || lower.contains("countdown") || lower.contains("alarm in")
            || lower.contains("alarm for") || lower.contains("set an alarm") || lower.contains("set alarm") else {
            return nil
        }
        guard let m = lower.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
              let value = Double(lower[m]) else { return nil }
        let mult: Double
        if lower.contains("hour") || lower.contains(" hr") { mult = 3600 }
        else if lower.contains("min") { mult = 60 }
        else if lower.contains("sec") { mult = 1 }
        else { mult = 60 }
        let seconds = value * mult
        guard seconds >= 1, seconds <= 12 * 3600 else { return nil }
        return seconds
    }

    // MARK: - AppleScript

    @discardableResult
    static func runAppleScript(_ source: String) -> (Bool, String?) {
        guard let script = NSAppleScript(source: source) else { return (false, "Bad script.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error as? [String: Any] {
            return (false, error[NSAppleScript.errorMessage] as? String ?? "macOS rejected the action.")
        }
        return (true, result.stringValue)
    }

    // MARK: - LLM fallback (ambiguous phrasing only; same allowlist, JSON only, no vision)

    struct RemoteAction: Decodable {
        let tool: String
        let app: String?
        let url: String?
        let query: String?
        let name: String?
        let command: String?
        let level: Int?
        let enabled: Bool?
        let seconds: Double?
    }

    struct RemotePlan: Decodable {
        let steps: [RemoteAction]?
    }

    /// Multi-step planner for compound or ambiguous phrasing. Returns ordered
    /// allowlisted steps, or nil when the input is a question/smalltalk.
    static func requestPlan(task: String, done: @escaping ([PendingCommand]?) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let env = ProcessInfo.processInfo.environment
            let key = env["AI_GATEWAY_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
                ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
            guard !key.isEmpty else { DispatchQueue.main.async { done(nil) }; return }
            let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
            let system = """
            You split a macOS request into ordered steps using only allowlisted tools. Return JSON only: {"steps":[{"tool":"...","app":"...","url":"...","query":"...","name":"...","command":"...","level":50,"enabled":true,"seconds":60}]}
            Tools: openApp(app), quitApp(app), openUrl(url), openSite(site like github/youtube/gmail), siteSearch(site,query), webDo(task for multi-step website work), chromeBookmarks, chromeBookmark(name), chromeSearch(query), spotifyPlay(query), spotifyPause, spotifyNext, spotifyPrev, terminal(command), volume(level 0-100), mute(enabled), darkMode(enabled), timer(seconds).
            Rules: split "and"/"then" compounds into one step each, in order. Merge same-site web work into ONE webDo step with the full subtask text, inventing concrete details (names, text) the user left as random/placeholder. {"steps":[]} when the request is a question or smalltalk.
            Example: "go on github and make a new repo with placeholder text" → {"steps":[{"tool":"webDo","query":"On GitHub: create a new repository with a placeholder name and description, fill the form and create it"}]}
            """
            let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.timeoutInterval = 15
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "temperature": 0, "reasoning_effort": "minimal",
                "response_format": ["type": "json_object"],
                "messages": [["role": "system", "content": system], ["role": "user", "content": task]],
            ])
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let steps = data.flatMap(decodePlan)
                DispatchQueue.main.async { done(steps?.isEmpty == true ? nil : steps) }
            }.resume()
        }
    }

    private static func decodePlan(_ data: Data) -> [PendingCommand]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              let obj = String(content[start...end]).data(using: .utf8) else { return nil }
        // Multi-step plan, or one legacy single-tool object.
        if let plan = try? JSONDecoder().decode(RemotePlan.self, from: obj), let steps = plan.steps {
            return Array(steps.prefix(6).compactMap(buildRemote))
        }
        if let action = try? JSONDecoder().decode(RemoteAction.self, from: obj),
           let cmd = buildRemote(action) {
            return [cmd]
        }
        return nil
    }

    private static func buildRemote(_ a: RemoteAction) -> PendingCommand? {
        switch a.tool {
        case "openApp": guard let app = a.app, !app.isEmpty else { return nil }
            let name = aliases[app.lowercased()] ?? app
            return .action(MacCommand(summary: "Open \(name)") { openApp(named: name) })
        case "quitApp": guard let app = a.app, !app.isEmpty else { return nil }
            let name = aliases[app.lowercased()] ?? app
            return .action(MacCommand(summary: "Quit \(name)") { quitApp(named: name) })
        case "openUrl": guard let url = a.url, !url.isEmpty else { return nil }
            return .action(MacCommand(summary: "Open \(url)") { openURL(url) ? "Opened \(url)." : "Could not open that page." })
        case "openSite": guard let site = a.app ?? a.name ?? a.query, !site.isEmpty else { return nil }
            let key = site.lowercased()
            if let url = Web.sites[key] {
                return .action(MacCommand(summary: "Open \(key) in Chrome") {
                    openURL(url, in: "Google Chrome") ? "Opened \(key) in Chrome." : "Could not open Chrome."
                })
            }
            return nil
        case "siteSearch": guard let site = a.app ?? a.name, let q = a.query, !q.isEmpty else { return nil }
            if let template = Web.siteSearch[site.lowercased()] {
                let url = String(format: template, q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                return .action(MacCommand(summary: "Search \(site) for \"\(q)\"") {
                    openURL(url, in: "Google Chrome") ? "Searching \(site) for \"\(q)\"." : "Could not open Chrome."
                })
            }
            return nil
        case "webDo": guard let t = a.query ?? a.command, !t.isEmpty else { return nil }
            return .action(MacCommand(summary: "Do on the web: \(t)") { Web.runSync(task: t) })
        case "chromeBookmarks":
            return .action(MacCommand(summary: "Open Chrome bookmarks") {
                openURL("chrome://bookmarks/", in: "Google Chrome") ? "Bookmarks open in Chrome." : "Could not open Chrome."
            })
        case "chromeBookmark": guard let name = a.name ?? a.query, !name.isEmpty else { return nil }
            return .action(MacCommand(summary: "Open bookmark: \(name)") { openChromeBookmark(named: name.lowercased()) })
        case "chromeSearch": guard let q = a.query, !q.isEmpty else { return nil }
            return .action(MacCommand(summary: "Search Google for \"\(q)\"") { chromeNewTab(search: q) })
        case "spotifyPlay": guard let q = a.query, !q.isEmpty else { return nil }
            return .action(MacCommand(summary: "Play \"\(q)\" on Spotify") { spotifyPlay(title: q, artist: nil) })
        case "spotifyPause":
            return .action(MacCommand(summary: "Pause Spotify") {
                runAppleScript("tell application \"Spotify\" to pause").0 ? "Spotify paused." : "Spotify is not running."
            })
        case "spotifyNext":
            return .action(MacCommand(summary: "Next track on Spotify") {
                runAppleScript("tell application \"Spotify\" to next track").0 ? "Skipped to next track." : "Spotify is not running."
            })
        case "spotifyPrev":
            return .action(MacCommand(summary: "Previous track on Spotify") {
                runAppleScript("tell application \"Spotify\" to previous track").0 ? "Back to previous track." : "Spotify is not running."
            })
        case "terminal": guard let c = a.command, !c.isEmpty, c.count < 300 else { return nil }
            return .action(MacCommand(summary: "Open Terminal, run: \(c)") { openTerminal(app: "Terminal", command: c) })
        case "volume": guard let l = a.level else { return nil }
            let cl = min(100, max(0, l))
            return .action(MacCommand(summary: "Set volume \(cl)%") {
                runAppleScript("set volume output volume \(cl) without output muted").0 ? "Volume is \(cl)%." : "macOS rejected the action."
            })
        case "mute":
            let en = a.enabled ?? true
            return .action(MacCommand(summary: en ? "Mute sound" : "Unmute sound") {
                runAppleScript(en ? "set volume with output muted" : "set volume without output muted").0
                    ? (en ? "Sound is muted." : "Sound is unmuted.") : "macOS rejected the action."
            })
        case "darkMode":
            let en = a.enabled ?? true
            return .action(MacCommand(summary: en ? "Turn on Dark Mode" : "Turn on Light Mode") {
                runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(en)").0
                    ? (en ? "Dark mode is on." : "Light mode is on.") : "macOS rejected the action."
            })
        case "timer": guard let s = a.seconds, s >= 1, s <= 43200 else { return nil }
            return .timer(seconds: s, label: "Timer for \(Int(s / 60) > 0 ? "\(Int(s / 60)) min" : "\(Int(s)) sec")")
        default: return nil
        }
    }
}
