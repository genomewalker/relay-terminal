import Foundation
import Testing
@testable import Relay

/// The remote bridge's host-only `bridgeScope` on relay_stack_pane and
/// relay_new_stacked_pane, driven through the real direct MCP handler. The
/// fence runs immediately before the mutation and refuses with 403 unless every
/// pane involved, and every pane of the tabs holding them, is on the scope host.
/// Hosts are .invalid, so no connection is made.
@MainActor @Suite("MCP stack bridge fence")
struct MCPStackBridgeFenceTests {
    typealias F = MCPTabMoveTests
    typealias Shape = MCPStackPaneTests.Shape
    static let hostA = "stack-fence-a.invalid"
    static let hostB = "stack-fence-b.invalid"

    @MainActor struct Fx {
        let workspace: WorkspaceModel
        let a1: UUID, a2: UUID, mac: UUID, b: UUID
        let handler = MCPDirectTabRequests()
        let instance = UUID()
        let resolve: (String) -> ConnectionProfile? = {
            $0 == "This Mac" ? .local : [MCPStackBridgeFenceTests.hostA, MCPStackBridgeFenceTests.hostB].contains($0) ? .sshConfigHost($0) : nil
        }
        init() throws {
            let ws = WorkspaceModel(restoreSavedWorkspace: false)
            func add(_ profile: ConnectionProfile) throws -> UUID {
                ws.newTab(profile: profile)
                return try #require(ws.selectedTab?.allPaneIDs.first)
            }
            a1 = try add(.sshConfigHost(MCPStackBridgeFenceTests.hostA))
            a2 = try add(.sshConfigHost(MCPStackBridgeFenceTests.hostA))
            mac = try add(.local)
            b = try add(.sshConfigHost(MCPStackBridgeFenceTests.hostB))
            workspace = ws
        }
        func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func stackBody(_ pane: UUID, onto target: UUID, scope: Any? = ["host": MCPStackBridgeFenceTests.hostA]) -> Data {
            var o: [String: Any] = ["instance": instance.uuidString, "requestID": UUID().uuidString,
                                    "paneID": pane.uuidString, "targetPaneID": target.uuidString]
            if let scope { o["bridgeScope"] = scope }
            return json(o)
        }
        func newBody(onto target: UUID, host: String, scope: Any? = ["host": MCPStackBridgeFenceTests.hostA]) -> Data {
            var o: [String: Any] = ["instance": instance.uuidString, "requestID": UUID().uuidString,
                                    "targetPaneID": target.uuidString, "host": host]
            if let scope { o["bridgeScope"] = scope }
            return json(o)
        }
        func stack(_ body: Data) -> Int {
            handler.stackPane(body, instance: instance, permits: F.all, workspace: workspace).status
        }
        func create(_ body: Data) -> Int {
            handler.newStackedPane(body, instance: instance, permits: F.all, workspace: workspace, resolve: resolve).status
        }
    }

