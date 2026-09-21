import AppKit
import ApplicationServices
import CoreGraphics

if CommandLine.arguments.contains("--permissions-status") {
    let screen = if #available(macOS 10.15, *) { CGPreflightScreenCaptureAccess() } else { true }
    let input = if #available(macOS 10.15, *) { CGPreflightListenEventAccess() } else { true }
    print("screen_recording=\(screen ? "granted" : "missing")")
    print("accessibility=\(AXIsProcessTrusted() ? "granted" : "missing")")
    print("input_monitoring=\(input ? "granted" : "missing")")
    exit(0)
}

if CommandLine.arguments.contains("--screen-recording-status") {
    if #available(macOS 10.15, *) {
        print(CGPreflightScreenCaptureAccess() ? "granted" : "missing")
    } else {
        print("granted")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = JevApp()
app.delegate = delegate
// NSApplication keeps its delegate weak. Keep Jev alive for the entire event
// loop so a fresh launch always owns its panel and global event monitors.
withExtendedLifetime(delegate) {
    app.run()
}
