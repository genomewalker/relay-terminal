import Foundation
import Testing
@testable import Relay

/// Remote MCP bridge tab/split creation through the desktop's real
/// /api/workspace/apply admission object (the one RelaySidePanelServer's route
/// delegates to). SSH hosts are .invalid, so no connection is made.
@Suite("Remote bridge workspace apply", .serialized)
@MainActor
struct RemoteBridgeWorkspaceApplyTests {
    static let hostA = "bridge-a.invalid"
    static let hostB = "bridge-b.invalid"

    @MainActor final class Fixture {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        var admission = WorkspaceApplyAdmission()
        var instance = UUID()
        var granted = Set(MCPWorkspaceCapability.allCases)
        let source: PaneModel
        let tabID: UUID
        let sessionID: UUID

        init() {
            workspace.newTab(profile: .sshConfigHost(RemoteBridgeWorkspaceApplyTests.hostA))
            source = workspace.activePane!
            let tab = workspace.tabID(containingPane: source.id)!
            tabID = tab
            sessionID = workspace.tabs.first { $0.id == tab }!.sessionID
        }

        func resolve(_ host: String) -> ConnectionProfile? {
            if host == "This Mac" { return .local }
            return [RemoteBridgeWorkspaceApplyTests.hostA, RemoteBridgeWorkspaceApplyTests.hostB].contains(host) ? .sshConfigHost(host) : nil
        }

        var scope: [String: String] {
            ["host": RemoteBridgeWorkspaceApplyTests.hostA, "tabID": tabID.uuidString.lowercased(), "sessionID": sessionID.uuidString.lowercased()]
        }

        func body(_ id: UUID, action: String = "newTab", host: String? = RemoteBridgeWorkspaceApplyTests.hostA,
                  scope: [String: String]? = nil, instance: UUID? = nil, extra: [String: Any] = [:]) -> Data {
            var object: [String: Any] = ["instance": (instance ?? self.instance).uuidString.lowercased(), "requestID": id.uuidString.lowercased(),
                                         "paneID": source.id.uuidString.lowercased(), "action": action]
            if let host { object["connectionHost"] = host }
            object["bridgeScope"] = scope ?? self.scope
            for (key, value) in extra { object[key] = value }
            return try! JSONSerialization.data(withJSONObject: object)
        }

        func apply(_ body: Data) -> WorkspaceApplyAdmission.Outcome {
            admission.apply(body, instance: instance, permits: { self.granted.contains($0) }, workspace: workspace, resolve: resolve)
        }

        /// Everything a mutation would change: tabs, their sessions and panes, and each pane's host.
        var snapshot: [String] {
            workspace.tabs.map { tab in
                "\(tab.id)/\(tab.sessionID):" + workspace.paneIDs(inTab: tab.id).map { id in
                    "\(id)@\(workspace.panes[id]?.profile.name ?? "?")"
                }.joined(separator: ",")
            }
        }

        /// Another actor (not the bridge) rebinds the scoped tab: a pane on
        /// another host joins it, so the tab is no longer wholly on host A.
        func rebindOtherHost() {
            let proposal = WorkspaceProposal(instance: instance, requestID: UUID(), paneID: source.id, action: .splitRight)
            _ = workspace.applyWorkspaceAction(proposal, expected: source, profile: .sshConfigHost(RemoteBridgeWorkspaceApplyTests.hostB))
        }
    }

    func applied(_ outcome: WorkspaceApplyAdmission.Outcome) -> [String: String]? {
        if case .applied(let result) = outcome { return result }
        return nil
    }

    func status(_ outcome: WorkspaceApplyAdmission.Outcome) -> Int {
        if case .rejected(let status, _) = outcome { return status }
        return 200
    }

