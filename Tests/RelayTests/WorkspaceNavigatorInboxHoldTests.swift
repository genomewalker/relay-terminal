import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Inbox rows hold still under the pointer")
struct WorkspaceNavigatorInboxHoldTests {
    private func event(_ pane: UUID, _ title: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: .failure, title: title,
                        occurredAt: Date(), sourceID: UUID().uuidString, alert: .error)
    }

    private func newPane(_ workspace: WorkspaceModel) throws -> UUID {
        workspace.newTab(profile: .sshConfigHost("inbox-hold.invalid"))
        return try #require(workspace.activePaneID)
    }

    @Test func heldRowsNeitherAppearNorLeave() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let first = try newPane(workspace), second = try newPane(workspace)
        store.record(event(first, "first failed"))

        workspace.holdNavigatorOrder(inbox: store)
        store.record(event(second, "second failed"))
        store.markPaneRead(first)
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [first])
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [second])

        workspace.releaseNavigatorOrder()
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [second])
    }

    @Test func anEmptyHeldInboxStaysEmpty() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = try newPane(workspace)
        workspace.holdNavigatorOrder(inbox: store)
        store.record(event(pane, "failed"))
        #expect(workspace.shownAttentionInbox(inbox: store).isEmpty)
    }

    @Test func aDismissedPaneLeavesTheHeldInboxAndAClosedOneAtRelease() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let dismissed = try newPane(workspace), closed = try newPane(workspace), kept = try newPane(workspace)
        for pane in [dismissed, closed, kept] { store.record(event(pane, "failed")) }

        workspace.holdNavigatorOrder(inbox: store)
        #expect(Set(workspace.shownAttentionInbox(inbox: store).map(\.paneID)) == [dismissed, closed, kept])
        workspace.dismissAttention(dismissed, inbox: store)
        workspace.selectTab(try #require(workspace.tabs.first { $0.allPaneIDs.contains(closed) }).id)
        workspace.selectPane(closed, origin: .user)
        workspace.closeActivePane()
        #expect(workspace.panes[closed] == nil)
        // The closed pane's row stays (shown as closed) so the rows below
        // it hold still; it goes at release.
        #expect(Set(workspace.shownAttentionInbox(inbox: store).map(\.paneID)) == [closed, kept])
        workspace.releaseNavigatorOrder()
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [kept])
    }

    @Test func aSecondHoldKeepsTheFirstRows() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let first = try newPane(workspace), second = try newPane(workspace)
        store.record(event(first, "first failed"))
        workspace.holdNavigatorOrder(inbox: store)
        store.record(event(second, "second failed"))
        workspace.holdNavigatorOrder(inbox: store)
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [first])
    }
}
