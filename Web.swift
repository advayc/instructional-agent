import AppKit
import Foundation

/// Website tasks start to finish. Fast path: known site + query opens the
/// site's own search URL. Hard path: a bounded model loop drives Chrome via
/// JavaScript in the tab (click, type, press, read), one verified step at a
/// time. Passwords, logins, payments, and checkout always stop with a status.
enum Web {
    static let sites: [String: String] = [
        "google": "https://www.google.com", "gmail": "https://mail.google.com",
        "drive": "https://drive.google.com", "docs": "https://docs.google.com",
        "sheets": "https://docs.google.com/spreadsheets", "slides": "https://docs.google.com/presentation",
        "maps": "https://maps.google.com", "calendar": "https://calendar.google.com",
        "photos": "https://photos.google.com", "meet": "https://meet.google.com",
        "translate": "https://translate.google.com", "flights": "https://www.google.com/flights",
        "youtube": "https://www.youtube.com", "github": "https://github.com",
        "gitlab": "https://gitlab.com", "stackoverflow": "https://stackoverflow.com",
        "reddit": "https://www.reddit.com", "twitter": "https://x.com", "x": "https://x.com",
        "instagram": "https://www.instagram.com", "facebook": "https://www.facebook.com",
        "linkedin": "https://www.linkedin.com", "amazon": "https://www.amazon.com",
        "ebay": "https://www.ebay.com", "etsy": "https://www.etsy.com",
        "netflix": "https://www.netflix.com", "twitch": "https://www.twitch.tv",
        "notion": "https://www.notion.so", "figma": "https://www.figma.com",
        "canva": "https://www.canva.com", "dropbox": "https://www.dropbox.com",
        "icloud": "https://www.icloud.com", "outlook": "https://outlook.live.com",
        "wikipedia": "https://www.wikipedia.org", "imdb": "https://www.imdb.com",
        "yelp": "https://www.yelp.com", "kayak": "https://www.kayak.com",
        "airbnb": "https://www.airbnb.com", "zillow": "https://www.zillow.com",
        "weather": "https://weather.com", "cnn": "https://www.cnn.com",
        "whatsapp": "https://web.whatsapp.com", "paypal": "https://www.paypal.com",
    ]

    /// %@ = percent-encoded query.
    static let siteSearch: [String: String] = [
        "google": "https://www.google.com/search?q=%@", "youtube": "https://www.youtube.com/results?search_query=%@",
        "amazon": "https://www.amazon.com/s?k=%@", "github": "https://github.com/search?q=%@",
        "stackoverflow": "https://stackoverflow.com/search?q=%@", "reddit": "https://www.reddit.com/search/?q=%@",
        "twitter": "https://x.com/search?q=%@", "x": "https://x.com/search?q=%@",
        "ebay": "https://www.ebay.com/sch/i.html?_nkw=%@", "etsy": "https://www.etsy.com/search?q=%@",
        "netflix": "https://www.netflix.com/search?q=%@", "maps": "https://www.google.com/maps/search/%@",
    ]

    static let agentVerbs = ["book", "order", "buy", "reserve", "schedule", "apply",
                             "fill", "sign up", "signup", "track", "compare", "cheapest",
                             "cart", "checkout", "login", "log in"]

    /// Creation verbs use word boundaries so "address" never matches "add".
    static let creationVerbs = ["make", "create", "post", "upload", "publish", "add", "start"]

    static func hasWord(_ lower: String, _ w: String) -> Bool {
        lower.range(of: "\\b\(w)\\b", options: .regularExpression) != nil
    }

    static func mentionsSite(_ lower: String, _ site: String) -> Bool {
        if site.count >= 3 { return hasWord(lower, site) }
        return lower.range(of: "\\s(on|in|at|from)\\s\(site)(?![a-z])", options: .regularExpression) != nil
    }

    static func wantsCreation(_ lower: String) -> Bool {
        creationVerbs.contains(where: { hasWord(lower, $0) })
            || agentVerbs.contains(where: { lower.contains($0) })
    }

    /// After "and"/"then", a second real verb means a compound task the
    /// planner must split — never a search query.
    static func hasSecondVerb(_ q: String) -> Bool {
        for sep in [" and ", " then ", " and then "] {
            if let r = q.range(of: sep) {
                let tail = String(q[r.upperBound...])
                if ["search", "order", "buy", "open", "book", "find", "play", "go", "make", "create", "check"].contains(where: { hasWord(tail, $0) }) {
                    return true
                }
            }
        }
        return false
    }

