import AppKit
import Foundation

struct GuideRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// A deliberately small, validated description of the one action Jev is
/// currently showing. The model can suggest it, but it never gets permission
/// to drive the real cursor or type into another app.
enum GuideAction: String {
    case click
    case type
    case shortcut
    case scroll
    case wait
    case done
    case unknown

    init(modelValue: String) {
        self = GuideAction(rawValue: modelValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
    }
}

struct GuideTarget: Decodable {
    let x: Double
    let y: Double

    var isValid: Bool {
        (0...1000).contains(x) && (0...1000).contains(y)
    }
}

struct GuideStep: Decodable {
    let done: Bool?
    let action: String
    let caption: String
    let target: GuideTarget?

    var isDone: Bool {
        done == true || actionKind == .done
    }

    var actionKind: GuideAction {
        let parsed = GuideAction(modelValue: action)
        // A target without an explicit action is still useful as a click hint.
        return parsed == .unknown && target != nil ? .click : parsed
    }

    var validTarget: GuideTarget? {
        guard let target, target.isValid else { return nil }
        return target
    }

    static func parse(_ response: String) -> GuideStep? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return nil
        }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8),
              let step = try? JSONDecoder().decode(GuideStep.self, from: data) else {
            return nil
        }
        let cleanCaption = step.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCaption.isEmpty, cleanCaption.count <= 180 else { return nil }
        return step
    }
}

final class GuideSession {
    let id = UUID()
    let task: String
    var completedCaptions: [String] = []
    var currentStep: GuideStep?
    var targetOnScreen: CGPoint?

    init(task: String) {
        self.task = task
    }
}
