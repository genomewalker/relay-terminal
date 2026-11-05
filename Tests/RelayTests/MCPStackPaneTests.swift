import AppKit
import Foundation
import Testing
@testable import Relay

/// relay_stack_pane and relay_new_stacked_pane, driven through the real
/// direct MCP handler over the two-session fixture of MCPTabMoveTests:
/// A1 (S1, W1); B1, B2 (S2, W2), one pane each.
@MainActor @Suite("MCP stack pane and new stacked pane")
struct MCPStackPaneTests {
    typealias F = MCPTabMoveTests

    static func stack(_ instance: UUID, _ request: UUID, _ pane: UUID, onto target: UUID) -> Data {
        F.body(["instance": instance.uuidString, "requestID": request.uuidString,
                "paneID": pane.uuidString, "targetPaneID": target.uuidString])
    }

    static func newStacked(_ instance: UUID, _ request: UUID, onto target: UUID, host: String) -> Data {
        F.body(["instance": instance.uuidString, "requestID": request.uuidString,
                "targetPaneID": target.uuidString, "host": host])
    }

    static func result(_ response: RelaySidePanelHTTPResponse) -> PaneStackResult? {
        try? JSONDecoder().decode(PaneStackResult.self, from: response.body)
    }

    /// This Mac only; every other host is refused, as an unconfigured alias is.
    static let resolve: (String) -> ConnectionProfile? = { $0 == "This Mac" ? .local : nil }

