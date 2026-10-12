import Foundation
import XCTest
@testable import Relay

final class RelayHostRotationRPCTests: XCTestCase {
    private let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let operationID = String(repeating: "a", count: 32)
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func enrollment() -> [String: Any] {
        ["session_id": "22222222-2222-4222-8222-222222222222", "client": "codex", "cwd": "/repo",
         "pane_id": pane.uuidString.lowercased(), "agent_pid": 101, "agent_start": 102,
         "worker_pid": 201, "worker_start": 202, "node_boot_id": "boot"]
    }
    private func enrolled() -> [String: Any] {
        ["v": 1, "operation_id": operationID, "operation": "enroll", "enabled": true,
         "state": "pending_evaluation", "generation": 1, "enrollment": enrollment(),
         "lifecycle": "unavailable", "refresh_capability": "unverified"]
    }
    private func enrollRequest() -> RelayHostRotationRPC.Request {
        .init(operation: .enroll, id: operationID,
              sessionID: "22222222-2222-4222-8222-222222222222", client: "codex", cwd: "/repo",
              agentPID: 101, agentStart: 102)
    }

    func testReadOnlyProbeAndUnsupportedShape() throws {
        let request = RelayHostRotationRPC.Request(operation: .status)
        XCTAssertTrue(request.valid)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "operation"])
        XCTAssertTrue(try RelayHostRotationRPC.decode(data(["state": "unsupported"]), paneID: pane, request: request).isUnsupported)
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(["state": "unsupported"]), paneID: pane, request: enrollRequest()))
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(["state": "unsupported", "v": 1, "enabled": true]), paneID: pane, request: request))
    }

    func testInitialStatusDoesNotInventEnrollment() throws {
        let object: [String: Any] = ["v": 1, "enabled": false, "state": "not_enrolled", "generation": 0,
                                    "lifecycle": "unavailable", "refresh_capability": "unverified"]
        let status = try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status))
        XCTAssertEqual(status.title, "Off")
        XCTAssertNil(status.enrollment)
        var invalid = object; invalid["enabled"] = true
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(invalid), paneID: pane, request: .init(operation: .status)))
    }

    func testEnrollmentMatchesExactReceipt() throws {
        let request = enrollRequest()
        XCTAssertTrue(request.valid)
        let status = try RelayHostRotationRPC.decode(data(enrolled()), paneID: pane, request: request)
        XCTAssertEqual(status.enrollment?.agentPID, 101)
        for (key, value) in ["operation_id": String(repeating: "b", count: 32), "operation": "disable"] {
            var object = enrolled(); object[key] = value
            XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: request))
        }
        var object = enrolled(); object["enabled"] = false
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: request))
        for (key, value) in ["pane_id": UUID().uuidString.lowercased(), "cwd": "/different", "session_id": "different"] {
            var binding = enrollment(); binding[key] = value; object = enrolled(); object["enrollment"] = binding
            XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: request))
        }
        var binding = enrollment(); binding["agent_pid"] = 102; object = enrolled(); object["enrollment"] = binding
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: request))
    }

    func testUInt64IdentityRemainsExact() throws {
        var request = enrollRequest(); request.agentStart = UInt64.max
        let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(wire.contains("18446744073709551615"))
        let body = String(decoding: try data(enrolled()), as: UTF8.self)
            .replacingOccurrences(of: "\"agent_start\":102", with: "\"agent_start\":18446744073709551615")
        let status = try RelayHostRotationRPC.decode(Data(body.utf8), paneID: pane, request: request)
        XCTAssertEqual(status.enrollment?.agentStart, UInt64.max)
    }

    func testRequestShapesRejectUnboundWrites() {
        var request = enrollRequest(); request.agentStart = 0; XCTAssertFalse(request.valid)
        request = enrollRequest(); request.cwd = "relative"; XCTAssertFalse(request.valid)
        request = enrollRequest(); request.client = "shell"; XCTAssertFalse(request.valid)
        request = enrollRequest(); request.id = UUID().uuidString; XCTAssertFalse(request.valid)
        request = .init(operation: .disable, id: operationID); XCTAssertTrue(request.valid)
        request.sessionID = "session"; XCTAssertFalse(request.valid)
        request = .init(operation: .status); request.id = operationID; XCTAssertFalse(request.valid)
    }

    func testRefusalAndCorruptStatusAreErrors() throws {
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(["state": "refused", "message": "input lease changed"]),
            paneID: pane, request: enrollRequest())) { error in
            XCTAssertEqual(error.localizedDescription, "input lease changed")
        }
        var object = enrolled(); object["generation"] = -1
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)))
        object = enrolled(); object["enrollment"] = nil
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)))
        XCTAssertThrowsError(try RelayHostRotationRPC.decode(Data(repeating: 32, count: 262_145), paneID: pane, request: .init(operation: .status)))
    }

    func testHumanTakeoverAndRecoveryAreVisible() throws {
        var object = enrolled(); object["state"] = "human_takeover"; object["enabled"] = false
        XCTAssertEqual(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)).title, "Paused after your input")
        object = enrolled(); object["state"] = "native_refused"
        XCTAssertEqual(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)).title, "Waiting for a new completed turn")
        object = enrolled(); object["state"] = "native_finalization_pending"
        XCTAssertEqual(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)).title, "Finishing recovery")
        object = enrolled(); object["enabled"] = false; object["state"] = "persistence_failed"
        XCTAssertEqual(try RelayHostRotationRPC.decode(data(object), paneID: pane, request: .init(operation: .status)).title, "Needs attention")
    }

    func testNativeBindingRequiresOriginalProviderIdentity() throws {
        let object: [String: Any] = ["version": 1, "session_id": "session", "transcript_path": "/private/source.jsonl",
                                    "revision": "revision", "producer": ["pane_id": pane.uuidString.lowercased(),
                                    "provider": "claude", "process_id": 101, "process_start": 102]]
        let binding = try JSONDecoder().decode(RelayHostRotationRPC.NativeBinding.self, from: data(object))
        XCTAssertTrue(binding.valid(for: pane))
        XCTAssertFalse(binding.valid(for: UUID()))
        var invalid = object
        invalid["producer"] = ["pane_id": pane.uuidString.lowercased(), "provider": "shell", "process_id": 101, "process_start": 102]
        XCTAssertFalse(try JSONDecoder().decode(RelayHostRotationRPC.NativeBinding.self, from: data(invalid)).valid(for: pane))
    }
}
