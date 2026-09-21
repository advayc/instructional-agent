import AppKit
import CoreGraphics

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
app.run()
