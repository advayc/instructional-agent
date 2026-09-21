import AppKit
import ApplicationServices
import Foundation

/// A small native Swift adaptation of arc-cua's DesktopSnapshot boundary. It
/// keeps UI perception local and exposes only live, named controls to the
/// planner; no model-provided coordinate is trusted as a selector.
struct GuideDesktopElement {
    let id: String
    let role: String
    let name: String
    let value: String?
    let bounds: CGRect?
    let point: CGPoint?
    let guardToken: String
    let isActionable: Bool

    var compact: [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "role": role,
            "name": String(name.prefix(120)),
            "actionable": isActionable
        ]
        // Never include the value of a text or secure text field in the model
        // context. Control names are enough to locate an input safely.
        if let value, !role.lowercased().contains("text") && !role.lowercased().contains("search") {
            row["value"] = String(value.prefix(80))
        }
        return row
    }
}

struct GuideResolvedTarget {
    let point: CGPoint
    let bounds: CGRect?
    let guardToken: String
    let elementID: String
}

struct GuideDesktopSnapshot {
    let application: String
    let window: String
    let revision: String
    let elements: [GuideDesktopElement]

    static var accessibilityIsAvailable: Bool {
        AXIsProcessTrusted()
    }

    /// A named, actionable control can ground a plan without a full desktop
    /// image. Prefer this lightweight path whenever the target app exposes it.
    var hasUsableControls: Bool {
        elements.contains { element in
            element.isActionable && element.point != nil && !element.name.isEmpty
        }
    }

    static func capture(for application: NSRunningApplication?, fallbackName: String) -> GuideDesktopSnapshot? {
        guard AXIsProcessTrusted() else { return nil }

        let targetApplication: NSRunningApplication?
        if let application, !application.isTerminated {
            targetApplication = application
        } else if let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else {
            targetApplication = nil
        }
        guard let targetApplication else { return nil }

        let appRef = AXUIElementCreateApplication(targetApplication.processIdentifier)
        let focusedWindow = attribute(appRef, kAXFocusedWindowAttribute).map {
            unsafeBitCast($0, to: AXUIElement.self)
        }
        let root = focusedWindow ?? appRef
        let appName = targetApplication.localizedName ?? fallbackName
        let windowTitle = stringAttribute(root, kAXTitleAttribute) ?? appName

        var elements: [GuideDesktopElement] = []
        var sequence = 0
        walk(root, elements: &elements, sequence: &sequence, depth: 0)

        let revisionRows = elements.map {
            [$0.id, $0.role, $0.name, $0.value ?? "", $0.guardToken].joined(separator: "|")
        }.joined(separator: "\n")
        return GuideDesktopSnapshot(
            application: appName,
            window: windowTitle,
            revision: fingerprint(revisionRows),
            elements: elements
        )
    }