    @Test("A scoped newTab creates a host-A tab in the scoped session; a same-ID replay returns the same IDs without a second tab")
    func scopedCreateAndReplay() throws {
        let f = Fixture()
        defer { f.workspace.shutdown() }
        let id = UUID()
        let first = try #require(applied(f.apply(f.body(id))))
        let tab = try #require(UUID(uuidString: first["tabID"] ?? ""))
        let pane = try #require(UUID(uuidString: first["paneID"] ?? ""))
        #expect(tab != f.tabID)
        #expect(f.workspace.tabs.first { $0.id == tab }?.sessionID == f.sessionID)
        #expect(f.workspace.panes[pane]?.profile.name == Self.hostA)
        let after = f.snapshot
        // Omitted and explicit host normalise to the same body at the bridge; here the replay is byte-identical.
        #expect(applied(f.apply(f.body(id))) == first)
        #expect(f.snapshot == after)
        let split = try #require(applied(f.apply(f.body(UUID(), action: "splitRight"))))
        #expect(f.workspace.panes[UUID(uuidString: split["paneID"]!)!]?.profile.name == Self.hostA)
    }

    @Test("Spoofed, mismatched or out-of-scope bridge requests are refused with no workspace change")
    func refusalsHaveNoSideEffect() {
        let f = Fixture()
        defer { f.workspace.shutdown() }
        let other = UUID().uuidString.lowercased()
        let cases: [(String, Data, Int)] = [
            ("other connection host", f.body(UUID(), host: Self.hostB), 403),
            ("This Mac target", f.body(UUID(), host: "This Mac"), 403),
            ("omitted host is not inherited", f.body(UUID(), host: nil), 403),
            ("scope host This Mac", f.body(UUID(), host: "This Mac", scope: ["host": "This Mac", "tabID": f.scope["tabID"]!, "sessionID": f.scope["sessionID"]!]), 403),
            ("scope host B", f.body(UUID(), host: Self.hostB, scope: ["host": Self.hostB, "tabID": f.scope["tabID"]!, "sessionID": f.scope["sessionID"]!]), 403),
            ("wrong tab", f.body(UUID(), scope: ["host": Self.hostA, "tabID": other, "sessionID": f.scope["sessionID"]!]), 403),
            ("wrong session", f.body(UUID(), scope: ["host": Self.hostA, "tabID": f.scope["tabID"]!, "sessionID": other]), 403),
            ("layout action", f.body(UUID(), action: "close", host: nil), 403),
            ("starting directory", f.body(UUID(), extra: ["directory": "/tmp"]), 403),
            ("unconfigured host", f.body(UUID(), host: "nowhere.invalid", scope: ["host": "nowhere.invalid", "tabID": f.scope["tabID"]!, "sessionID": f.scope["sessionID"]!]), 400),
            ("stale instance", f.body(UUID(), instance: UUID()), 400),
        ]
        for (name, body, want) in cases {
            let before = f.snapshot
            let outcome = f.apply(body)
            #expect(status(outcome) == want, "\(name): \(outcome)")
            #expect(f.snapshot == before, "\(name) changed the workspace")
        }
        #expect(f.admission.requests.isEmpty)
    }

    @Test("Revoked grant, a rebound tab and a restart all fail closed at mutation time")
    func revocationAtMutation() {
        let f = Fixture()
        defer { f.workspace.shutdown() }
        f.granted.remove(.create)
        var before = f.snapshot
        #expect(status(f.apply(f.body(UUID()))) == 403)
        #expect(f.snapshot == before)
        f.granted = Set(MCPWorkspaceCapability.allCases)
        f.granted.remove(.layout)
        #expect(status(f.apply(f.body(UUID(), action: "splitDown"))) == 403)
        f.granted = Set(MCPWorkspaceCapability.allCases)
        let id = UUID()
        let body = f.body(id)
        f.rebindOtherHost()
        before = f.snapshot
        #expect(status(f.apply(body)) == 403, "a scope captured before the rebind must not mutate after it")
        #expect(f.snapshot == before)
        let stale = f.body(UUID())
        f.instance = UUID()
        f.admission = WorkspaceApplyAdmission()
        #expect(status(f.apply(stale)) == 400)
        #expect(f.snapshot == before)
    }

