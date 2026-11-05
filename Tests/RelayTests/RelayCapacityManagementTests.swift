import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Relay

final class RelayCapacityManagementTests: XCTestCase {
    private func fixture(_ id: String = "request") throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let settings = try JSONSerialization.jsonObject(with: encoder.encode(RelayCapacityManagement.Settings()))
        return try JSONSerialization.data(withJSONObject: ["request_id": id, "result": [
            "v": 1, "revision": 0, "settings": settings, "state": "held", "reason": "native_retirement_contract_unavailable",
            "supported": true, "managed": true, "enabled": true, "ready": false,
            "capabilities": ["provider_version": "", "admission": false, "complete_work": false, "scheduled_tasks": false, "preservation": false, "pickup": false, "reason": "unsupported"],
            "accounts": [], "registered_accounts": ["team", "personal"]
        ]], options: .sortedKeys)
    }
    func testStrictResponseIdentityDefaultsAndCapability() throws {
        let data = try fixture(); let status = try RelayCapacityManagement.decode(data, requestID: "request")
        XCTAssertTrue(status.enabled); XCTAssertFalse(status.ready, "ENABLED_IS_NOT_READY")
        XCTAssertEqual(status.settings.thresholdTokens, 100_000)
        XCTAssertTrue(status.settings.newPaneDefault); XCTAssertFalse(status.settings.quotaEnabled); XCTAssertTrue(status.settings.rebalanceEnabled, "REBALANCE_DEFAULT_ON_WITHOUT_ACCOUNT_AUTHORITY")
        XCTAssertThrowsError(try RelayCapacityManagement.decode(data, requestID: "other"), "EXACT_RESPONSE_IDENTITY")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any]); result["ready"] = true; object["result"] = result
        XCTAssertThrowsError(try RelayCapacityManagement.decode(JSONSerialization.data(withJSONObject: object), requestID: "request"), "UNAVAILABLE_CAPABILITY_CANNOT_BE_READY")
        result["ready"] = false; result["managed"] = false; object["result"] = result
        XCTAssertThrowsError(try RelayCapacityManagement.decode(JSONSerialization.data(withJSONObject: object), requestID: "request"), "ENABLED_WITHOUT_LANE_OWNER")
        result["managed"] = true
        result["ready"] = false; result["source"] = ["pid": 10, "admission": true]; object["result"] = result
        XCTAssertThrowsError(try RelayCapacityManagement.decode(JSONSerialization.data(withJSONObject: object), requestID: "request"), "UNKNOWN_NESTED_AUTHORITY")
    }
    func testParserPropertiesAndMutatedInputs() throws {
        let seed = try fixture()
        for i in 0..<seed.count { XCTAssertThrowsError(try RelayCapacityManagement.decode(seed.prefix(i), requestID: "request"), "TRUNCATED_RESPONSE_\(i)") }
        for raw in [#"{"a":1,"a":2}"#, #"{"a":{"b":1,"b":2}}"#, #"{"\u0061":1,"a":2}"#, #"[1] {}"#, #"{"x":"bad\u0000","x":2}"#] {
            XCTAssertThrowsError(try RelayCapacityJSON.validate(Data(raw.utf8)), "DUPLICATE_OR_TRAILING_JSON")
        }
        var state: UInt64 = 1631
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        for _ in 0..<10_000 {
            var data = Array(seed)
            let index = Int(next() % UInt64(data.count)); data[index] = UInt8(truncatingIfNeeded: next() >> 32)
            if let status = try? RelayCapacityManagement.decode(Data(data), requestID: "request") {
                XCTAssertTrue(status.valid, "ACCEPTED_RESPONSE_DOMAIN_PROPERTY")
                XCTAssertFalse(status.ready && !status.capabilities.ready, "CAPABILITY_PROPERTY")
            }
        }
        print("capacity Swift codec: seed=1631 mutated_inputs=10000 plus every seed truncation; accepted responses checked for domain/identity/capability")
    }
    func testNativeActionSchemaCannotCarryAuthority() throws {
        let request = RelayCapacityActionRequest(instance: UUID(), requestID: UUID(), action: "manual_move", targetAccount: "personal")
        let bytes = try JSONEncoder().encode(request); XCTAssertEqual(try RelayCapacityActionRequest.decode(bytes), request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); object["capabilities"] = ["admission": true]
        XCTAssertThrowsError(try RelayCapacityActionRequest.decode(JSONSerialization.data(withJSONObject: object)), "ACTION_AUTHORITY_INJECTION")
        object.removeValue(forKey: "capabilities")
        for key in ["weights", "approved_accounts", "settings"] {
            object[key] = []
            XCTAssertThrowsError(try RelayCapacityActionRequest.decode(JSONSerialization.data(withJSONObject: object)), "MODEL_POLICY_AUTHORITY_INJECTION")
            object.removeValue(forKey: key)
        }
        object["action"] = "stop_tasks"
        XCTAssertThrowsError(try RelayCapacityActionRequest.decode(JSONSerialization.data(withJSONObject: object)), "DESTRUCTIVE_ACTION_INJECTION")
    }
    func testDatedWeightEditsAndStrictStatusBounds() throws {
        let now: Int64 = 1_000_000
        let initial = try XCTUnwrap(RelayCapacityManagement.parseWeights("claude:personal:*=5, codex:work:*=1", existing: [], nowMs: now))
        let edited = try XCTUnwrap(RelayCapacityManagement.parseWeights("codex:work:*=1, claude:personal:*=6", existing: initial, nowMs: now + 10_000))
        XCTAssertEqual(edited[0].asOfMs, now, "UNCHANGED_WEIGHT_PROVENANCE_PRESERVED")
        XCTAssertEqual(edited[1].asOfMs, now + 10_000, "EDIT_DATES_ONLY_CHANGED_ASSUMPTION")
        let reconfirmed = try XCTUnwrap(RelayCapacityManagement.parseWeights(RelayCapacityManagement.formatWeights(initial), existing: initial, nowMs: now + 20_000, reconfirm: true))
        XCTAssertTrue(reconfirmed.allSatisfy { $0.asOfMs == now + 20_000 }, "EXPLICIT_RECONFIRM_ONLY")
        for text in ["claude:a:*=0", "claude:a:*=-1", "claude:a:*=nan", "claude:a:*=inf", "claude:a:*=1000001", "claude:a:*=1,claude:a:*=2", "other:a:*=1", "claude:a:*=1,"] {
            XCTAssertNil(RelayCapacityManagement.parseWeights(text, existing: [], nowMs: now), "INVALID_ASSUMPTION_\(text)")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any])
        var settings = try XCTUnwrap(result["settings"] as? [String: Any])
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let weights = (0..<64).map { RelayCapacityManagement.Weight(provider: "claude", account: "account\($0)", model: "*", value: 1, asOfMs: now, expiresMs: now + 100_000) }
        settings["weights"] = try JSONSerialization.jsonObject(with: encoder.encode(weights)); result["settings"] = settings
        result["operation"] = ["plan": ["preparation": ["canonical_json": ["gates": ["native": ["status": "pass", "number": 1]]]]]]
        object["result"] = result
        XCTAssertEqual(try RelayCapacityManagement.decode(JSONSerialization.data(withJSONObject: object), requestID: "request").settings.weights.count, 64, "WEIGHTS_SCHEMA_BOUND_64")
        result["operation"] = ["plan": ["preparation": ["canonical_json": ["gates": ["native": ["status": "unknown", "number": 1]]]]]]; object["result"] = result
        XCTAssertThrowsError(try RelayCapacityManagement.decode(JSONSerialization.data(withJSONObject: object), requestID: "request"), "INVALID_CANONICAL_GATE")
    }
    @MainActor func testActualNativeRPCEnvelopeAndHeldReceipt() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try XCTUnwrap(workspace.activePane)
        var observed: [String: Any] = [:]
        let value = try await RelayCapacityManagement.send(.init(operation: "capacity_status", paneId: pane.id.uuidString.lowercased()), profile: pane.profile) { payload in
            observed = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let id = try XCTUnwrap(observed["request_id"] as? String)
            return try self.fixture(id)
        }
        XCTAssertEqual(observed["operation"] as? String, "host_accounts", "REAL_HOST_ROUTE")
        let forward = try XCTUnwrap(observed["host_accounts"] as? [String: Any]); let request = try XCTUnwrap(forward["request"] as? [String: Any])
        XCTAssertEqual(request["operation"] as? String, "capacity_status")
        XCTAssertNil(request["source"]); XCTAssertNil(request["capabilities"])
        XCTAssertFalse(value.ready); XCTAssertEqual(value.reason, "native_retirement_contract_unavailable")
    }
    @MainActor func testMikoActualValidationAndNativeActionCard() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try XCTUnwrap(workspace.activePaneID)
        let snapshot = RelayAssistantSnapshot.capture(workspace)
        let fields: [String: RelayPaneHealthJSON] = ["pane_id": .string(pane.uuidString.lowercased()), "paused": .bool(true)]
        guard case .success(.change(let change)) = RelayAssistantToolValidator.validate(name: "set_capacity_pause", input: .object(fields), snapshot: snapshot) else { return XCTFail("MIKO_PAUSE_VALIDATION") }
        XCTAssertEqual(RelayAssistantActions.requiredCapabilities(change), [.input], "MIKO_SAME_NATIVE_GRANT")
        let card = RelayAssistantActions.card(for: change, actionID: UUID(), executor: CapacityCardExecutor(), snapshot: snapshot, workspace: workspace,
            facts: .live(workspace), now: Date(), timeout: 60)
        XCTAssertTrue(card.preview.contains("capacity_action=pause"), "MIKO_NATIVE_CARD_PREVIEW")
        XCTAssertEqual(card.method, "POST"); XCTAssertEqual(card.path, "/api/panes/" + pane.uuidString.lowercased() + "/capacity-action", "MIKO_REAL_NATIVE_ROUTE")
        XCTAssertEqual(try RelayCapacityActionRequest.decode(card.body).action, "pause", "MIKO_TYPED_NATIVE_PAYLOAD")
        let bad: [String: RelayPaneHealthJSON] = ["pane_id": .string(pane.uuidString.lowercased()), "action": .string("stop_tasks")]
        guard case .failure = RelayAssistantToolValidator.validate(name: "request_capacity_action", input: .object(bad), snapshot: snapshot) else { return XCTFail("MIKO_DESTRUCTIVE_ACTION_ACCEPTED") }
    }
    func testNativeActionReceiptBoundedAuthorityAndTwoActors() throws {
        let instance = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, pane = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, otherPane = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let wrongInstance = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let request = RelayCapacityActionRequest(instance: instance, requestID: requestID, action: "manual_refresh")
        let conflict = RelayCapacityActionRequest(instance: instance, requestID: requestID, action: "manual_move", targetAccount: "personal")
        var visits = 0, transitions = 0
        func walk(_ state: RelayCapacityActionReceipts, _ owner: (UUID, RelayCapacityActionRequest)?, _ depth: Int) {
            visits += 1
            XCTAssertLessThanOrEqual(state.count, 1, "RECEIPT_BOUND")
            guard depth > 0 else { return }
            for operation in 0..<7 {
                var next = state, nextOwner = owner
                if operation == 6 { next.finish(pane: pane, requestID: requestID, result: ["status": "held"] ) }
                else {
                    let body = operation == 2 ? conflict : request
                    let target = operation == 3 ? otherPane : pane
                    let expected = operation == 4 ? wrongInstance : instance
                    let grant = operation != 5
                    let result = next.begin(pane: target, request: body, expectedInstance: expected, inputGranted: grant)
                    if result == .admitted {
                        XCTAssertTrue(grant && expected == instance, "UNAUTHORIZED_NATIVE_ACTION_ADMITTED")
                        XCTAssertNil(owner, "REPLAYED_NATIVE_ACTION")
                        nextOwner = (target, body)
                    }
                    if !grant || expected != instance {
                        guard case .refused = result else { return XCTFail("DENIED_NATIVE_GRANT_RETURNED_RESULT") }
                        XCTAssertEqual(next.count, state.count)
                    } else if let owner {
                        if owner.0 != target || owner.1 != body {
                            guard case .refused = result else { return XCTFail("NATIVE_RECEIPT_IDENTITY_CONFLICT") }
                        } else {
                            guard case .result = result else { return XCTFail("EXACT_NATIVE_RECEIPT_NOT_CACHED") }
                        }
                    } else { XCTAssertEqual(result, .admitted, "FRESH_NATIVE_RECEIPT_NOT_ADMITTED") }
                }
                transitions += 1; walk(next, nextOwner, depth - 1)
            }
        }
        walk(RelayCapacityActionReceipts(), nil, 4)
        XCTAssertEqual(visits, 2801); XCTAssertEqual(transitions, 2800)
        let schedules = [[0,0,1,1],[0,1,0,1],[0,1,1,0],[1,0,0,1],[1,0,1,0],[1,1,0,0]]
        for schedule in schedules {
            var receipts = RelayCapacityActionReceipts(), actorStep = [0,0], admissions = 0
            for actor in schedule {
                if actorStep[actor] == 0 {
                    if receipts.begin(pane: pane, request: request, expectedInstance: instance, inputGranted: true) == .admitted { admissions += 1 }
                } else { receipts.finish(pane: pane, requestID: requestID, result: ["status": "held"]) }
                actorStep[actor] += 1
                XCTAssertLessThanOrEqual(admissions, 1, "TWO_ACTOR_NATIVE_REQUEST_REPLAY")
            }
            XCTAssertEqual(admissions, 1)
        }
        print("native receipt real reducer: alphabet=7 depth=4 visits=2801 transitions=2800; two actors/two events ordered_interleavings=6 steps=24; grant, identity and no-replay checked after every step")
    }
    @MainActor func testNativePolicyWritePinsWholeConnectionAndPane() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let originalPane = try XCTUnwrap(workspace.activePane)
        let origin = RelayCapacityPolicyOrigin(paneID: originalPane.id, profile: originalPane.profile)
        var states = 0
        for sameHost in [false, true] { for samePane in [false, true] {
            for before in [false, true] { for after in [false, true] {
                var profile = originalPane.profile
                if !sameHost { profile.host = "different-native-host.invalid" }
                let pane = PaneModel(id: samePane ? originalPane.id : UUID(), profile: profile)
                let request = RelayCapacityManagement.Request(operation: "capacity_configure", id: RelayHostRotationRPC.newOperationID(), expectedRevision: 0, settings: RelayCapacityManagement.Settings())
                var current = before, calls = 0, applied = false
                do {
                    _ = try await RelayCapacityManagement.sendBound(request, origin: origin, pane: pane, isCurrent: { current }) { data in
                        calls += 1; current = after
                        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); return try self.fixture(try XCTUnwrap(doc["request_id"] as? String))
                    }
                    applied = true
                } catch RelayHostRotationRPC.Failure.changedConnection { }
                let admitted = sameHost && samePane && before
                XCTAssertEqual(calls, admitted ? 1 : 0, "WRONG_HOST_NATIVE_POLICY_WRITE_SENT")
                if !sameHost && applied { XCTFail("WRONG_HOST_NATIVE_POLICY_WRITE_ACCEPTED") }
                if !samePane && applied { XCTFail("POLICY_ORIGIN_CROSS_PANE") }
                XCTAssertEqual(applied, admitted && after, "POLICY_RECEIPT_APPLIED_TO_CHANGED_CONNECTION")
                states += 1
            } }
        } }
        XCTAssertEqual(states, 16, "NATIVE_POLICY_ORIGIN_BOUND")
        print("native policy write real RPC guard: host=2 pane=2 pre-observation=2 post-observation=2 states=16; no RPC before admission, no changed-origin receipt applied")
    }
    @MainActor func testUnknownNativeOwnershipCannotFallBackToLegacy() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try XCTUnwrap(workspace.activePane)
        let coordinator = RelayCapacityManagementCoordinator()
        let unknown = await coordinator.shouldUseCombined(pane) { _ in throw RelayHostRotationRPC.Failure.unavailable }
        XCTAssertTrue(unknown, "UNKNOWN_NATIVE_OWNER_AUTHORIZED_LEGACY_EXIT")
        let legacy = await coordinator.shouldUseCombined(pane) { bytes in
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); let id = try XCTUnwrap(request["request_id"] as? String)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.fixture(id)) as? [String: Any]); var result = try XCTUnwrap(object["result"] as? [String: Any])
            result["managed"] = false; result["enabled"] = false; object["result"] = result
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertFalse(legacy, "FRESH_UNMANAGED_NATIVE_PROOF_REFUSED")
        let staleFalse = await coordinator.shouldUseCombined(pane) { _ in throw RelayHostRotationRPC.Failure.unavailable }
        XCTAssertTrue(staleFalse, "CACHED_UNMANAGED_STATE_AUTHORIZED_LEGACY_EXIT")
    }
    @MainActor func testDefaultTransportOwnershipFailureCannotAuthorizeLegacy() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try XCTUnwrap(workspace.activePane)
        var reads = 0
        let coordinator = RelayCapacityManagementCoordinator(readExchange: { _ in
            reads += 1
            throw RelayHostRotationRPC.Failure.unavailable
        })
        // No per-call override: the normal ownership entry must read and fail
        // closed even in a test process. Test mode never means unmanaged.
        let combined = await coordinator.shouldUseCombined(pane)
        XCTAssertTrue(combined, "DEFAULT_OWNERSHIP_TRANSPORT_FAILURE_AUTHORIZED_LEGACY_EXIT")
        XCTAssertEqual(reads, 1, "DEFAULT_OWNERSHIP_ENTRY_BYPASSED_READ")
    }
    @MainActor func testLegacyMoverUsesCombinedNativeLaneBeforeAnyExit() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try XCTUnwrap(workspace.activePane)
        let mover = RelayAgentAccountMove()
        var requests = 0
        mover.capacityRoute = { _ in true }
        mover.capacityAction = { _, _ in requests += 1; return "native_retirement_contract_unavailable" }
        mover.sendExit = { _, _, _, _ in XCTFail("LEGACY_EXIT_BYPASSED_COMBINED_LANE"); return false }
        let target = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
        let outcome = await mover.move(pane, in: workspace, to: target, origin: .user, inputGranted: false)
        XCTAssertEqual(outcome.state, "held", "COMBINED_NATIVE_LANE_REQUIRED")
        XCTAssertEqual(requests, 1)
    }
    @MainActor func testNativeSettingsRenderFixedFrame() async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RelayCapacitySettingsView(pane: nil).padding(20).frame(width: 900, height: 640, alignment: .topLeading).background(RelayTheme.surface))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        await Task.yield(); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); await Task.yield(); view.displayIfNeeded()
        XCTAssertFalse(window.isVisible, "RENDER_OFFSCREEN")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); XCTAssertGreaterThan(png.count, 1000, "RENDER_NONEMPTY")
        var colors = Set<String>(); for x in stride(from: 0, to: bitmap.pixelsWide, by: 13) { for y in stride(from: 0, to: bitmap.pixelsHigh, by: 13) { if let c = bitmap.colorAt(x: x, y: y) { colors.insert(c.description) } } }
        XCTAssertGreaterThan(colors.count, 8, "RENDER_VISIBLE_NATIVE_CONTROLS")
        if let path = ProcessInfo.processInfo.environment["CTXQ_SETTINGS_SNAPSHOT"] { try png.write(to: URL(fileURLWithPath: path)) }
    }
}

@MainActor private final class CapacityCardExecutor: RelayAssistantActionExecutor {
    let instance: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000001631")!
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { capability == .input }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        XCTFail("CAPACITY_PREVIEW_EXECUTED_AN_ACTION")
        return (500, Data())
    }
}
