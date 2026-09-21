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

final class CLIStream: NSObject, URLSessionDataDelegate {
    var text = ""
    var buffer = Data()
    let sem = DispatchSemaphore(value: 0)
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        guard let raw = String(data: data, encoding: .utf8) else { return }
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("data: ") else { continue }
            let part = String(t.dropFirst(6))
            if part == "[DONE]" { continue }
            if let d = part.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let c = delta["content"] as? String {
                if text.isEmpty { /* first token: ensure newline handling */ }
                text += c
                fputs(c, stdout); fflush(stdout)
            }
        }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if !text.isEmpty { print("") }
        sem.signal()
    }
}
func ask() -> String? {
    let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 22
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let body: [String: Any] = ["model": model, "messages": history, "stream": true, "temperature": 0.2]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let delegate = CLIStream()
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    session.dataTask(with: req).resume()
    delegate.sem.wait()
    if !delegate.text.isEmpty { return delegate.text }
    // Fallback: non-stream JSON
    if let out = try? JSONDecoder().decode(Out.self, from: delegate.buffer) { return out.choices.first?.message.content }
    if let obj = try? JSONSerialization.jsonObject(with: delegate.buffer) as? [String: Any],
       let choices = obj["choices"] as? [[String: Any]],
       let msg = choices.first?["message"] as? [String: Any],
       let c = msg["content"] as? String { return c }
    return nil
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