    /// Bounded exhaustive check: every sequence of up to 4 operations from a
    /// two-actor set, against the real admission object and workspace. The
    /// bridge captures its scope (snapshot) before it applies, so another
    /// actor's rebind/revoke/restart can fall between the two.
    @Test("Every two-actor interleaving up to depth 4 keeps the bridge safety properties")
    func boundedInterleavings() async throws {
        enum Op: CaseIterable { case snapshot, applyNew, replay, applySplit, spoof, rebind, revoke, restart }
        let ops = Op.allCases
        var sequences = 0, steps = 0
        var states = Set<String>()
        for depth in 1...4 {
            var counter = Array(repeating: 0, count: depth)
            repeat {
                sequences += 1
                let f = Fixture()
                var captured: [String: String]? = nil
                var firstID: UUID? = nil
                var firstInstance: UUID? = nil
                var firstResult: [String: String]? = nil
                var revoked = false, rebound = false
                for index in counter {
                    let op = ops[index]
                    let before = f.snapshot
                    var outcome: WorkspaceApplyAdmission.Outcome? = nil
                    var id = UUID()
                    switch op {
                    case .snapshot: captured = f.scope
                    case .applyNew, .applySplit:
                        guard let scope = captured else { break }
                        outcome = f.apply(f.body(id, action: op == .applyNew ? "newTab" : "splitRight", scope: scope))
                        // A replay is the same request ID with the same instance as a request that applied.
                        if op == .applyNew, firstID == nil, let result = applied(outcome!) {
                            firstID = id
                            firstInstance = f.instance
                            firstResult = result
                        }
                    case .replay:
                        guard let scope = captured, let first = firstID, let instance = firstInstance else { break }
                        id = first
                        outcome = f.apply(f.body(first, scope: scope, instance: instance))
                    case .spoof:
                        outcome = f.apply(f.body(id, host: Self.hostB, scope: captured ?? f.scope))
                    case .rebind: f.rebindOtherHost(); rebound = true
                    case .revoke: f.granted.remove(.create); revoked = true
                    case .restart: f.instance = UUID(); f.admission = WorkspaceApplyAdmission()
                    }
                    steps += 1
                    states.insert(f.snapshot.joined(separator: ";") + "|\(revoked)|\(rebound)|\(f.admission.requests.count)")
                    guard let outcome else { continue }
                    let result = applied(outcome)
                    // L1 liveness: a valid in-scope create must apply, and a same-instance replay
                    // must return the first result. A refuse-all admission fails here although S1-S5 hold.
                    if (op == .applyNew || op == .applySplit), !revoked, !rebound {
                        #expect(result != nil, "L1 valid \(op) refused: \(counter) \(outcome)")
                    }
                    if op == .replay, !revoked, f.instance == firstInstance {
                        #expect(result == firstResult, "L1 replay not answered from the first result: \(counter) \(outcome)")
                    }
                    // S1: a refusal never changes the workspace.
                    if result == nil { #expect(f.snapshot == before, "refused \(op) mutated: \(counter)") }
                    // S2: spoofed hosts never apply.
                    if op == .spoof { #expect(result == nil, "spoof applied: \(counter)") }
                    // S3: after revoke or rebind, no new create applies.
                    if (revoked || rebound) && op != .replay { #expect(result == nil, "\(op) applied after revoke/rebind: \(counter)") }
                    // S4: a same-ID replay returns the first result and changes nothing, or is refused.
                    if op == .replay {
                        #expect(f.snapshot == before, "replay mutated: \(counter)")
                        if let result { #expect(result == firstResult, "replay changed result: \(counter)") }
                    }
                    // S5: every applied pane is on host A, in the scoped session.
                    if let result, let pane = UUID(uuidString: result["paneID"] ?? ""), let tab = UUID(uuidString: result["tabID"] ?? "") {
                        #expect(f.workspace.panes[pane]?.profile.name == Self.hostA, "applied pane off host: \(counter)")
                        #expect(f.workspace.tabs.first { $0.id == tab }?.sessionID == f.sessionID, "applied outside session: \(counter)")
                    }
                }
                f.workspace.shutdown()
                // Yield the main actor between sequences so parallel suites are not starved.
                await Task.yield()
                var position = depth - 1
                while position >= 0 {
                    counter[position] += 1
                    if counter[position] < ops.count { break }
                    counter[position] = 0
                    position -= 1
                }
                if position < 0 { break }
            } while true
        }
        #expect(sequences == 8 + 64 + 512 + 4096)
        print("RemoteBridgeWorkspaceApply bound=4 ops=\(ops.count) sequences=\(sequences) steps=\(steps) concrete_snapshots=\(states.count) (UUID-bearing, not canonical logical states)")
    }
}
