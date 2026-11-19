import Foundation
import Testing
@testable import Relay

/// Case 30a62084 / 8616d845 (2026-11-19): Resume on an exited stacked pane
/// swapped the replacement into the layout but left the stack table naming
/// the retired pane. The next reconcileStacks found the stack's showing
/// member missing and re-tiled every member, including the dead ID, so the
/// tab gained empty slots and lost its stacks.
@MainActor @Suite("Resume keeps an exited pane's place in its stack")
struct RelayResumeStackReplacementTests {
    private static let profile = ConnectionProfile(
        name: "HPC login", kind: .ssh, host: "resume-stack.invalid",
        command: "ssh -o BatchMode=yes login.invalid", backend: .relay)

    private func isolatedWorkspace() throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(
            restoreSavedWorkspace: false,
            workspaceDirectory: root.appendingPathComponent("Workspace", isDirectory: true),
            recoveryStore: RelayRecoveryStore(directory: root.appendingPathComponent("Recovery", isDirectory: true)))
        return (workspace, root)
    }

    /// Tab with A | B tiled and C stacked onto A (C showing, A hidden).
    private func stackedTab(_ workspace: WorkspaceModel) throws -> (TabModel, a: UUID, b: UUID, c: UUID) {
        workspace.newTab(profile: Self.profile)
        let tab = try #require(workspace.selectedTab)
        let a = try #require(workspace.activePaneID)
        workspace.splitActive(axis: .horizontal, profile: Self.profile)
        let b = try #require(workspace.activePaneID)
        workspace.splitActive(axis: .vertical, profile: Self.profile)
        let c = try #require(workspace.activePaneID)
        try workspace.stackPane(c, onto: a)
        let stack = try #require(tab.stack(containing: a))
        #expect(stack.selected == c && Set(stack.members) == [a, c])
        #expect(Set(tab.layout.paneIDs) == [b, c])
        return (tab, a, b, c)
    }

    private func exit(_ workspace: WorkspaceModel, _ paneID: UUID) throws {
        let pane = try #require(workspace.panes[paneID])
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 0, now: start.addingTimeInterval(0.5))
    }

    @Test func resumingTheShowingMemberKeepsTheStackAndAddsNoSlot() throws {
        let (workspace, root) = try isolatedWorkspace()
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        let (tab, a, b, c) = try stackedTab(workspace)
        try exit(workspace, c)

        let r = try #require(workspace.restartExitedPane(c))
        tab.reconcileStacks()

        #expect(Set(tab.layout.paneIDs) == [b, r], "no ghost leaf for the retired pane")
        let stack = try #require(tab.stack(containing: r))
        #expect(stack.selected == r && Set(stack.members) == [a, r])
        #expect(!tab.allPaneIDs.contains(c))
        #expect(Set(tab.allPaneIDs) == [a, b, r])
        #expect(tab.allPaneIDs.allSatisfy { workspace.panes[$0] != nil })
    }

    @Test func resumingAHiddenMemberKeepsItHiddenInTheSameStack() throws {
        let (workspace, root) = try isolatedWorkspace()
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        let (tab, a, b, c) = try stackedTab(workspace)
        try exit(workspace, a)

        let r = try #require(workspace.restartExitedPane(a))
        tab.reconcileStacks()

        #expect(Set(tab.layout.paneIDs) == [b, c], "the visible layout is unchanged")
        let stack = try #require(tab.stack(containing: c))
        #expect(stack.selected == c && Set(stack.members) == [c, r])
        #expect(Set(tab.allPaneIDs) == [b, c, r])
        #expect(tab.allPaneIDs.allSatisfy { workspace.panes[$0] != nil })
    }
}

/// Tab bf85207f (2026-11-19): a dead Resume leaf stayed in the layout with no
/// pane behind it. Restore then refused the whole tab; now only the slot goes.
@MainActor @Suite("A slot whose pane is gone is dropped, not the tab")
struct RelayDeadSlotTests {
    @Test func theDeadSlotGoesAndEveryLivePaneAndStackStays() throws {
        let (a, b, c, d, dead, hidden) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        let tab = TabModel(id: UUID(), sessionID: UUID(), name: "Kapk", firstPane: a, floatingPanes: [])
        tab.layout = .split(id: UUID(), axis: .vertical,
            first: .split(id: UUID(), axis: .horizontal, first: .pane(a), second: .pane(b)),
            second: .split(id: UUID(), axis: .horizontal, first: .pane(c),
                second: .split(id: UUID(), axis: .horizontal, first: .pane(d), second: .pane(dead))))
        tab.stacks = [PaneStack(id: UUID(), members: [b, hidden], selected: b)]
        let live: Set<UUID> = [a, b, c, d, hidden]

        #expect(tab.dropMissingPanes { live.contains($0) })
        #expect(Set(tab.layout.paneIDs) == [a, b, c, d])
        #expect(Set(tab.allPaneIDs) == live)
        #expect(tab.stack(containing: hidden)?.selected == b)
    }

    @Test func aTabWithNothingLiveIsNotKept() {
        let gone = UUID()
        let tab = TabModel(id: UUID(), sessionID: UUID(), name: "x", firstPane: gone, floatingPanes: [])
        #expect(!tab.dropMissingPanes { _ in false })
    }
}
