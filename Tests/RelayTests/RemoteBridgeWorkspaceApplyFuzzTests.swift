import Foundation
import Testing
@testable import Relay

/// Native deterministic fuzz target for the desktop's /api/workspace/apply
/// decoder and bridge fence (WorkspaceProposal + WorkspaceBridgeScope through
/// WorkspaceApplyAdmission.apply). Seeded SplitMix64, so every run replays the
/// same inputs; committed seeds are the structured cases below. Properties,
/// checked against an independent JSONSerialization oracle:
///   SF1 an applied request that carries bridgeScope had: the live instance, a
///       create action, connectionHost == bridgeScope.host == host A, and the
///       source pane's real tab and session; its new pane is on host A, in that session;
///   SF2 any refusal leaves the workspace snapshot unchanged;
///   SF3 liveness: the generator reaches both acceptance and refusal;
///   SF4 a mutated body never crashes the decoder (the test completing is the check).
@Suite("Remote bridge workspace apply fuzz", .serialized)
@MainActor
struct RemoteBridgeWorkspaceApplyFuzzTests {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    typealias Fixture = RemoteBridgeWorkspaceApplyTests.Fixture
    static let hostA = RemoteBridgeWorkspaceApplyTests.hostA

    func structured(_ f: Fixture, _ rng: inout SplitMix64) -> [String: Any] {
        let realTab = f.tabID.uuidString.lowercased(), realSession = f.sessionID.uuidString.lowercased()
        var object: [String: Any] = [
            "instance": rng.chance(85) ? f.instance.uuidString.lowercased() : UUID().uuidString,
            "requestID": rng.chance(90) ? UUID().uuidString.lowercased() : rng.pick(["x", "", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]),
            "paneID": rng.chance(85) ? f.source.id.uuidString.lowercased() : rng.pick([UUID().uuidString, "x", f.tabID.uuidString]),
            "action": rng.pick(["newTab", "newTab", "splitRight", "splitDown", "close", "select", "zoom", "terminal", "nope"]),
        ]
        switch rng.next() % 6 {
        case 0: break
        case 1, 2: object["connectionHost"] = Self.hostA
        case 3: object["connectionHost"] = rng.pick(["This Mac", RemoteBridgeWorkspaceApplyTests.hostB, "", "nowhere.invalid"])
        case 4: object["connectionHost"] = NSNull()
        default: object["connectionHost"] = rng.pick([7, true, ["x"]] as [Any])
        }
        var scope: [String: Any] = ["host": Self.hostA, "tabID": realTab, "sessionID": realSession]
        if rng.chance(25) { scope["host"] = rng.pick(["This Mac", RemoteBridgeWorkspaceApplyTests.hostB, "", "BRIDGE-A.INVALID"]) }
        if rng.chance(20) { scope["tabID"] = rng.pick([UUID().uuidString, realSession, "x"]) }
        if rng.chance(20) { scope["sessionID"] = rng.pick([UUID().uuidString, realTab, "x"]) }
        if rng.chance(10) { scope.removeValue(forKey: rng.pick(["host", "tabID", "sessionID"])) }
        if rng.chance(10) { scope["extra"] = 1 }
        switch rng.next() % 10 {
        case 0: break
        case 1: object["bridgeScope"] = NSNull()
        case 2: object["bridgeScope"] = rng.pick(["scope", 3, [scope]] as [Any])
        default: object["bridgeScope"] = scope
        }
        if rng.chance(8) { object["directory"] = rng.pick(["/tmp", "", "relative"]) }
        if rng.chance(8) { object["unknown"] = 1 }
        return object
    }

    func mutateBytes(_ data: Data, _ rng: inout SplitMix64) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<(1 + Int(rng.next() % 3)) {
            guard !bytes.isEmpty else { break }
            let i = Int(rng.next() % UInt64(bytes.count))
            switch rng.next() % 5 {
            case 0: bytes[i] = UInt8(truncatingIfNeeded: rng.next())
            case 1: bytes.removeSubrange(i..<min(bytes.count, i + 1 + Int(rng.next() % 8)))
            case 2: bytes.insert(contentsOf: Array(rng.pick(["{}", "null", "\"", ",", "\\u0000", "]"]).utf8), at: i)
            case 3: bytes = Array(bytes.prefix(i))
            default: bytes.append(contentsOf: Array(rng.pick(["{}", " ", "x"]).utf8))
            }
        }
        return Data(bytes)
    }

    @Test("Seeded fuzz of the bridge-scoped apply decoder and fence keeps SF1-SF4")
    func fuzzBridgeScopedApply() async throws {
        var rng = SplitMix64(state: 20_261_101)
        let iterations = 8000
        var applied = 0, refused = 0, mutatedBytes = 0, unscoped = 0
        var f = Fixture()
        var appliedIDs = Set<String>()
        for iteration in 0..<iterations {
            if iteration % 60 == 0 {
                f.workspace.shutdown(); f = Fixture(); appliedIDs = []
                await Task.yield()
            }
            let object = structured(f, &rng)
            var body = try JSONSerialization.data(withJSONObject: object)
            if rng.chance(30) { body = mutateBytes(body, &rng); mutatedBytes += 1 }
            let before = f.snapshot
            let paneCount = f.workspace.panes.count
            let outcome = f.apply(body)
            guard case .applied(let result) = outcome else {
                refused += 1
                #expect(f.snapshot == before, "SF2 refusal mutated the workspace: \(String(decoding: body, as: UTF8.self))")
                continue
            }
            // Independent oracle of what was actually sent.
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            // A replay is a request ID that already applied on this fixture; it returns that result unchanged.
            let rid = ((sent?["requestID"] as? String) ?? "").lowercased()
            if appliedIDs.contains(rid) {
                #expect(f.workspace.panes.count == paneCount, "replay mutated the workspace")
                continue
            }
            appliedIDs.insert(rid)
            applied += 1
            let pane = UUID(uuidString: result["paneID"] ?? "").flatMap { f.workspace.panes[$0] }
            let tab = UUID(uuidString: result["tabID"] ?? "").flatMap { id in f.workspace.tabs.first { $0.id == id } }
            if let scope = sent?["bridgeScope"] as? [String: Any] {
                #expect(scope["host"] as? String == Self.hostA && (scope["tabID"] as? String)?.lowercased() == f.tabID.uuidString.lowercased()
                        && (scope["sessionID"] as? String)?.lowercased() == f.sessionID.uuidString.lowercased(),
                        "SF1 applied with a foreign bridge scope: \(scope)")
                #expect(sent?["connectionHost"] as? String == Self.hostA, "SF1 applied without the bridge host: \(String(describing: sent?["connectionHost"]))")
                #expect(["newTab", "splitRight", "splitDown"].contains(sent?["action"] as? String ?? ""), "SF1 non-create action applied")
                #expect(pane?.profile.name == Self.hostA && tab?.sessionID == f.sessionID, "SF1 new pane off host or outside session")
            } else {
                // No bridgeScope: the existing local-caller route (the bridge always attaches one; Go/Python tests pin that).
                unscoped += 1
            }
        }
        f.workspace.shutdown()
        // Liveness: the generator must reach acceptance and refusal, or the properties are vacuous.
        #expect(applied - unscoped >= 50 && refused >= 500, "SF3 fuzz did not exercise both outcomes: applied=\(applied) refused=\(refused)")
        print("RemoteBridgeWorkspaceApplyFuzz seed=20261101 iterations=\(iterations) applied=\(applied) unscoped_local=\(unscoped) refused=\(refused) byte_mutated=\(mutatedBytes)")
    }
}
