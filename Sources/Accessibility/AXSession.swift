import AppKit
import ApplicationServices
import Foundation

/// One selected application/window and one generation of semantic element references.
/// AX handles never leave this object. Every mutation invalidates the observation,
/// including failed deliveries, so a caller cannot accidentally replay an action.
@MainActor
final class AXSession {
    let sessionID = UUID()
    private(set) var generation: UInt64 = 0
    private let catalog: ApplicationCatalog
    private let budget: AXTraversalBudget
    private var selection: Selection?
    private var observation: Capture?
    private var observer: AXObserver?
    private let changes = ChangeSignal()
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let writableAttributes: Set<String> = [
        "AXValue", "AXSelectedText", "AXFocused", "AXSelected", "AXExpanded", "AXMinimized", "AXMain"
    ]
    private static let metadataAttributes = [
        "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXHelp",
        "AXRoleDescription", "AXEnabled", "AXFocused", "AXSelected", "AXExpanded",
        "AXMinimized", "AXRequired", "AXVisited", "AXEditable", "AXProtectedContent", "AXIsPassword", "AXParent"
    ]
    private static let traversalAttributes = [
        "AXChildren", "AXVisibleChildren", "AXContents", "AXRows", "AXColumns", "AXSelectedChildren"
    ]
    private static let relationshipAttributes = [
        "AXLinkedUIElements", "AXTitleUIElement", "AXServesAsTitleForUIElements"
    ]

