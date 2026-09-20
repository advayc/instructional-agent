#!/usr/bin/env swift
import Foundation

// jev v0 — text-only mac integration. No deps, stdlib only.
// Usage: AI_GATEWAY_API_KEY=... swift jev.swift "your question"
// ponytail: single script, no Xcode project until popup proves useful.

let env = ProcessInfo.processInfo.environment
let key = env["AI_GATEWAY_API_KEY"].flatMap({ $0.isEmpty ? nil : $0 }) ?? env["AI_GATEWAY_API_KEY_BACKUP"] ?? ""
guard !key.isEmpty else {
    fputs("missing AI_GATEWAY_API_KEY in environment\n", stderr)
    exit(1)
}
let model = env["AI_GATEWAY_MODEL"] ?? "vmc/jev"
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !prompt.isEmpty else {
    fputs("usage: swift jev.swift \"your question\"\n", stderr)
    exit(1)
}

let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
let body: [String: Any] = [
    "model": model,
    "messages": [["role": "user", "content": prompt]]
]
req.httpBody = try JSONSerialization.data(withJSONObject: body)

struct Out: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { let content: String? }
        let message: Msg
    }
    let choices: [Choice]
}

let sem = DispatchSemaphore(value: 0)
var failed = false
URLSession.shared.dataTask(with: req) { data, _, err in
    defer { sem.signal() }
    if let err = err { fputs("request failed: \(err)\n", stderr); failed = true; return }
    guard let data = data,
          let out = try? JSONDecoder().decode(Out.self, from: data),
          let text = out.choices.first?.message.content else {
        fputs("bad response: \(String(data: data ?? Data(), encoding: .utf8) ?? "")\n", stderr)
        failed = true
        return
    }
    print(text)
}.resume()
sem.wait()
exit(failed ? 1 : 0)