    @Test func scopedRequestsOnTheBridgeHostApply() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        #expect(f.stack(f.stackBody(f.a2, onto: f.a1)) == 200)
        #expect(MCPStackPaneTests.isStacked(f.a2, with: f.a1, in: f.workspace))
        let before = f.workspace.panes.count
        #expect(f.create(f.newBody(onto: f.a1, host: Self.hostA)) == 200)
        #expect(f.workspace.panes.count == before + 1)
    }

    @Test func targetOrPaneOnAnotherHostIsDeniedAndNothingChanges() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        let shape = Shape(f.workspace)
        #expect(f.stack(f.stackBody(f.a1, onto: f.b)) == 403)     // target on host B
        #expect(f.stack(f.stackBody(f.b, onto: f.a1)) == 403)     // moving pane on host B
        #expect(f.stack(f.stackBody(f.mac, onto: f.a1)) == 403)   // moving pane on This Mac
        #expect(f.create(f.newBody(onto: f.b, host: Self.hostA)) == 403)
        #expect(f.create(f.newBody(onto: f.mac, host: Self.hostA)) == 403)
        #expect(Shape(f.workspace) == shape)
    }

    @Test func aTabHoldingAMacPaneIsDenied() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        try f.workspace.newStackedPane(onto: f.a2, profile: .local)   // a2's tab now holds a Mac pane
        let shape = Shape(f.workspace)
        #expect(f.stack(f.stackBody(f.a2, onto: f.a1)) == 403)        // source tab
        #expect(f.stack(f.stackBody(f.a1, onto: f.a2)) == 403)        // target tab
        #expect(f.create(f.newBody(onto: f.a2, host: Self.hostA)) == 403)
        #expect(Shape(f.workspace) == shape)
    }

    @Test func newStackedHostMustBeTheScopeHostAndResolveToIt() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        let shape = Shape(f.workspace)
        #expect(f.create(f.newBody(onto: f.a1, host: "This Mac")) == 403)
        #expect(f.create(f.newBody(onto: f.a1, host: Self.hostB)) == 403)
        #expect(f.create(f.newBody(onto: f.a1, host: Self.hostA, scope: ["host": "This Mac"])) == 403)
        #expect(f.create(f.newBody(onto: f.a1, host: Self.hostB, scope: ["host": Self.hostB])) == 403)  // target tab is host A
        // Scope host equals the requested alias, but the alias resolves to a different profile.
        let swapped = f.handler.newStackedPane(f.newBody(onto: f.a1, host: Self.hostA), instance: f.instance, permits: F.all,
                                                workspace: f.workspace, resolve: { _ in .sshConfigHost(Self.hostB) })
        #expect(swapped.status == 403)
        let mac = f.handler.newStackedPane(f.newBody(onto: f.a1, host: Self.hostA), instance: f.instance, permits: F.all,
                                           workspace: f.workspace, resolve: { _ in .local })
        #expect(mac.status == 403)
        #expect(Shape(f.workspace) == shape)
    }

    @Test func unscopedLocalRequestsBehaveAsBefore() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        #expect(f.stack(f.stackBody(f.mac, onto: f.a1, scope: nil)) == 200)
        #expect(MCPStackPaneTests.isStacked(f.mac, with: f.a1, in: f.workspace))
        let before = f.workspace.panes.count
        #expect(f.create(f.newBody(onto: f.b, host: "This Mac", scope: nil)) == 200)
        #expect(f.workspace.panes.count == before + 1)
    }

    /// The bridge checks, then another actor changes the world before the
    /// desktop commits: the fence at the mutation sees the new state.
    @Test func hostChangeBetweenBridgeCheckAndCommitIsDenied() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        let body = f.stackBody(f.a2, onto: f.a1)
        // The bridge's check passes against its snapshot.
        #expect(MCPDirectTabRequests.bridgeFence(scope: PaneStackBridgeScope(host: Self.hostA), paneIDs: [f.a2, f.a1],
                                                 requestedHost: nil, profile: nil, workspace: f.workspace) == nil)
        // A Mac pane joins the target's tab before the commit.
        try f.workspace.newStackedPane(onto: f.a1, profile: .local)
        let shape = Shape(f.workspace)
        #expect(f.stack(body) == 403)
        #expect(Shape(f.workspace) == shape)
        #expect(!MCPStackPaneTests.isStacked(f.a2, with: f.a1, in: f.workspace))
    }

    @Test func aPresentButInvalidBridgeScopeFailsToDecode() throws {
        let f = try Fx()
        defer { f.workspace.shutdown() }
        let shape = Shape(f.workspace)
        let bad: [Any] = [["host": ""], ["host": 5], "bare", NSNull(), ["host": Self.hostA, "tabID": "x"], [String: Any](), ["Host": Self.hostA]]
        for scope in bad {
            #expect(f.stack(f.stackBody(f.mac, onto: f.a1, scope: scope)) == 400)
            #expect(f.create(f.newBody(onto: f.a1, host: "This Mac", scope: scope)) == 400)
        }
        #expect(Shape(f.workspace) == shape)
        #expect(try JSONDecoder().decode(PaneStackProposal.self, from: f.stackBody(f.a2, onto: f.a1, scope: nil)).bridgeScope == nil)
        #expect(try JSONDecoder().decode(PaneStackProposal.self, from: f.stackBody(f.a2, onto: f.a1)).bridgeScope?.host == Self.hostA)
    }
}
