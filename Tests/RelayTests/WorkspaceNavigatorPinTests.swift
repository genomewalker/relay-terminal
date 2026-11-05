import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Workspace row pin control")
struct WorkspaceNavigatorPinTests {
    @Test func aPinShowsWhenPinnedOrUnderThePointer() {
        #expect(!WorkspaceNavigatorPin.shown(favourite: false, hovering: false))
        #expect(WorkspaceNavigatorPin.shown(favourite: false, hovering: true))
        #expect(WorkspaceNavigatorPin.shown(favourite: true, hovering: false))
        #expect(WorkspaceNavigatorPin.shown(favourite: true, hovering: true))
    }

    @Test func aHiddenPinIgnoresItsClickAndAShownOneToggles() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let id = workspace.createWorkspace(named: "Beta")
        func record() throws -> WorkspaceRecord { try #require(workspace.ownership.workspace(id)) }

        // The hidden control stays clickable; its click must not pin.
        WorkspaceNavigatorPin.toggle(try record(), shown: false, in: workspace)
        #expect(try !record().favourite)

        WorkspaceNavigatorPin.toggle(try record(), shown: true, in: workspace)
        #expect(try record().favourite)
        WorkspaceNavigatorPin.toggle(try record(), shown: true, in: workspace)
        #expect(try !record().favourite)
    }

    @Test func theInboxIsNeverPinned() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let inbox = try #require(workspace.ownership.workspaces.first { $0.isInbox })
        WorkspaceNavigatorPin.toggle(inbox, shown: true, in: workspace)
        #expect(workspace.ownership.workspace(inbox.id)?.favourite == false)
    }
}
