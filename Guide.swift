import AppKit
import Foundation

struct GuideRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// A plan is always grounded in the live Accessibility snapshot. When the
/// person explicitly enables hands-free approval, the same bounded actions can
/// be carried out by Jev instead of only being shown as a visual guide.
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

enum GuidePlanStatus: String {
    case active
    case complete
    case blocked
    case needsAgent = "needs_agent"

    init(modelValue: String?) {
        switch modelValue?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "complete", "done", "subtask_complete": self = .complete
        case "blocked": self = .blocked
        case "needs_agent", "needsagent", "uncertain": self = .needsAgent
        default: self = .active
        }
    }
}

enum GuidePlanningMode {
    case initial
    case replan
    case verify

    var promptLabel: String {
        switch self {
        case .initial: return "initial plan"
        case .replan: return "corrective plan"
        case .verify: return "completion verification"
        }
    }
}

struct GuideTarget: Decodable {
    let x: Double
    let y: Double

    var isValid: Bool {
        (0...1000).contains(x) && (0...1000).contains(y)
    }
}

/// `targetId` is an ID from the current local Accessibility snapshot. It is a
/// hint, not an executable selector: Jev checks its semantic guard again right
/// before showing it to the person.
struct GuideStep: Decodable {
    let done: Bool?
    let action: String
    let caption: String
    let target: GuideTarget?
    let targetText: String?
    let targetRole: String?
    let targetId: String?
    /// Exact literal text for a hands-free `type` action. Captions remain
    /// human-readable instructions; this field is the only text Jev may send.
    let text: String?
    /// Modifier names and one key for a `shortcut` action, for example
    /// ["command", "space"].
    let keys: [String]?
    /// A machine-readable direction for `scroll`: up, down, left, or right.
    let direction: String?

    init(
        done: Bool? = nil,
        action: String,
        caption: String,
        target: GuideTarget? = nil,
        targetText: String? = nil,
        targetRole: String? = nil,
        targetId: String? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        direction: String? = nil
    ) {
        self.done = done
        self.action = action
        self.caption = caption
        self.target = target
        self.targetText = targetText
        self.targetRole = targetRole
        self.targetId = targetId
        self.text = text
        self.keys = keys
        self.direction = direction
    }

    var isDone: Bool {
        done == true || actionKind == .done
    }

    var actionKind: GuideAction {
        let parsed = GuideAction(modelValue: action)
        return parsed == .unknown && (target != nil || targetText != nil || targetId != nil) ? .click : parsed
    }

    var validTarget: GuideTarget? {
        guard let target, target.isValid else { return nil }
        return target
    }

    var trimmedCaption: String {
        caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedTargetText: String? {
        guard let targetText = targetText?.trimmingCharacters(in: .whitespacesAndNewlines), !targetText.isEmpty else {
            return nil
        }
        return targetText
    }

    var automationText: String? {
        guard let text else { return nil }
        let cleaned = text.unicodeScalars
            .filter { scalar in
                scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
            }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(1_200))
    }

    var automationKeys: [String]? {
        let cleaned = (keys ?? []).compactMap { raw -> String? in
            let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.count <= 24,
                  key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
                return nil
            }
            return key
        }
        guard !cleaned.isEmpty else { return nil }
        return Array(cleaned.prefix(6))
    }

    var scrollDirection: String? {
        let value = direction?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, ["up", "down", "left", "right"].contains(value) else { return nil }
        return value
    }

    var needsPointer: Bool {
        switch actionKind {
        case .click:
            return true
        case .type:
            return target != nil || targetText != nil || targetId != nil
        default:
            return false
        }
    }

    var fingerprint: String {
        [actionKind.rawValue, normalizedTargetText ?? "", targetRole ?? "", trimmedCaption]
            .joined(separator: "|")
            .lowercased()
    }

    func sanitized() -> GuideStep? {
        let caption = trimmedCaption
        guard !caption.isEmpty, caption.count <= 180, actionKind != .unknown else { return nil }
        return GuideStep(
            done: done,
            action: actionKind.rawValue,
            caption: caption,
            target: validTarget,
            targetText: normalizedTargetText,
            targetRole: targetRole?.trimmingCharacters(in: .whitespacesAndNewlines),
            targetId: targetId?.trimmingCharacters(in: .whitespacesAndNewlines),
            text: automationText,
            keys: automationKeys,
            direction: scrollDirection
        )
    }
}

/// A bounded plan replaces a remote vision round trip after every click. It is
/// deliberately short: dynamic UI is re-planned only when the next live target
/// cannot be found or when the final state cannot be verified.
struct GuidePlan: Decodable {
    let status: String?
    let steps: [GuideStep]?
    let verification: [String]?
    let completionCaption: String?
    let reason: String?

    init(
        status: String? = nil,
        steps: [GuideStep]? = nil,
        verification: [String]? = nil,
        completionCaption: String? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.steps = steps
        self.verification = verification
        self.completionCaption = completionCaption
        self.reason = reason
    }

    var planStatus: GuidePlanStatus { GuidePlanStatus(modelValue: status) }

    var sanitizedSteps: [GuideStep] {
        Array((steps ?? []).prefix(8).compactMap { step in
            guard !step.isDone else { return nil }
            return step.sanitized()
        })
    }

    var sanitizedVerification: [String] {
        Array((verification ?? []).compactMap { criterion in
            let cleaned = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : String(cleaned.prefix(160))
        }.prefix(4))
    }

    var cleanCompletionCaption: String {
        let cleaned = completionCaption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "Done — the requested result is visible." : String(cleaned.prefix(160))
    }

    var cleanReason: String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return String(reason.prefix(180))
    }

    static func parse(_ response: String) -> GuidePlan? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return nil
        }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else { return nil }

        if let plan = try? JSONDecoder().decode(GuidePlan.self, from: data) {
            let status = plan.planStatus
            if status != .active || !plan.sanitizedSteps.isEmpty {
                return plan
            }
        }

        // Accept a former single-step response while an already-running gateway
        // model catches up to the new contract.
        if let step = try? JSONDecoder().decode(GuideStep.self, from: data), let cleanStep = step.sanitized() {
            return GuidePlan(status: cleanStep.isDone ? "complete" : "active", steps: [cleanStep])
        }
        return nil
    }
}

final class GuideSession {
    let id = UUID()
    let task: String
    var completedCaptions: [String] = []
    var currentStep: GuideStep?
    var targetOnScreen: CGPoint?
    var targetBoundsOnScreen: CGRect?
    var currentTargetGuard: String?
    var currentSnapshotRevision: String?
    var currentSnapshot: GuideDesktopSnapshot?
    var steps: [GuideStep] = []
    var nextStepIndex = 0
    var planSnapshotRevision: String?
    var verification: [String] = []
    var completionCaption = "Done — the requested result is visible."
    var actionCount = 0
    var replanCount = 0
    var verificationAttempts = 0
    var noProgressAttempts = 0
    private var presentedSteps: [String: Int] = [:]

    init(task: String) {
        self.task = task
    }

    func recordCompletion(of step: GuideStep) {
        completedCaptions.append(step.trimmedCaption)
        if completedCaptions.count > 12 {
            completedCaptions.removeFirst(completedCaptions.count - 12)
        }
        actionCount += 1
    }

    /// A repeated unresolved action is a terminal signal, not a reason to keep
    /// asking the model to repeat itself.
    func canPresent(_ step: GuideStep) -> Bool {
        let count = (presentedSteps[step.fingerprint] ?? 0) + 1
        presentedSteps[step.fingerprint] = count
        return count <= 2
    }
}
