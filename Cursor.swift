import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ApprovedActionResult {
    case success
    case blocked(String)
    case failed(String)
}

/// A deliberately small policy boundary for the persistent approval switch.
/// It permits ordinary UI work that was explicitly requested, but it does not
/// turn a screen-reading model into an authority for secrets, money, account
/// security, destructive changes, or unsolicited outbound communication.
enum AutoApprovalPolicy {
    static func blockedReason(for step: GuideStep, task: String) -> String? {
        let action = [
            step.trimmedCaption,
            step.normalizedTargetText ?? "",
            step.automationText ?? "",
            task
        ].joined(separator: " ").lowercased()

        let sensitiveTerms = [
            "password", "passcode", "verification code", "one time code", "2fa", "two factor",
            "credit card", "debit card", "card number", "cvv", "bank", "wire transfer",
            "purchase", "checkout", "buy now", "pay ", "payment", "refund",
            "delete", "erase", "empty trash", "factory reset", "format disk",
            "privacy", "security", "permission", "allow access", "system extension",
            "install profile", "keychain", "recovery key"
        ]
        if sensitiveTerms.contains(where: { action.contains($0) }) {
            return "Auto-approval pauses for passwords, money, destructive changes, or security/privacy prompts."
        }

        switch step.actionKind {
        case .type:
            guard step.automationText != nil else {
                return "I need the exact text before I can type it for you."
            }
            guard step.normalizedTargetText != nil else {
                return "I need a live text field before I can type for you."
            }
        case .shortcut:
            guard step.automationKeys != nil else {
                return "I need the exact shortcut before I can run it."
            }
        case .scroll:
            guard step.scrollDirection != nil else {
                return "I need a clear scroll direction before I can continue."
            }
        case .click, .wait:
            break
        case .done, .unknown:
            return "That action is not safe to run automatically."
        }

        let outgoingTerms = ["send", "post", "publish", "share", "submit", "invite", "reply"]
        let directIntentTerms = ["text", "message", "send", "email", "mail", "post", "publish", "share", "reply", "invite"]
        if outgoingTerms.contains(where: { action.contains($0) }) &&
            !directIntentTerms.contains(where: { task.lowercased().contains($0) }) {
            return "I only send or post when your request explicitly asks me to."
        }
        return nil
    }
}

/// Drives the visible cursor and posts only a small fixed set of macOS input
/// events. Every pointer action is still resolved from a fresh local
/// Accessibility element by JevApp immediately before it gets here.
final class CursorDriver {
    private var generation = 0
    private(set) var isRunning = false

    func cancel() {
        generation &+= 1
        isRunning = false
    }

    func perform(
        _ step: GuideStep,
        target: GuideResolvedTarget?,
        completion: @escaping (ApprovedActionResult) -> Void
    ) {
        guard AXIsProcessTrusted() else {
            completion(.failed("Enable Accessibility for Jev before using Approve for me."))
            return
        }

        generation &+= 1
        let run = generation
        isRunning = true

        func finish(_ result: ApprovedActionResult) {
            guard self.generation == run else { return }
            self.isRunning = false
            completion(result)
        }

        switch step.actionKind {
        case .click:
            guard let target else {
                finish(.failed("That control moved before I could click it."))
                return
            }
            glide(to: target.point, run: run) { [weak self] in
                guard let self, self.generation == run else { return }
                if self.press(target) || self.mouseClick(at: target.point) {
                    finish(.success)
                } else {
                    finish(.failed("macOS did not accept that click."))
                }
            }

        case .type:
            guard let target, let text = step.automationText else {
                finish(.failed("The text field or exact text is no longer available."))
                return
            }
            glide(to: target.point, run: run) { [weak self] in
                guard let self, self.generation == run else { return }
                guard self.focus(target) || self.mouseClick(at: target.point) else {
                    finish(.failed("macOS did not focus that text field."))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                    guard self.generation == run else { return }
                    finish(self.type(text) ? .success : .failed("macOS did not accept that text."))
                }
            }

        case .shortcut:
            guard let keys = step.automationKeys else {
                finish(.failed("The shortcut is missing its keys."))
                return
            }
            finish(sendShortcut(keys) ? .success : .failed("macOS did not accept that shortcut."))

        case .scroll:
            guard let direction = step.scrollDirection else {
                finish(.failed("The scroll direction is unclear."))
                return
            }
            let performScroll = { [weak self] in
                guard let self, self.generation == run else { return }
                finish(self.scroll(direction) ? .success : .failed("macOS did not accept that scroll."))
            }
            if let target {
                glide(to: target.point, run: run, completion: performScroll)
            } else {
                performScroll()
            }

        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard self.generation == run else { return }
                finish(.success)
            }

        case .done, .unknown:
            finish(.blocked("That action is not safe to run automatically."))
        }
    }

    private func glide(to destination: CGPoint, run: Int, completion: @escaping () -> Void) {
        let start = NSEvent.mouseLocation
        let dx = destination.x - start.x
        let dy = destination.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > 2 else {
            completion()
            return
        }

        // A short glide makes the action legible without turning every step
        // into a sluggish animation. Escape can cancel between frames.
        let duration = min(0.16, max(0.045, distance / 7_000))
        let frameCount = max(2, min(10, Int((duration * 60).rounded())))
        var frame = 0

        func move() {
            guard self.generation == run else { return }
            frame += 1
            let t = CGFloat(frame) / CGFloat(frameCount)
            let eased = t * t * (3 - 2 * t)
            let point = CGPoint(x: start.x + dx * eased, y: start.y + dy * eased)
            _ = CGWarpMouseCursorPosition(point)
            if frame >= frameCount {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration / Double(frameCount), execute: move)
            }
        }
        move()
    }

    private func press(_ target: GuideResolvedTarget) -> Bool {
        AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
    }

    private func focus(_ target: GuideResolvedTarget) -> Bool {
        AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func mouseClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func type(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func sendShortcut(_ keys: [String]) -> Bool {
        var flags: CGEventFlags = []
        var keyName: String?
        for key in keys {
            switch key {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default:
                guard keyName == nil else { return false }
                keyName = key
            }
        }
        guard let keyName, let code = keyCode(for: keyName),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func scroll(_ direction: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let amount: Int32 = 5
        let vertical: Int32
        let horizontal: Int32
        switch direction {
        case "up": vertical = amount; horizontal = 0
        case "down": vertical = -amount; horizontal = 0
        case "left": vertical = 0; horizontal = -amount
        case "right": vertical = 0; horizontal = amount
        default: return false
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
            "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equals": 24, "9": 25,
            "7": 26, "minus": 27, "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32,
            "leftbracket": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
            "quote": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44,
            "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49, "grave": 50,
            "delete": 51, "escape": 53, "esc": 53, "forwarddelete": 117,
            "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return codes[key]
    }
}
