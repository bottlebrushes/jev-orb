import Foundation

struct AXTraversalBudget: Sendable {
    var maximumNodes = 2_000
    var maximumDepth = 64
    var maximumSeconds: TimeInterval = 4
    var messagingTimeout: Float = 0.25
    var maximumTextLength = 500
}

struct AXElementReference: Hashable, Codable, Sendable, CustomStringConvertible {
    let sessionID: UUID
    let processIdentifier: pid_t
    let windowID: String
    let generation: UInt64
    let nodeID: Int

    var description: String {
        "@\(sessionID.uuidString):\(processIdentifier):\(windowID):\(generation):\(nodeID)"
    }
}

enum AXValueKind: String, Codable, Sendable {
    case none, text, number, boolean, collection, other, unavailable, protected
}

struct AXValueSummary: Codable, Sendable, Equatable {
    let kind: AXValueKind
    let text: String?
    let isRedacted: Bool
}

struct AXNodeState: Codable, Sendable, Equatable {
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let expanded: Bool?
    let minimized: Bool?
    let required: Bool?
    let visited: Bool?
    let editable: Bool
}

struct AXAncestor: Codable, Sendable, Hashable {
    let reference: String
    let role: String
    let name: String
    let identifier: String?
}

struct AXReadFailure: Codable, Sendable, Equatable {
    let attribute: String
    let code: Int32
}

struct AXNode: Codable, Sendable, Identifiable {
    let reference: AXElementReference
    let role: String
    let subrole: String?
    let identifier: String?
    let title: String?
    let description: String?
    let help: String?
    let roleDescription: String?
    let name: String
    let value: AXValueSummary
    let state: AXNodeState
    let parent: String?
    let ancestors: [AXAncestor]
    let actions: [String]
    let attributes: [String]
    let settableAttributes: [String]
    let relationships: [String: [String]]
    let readFailures: [AXReadFailure]

    var id: String { reference.description }
    var isActionable: Bool { !actions.isEmpty || !settableAttributes.isEmpty }
}

enum AXTruncationReason: String, Codable, Sendable {
    case nodeLimit, depthLimit, timeLimit
}

struct AXSnapshot: Codable, Sendable {
    let sessionID: UUID
    let processIdentifier: pid_t
    let windowID: String
    let generation: UInt64
    let rootReference: String
    let nodes: [AXNode]
    let truncation: [AXTruncationReason]
    let elapsedSeconds: TimeInterval

    var isComplete: Bool { truncation.isEmpty }
}

enum AXWritableValue: Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

enum AXKey: String, Codable, Sendable {
    case enter, tab, escape, backspace, deleteForward, space
    case up, down, left, right, pageUp, pageDown, home, end
    case a, c, v, x, z
}

enum AXKeyModifier: String, Codable, Sendable, Hashable {
    case command, shift, option, control
}

struct AXKeyChord: Codable, Sendable {
    let key: AXKey
    var modifiers: Set<AXKeyModifier> = []
}

enum AXScrollDirection: String, Codable, Sendable {
    case up, down, left, right, beginning, end
}

/// Delivery is not proof of the requested effect. Call observe() and verify a predicate.
struct AXActionReceipt: Codable, Sendable {
    let operation: String
    let reference: String
    let generation: UInt64
    let deliveryMethod: String
    let verificationRequired: Bool
}

enum AXSessionError: LocalizedError, Sendable, Equatable {
    case accessibilityPermissionDenied
    case noSelection
    case invalidBudget
    case processUnavailable(pid_t)
    case windowUnavailable(String)
    case windowNotSelected
    case staleReference(String)
    case missingTarget(String)
    case ambiguousTarget(String, count: Int)
    case disabledTarget(String)
    case unsupportedAction(String)
    case unsupportedAttribute(String)
    case invalidValue
    case focusMismatch
    case incompleteObservation
    case observationTimedOut
    case axFailure(operation: String, code: Int32)
    case deliveryUncertain(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Enable Accessibility for JevOrb in System Settings → Privacy & Security → Accessibility."
        case .noSelection: return "Select an application and window before observing or acting."
        case .invalidBudget: return "Accessibility traversal budgets must be finite and positive."
        case .processUnavailable(let pid): return "The selected process (\(pid)) is no longer available."
        case .windowUnavailable: return "The selected accessibility window is no longer available."
        case .windowNotSelected: return "No unique focused or main window is selected."
        case .staleReference: return "STALE_REFERENCE: observe again before selecting a target."
        case .missingTarget: return "The target is missing from the current accessibility tree."
        case .ambiguousTarget(_, let count): return "AMBIGUOUS_TARGET: \(count) controls share the selected semantic identity."
        case .disabledTarget: return "The selected accessibility target is disabled."
        case .unsupportedAction(let action): return "UNSUPPORTED_ACTION: \(action)."
        case .unsupportedAttribute(let attribute): return "The semantic attribute \(attribute) is not currently settable."
        case .invalidValue: return "The supplied value is not valid for this semantic attribute."
        case .focusMismatch: return "The expected application, window, and element do not have accessibility focus."
        case .incompleteObservation: return "The bounded observation cannot prove a unique live target; narrow the context or increase the budget."
        case .observationTimedOut: return "Accessibility observation exceeded its time budget."
        case .axFailure(let operation, let code): return "Accessibility \(operation) failed (\(code))."
        case .deliveryUncertain(let operation, let code): return "Delivery of \(operation) is uncertain (\(code)); observe before taking further action and do not replay automatically."
        }
    }
}
