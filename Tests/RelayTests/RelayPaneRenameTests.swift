import Foundation
import Testing
@testable import Relay

@Suite("Persistent pane naming", .serialized)
@MainActor struct RelayPaneRenameTests {
    @Test func renamePreservesIdentityAndRequiresLayoutGrant() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let pane = try #require(workspace.panes[paneID])
        let tab = workspace.selectedTabID
        let instance = UUID(), request = UUID()
        let handler = MCPDirectTabRequests()
        func body(_ name: String, id: UUID? = nil, target: UUID? = nil, owner: UUID? = nil) throws -> Data {
            try JSONEncoder().encode(MCPDirectTabRequests.PaneRenameProposal(instance: owner ?? instance, requestID: id ?? request, paneID: target ?? paneID, name: name))
        }
        let wire = try body("Relay · Miko and account migration")
        let old = pane.customName
        #expect(handler.renamePane(wire, instance: instance, permits: { _ in false }, workspace: workspace).status == 403)
        #expect(pane.customName == old)
        #expect(handler.renamePane(wire, instance: instance, permits: { $0 == .layout }, workspace: workspace).status == 200)
        #expect(pane.customName == "Relay · Miko and account migration")
        #expect(workspace.panes[paneID] === pane)
        #expect(workspace.activePaneID == paneID && workspace.selectedTabID == tab)
        #expect(handler.renamePane(wire, instance: instance, permits: { $0 == .layout }, workspace: workspace).status == 200)
        #expect(handler.renamePane(try body("Conflicting name"), instance: instance, permits: { _ in true }, workspace: workspace).status == 409)
        #expect(pane.customName == "Relay · Miko and account migration")
        #expect(handler.renamePane(try body("Name", id: UUID(), target: UUID()), instance: instance, permits: { _ in true }, workspace: workspace).status == 409)
        #expect(handler.renamePane(try body("Name", id: UUID(), owner: UUID()), instance: instance, permits: { _ in true }, workspace: workspace).status == 400)
        for name in ["", "   ", String(repeating: "x", count: 81), "hidden\nline", "\u{1b}escape"] {
            #expect(handler.renamePane(try body(name, id: UUID()), instance: instance, permits: { _ in true }, workspace: workspace).status == 400)
        }
    }
}
