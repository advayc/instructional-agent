#!/usr/bin/env swift
import Foundation
import AppKit

let env = ProcessInfo.processInfo.environment
let key = env["AI_GATEWAY_API_KEY"].flatMap({ $0.isEmpty ? nil : $0 }) ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
guard !key.isEmpty else {
    fputs("missing AI_GATEWAY_API_KEY in environment\n", stderr)
    exit(1)
}
let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
var history: [[String: String]] = [["role": "system", "content": "You are jev, a fast macOS assistant. User is on a Mac, frontmost app is \(front). Assume macOS always, never ask which OS. Answer short and actionable: exact menu paths, keys, clicks. No fluff. For setting changes, list precise steps."]]

struct Out: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { let content: String? }
        let message: Msg
    }
    let choices: [Choice]
}

func ask() -> String? {
    let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": history])
    var text: String?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data,
              let out = try? JSONDecoder().decode(Out.self, from: data) else { return }
        text = out.choices.first?.message.content
    }.resume()
    sem.wait()
    return text
}

let args = CommandLine.arguments.dropFirst().joined(separator: " ")
if args.isEmpty {
    while true {
        print("> ", terminator: "")
        guard let line = readLine(), !line.isEmpty else { break }
        if line == "exit" { break }
        history.append(["role": "user", "content": line])
        guard let reply = ask() else { fputs("request failed\n", stderr); history.removeLast(); continue }
        print(reply)
        history.append(["role": "assistant", "content": reply])
    }
} else {
    history.append(["role": "user", "content": args])
    guard let reply = ask() else { fputs("request failed\n", stderr); exit(1) }
    print(reply)
}