    /// Large Electron apps can expose hundreds of Accessibility nodes. Rank a
    /// compact context around the person's task so request encoding, upload,
    /// and model input work do not delay the first visible instruction.
    func compactJSON(relevantTo task: String, maximumElements: Int = 84) -> String {
        let taskWords = Self.meaningfulWords(in: task)
        let ranked = elements.enumerated().compactMap { index, element -> (score: Int, index: Int, element: GuideDesktopElement)? in
            guard !element.name.isEmpty else { return nil }

            let nameWords = Self.meaningfulWords(in: element.name)
            var score = taskWords.intersection(nameWords).count * 120
            if !taskWords.isEmpty && nameWords.isSuperset(of: taskWords) {
                score += 280
            }
            if element.isActionable { score += 180 }
            if element.point != nil { score += 50 }
            if ["Button", "MenuItem", "MenuBarItem", "Tab", "Link", "CheckBox", "RadioButton", "PopUpButton"].contains(element.role) {
                score += 35
            }
            return (score, index, element)
        }
        let rows = ranked
            .sorted {
                $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
            }
            .prefix(maximumElements)
            .map(\.element.compact)
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    func resolve(_ step: GuideStep) -> GuideResolvedTarget? {
        if let id = step.targetId,
           let exact = elements.first(where: { $0.id == id }),
           let point = exact.point {
            return GuideResolvedTarget(point: point, bounds: exact.bounds, guardToken: exact.guardToken, elementID: exact.id)
        }

        guard let wanted = step.normalizedTargetText.map(Self.normalize) else { return nil }
        let expectedRole = step.targetRole.map(Self.normalize)
        var best: (element: GuideDesktopElement, score: Int)?

        for element in elements {
            guard let _ = element.point, !element.name.isEmpty else { continue }
            let name = Self.normalize(element.name)
            guard !name.isEmpty else { continue }

            var score = 0
            if name == wanted {
                score += 1000
            } else if name.contains(wanted) {
                score += 760
            } else if wanted.contains(name), name.count >= 3 {
                score += 480
            } else {
                let wantedWords = Set(wanted.split(separator: " "))
                let nameWords = Set(name.split(separator: " "))
                score += wantedWords.intersection(nameWords).count * 95
            }
            guard score > 0 else { continue }

            if let expectedRole, !expectedRole.isEmpty {
                let actualRole = Self.normalize(element.role)
                if actualRole == expectedRole || actualRole.contains(expectedRole) || expectedRole.contains(actualRole) {
                    score += 170
                } else {
                    score -= 70
                }
            }
            if element.isActionable { score += 45 }
            if best == nil || score > best!.score {
                best = (element, score)
            }
        }

        guard let best, best.score >= 190, let point = best.element.point else { return nil }
        return GuideResolvedTarget(
            point: point,
            bounds: best.element.bounds,
            guardToken: best.element.guardToken,
            elementID: best.element.id
        )
    }

    func isFresh(_ guardToken: String, for step: GuideStep) -> Bool {
        if let target = resolve(step) {
            return target.guardToken == guardToken
        }
        return false
    }

    private static func walk(
        _ element: AXUIElement,
        elements: inout [GuideDesktopElement],
        sequence: inout Int,
        depth: Int
    ) {
        // AX calls are synchronous. Bound the initial inspection so a deeply
        // nested window cannot make the prompt feel frozen before networking
        // even begins.
        guard depth <= 14, elements.count < 360 else { return }
        sequence += 1

        let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let name = firstStringAttribute(element, [
            kAXTitleAttribute,
            "AXLabel",
            kAXDescriptionAttribute,
            "AXHelp"
        ]) ?? ""
        let value = valueAttribute(element)
        let bounds = boundsAttribute(element).map(appKitBounds(fromAccessibility:))
        let actions = actionNames(element)
        let actionable = !actions.isEmpty || isLikelyActionable(role)
        let semantic = !name.isEmpty || value != nil || actionable || ["AXWindow", "AXMenu", "AXToolbar"].contains(role)

        if semantic {
            let id = "ax_\(sequence)_\(fingerprint([role, name, value ?? "", bounds.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" } ?? ""].joined(separator: "|")))"
            let token = fingerprint([
                role,
                name,
                value ?? "",
                String(actionable),
                bounds.map { "\($0.origin.x.rounded()),\($0.origin.y.rounded()),\($0.width.rounded()),\($0.height.rounded())" } ?? ""
            ].joined(separator: "|"))
            elements.append(GuideDesktopElement(
                id: id,
                role: role.replacingOccurrences(of: "AX", with: "", options: [.anchored]),
                name: name,
                value: value,
                bounds: bounds,
                point: bounds.map { CGPoint(x: $0.midX, y: $0.midY) },
                guardToken: token,
                isActionable: actionable
            ))
        }

        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            guard elements.count < 360 else { break }
            walk(child, elements: &elements, sequence: &sequence, depth: depth + 1)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func firstStringAttribute(_ element: AXUIElement, _ names: [String]) -> String? {
        for name in names {
            if let value = stringAttribute(element, name) {
                return value
            }
        }
        return nil
    }

    private static func valueAttribute(_ element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXValueAttribute) else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boundsAttribute(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute),
              let rawSize = attribute(element, kAXSizeAttribute) else {
            return nil
        }
        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success,
              let values else {
            return []
        }
        return values as? [String] ?? []
    }

    private static func isLikelyActionable(_ role: String) -> Bool {
        [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXTab", "AXTextField", "AXTextArea",
            "AXSearchField", "AXComboBox", "AXSlider", "AXRow", "AXCell"
        ].contains(role)
    }

    /// Accessibility geometry uses a top-left desktop origin. AppKit overlays
    /// use a bottom-left origin, so convert once at the perception boundary.
    private static func appKitBounds(fromAccessibility bounds: CGRect) -> CGRect {
        let desktop = desktopFrame()
        return CGRect(
            x: bounds.minX,
            y: desktop.maxY - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    private static func desktopFrame() -> CGRect {
        guard let first = NSScreen.screens.first else { return .zero }
        return NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func meaningfulWords(in value: String) -> Set<String> {
        let ignored: Set<String> = [
            "a", "an", "and", "at", "do", "for", "from", "how", "i", "in", "is",
            "it", "me", "my", "of", "on", "please", "the", "this", "to", "with"
        ]
        return Set(normalize(value).split(separator: " ").map(String.init)).subtracting(ignored)
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
