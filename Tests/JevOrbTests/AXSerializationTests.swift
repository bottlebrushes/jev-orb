import Foundation
import XCTest
@testable import JevOrb

final class AXSerializationTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testSnapshotRoundTripPreservesSemanticGraphAndObservationFailures() throws {
        let root = reference(node: 0)
        let child = reference(node: 1)
        let ancestor = AXAncestor(reference: root.description, role: "AXGroup", name: "案件 – résumé", identifier: "case-group")
        let rootNode = node(reference: root, role: "AXGroup", relationships: ["AXChildren": [child.description]])
        let childNode = node(
            reference: child, role: "AXStaticText", name: "案件 – résumé",
            value: .init(kind: .text, text: "Ready\nfor review", isRedacted: false),
            parent: root.description, ancestors: [ancestor],
            relationships: ["AXTitleUIElement": [root.description]],
            failures: [.init(attribute: "AXHelp", code: -25205)]
        )
        let original = snapshot(nodes: [rootNode, childNode])
        let restored = try roundTrip(original)

        XCTAssertEqual(restored.sessionID, original.sessionID)
        XCTAssertEqual(restored.processIdentifier, original.processIdentifier)
        XCTAssertEqual(restored.windowID, original.windowID)
        XCTAssertEqual(restored.generation, original.generation)
        XCTAssertEqual(restored.rootReference, root.description)
        let nodes = Dictionary(uniqueKeysWithValues: restored.nodes.map { ($0.id, $0) })
        let restoredRoot = try XCTUnwrap(nodes[restored.rootReference])
        let restoredChild = try XCTUnwrap(nodes[child.description])
        XCTAssertEqual(restoredRoot.relationships["AXChildren"], [restoredChild.id])
        XCTAssertEqual(restoredChild.parent, restoredRoot.id)
        XCTAssertEqual(restoredChild.ancestors, [ancestor])
        XCTAssertEqual(restoredChild.relationships["AXTitleUIElement"], [restoredRoot.id])
        XCTAssertEqual(restoredChild.name, childNode.name)
        XCTAssertEqual(restoredChild.value, childNode.value)
        XCTAssertEqual(restoredChild.readFailures, childNode.readFailures)
        XCTAssertTrue(restored.isComplete, "A per-node read failure does not mean traversal was truncated")
    }

    // These are already-sanitized observation fixtures. Sanitizing live AX values
    // belongs to AXSession; this guards the model-facing serialization boundary.
    func testRedactedSecureAndEditableFixturesRemainValuelessOnTheWire() throws {
        let protected = node(
            reference: reference(node: 0), role: "AXTextField", subrole: "AXSecureTextField",
            value: .init(kind: .protected, text: nil, isRedacted: true), editable: true,
            settable: ["AXValue"]
        )
        let editable = node(
            reference: reference(node: 1), role: "AXTextArea",
            value: .init(kind: .text, text: nil, isRedacted: true), editable: true,
            settable: ["AXValue"]
        )
        let data = try JSONEncoder().encode(snapshot(nodes: [protected, editable]))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedNodes = try XCTUnwrap(payload["nodes"] as? [[String: Any]])
        for encodedNode in encodedNodes {
            let value = try XCTUnwrap(encodedNode["value"] as? [String: Any])
            XCTAssertNil(value["text"], "Redacted fixtures must not introduce a serializable text value")
            XCTAssertEqual(value["isRedacted"] as? Bool, true)
        }
        let restored = try JSONDecoder().decode(AXSnapshot.self, from: data)
        XCTAssertEqual(restored.nodes.map(\.value), [protected.value, editable.value])
        XCTAssertTrue(restored.nodes.allSatisfy { $0.state.editable && $0.isActionable })
    }

    func testReferencesDistinguishEveryIdentityScopeAfterSerialization() throws {
        let otherSession = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let references = [
            reference(node: 0),
            reference(node: 0, session: otherSession),
            reference(node: 0, pid: 202),
            reference(node: 0, window: "other-window"),
            reference(node: 0, generation: 8),
            reference(node: 1)
        ]
        let restored = try roundTrip(references)
        XCTAssertEqual(Set(restored).count, references.count)
        XCTAssertEqual(Set(restored.map(\.description)).count, references.count)
        XCTAssertEqual(restored, references)
        XCTAssertEqual(restored[0].description, "@\(sessionID.uuidString):101:window-fixture:7:0")
    }

    func testActionabilityRequiresExposedCapabilitiesRatherThanRole() throws {
        let unsupportedButton = node(reference: reference(node: 0), role: "AXButton")
        let customControl = node(reference: reference(node: 1), role: "AXUnknown", actions: ["AXPress"])
        let editableControl = node(reference: reference(node: 2), role: "AXTextField", editable: true, settable: ["AXValue"])
        let restored = try roundTrip(snapshot(nodes: [unsupportedButton, customControl, editableControl]))
        XCTAssertEqual(restored.nodes.map(\.isActionable), [false, true, true])
    }

    func testTruncatedSnapshotCannotBecomeCompleteThroughSerialization() throws {
        let reasons: [AXTruncationReason] = [.nodeLimit, .depthLimit, .timeLimit]
        let restored = try roundTrip(snapshot(nodes: [node(reference: reference(node: 0))], truncation: reasons))
        XCTAssertFalse(restored.isComplete)
        XCTAssertEqual(restored.truncation, reasons)
    }

    func testKeyboardSchemaRejectsUnknownKeysAndModifiers() throws {
        let chord = AXKeyChord(key: .tab, modifiers: [.shift, .option])
        let restored = try roundTrip(chord)
        XCTAssertEqual(restored.key, .tab)
        XCTAssertEqual(restored.modifiers, [.shift, .option])
        XCTAssertThrowsError(try JSONDecoder().decode(AXKeyChord.self, from: Data(#"{"key":"arbitrary-command","modifiers":[]}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AXKeyChord.self, from: Data(#"{"key":"tab","modifiers":["unknown"]}"#.utf8)))
    }

    private func reference(node: Int, session: UUID? = nil, pid: pid_t = 101,
                           window: String = "window-fixture", generation: UInt64 = 7) -> AXElementReference {
        AXElementReference(sessionID: session ?? sessionID, processIdentifier: pid,
                           windowID: window, generation: generation, nodeID: node)
    }

    private func node(reference: AXElementReference, role: String = "AXGroup", subrole: String? = nil,
                      name: String = "Fixture", value: AXValueSummary = .init(kind: .none, text: nil, isRedacted: false),
                      editable: Bool = false, parent: String? = nil, ancestors: [AXAncestor] = [],
                      actions: [String] = [], settable: [String] = [], relationships: [String: [String]] = [:],
                      failures: [AXReadFailure] = []) -> AXNode {
        AXNode(reference: reference, role: role, subrole: subrole, identifier: nil, title: nil,
               description: nil, help: nil, roleDescription: nil, name: name, value: value,
               state: .init(enabled: true, focused: nil, selected: nil, expanded: nil,
                            minimized: nil, required: nil, visited: nil, editable: editable),
               parent: parent, ancestors: ancestors, actions: actions, attributes: ["AXRole", "AXValue"],
               settableAttributes: settable, relationships: relationships, readFailures: failures)
    }

    private func snapshot(nodes: [AXNode], truncation: [AXTruncationReason] = []) -> AXSnapshot {
        AXSnapshot(sessionID: sessionID, processIdentifier: 101, windowID: "window-fixture", generation: 7,
                   rootReference: reference(node: 0).description, nodes: nodes, truncation: truncation,
                   elapsedSeconds: 0.01)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