    static func agentCommand(site: String, task: String) -> PendingCommand {
        var detail = task
        let l = task.lowercased()
        if l.contains("random") || l.contains("placeholder") || l.contains("dummy") || l.contains("anything") {
            detail += " (invent any needed names, text, or details)"
        }
        return .action(MacCommand(summary: "Do on \(site): \(task)") { runSync(task: detail) })
    }

    // MARK: - Parse

    static func parse(_ lower: String, original: String) -> PendingCommand? {
        guard !lower.contains("bookmark"), !lower.contains("new tab"),
              !lower.contains("terminal"), !lower.contains("spotify") else { return nil }
        var s = lower
        for v in ["go on ", "go to ", "goto ", "visit ", "open ", "launch ", "show me ", "take me to "] {
            if s.hasPrefix(v) { s = String(s.dropFirst(v.count)); break }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        var token = s
        for suffix in [" homepage", " website", " site", " app", " page"] where token.hasSuffix(suffix) {
            token = String(token.dropLast(suffix.count))
        }
        if let url = sites[token] {
            return .action(MacCommand(summary: "Open \(token) in Chrome") {
                Actions.openURL(url, in: "Google Chrome") ? "Opened \(token) in Chrome." : "Could not open Chrome."
            })
        }
        // "make a repo", "open my repos" — GitHub is implied.
        if lower.contains("repo") {
            if wantsCreation(lower) || hasWord(lower, "new") {
                return agentCommand(site: "github", task: original)
            }
            if ["my ", "list", "show", "open"].contains(where: { lower.contains($0) }) {
                return .action(MacCommand(summary: "Open my GitHub repos") {
                    Actions.openURL("https://github.com?tab=repositories", in: "Google Chrome")
                        ? "Repos open in Chrome." : "Could not open Chrome."
                })
            }
        }
        for site in sites.keys.sorted(by: { $0.count > $1.count }) {
            // "search amazon" alone → homepage.
            if lower == "search \(site)" || lower == "open \(site) search" {
                if let url = sites[site] {
                    return .action(MacCommand(summary: "Open \(site) in Chrome") {
                        Actions.openURL(url, in: "Google Chrome") ? "Opened \(site) in Chrome." : "Could not open Chrome."
                    })
                }
            }
            if let q = webQuery(lower: lower, site: site) {
                if hasSecondVerb(q) { return nil }
                if wantsCreation(lower) {
                    return agentCommand(site: site, task: original)
                }
                if let template = siteSearch[site] {
                    let url = String(format: template, q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                    return .action(MacCommand(summary: "Search \(site) for \"\(q)\"") {
                        Actions.openURL(url, in: "Google Chrome") ? "Searching \(site) for \"\(q)\"." : "Could not open Chrome."
                    })
                }
                if agentVerbs.contains(where: { lower.contains($0) }) {
                    return agentCommand(site: site, task: original)
                }
                if let url = sites[site] {
                    return .action(MacCommand(summary: "Open \(site) in Chrome") {
                        Actions.openURL(url, in: "Google Chrome") ? "Opened \(site) in Chrome." : "Could not open Chrome."
                    })
                }
            } else if wantsCreation(lower) && mentionsSite(lower, site) {
                return agentCommand(site: site, task: original)
            }
        }
        return nil
    }

    static func webQuery(lower: String, site: String) -> String? {
        for verb in ["search ", "find ", "look up ", "look for ", "watch "] {
            let head = verb + site
            if lower.hasPrefix(head) {
                var rest = String(lower.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("for ") { rest = String(rest.dropFirst(4)) }
                rest = cleanQ(rest)
                if !rest.isEmpty { return rest }
            }
        }
        // "<verb> <q> on|in|at|from <site>" with a word boundary after the site.
        if let r = lower.range(of: "\\s(on|in|at|from)\\s\(site)(?![a-z])", options: .regularExpression) {
            var head = String(lower[..<r.lowerBound])
            for verb in ["search for ", "search ", "find ", "look up ", "look for ", "watch ",
                         "check ", "get ", "show me ", "price of ", "price for ",
                         "go on ", "go to ", "go ", "head to ", "navigate to ", "navigate "] {
                if head.hasPrefix(verb) { head = String(head.dropFirst(verb.count)); break }
            }
            head = cleanQ(head)
            // Bare navigation ("go on github") or a compound task is not a query.
            if head.isEmpty || head.contains(" and ") || head.contains(" then ") { return nil }
            if !head.isEmpty { return head }
        }
        if lower.hasPrefix(site + " ") {
            let rest = cleanQ(String(lower.dropFirst(site.count + 1)))
            if !rest.isEmpty, rest.count < 100 { return rest }
        }
        return nil
    }

    static func cleanQ(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces)
        for suffix in [" please", " for me", " online"] where r.hasSuffix(suffix) {
            r = String(r.dropLast(suffix.count))
        }
        return r.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
    }

    // MARK: - Agent loop (runs on a background thread)

    static let maxRounds = 8

    struct Step: Decodable {
        let op: String
        let ref: Int?
        let text: String?
        let url: String?
        let key: String?
        let secs: Double?
    }

    static func runSync(task: String) -> String {
        guard snapshot() != nil else {
            return "Chrome blocked scripting. One-time fix: Chrome → View → Developer → Allow JavaScript from Apple Events, then retry."
        }
        guard Actions.openURL("about:blank", in: "Google Chrome") else {
            return "Could not open Chrome."
        }
        Thread.sleep(forTimeInterval: 0.8)
        guard snapshot() != nil else {
            return "Chrome stopped responding."
        }
        var history: [String] = []
        for _ in 0..<maxRounds {
            guard let snap = snapshot() else { return "Chrome stopped responding." }
            guard let step = nextStep(task: task, snapshot: snap, history: history) else {
                return "Could not plan the next step. Last page: \(currentURL() ?? "unknown")."
            }
            let obs = perform(step)
            if step.op == "done" || step.op == "fail" { return obs }
            history.append("\(describe(step)) → \(obs)")
            if history.count > 14 { history.removeFirst(2) }
        }
        return "Ran out of steps at \(currentURL() ?? "unknown"). Say it more specifically and I'll continue."
    }

    static func describe(_ s: Step) -> String {
        switch s.op {
        case "goto": return "goto \(s.url ?? "")"
        case "click": return "click ref \(s.ref ?? -1)"
        case "type": return "type ref \(s.ref ?? -1)"
        case "press": return "press \(s.key ?? "")"
        case "wait": return "wait"
        case "read": return "read"
        default: return s.op
        }
    }

    static func perform(_ s: Step) -> String {
        switch s.op {
        case "goto":
            guard let url = s.url, !url.isEmpty else { return "no url given" }
            return chromeGoto(url) ? "opened \(url)" : "navigation failed"
        case "click":
            guard let ref = s.ref else { return "no ref given" }
            return chromeClick(ref: ref)
        case "type":
            guard let ref = s.ref, let text = s.text, !text.isEmpty else { return "need ref and text" }
            return chromeType(ref: ref, text: text)
        case "press":
            return chromePress(key: s.key ?? "return")
        case "wait":
            Thread.sleep(forTimeInterval: min(8, max(0.5, s.secs ?? 2)))
            return "waited"
        case "read":
            return "page text: \((chromeJS(readJS) ?? "").prefix(800))"
        case "done":
            return s.text?.isEmpty == false ? s.text! : "Done."
        case "fail":
            return s.text?.isEmpty == false ? s.text! : "Stopped."
        default:
            return "unknown op \(s.op)"
        }
    }

    // MARK: - Chrome bridge

    static func chromeJS(_ js: String) -> String? {
        let esc = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "tell application \"Google Chrome\" to execute front window's active tab javascript \"\(esc)\""
        let (ok, out) = Actions.runAppleScript(src)
        guard ok else { return nil }
        return out ?? ""
    }

    static func snapshot() -> String? {
        guard let out = chromeJS(snapshotJS), !out.isEmpty else { return nil }
        return String(out.prefix(3500))
    }

    static func currentURL() -> String? {
        chromeJS("location.href")
    }

    static func chromeGoto(_ url: String) -> Bool {
        let esc = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard chromeJS("location.href=\"\(esc)\"") != nil else { return false }
        let deadline = Date().addingTimeInterval(9)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            if chromeJS("document.readyState") == "complete" { return true }
        }
        return true
    }

    static func chromeClick(ref: Int) -> String {
        let js = "((R)=>{const q=[...document.querySelectorAll('a,button,input,select,textarea,[role=\"button\"]')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0});const e=q[R];if(!e)return 'missing';e.scrollIntoView({block:'center'});e.click();return 'clicked '+((e.innerText||e.value||e.type||'').trim().replace(/\\s+/g,' ').slice(0,80))})(\(ref))"
        return chromeJS(js) ?? "no response"
    }

    static func chromeType(ref: Int, text: String) -> String {
        let t = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = "((R,T)=>{const q=[...document.querySelectorAll('input,select,textarea,[contenteditable]')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0});const e=q[R];if(!e)return 'missing';e.scrollIntoView({block:'center'});e.focus();if(e.tagName==='SELECT'){const o=[...e.options].find(o=>o.text.toLowerCase().includes(T.toLowerCase()));if(!o)return 'no such option';e.selectedIndex=o.index;e.dispatchEvent(new Event('change',{bubbles:true}));return 'selected '+o.text.slice(0,60)}try{document.execCommand('selectAll',false,null);document.execCommand('insertText',false,T)}catch(_){e.value=T;e.dispatchEvent(new Event('input',{bubbles:true}))}e.dispatchEvent(new Event('change',{bubbles:true}));return 'typed'})(\(ref),\"\(t)\")"
        return chromeJS(js) ?? "no response"
    }

    static func chromePress(key: String) -> String {
        let code: Int
        switch key.lowercased() {
        case "return", "enter": code = 36
        case "tab": code = 48
        case "escape", "esc": code = 53
        case "space": code = 49
        case "down": code = 125
        case "up": code = 126
        case "left": code = 123
        case "right": code = 124
        default: code = 36
        }
        let ok = Actions.runAppleScript("tell application \"System Events\" to tell process \"Google Chrome\" to key code \(code)").0
        Thread.sleep(forTimeInterval: 0.6)
        return ok ? "pressed \(key)" : "keypress failed"
    }

    static let snapshotJS = "(()=>{const q=document.querySelectorAll('a,button,input,select,textarea,[role=\"button\"]');const els=[...q].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}).slice(0,60).map((e,i)=>({ref:i,tag:e.tagName.toLowerCase(),text:((e.innerText||e.value||e.placeholder||e.getAttribute('aria-label')||'')+'').trim().replace(/\\s+/g,' ').slice(0,80),href:(e.href||'').slice(0,120),type:e.type||''}));return JSON.stringify({url:location.href,title:document.title.slice(0,120),els})})()"

    static let readJS = "(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,1200)"

    // MARK: - Planner (one JSON step per round, same gateway)

    static func nextStep(task: String, snapshot: String, history: [String]) -> Step? {
        let env = ProcessInfo.processInfo.environment
        let key = env["AI_GATEWAY_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
        guard !key.isEmpty else { return nil }
        let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
        let system = """
        You operate Google Chrome to finish the user's website task. Page snapshot lists clickable elements with ref numbers. Return exactly one JSON step, no prose:
        {"op":"goto","url":"https://..."} | {"op":"click","ref":N} | {"op":"type","ref":N,"text":"..."} | {"op":"press","key":"return|tab|escape|down|up"} | {"op":"wait","secs":2} | {"op":"read"} | {"op":"done","text":"result summary"} | {"op":"fail","text":"what is ready and what needs the user"}
        Rules: finish start to finish using only snapshot refs. Type replaces field content. After goto the page loads itself. Dismiss cookie banners by clicking reject/accept. Return done with the concrete result (price, link, confirmation). Never passwords, logins, payments, checkout, place-order, account or security changes: use fail naming the page and what is ready. JSON only.
        """
        let past = history.isEmpty ? "None yet." : history.joined(separator: "\n")
        let user = "Task: \(task)\nSteps so far:\n\(past)\nSnapshot:\n\(snapshot)"
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "reasoning_effort": "minimal",
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        var step: Step?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String,
                  let start = content.firstIndex(of: "{"),
                  let end = content.lastIndex(of: "}"),
                  let obj = String(content[start...end]).data(using: .utf8) else { return }
            step = try? JSONDecoder().decode(Step.self, from: obj)
        }.resume()
        sem.wait()
        return step
    }
}
