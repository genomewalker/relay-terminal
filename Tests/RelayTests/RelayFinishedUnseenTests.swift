import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// A finished turn leaves the Needs attention list but keeps a calm cue: an
/// info-role dot while the pane was out of sight, cleared once it is viewed.
@MainActor @Suite("Finished, not yet seen")
struct RelayFinishedUnseenTests {
    private func done(_ pane: UUID) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .claude, kind: .completion, title: "Claude completed a turn",
                        occurredAt: Date(), sourceID: UUID().uuidString, alert: .done)
    }

    @Test("A hidden pane that finishes is unseen until viewed; a visible one never is; it never waits")
    func lifecycle() throws {
        let hidden = UUID(), visible = UUID()
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        // The notifier reports whether the user is already looking at the pane.
        store.onRecord = { $0.paneID == visible }
        store.record(done(hidden))
        store.record(done(visible))
        #expect(RelayFinishedDot.unseen([hidden], inbox: store) == 1)
        #expect(RelayFinishedDot.unseen([visible], inbox: store) == 0)
        #expect(RelayFinishedDot.unseen([hidden, visible], inbox: store) == 1)
        #expect(RelayFinishedDot.label(2) == "2 panes finished, not yet seen")
        // Not a wait: it does not count as needing the user.
        #expect(store.panesNeedingUser == 0)
        // Viewing the pane (the workspace calls markPaneRead when it is shown) clears it.
        store.markPaneRead(hidden)
        #expect(RelayFinishedDot.unseen([hidden], inbox: store) == 0)
        // The role is the calm info role, with the info colour.
        #expect(RelayTheme.StatusRole.info.color != RelayTheme.StatusRole.warning.color)
    }

    @Test("Stack chips and the sidebar row show the dot, light and dark")
    func snapshots() throws {
        let f = try RelayAttentionClassificationTests.makeFixture()
        defer { f.workspace.shutdown() }
        // The fixture's relay-build pane has an unread "done" marker.
        let first = try #require(f.workspace.activePane)
        let tab = try #require(f.workspace.selectedTab)
        f.workspace.splitActive(axis: .horizontal)
        let second = try #require(f.workspace.activePane)
        try f.workspace.stackPane(second.id, onto: first.id)
        f.store.record(done(second.id))
        let chrome = WorkspacePaneStackChrome(tab: tab, workspace: f.workspace, paneID: first.id, inbox: f.store) {
            Color.clear.frame(height: 8)
        }
        try RelayUIShot.window(chrome, "unseen-stack-chips", size: NSSize(width: 360, height: 40), background: RelayTheme.canvas)
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store), "unseen-sidebar-row",
                               size: NSSize(width: 260, height: 520), background: RelayTheme.sidebar)
    }
}