    init(catalog: ApplicationCatalog, budget: AXTraversalBudget = .init()) {
        self.catalog = catalog
        self.budget = budget
        let signal = changes
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { signal.changed = true } })
        }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    func invalidate() {
        generation &+= 1
        observation = nil
        changes.changed = false
    }

    func observe(pid: pid_t, windowID: String? = nil) throws -> AXSnapshot {
        try checkBudget()
        invalidate()
        selection = nil
        removeObserver()
        guard AXIsProcessTrusted() else { throw AXSessionError.accessibilityPermissionDenied }
        let process = try runningProcess(pid)
        let application = AXUIElementCreateApplication(pid)
        try configure(application)
        let windows = try catalog.windows(for: pid)
        let selectedID: String?
        if let windowID {
            guard windows.contains(where: { $0.id == windowID }) else {
                throw AXSessionError.windowUnavailable(windowID)
            }
            selectedID = windowID
        } else {
            let focused = windows.filter(\.isFocused)
            let main = windows.filter(\.isMain)
            let candidates = focused.isEmpty ? main : focused
            if candidates.count > 1 { throw AXSessionError.windowNotSelected }
            if let window = candidates.first { selectedID = window.id }
            else if windows.isEmpty { selectedID = nil }
            else { throw AXSessionError.windowNotSelected }
        }
        let root: AXUIElement
        if let selectedID {
            root = try catalog.withWindow(pid: pid, windowID: selectedID) { $0 }
        } else {
            root = application
        }
        try configure(root)
        selection = Selection(pid: pid, launchDate: process.launchDate, bundleURL: process.bundleURL,
                              windowID: selectedID ?? "application", application: application,
                              root: root, isApplicationRoot: selectedID == nil)
        try verifySelection(requireActive: true)
        installObserver(pid: pid, application: application, root: root)
        return try observe()
    }

    func observe() throws -> AXSnapshot {
        try checkBudget()
        invalidate()
        try verifySelection(requireActive: true)
        let capture = try captureTree()
        observation = capture
        return capture.snapshot
    }

    func performAction(reference: String, action: String) throws -> AXActionReceipt {
        let target = try validated(reference)
        return try mutate(reference: reference, operation: "PERFORM_ACTION", method: action) {
            try requireAction(action, on: target.element)
            try dispatch(AXUIElementPerformAction(target.element, action as CFString), operation: action)
        }
    }

    func setValue(reference: String, attribute: String = "AXValue", value: AXWritableValue) throws -> AXActionReceipt {
        let target = try validated(reference)
        let converted = try attributeValue(value, for: attribute)
        return try mutate(reference: reference, operation: "SET_VALUE", method: attribute) {
            try requireSettable(attribute, on: target.element)
            try dispatch(AXUIElementSetAttributeValue(target.element, attribute as CFString, converted), operation: attribute)
        }
    }

    /// Compare a fresh observation's value locally without putting user text in
    /// a snapshot. Protected fields are deliberately never read, even here.
    func matchesValue(reference: String, attribute: String = "AXValue", expected: AXWritableValue) throws -> Bool {
        guard Self.writableAttributes.contains(attribute) else { throw AXSessionError.unsupportedAttribute(attribute) }
        let target = try validated(reference)
        guard target.node.value.kind != .protected else { throw AXSessionError.unsupportedAction("Reading protected values") }
        let expectedValue = try attributeValue(expected, for: attribute)
        let result = try readAttribute(target.element, attribute: attribute, context: ReadContext(budget: budget))
        guard result.error == .success, let actual = result.value else {
            throw AXSessionError.axFailure(operation: "verify value", code: result.error.rawValue)
        }
        return CFEqual(actual, expectedValue)
    }

    func focusElement(reference: String) throws -> AXActionReceipt {
        let target = try validated(reference)
        return try mutate(reference: reference, operation: "FOCUS_ELEMENT", method: "AXFocused") {
            try focusThroughAX(target.element)
        }
    }

    /// Replaces the field value when AXValue is settable; otherwise inserts Unicode
    /// text at the focused caret. The receipt identifies the method used.
    func typeText(reference: String, text: String) throws -> AXActionReceipt {
        let target = try validated(reference)
        guard target.node.state.editable else { throw AXSessionError.unsupportedAction("TYPE_TEXT on a non-editable element") }
        let useValue = try isSettable("AXValue", on: target.element)
        guard useValue || text.utf16.count <= 100_000 else { throw AXSessionError.invalidValue }
        return try mutate(reference: reference, operation: "TYPE_TEXT", method: useValue ? "AXValue" : "Unicode keyboard") {
            try focusThroughAX(target.element)
            try verifyFocus(target.element)
            if useValue {
                try requireSettable("AXValue", on: target.element)
                try dispatch(AXUIElementSetAttributeValue(target.element, "AXValue" as CFString, text as CFString), operation: "TYPE_TEXT")
            } else {
                try typeUnicode(text, into: target.element)
            }
        }
    }

    func pressKey(reference: String, key: AXKeyChord) throws -> AXActionReceipt {
        let target = try validated(reference)
        try validateChord(key)
        let focused = try keyboardTarget(target)
        return try mutate(reference: reference, operation: "PRESS_KEY", method: key.key.rawValue) {
            try sendKey(key, into: focused)
        }
    }

    func scroll(reference: String, direction: AXScrollDirection) throws -> AXActionReceipt {
        let target = try validated(reference)
        let roles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXWindow"]
        guard roles.contains(target.node.role) else { throw AXSessionError.unsupportedAction("SCROLL on this element") }
        let action: String
        let key: AXKey
        switch direction {
        case .up: action = "AXScrollUp"; key = .pageUp
        case .down: action = "AXScrollDown"; key = .pageDown
        case .left: action = "AXScrollLeft"; key = .left
        case .right: action = "AXScrollRight"; key = .right
        case .beginning: action = "AXScrollToBeginning"; key = .home
        case .end: action = "AXScrollToEnd"; key = .end
        }
        if target.node.actions.contains(action) {
            return try mutate(reference: reference, operation: "SCROLL", method: action) {
                try requireAction(action, on: target.element)
                try dispatch(AXUIElementPerformAction(target.element, action as CFString), operation: action)
            }
        }
        return try mutate(reference: reference, operation: "SCROLL", method: key.rawValue) {
            if target.node.role == "AXWindow" {
                // A focused window owns its currently focused control; unlike a
                // scroll container, it need not itself be AXFocusedUIElement.
                let focused = try keyboardTarget(target)
                try sendKey(AXKeyChord(key: key), into: focused)
            } else {
                // Never guess a descendant of a semantic scroll container.
                try focusThroughAX(target.element)
                try sendKey(AXKeyChord(key: key), into: target.element)
            }
        }
    }

    // MARK: Observation

    private func captureTree() throws -> Capture {
        guard let selection else { throw AXSessionError.noSelection }
        let context = ReadContext(budget: budget)
        var queue = [Pending(element: selection.root, depth: 0, protected: false)]
        var discovered = ElementIndex()
        discovered.insert(selection.root, at: 0)
        var drafts: [Draft] = []
        var reasons: Set<AXTruncationReason> = []
        var reliable = true
        var cursor = 0
        while cursor < queue.count {
            if context.expired { reasons.insert(.timeLimit); break }
            let pending = queue[cursor]
            do {
                var draft = try readNode(pending, context: context)
                if cursor == 0 && draft.role == "AXUnknown" {
                    throw AXSessionError.windowUnavailable(selection.windowID)
                }
                if draft.role == "AXUnknown" || !draft.structureReliable { reliable = false }
                if draft.linksTruncated { reasons.insert(.nodeLimit) }
                for attribute in Self.traversalAttributes {
                    let children = draft.links[attribute] ?? []
                    for child in children {
                        if context.expired { reasons.insert(.timeLimit); break }
                        if discovered.index(of: child) != nil { continue }
                        if pending.depth >= budget.maximumDepth { reasons.insert(.depthLimit); continue }
                        if queue.count >= budget.maximumNodes { reasons.insert(.nodeLimit); continue }
                        discovered.insert(child, at: queue.count)
                        queue.append(Pending(element: child, depth: pending.depth + 1, protected: draft.protected))
                    }
                }
                draft.element = pending.element
                drafts.append(draft)
                cursor += 1
            } catch AXSessionError.observationTimedOut {
                reasons.insert(.timeLimit)
                break
            }
        }
        guard !drafts.isEmpty else { throw AXSessionError.observationTimedOut }
        // A dead root is a failed observation, not a valid partial snapshot.
        try verifySelection(requireActive: true)
        let refs = drafts.indices.map {
            AXElementReference(sessionID: sessionID, processIdentifier: selection.pid,
                               windowID: selection.windowID, generation: generation, nodeID: $0)
        }
        let parents: [Int?] = drafts.map { draft in
            guard let parent = draft.parent, let index = discovered.index(of: parent), index < drafts.count else { return nil }
            return index
        }
        var records: [Record] = []
        for index in drafts.indices {
            let draft = drafts[index]
            var ancestors: [AXAncestor] = []
            var identityAncestors: [Fingerprint.Ancestor] = []
            var seen: Set<Int> = [index]
            var parent = parents[index]
            while let ancestorIndex = parent, seen.insert(ancestorIndex).inserted, ancestors.count < budget.maximumDepth {
                let ancestor = drafts[ancestorIndex]
                ancestors.append(AXAncestor(reference: refs[ancestorIndex].description, role: ancestor.role,
                                            name: ancestor.name, identifier: ancestor.identifier))
                identityAncestors.append(.init(role: ancestor.role, name: ancestor.identityName,
                                               identifier: ancestor.identityIdentifier))
                parent = parents[ancestorIndex]
            }
            ancestors.reverse()
            identityAncestors.reverse()
            var relationships: [String: [String]] = [:]
            for (attribute, elements) in draft.links {
                relationships[attribute] = elements.compactMap {
                    guard let index = discovered.index(of: $0), index < refs.count else { return nil }
                    return refs[index].description
                }
            }
            let node = AXNode(reference: refs[index], role: draft.role, subrole: draft.subrole,
                              identifier: draft.identifier, title: draft.title, description: draft.description,
                              help: draft.help, roleDescription: draft.roleDescription, name: draft.name,
                              value: draft.value, state: draft.state,
                              parent: parents[index].map { refs[$0].description }, ancestors: ancestors,
                              actions: draft.actions, attributes: draft.attributes, settableAttributes: draft.settable,
                              relationships: relationships, readFailures: draft.failures)
            let fingerprint = Fingerprint(node, name: draft.identityName, identifier: draft.identityIdentifier,
                                          ancestors: identityAncestors)
            records.append(Record(element: draft.element, node: node, fingerprint: fingerprint))
        }
        let snapshot = AXSnapshot(sessionID: sessionID, processIdentifier: selection.pid, windowID: selection.windowID,
                                  generation: generation, rootReference: refs[0].description,
                                  nodes: records.map(\.node), truncation: reasons.sorted { $0.rawValue < $1.rawValue },
                                  elapsedSeconds: ProcessInfo.processInfo.systemUptime - context.started)
        return Capture(snapshot: snapshot, records: records, reliable: reliable)
    }

    private func readNode(_ pending: Pending, context: ReadContext) throws -> Draft {
        let element = pending.element
        var failures: [AXReadFailure] = []
        var attributesArray: CFArray?
        let attributesError = try context.read(element) { AXUIElementCopyAttributeNames(element, &attributesArray) }
        let attributes = (attributesArray as? [String] ?? []).sorted()
        if attributesError != .success { failures.append(.init(attribute: "attributes", code: attributesError.rawValue)) }
        let requested = attributesError == .success ? Self.metadataAttributes.filter { attributes.contains($0) } : Self.metadataAttributes
        let values = try readBatch(element, attributes: requested, context: context, failures: &failures)
        let role = string(values["AXRole"]) ?? "AXUnknown"
        let subrole = string(values["AXSubrole"])
        let title = bounded(string(values["AXTitle"]))
        let description = bounded(string(values["AXDescription"]))
        let identityIdentifier = string(values["AXIdentifier"])
        let identifier = bounded(identityIdentifier)
        let identityName = [string(values["AXTitle"]), string(values["AXDescription"])]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let name = bounded(identityName) ?? ""
        let sensitiveLabel = [identityName, identityIdentifier ?? ""].joined(separator: " ").lowercased()
        let classificationFailed = failures.contains {
            ["AXRole", "AXSubrole", "AXProtectedContent", "AXIsPassword"].contains($0.attribute)
                && $0.code != AXError.attributeUnsupported.rawValue
        }
        let protected = pending.protected || classificationFailed || role == "AXUnknown"
            || role == "AXSecureTextField" || subrole == "AXSecureTextField"
            || bool(values["AXProtectedContent"]) == true || bool(values["AXIsPassword"]) == true
            || ["password", "passcode", "credential", "secret", "token", "private key", "credit card", "social security"].contains(where: sensitiveLabel.contains)
        var actionArray: CFArray?
        let actionsError = try context.read(element) { AXUIElementCopyActionNames(element, &actionArray) }
        let actions = (actionArray as? [String] ?? []).sorted()
        if actionsError != .success && actionsError != .noValue && actionsError != .notImplemented {
            failures.append(.init(attribute: "actions", code: actionsError.rawValue))
        }
        var settable: [String] = []
        for attribute in attributes where Self.writableAttributes.contains(attribute) {
            var canSet: DarwinBoolean = false
            let error = try context.read(element) { AXUIElementIsAttributeSettable(element, attribute as CFString, &canSet) }
            if error == .success && canSet.boolValue { settable.append(attribute) }
            else if error != .success { failures.append(.init(attribute: attribute + ".settable", code: error.rawValue)) }
        }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
        let editable = bool(values["AXEditable"]) != false
            && (bool(values["AXEditable"]) == true || settable.contains("AXSelectedText")
                || (settable.contains("AXValue") && textRoles.contains(role)))
        let value: AXValueSummary
        if protected {
            value = AXValueSummary(kind: .protected, text: nil, isRedacted: true)
        } else if attributes.contains("AXValue") {
            let result = try readAttribute(element, attribute: "AXValue", context: context)
            if result.error == .success {
                // Editable user text is never projected to the planner. Verification
                // can use independent semantic state without logging entered values.
                value = summarize(result.value, redactText: editable)
            } else {
                failures.append(.init(attribute: "AXValue", code: result.error.rawValue))
                value = AXValueSummary(kind: .unavailable, text: nil, isRedacted: true)
            }
        } else { value = AXValueSummary(kind: .none, text: nil, isRedacted: false) }
        var links: [String: [AXUIElement]] = [:]
        var structureReliable = attributesError == .success
        var linksTruncated = false
        for attribute in Self.traversalAttributes + Self.relationshipAttributes where attributes.contains(attribute) {
            let result = try readElements(element, attribute: attribute, context: context)
            if result.error == .success {
                links[attribute] = result.elements
                linksTruncated = linksTruncated || result.truncated
            }
            else if result.error != .noValue {
                failures.append(.init(attribute: attribute, code: result.error.rawValue))
                if Self.traversalAttributes.contains(attribute) { structureReliable = false }
            }
        }
        let state = AXNodeState(enabled: bool(values["AXEnabled"]), focused: bool(values["AXFocused"]),
                                selected: bool(values["AXSelected"]), expanded: bool(values["AXExpanded"]),
                                minimized: bool(values["AXMinimized"]), required: bool(values["AXRequired"]),
                                visited: bool(values["AXVisited"]), editable: editable)
        return Draft(element: element, role: role, subrole: subrole, identifier: identifier, title: title,
                     description: description, help: bounded(string(values["AXHelp"])),
                     roleDescription: bounded(string(values["AXRoleDescription"])), name: name,
                     value: value, state: state, parent: asElement(values["AXParent"]), actions: actions,
                     attributes: attributes, settable: settable, links: links, failures: failures,
                     protected: protected, structureReliable: structureReliable, linksTruncated: linksTruncated,
                     identityName: identityName, identityIdentifier: identityIdentifier)
    }

    private func readBatch(_ element: AXUIElement, attributes: [String], context: ReadContext,
                           failures: inout [AXReadFailure]) throws -> [String: CFTypeRef] {
        guard !attributes.isEmpty else { return [:] }
        var array: CFArray?
        let error = try context.read(element) {
            AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &array)
        }
        var result: [String: CFTypeRef] = [:]
        if error == .success, let values = array as? [CFTypeRef], values.count == attributes.count {
            for (attribute, value) in zip(attributes, values) {
                if CFGetTypeID(value) == CFNullGetTypeID() { continue }
                if CFGetTypeID(value) == AXValueGetTypeID() {
                    let axValue = value as! AXValue
                    if AXValueGetType(axValue) == .axError {
                        var readError = AXError.success
                        if AXValueGetValue(axValue, .axError, &readError), readError != .noValue {
                            failures.append(.init(attribute: attribute, code: readError.rawValue))
                        }
                        continue
                    }
                }
                result[attribute] = value
            }
            return result
        }
        // Some providers do not implement the batched API. The same overall
        // deadline and finite per-message timeout still govern the fallback.
        for attribute in attributes {
            let item = try readAttribute(element, attribute: attribute, context: context)
            if item.error == .success { result[attribute] = item.value }
            else if item.error != .noValue && item.error != .attributeUnsupported {
                failures.append(.init(attribute: attribute, code: item.error.rawValue))
            }
        }
        return result
    }

    private func readAttribute(_ element: AXUIElement, attribute: String, context: ReadContext) throws -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = try context.read(element) { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }
        return (value, error)
    }

    private func readElements(_ element: AXUIElement, attribute: String, context: ReadContext) throws
        -> (elements: [AXUIElement], error: AXError, truncated: Bool) {
        var count: CFIndex = 0
        let countError = try context.read(element) {
            AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        }
        if countError == .success {
            guard count > 0 else { return ([], .success, false) }
            var values: CFArray?
            let error = try context.read(element) {
                AXUIElementCopyAttributeValues(element, attribute as CFString, 0, min(count, budget.maximumNodes), &values)
            }
            return (elements(values), error, count > budget.maximumNodes)
        }
        // Scalar relationships (notably AXTitleUIElement), and providers that
        // lack the paged API, still use the same deadline and retained-node cap.
        guard countError == .illegalArgument || countError == .notImplemented || countError == .attributeUnsupported else {
            return ([], countError, false)
        }
        let result = try readAttribute(element, attribute: attribute, context: context)
        let found = elements(result.value)
        return (Array(found.prefix(budget.maximumNodes)), result.error, found.count > budget.maximumNodes)
    }

    // MARK: Identity and dispatch

    private func validated(_ reference: String) throws -> Record {
        if changes.changed { invalidate() }
        guard let observation,
              let original = observation.records.first(where: { $0.node.id == reference }),
              original.node.reference.generation == generation else { throw AXSessionError.staleReference(reference) }
        try verifySelection(requireActive: true)
        let live = try captureTree()
        guard live.snapshot.isComplete && live.reliable else { throw AXSessionError.incompleteObservation }
        let matches = live.records.filter { $0.fingerprint == original.fingerprint }
        guard matches.count <= 1 else { throw AXSessionError.ambiguousTarget(reference, count: matches.count) }
        guard let match = matches.first else {
            if live.records.contains(where: { CFEqual($0.element, original.element) }) { throw AXSessionError.staleReference(reference) }
            throw AXSessionError.missingTarget(reference)
        }
        if !CFEqual(match.element, original.element) {
            // Fingerprint re-resolution is permitted only after the saved handle
            // has actually become invalid, never just because a similar node exists.
            var value: CFTypeRef?
            try configure(original.element)
            let error = AXUIElementCopyAttributeValue(original.element, "AXRole" as CFString, &value)
            guard error == .invalidUIElement else { throw AXSessionError.staleReference(reference) }
        }
        guard match.node.role != "AXUnknown" else { throw AXSessionError.staleReference(reference) }
        if match.node.state.enabled == false { throw AXSessionError.disabledTarget(reference) }
        if match.node.readFailures.contains(where: { ["AXEnabled", "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXParent", "actions"].contains($0.attribute) }) {
            throw AXSessionError.incompleteObservation
        }
        try verifySelection(requireActive: true)
        return match
    }

    private func mutate(reference: String, operation: String, method: String, body: () throws -> Void) throws -> AXActionReceipt {
        defer { invalidate() }
        try verifySelection(requireActive: true)
        try body()
        return AXActionReceipt(operation: operation, reference: reference, generation: generation &+ 1,
                               deliveryMethod: method, verificationRequired: true)
    }

    private func dispatch(_ error: AXError, operation: String) throws {
        if error == .cannotComplete { throw AXSessionError.deliveryUncertain(operation: operation, code: error.rawValue) }
        guard error == .success else { throw AXSessionError.axFailure(operation: operation, code: error.rawValue) }
    }

    private func requireAction(_ action: String, on element: AXUIElement) throws {
        try configure(element)
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success else { throw AXSessionError.axFailure(operation: "read action support", code: error.rawValue) }
        guard (names as? [String] ?? []).contains(action) else { throw AXSessionError.unsupportedAction(action) }
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) throws -> Bool {
        guard Self.writableAttributes.contains(attribute) else { return false }
        try configure(element)
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if error == .attributeUnsupported || error == .noValue { return false }
        guard error == .success else { throw AXSessionError.axFailure(operation: "read attribute support", code: error.rawValue) }
        return settable.boolValue
    }

    private func requireSettable(_ attribute: String, on element: AXUIElement) throws {
        guard try isSettable(attribute, on: element) else { throw AXSessionError.unsupportedAttribute(attribute) }
    }

    private func attributeValue(_ value: AXWritableValue, for attribute: String) throws -> CFTypeRef {
        switch (attribute, value) {
        case ("AXValue", .string(let string)), ("AXSelectedText", .string(let string)): return string as CFString
        case ("AXValue", .number(let number)) where number.isFinite: return NSNumber(value: number)
        case ("AXValue", .boolean(let boolean)): return boolean ? kCFBooleanTrue : kCFBooleanFalse
        case (let attribute, .boolean(let boolean)) where ["AXFocused", "AXSelected", "AXExpanded", "AXMinimized", "AXMain"].contains(attribute):
            return boolean ? kCFBooleanTrue : kCFBooleanFalse
        default: throw AXSessionError.invalidValue
        }
    }

    private func focusThroughAX(_ element: AXUIElement) throws {
        try verifySelection(requireActive: true)
        if let focused = try focusedElement(), CFEqual(element, focused) {
            try verifyFocus(element)
            return
        }
        try requireSettable("AXFocused", on: element)
        try dispatch(AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue), operation: "AXFocused")
        try verifyFocus(element)
    }

    private func keyboardTarget(_ target: Record) throws -> AXUIElement {
        guard let selection else { throw AXSessionError.noSelection }
        if CFEqual(target.element, selection.root) && !selection.isApplicationRoot {
            guard let focused = try focusedElement() else { throw AXSessionError.focusMismatch }
            try verifyFocus(focused)
            return focused
        }
        try verifyFocus(target.element)
        return target.element
    }

    private func verifyFocus(_ element: AXUIElement) throws {
        try verifySelection(requireActive: true)
        guard let selection, !selection.isApplicationRoot,
              let focused = try focusedElement(), CFEqual(element, focused) else { throw AXSessionError.focusMismatch }
        let context = ReadContext(budget: budget)
        let enabled = try readAttribute(element, attribute: "AXEnabled", context: context)
        if enabled.error == .success && bool(enabled.value) == false { throw AXSessionError.disabledTarget("focused element") }
        if enabled.error != .success && enabled.error != .attributeUnsupported && enabled.error != .noValue {
            throw AXSessionError.focusMismatch
        }
        let window = try readAttribute(element, attribute: "AXWindow", context: context)
        if let window = asElement(window.value), CFEqual(window, selection.root) { return }
        // Not every provider exposes AXWindow. Prove containment through AXParent.
        var cursor: AXUIElement? = element
        var visited = ElementIndex()
        var depth = 0
        while let current = cursor, depth <= budget.maximumDepth {
            if CFEqual(current, selection.root) { return }
            if visited.index(of: current) != nil { break }
            visited.insert(current, at: depth)
            cursor = asElement(try readAttribute(current, attribute: "AXParent", context: context).value)
            depth += 1
        }
        throw AXSessionError.focusMismatch
    }

    private func focusedElement() throws -> AXUIElement? {
        guard let selection else { throw AXSessionError.noSelection }
        let result = try readAttribute(selection.application, attribute: "AXFocusedUIElement", context: ReadContext(budget: budget))
        if result.error == .noValue || result.error == .attributeUnsupported { return nil }
        guard result.error == .success else { throw AXSessionError.focusMismatch }
        return asElement(result.value)
    }

    private func verifySelection(requireActive: Bool) throws {
        guard AXIsProcessTrusted() else { throw AXSessionError.accessibilityPermissionDenied }
        guard let selection else { throw AXSessionError.noSelection }
        let process = try runningProcess(selection.pid)
        guard process.launchDate == selection.launchDate && process.bundleURL == selection.bundleURL else {
            throw AXSessionError.processUnavailable(selection.pid)
        }
        if requireActive && (!process.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != selection.pid) {
            throw AXSessionError.focusMismatch
        }
        let context = ReadContext(budget: budget)
        if selection.isApplicationRoot {
            let windows = try readAttribute(selection.application, attribute: "AXWindows", context: context)
            guard windows.error == .success || windows.error == .noValue || windows.error == .attributeUnsupported else {
                throw AXSessionError.axFailure(operation: "read windows", code: windows.error.rawValue)
            }
            if !elements(windows.value).isEmpty { throw AXSessionError.windowNotSelected }
            return
        }
        do {
            try catalog.withWindow(pid: selection.pid, windowID: selection.windowID) { current in
                guard CFEqual(current, selection.root) else { throw AXSessionError.windowUnavailable(selection.windowID) }
            }
        } catch { throw AXSessionError.windowUnavailable(selection.windowID) }
        let focused = try readAttribute(selection.application, attribute: "AXFocusedWindow", context: context)
        let current: AXUIElement?
        if let window = asElement(focused.value) { current = window }
        else if focused.error == .success || focused.error == .noValue || focused.error == .attributeUnsupported {
            current = asElement(try readAttribute(selection.application, attribute: "AXMainWindow", context: context).value)
        } else { current = nil }
        guard let current, CFEqual(current, selection.root) else { throw AXSessionError.focusMismatch }
    }

    private func runningProcess(_ pid: pid_t) throws -> NSRunningApplication {
        guard pid > 0, let process = NSRunningApplication(processIdentifier: pid), !process.isTerminated else {
            throw AXSessionError.processUnavailable(pid)
        }
        return process
    }

    private func configure(_ element: AXUIElement) throws {
        let error = AXUIElementSetMessagingTimeout(element, budget.messagingTimeout)
        guard error == .success else { throw AXSessionError.axFailure(operation: "set messaging timeout", code: error.rawValue) }
    }

    private func checkBudget() throws {
        guard budget.maximumNodes > 0, budget.maximumNodes <= 100_000,
              budget.maximumDepth > 0, budget.maximumDepth <= 512,
              budget.maximumSeconds.isFinite, budget.maximumSeconds > 0, budget.maximumSeconds <= 60,
              budget.messagingTimeout.isFinite, budget.messagingTimeout > 0, budget.messagingTimeout <= 5,
              budget.maximumTextLength > 0, budget.maximumTextLength <= 10_000 else { throw AXSessionError.invalidBudget }
    }

    // MARK: Keyboard-only fallback

    private func validateChord(_ chord: AXKeyChord) throws {
        if [.a, .c, .v, .x, .z].contains(chord.key) && !chord.modifiers.contains(.command) {
            throw AXSessionError.unsupportedAction("Letter keys require an allowlisted Command chord; use TYPE_TEXT for text")
        }
    }

    private func sendKey(_ chord: AXKeyChord, into element: AXUIElement) throws {
        try validateChord(chord)
        let code: CGKeyCode
        switch chord.key {
        case .enter: code = 36
        case .tab: code = 48
        case .escape: code = 53
        case .backspace: code = 51
        case .deleteForward: code = 117
        case .space: code = 49
        case .up: code = 126
        case .down: code = 125
        case .left: code = 123
        case .right: code = 124
        case .pageUp: code = 116
        case .pageDown: code = 121
        case .home: code = 115
        case .end: code = 119
        case .a: code = 0
        case .c: code = 8
        case .v: code = 9
        case .x: code = 7
        case .z: code = 6
        }
        var flags: CGEventFlags = []
        for modifier in chord.modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false),
              let selection else { throw AXSessionError.unsupportedAction("Keyboard event creation") }
        down.flags = flags
        up.flags = flags
        try verifyFocus(element)
        down.postToPid(selection.pid)
        // Always balance a delivered key-down, even if focus subsequently changes.
        up.postToPid(selection.pid)
    }

    private func typeUnicode(_ text: String, into element: AXUIElement) throws {
        let units = Array(text.utf16)
        guard let source = CGEventSource(stateID: .privateState), let selection else {
            throw AXSessionError.unsupportedAction("Unicode event creation")
        }
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                if start > 0 { throw AXSessionError.deliveryUncertain(operation: "TYPE_TEXT", code: AXError.failure.rawValue) }
                throw AXSessionError.unsupportedAction("Unicode event creation")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: end - start, unicodeString: buffer.baseAddress!.advanced(by: start))
                up.keyboardSetUnicodeString(stringLength: end - start, unicodeString: buffer.baseAddress!.advanced(by: start))
            }
            do { try verifyFocus(element) }
            catch {
                if start > 0 { throw AXSessionError.deliveryUncertain(operation: "TYPE_TEXT", code: AXError.failure.rawValue) }
                throw error
            }
            down.postToPid(selection.pid)
            up.postToPid(selection.pid)
            start = end
        }
    }

    // MARK: Notifications and private value conversion

    private func installObserver(pid: pid_t, application: AXUIElement, root: AXUIElement) {
        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let signal = Unmanaged<ChangeSignal>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { signal.changed = true }
        }, &created)
        guard result == .success, let created else { return }
        observer = created
        let context = Unmanaged.passUnretained(changes).toOpaque()
        let notifications = ["AXWindowCreated", "AXUIElementDestroyed", "AXFocusedWindowChanged",
                             "AXMainWindowChanged", "AXLayoutChanged", "AXCreated", "AXChildrenChanged",
                             "AXSelectedChildrenChanged"]
        for element in [application, root] {
            for notification in notifications {
                AXObserverAddNotification(created, element, notification as CFString, context)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        changes.changed = false
    }

    private func bounded(_ text: String?) -> String? { text.map { String($0.prefix(budget.maximumTextLength)) } }
    private func string(_ value: CFTypeRef?) -> String? { value as? String }
    private func bool(_ value: CFTypeRef?) -> Bool? { (value as? NSNumber)?.boolValue }

    private func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        if let element = asElement(value) { return [element] }
        return (value as? [CFTypeRef] ?? []).compactMap(asElement)
    }

    private func summarize(_ value: CFTypeRef?, redactText: Bool) -> AXValueSummary {
        guard let value else { return .init(kind: .none, text: nil, isRedacted: false) }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .init(kind: .boolean, text: bool(value) == true ? "true" : "false", isRedacted: false) }
        if let text = value as? String { return .init(kind: .text, text: redactText ? nil : bounded(text), isRedacted: redactText) }
        if let number = value as? NSNumber { return .init(kind: .number, text: number.stringValue, isRedacted: false) }
        if CFGetTypeID(value) == CFArrayGetTypeID() { return .init(kind: .collection, text: nil, isRedacted: true) }
        return .init(kind: .other, text: nil, isRedacted: true)
    }

    private struct Selection {
        let pid: pid_t
        let launchDate: Date?
        let bundleURL: URL?
        let windowID: String
        let application: AXUIElement
        let root: AXUIElement
        let isApplicationRoot: Bool
    }

    private struct Pending {
        let element: AXUIElement
        let depth: Int
        let protected: Bool
    }

    private struct Draft {
        var element: AXUIElement
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
        let parent: AXUIElement?
        let actions: [String]
        let attributes: [String]
        let settable: [String]
        let links: [String: [AXUIElement]]
        let failures: [AXReadFailure]
        let protected: Bool
        let structureReliable: Bool
        let linksTruncated: Bool
        let identityName: String
        let identityIdentifier: String?
    }

    private struct Fingerprint: Equatable {
        struct Ancestor: Equatable {
            let role: String
            let name: String
            let identifier: String?
        }
        let role: String
        let subrole: String?
        let identifier: String?
        let name: String
        let valueKind: AXValueKind
        let selected: Bool?
        let ancestors: [Ancestor]
        let actions: [String]

        init(_ node: AXNode, name: String, identifier: String?, ancestors: [Ancestor]) {
            role = node.role
            subrole = node.subrole
            self.identifier = identifier
            self.name = name
            valueKind = node.value.kind
            selected = node.state.selected
            self.ancestors = ancestors
            actions = node.actions
        }
    }

    private struct Record {
        let element: AXUIElement
        let node: AXNode
        let fingerprint: Fingerprint
    }

    private struct Capture {
        let snapshot: AXSnapshot
        let records: [Record]
        let reliable: Bool
    }

    private struct ElementIndex {
        private var buckets: [CFHashCode: [(AXUIElement, Int)]] = [:]
        func index(of element: AXUIElement) -> Int? {
            buckets[CFHash(element)]?.first(where: { CFEqual($0.0, element) })?.1
        }
        mutating func insert(_ element: AXUIElement, at index: Int) {
            buckets[CFHash(element), default: []].append((element, index))
        }
    }

    // AXObserver's source is installed only on the main run loop. This signal
    // avoids capturing either the session or its AX handles in the C callback.
    @MainActor
    private final class ChangeSignal {
        var changed = false
    }

    private final class ReadContext {
        let started = ProcessInfo.processInfo.systemUptime
        let budget: AXTraversalBudget
        var expired: Bool { ProcessInfo.processInfo.systemUptime - started >= budget.maximumSeconds }
        init(budget: AXTraversalBudget) { self.budget = budget }

        func read(_ element: AXUIElement, body: () -> AXError) throws -> AXError {
            for attempt in 0..<2 {
                let remaining = budget.maximumSeconds - (ProcessInfo.processInfo.systemUptime - started)
                guard remaining > 0 else { throw AXSessionError.observationTimedOut }
                let timeout = AXUIElementSetMessagingTimeout(element, min(budget.messagingTimeout, Float(remaining)))
                guard timeout == .success else { return timeout }
                let result = body()
                if result != .cannotComplete || attempt == 1 { return result }
            }
            return .cannotComplete
        }
    }
}