    /// Everything a refused request must leave exactly as it was.
    struct Shape: Equatable {
        let tabs: [UUID]
        let layouts: [UUID: PaneLayout]
        let stacks: [UUID: [PaneStack]]
        let floating: [UUID: [UUID]]
        let panes: Set<UUID>
        let owners: [WorkspaceTabOwner]
        let placements: [WorkspaceTabPlacement]
        @MainActor init(_ workspace: WorkspaceModel) {
            tabs = workspace.tabs.map(\.id)
            layouts = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.layout) })
            stacks = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.stacks) })
            floating = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.floatingPanes.map(\.paneID)) })
            panes = Set(workspace.panes.keys)
            owners = workspace.ownership.owners.sorted { $0.id.uuidString < $1.id.uuidString }
            placements = workspace.organization.placements.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// X sits in Y's stack and only the stack's shown member is a leaf.
    static func isStacked(_ x: UUID, with y: UUID, in workspace: WorkspaceModel) -> Bool {
        guard let tab = workspace.tabs.first(where: { $0.stack(containing: y) != nil }),
              let stack = tab.stack(containing: y) else { return false }
        return stack.members.contains(x) && tab.layout.paneIDs.filter(stack.members.contains) == [stack.selected]
    }

    @Test func crossSessionStackLandsInTargetStackAndRemovesEmptySource() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        let x = try #require(f.a1.allPaneIDs.first), y = try #require(f.b1.allPaneIDs.first)
        let object = try #require(f.workspace.panes[x]), runtime = object.runtime
        let paneSet = Set(f.workspace.panes.keys)
        let birth = [object.remoteWorkspaceSessionID, object.remoteTabID]
        let response = handler.stackPane(Self.stack(instance, UUID(), x, onto: y), instance: instance,
                                         permits: F.all, workspace: f.workspace)
        #expect(response.status == 200)
        let result = try #require(Self.result(response))
        let stack = try #require(f.b1.stack(containing: y))
        #expect(result.status == "stacked" && result.stackID == stack.id.uuidString.lowercased())
        #expect(result.members == [y, x].map { $0.uuidString.lowercased() } && stack.members == [y, x])
        #expect(result.tabID == f.b1.id.uuidString.lowercased())
        // Never a split: B1 still has one leaf, the stack's shown member.
        #expect(f.b1.layout.paneIDs == [x] && Self.isStacked(x, with: y, in: f.workspace))
        // The emptied source tab is gone; nothing was stopped or rebuilt.
        #expect(result.removedTabID == f.a1.id.uuidString.lowercased())
        #expect(!f.workspace.tabs.contains { $0.id == f.a1.id })
        #expect(f.workspace.panes[x] === object && object.runtime === runtime)
        #expect([object.remoteWorkspaceSessionID, object.remoteTabID] == birth)
        #expect(Set(f.workspace.panes.keys) == paneSet)
    }

    @Test func stackFromMultiPaneTabKeepsSourceTabAndAppendsToExistingStack() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        f.workspace.selectTab(f.b2.id)
        f.workspace.splitActive(axis: .horizontal)
        let b2Panes = f.b2.allPaneIDs
        #expect(b2Panes.count == 2)
        let x = b2Panes[1], keep = b2Panes[0], y = try #require(f.a1.allPaneIDs.first)
        let first = handler.stackPane(Self.stack(instance, UUID(), x, onto: y), instance: instance,
                                      permits: F.all, workspace: f.workspace)
        #expect(first.status == 200 && Self.result(first)?.removedTabID == nil)
        #expect(f.workspace.tabs.contains { $0.id == f.b2.id } && f.b2.allPaneIDs == [keep])
        #expect(f.a1.layout.paneIDs == [x] && Self.isStacked(x, with: y, in: f.workspace))
        // A third pane joins the same stack, targeting its hidden member Y.
        let z = try #require(f.b1.allPaneIDs.first)
        let stackID = try #require(f.a1.stack(containing: y)?.id)
        let second = handler.stackPane(Self.stack(instance, UUID(), z, onto: y), instance: instance,
                                       permits: F.all, workspace: f.workspace)
        #expect(second.status == 200)
        #expect(Self.result(second)?.stackID == stackID.uuidString.lowercased())
        #expect(f.a1.stack(containing: y)?.members == [y, x, z] && f.a1.layout.paneIDs == [z])
        #expect(!f.workspace.tabs.contains { $0.id == f.b1.id })
    }

    @Test func newStackedPaneIsCreatedInTargetStack() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID(), id = UUID()
        let y = try #require(f.b1.allPaneIDs.first)
        let before = Set(f.workspace.panes.keys)
        let response = handler.newStackedPane(Self.newStacked(instance, id, onto: y, host: "This Mac"), instance: instance,
                                              permits: F.all, workspace: f.workspace, resolve: Self.resolve)
        #expect(response.status == 200)
        let result = try #require(Self.result(response))
        let created = try #require(UUID(uuidString: result.paneID))
        #expect(result.status == "created" && !before.contains(created))
        #expect(Set(f.workspace.panes.keys) == before.union([created]))
        #expect(f.workspace.panes[created]?.profile.kind == .local)
        #expect(f.b1.stack(containing: y)?.members == [y, created])
        #expect(result.stackID == f.b1.stack(containing: y)?.id.uuidString.lowercased())
        #expect(f.b1.layout.paneIDs == [created] && Self.isStacked(created, with: y, in: f.workspace))
        // Idempotent by request ID: the same request creates nothing more.
        let again = handler.newStackedPane(Self.newStacked(instance, id, onto: y, host: "This Mac"), instance: instance,
                                           permits: F.all, workspace: f.workspace, resolve: Self.resolve)
        #expect(again.status == 200 && again.body == response.body)
        #expect(f.workspace.panes.count == before.count + 1)
        let b2 = try #require(f.b2.allPaneIDs.first)
        #expect(handler.newStackedPane(Self.newStacked(instance, id, onto: b2, host: "This Mac"), instance: instance,
                                       permits: F.all, workspace: f.workspace, resolve: Self.resolve).status == 409)
        #expect(f.workspace.panes.count == before.count + 1)
    }

    @Test func stackRequestIDsAreIdempotent() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID(), id = UUID()
        let x = try #require(f.a1.allPaneIDs.first), y = try #require(f.b1.allPaneIDs.first)
        let b2 = try #require(f.b2.allPaneIDs.first)
        let first = handler.stackPane(Self.stack(instance, id, x, onto: y), instance: instance, permits: F.all, workspace: f.workspace)
        #expect(first.status == 200)
        let shape = Shape(f.workspace)
        let again = handler.stackPane(Self.stack(instance, id, x, onto: y), instance: instance, permits: F.all, workspace: f.workspace)
        #expect(again.status == 200 && again.body == first.body)
        #expect(Shape(f.workspace) == shape)
        #expect(handler.stackPane(Self.stack(instance, id, b2, onto: y), instance: instance,
                                  permits: F.all, workspace: f.workspace).status == 409)
        #expect(Shape(f.workspace) == shape)
    }

    /// Miko sees both tools with the same grants as the direct endpoints.
    @Test func mikoClassifiesBothStackTools() {
        func request(_ tool: String, _ path: String) -> RelayMikoToolRequest {
            RelayMikoToolRequest(tool: tool, tier: "change", method: "POST", path: path, body: Data("{}".utf8))
        }
        #expect(RelayMikoToolCatalog.names.isSuperset(of: ["relay_stack_pane", "relay_new_stacked_pane"]))
        #expect(Set(request("relay_stack_pane", "/api/workspace/stack-pane").capabilities)
            == MCPDirectTabRequests.Endpoint.stackPane.capabilities)
        #expect(Set(request("relay_new_stacked_pane", "/api/workspace/new-stacked-pane").capabilities)
            == MCPDirectTabRequests.Endpoint.newStackedPane.capabilities)
        #expect(RelayMikoActionPolicy.tier("relay_new_stacked_pane") == .coordination)
        #expect(RelayMikoActionPolicy.tier("relay_stack_pane") == .reversible)
    }

    @Test func refusalsChangeNothing() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        let a = try #require(f.a1.allPaneIDs.first), b1 = try #require(f.b1.allPaneIDs.first)
        let b2 = try #require(f.b2.allPaneIDs.first)
        // Already stacked: an applied pair, then nothing may change.
        #expect(handler.stackPane(Self.stack(instance, UUID(), b2, onto: b1), instance: instance,
                                  permits: F.all, workspace: f.workspace).status == 200)
        let shape = Shape(f.workspace)
        func stack(_ x: UUID, _ y: UUID, permits: @escaping (MCPWorkspaceCapability) -> Bool = F.all, instance stale: UUID? = nil) -> Int {
            handler.stackPane(Self.stack(stale ?? instance, UUID(), x, onto: y), instance: instance,
                              permits: permits, workspace: f.workspace).status
        }
        func create(_ y: UUID, host: String = "This Mac", permits: @escaping (MCPWorkspaceCapability) -> Bool = F.all) -> Int {
            handler.newStackedPane(Self.newStacked(instance, UUID(), onto: y, host: host), instance: instance,
                                   permits: permits, workspace: f.workspace, resolve: Self.resolve).status
        }
        #expect(stack(a, a) == 409)                          // same pane
        #expect(stack(UUID(), b1) == 409)                    // stale pane
        #expect(stack(a, UUID()) == 409)                     // stale target
        #expect(stack(b2, b1) == 409)                        // already in Y's stack
        #expect(stack(a, b1, instance: UUID()) == 400)       // stale instance
        #expect(stack(a, b1, permits: { $0 != .layout }) == 403)
        #expect(create(UUID()) == 409)                       // stale target
        #expect(create(b1, host: "unconfigured.invalid") == 400)
        #expect(create(b1, permits: { $0 != .layout }) == 403)
        #expect(create(b1, permits: { $0 != .create }) == 403)
        _ = f.workspace.whileAwaitingCloseConfirmation([f.b1.id]) {
            #expect(stack(a, b1) == 409)                     // target tab closing
            #expect(create(b1) == 409)
            return false
        }
        _ = f.workspace.whileAwaitingCloseConfirmation([f.a1.id]) {
            #expect(stack(a, b1) == 409)                     // source tab closing
            return false
        }
        #expect(Shape(f.workspace) == shape)
        // After the refusals, the same request is admitted.
        #expect(stack(a, b1) == 200)
    }
}
