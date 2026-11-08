import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Editors start without waiting for their view")
struct EditorStartTests {
    private func savedActiveState() -> PersistedAgentPaneState {
        PersistedAgentPaneState(cursor: 7, kind: .codex, phase: .active, summary: "working",
                                subagents: [], activities: [], resourceUsage: nil,
                                progressPercent: nil, pendingApprovals: 0)
    }

    @Test func anEditorThatHasNotStartedSaysSo() {
        let editor = PaneModel(profile: .sshConfigHost("editor-start.invalid"), contentKind: .editor,
                               savedAgentState: savedActiveState())
        #expect(editor.connectionStatusLabel == "Not started")
        #expect(editor.activitySummary == "Not started")
        // A saved agent phase is not restored onto an editor.
        #expect(editor.phase != .active)

        editor.connected()
        #expect(editor.connectionStatusLabel == "Connected")
        #expect(editor.activitySummary != "Not started")
    }

    @Test func anEditorSaysStartingWhileItsStartOrReconnectIsInFlight() {
        let editor = PaneModel(profile: .sshConfigHost("editor-start.invalid"), contentKind: .editor)
        #expect(editor.connectionStatusLabel == "Not started")
        // The runtime's start asks to connect before its first discovery returns.
        editor.reconnecting()
        #expect(editor.connectionStatusLabel == "Starting")
        #expect(editor.activitySummary == "Starting")

        editor.editorViewShown = true
        editor.disconnected("Discovery failed")
        #expect(editor.connectionStatusLabel == "Connection lost")
        editor.reconnecting()
        #expect(editor.connectionStatusLabel == "Starting")
        editor.connected()
        #expect(editor.connectionStatusLabel == "Connected")
    }

    @Test func aTerminalStillRestoresItsSavedPhase() {
        let terminal = PaneModel(profile: .sshConfigHost("editor-start.invalid"), savedAgentState: savedActiveState())
        #expect(terminal.phase == .active)
        #expect(terminal.connectionStatusLabel == "Connecting")
    }

    @Test func storingOrSelectingAnEditorStartsIt() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var started: [UUID] = []
        workspace.startEditorRuntime = { started.append($0.id) }
        workspace.newTab(profile: .sshConfigHost("editor-start.invalid"))
        let console = try #require(workspace.activePane)
        #expect(started.isEmpty)

        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        #expect(started == [editor.id])
        workspace.selectPane(editor.id, origin: .user)
        #expect(started == [editor.id, editor.id])
        workspace.selectPane(console.id, origin: .user)
        #expect(started == [editor.id, editor.id])
    }

    @Test func selectingAFloatingRPaneRevealsItsWorkspace() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.startEditorRuntime = { _ in }
        var revealed: [UUID] = []
        workspace.revealFloatingRPane = { revealed.append($0) }
        workspace.newTab(profile: .sshConfigHost("editor-start.invalid"))
        let console = try #require(workspace.activePane)
        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)

        workspace.selectPane(console.id, origin: .user)
        #expect(revealed.isEmpty)
        workspace.selectPane(editor.id, origin: .user)
        #expect(revealed == [editor.id])
    }

    private func rConsole(_ workspace: WorkspaceModel) throws -> PaneModel {
        workspace.startEditorRuntime = { _ in }
        workspace.newTab(profile: .sshConfigHost("editor-start.invalid"))
        return try #require(workspace.activePane)
    }

    private func editorCount(_ workspace: WorkspaceModel) -> Int {
        workspace.panes.values.filter { $0.contentKind == .editor }.count
    }

    @Test func revealingAnUndrawnExtraEditorDrawsThatEditorBesideThePrimary() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let console = try rConsole(workspace)
        let primary = try workspace.prepareFloatingRWorkspace(consoleID: console.id)
        let extra = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        let coordinator = RelayToolWindowCoordinator()
        let key = console.id.uuidString + ":RStudio"

        coordinator.revealR(paneID: extra.id, workspace: workspace)
        #expect(coordinator.rPaneIDs.contains(extra.id))
        #expect(coordinator.extraRPanels[key]?.contains { $0.pane?.id == extra.id } == true)
        #expect(coordinator.presentationSnapshot(workspace: workspace).map(\.editorID) == [primary.id])
        #expect(coordinator.selectedRWorkspace == key)
        #expect(editorCount(workspace) == 2)

        coordinator.revealR(paneID: extra.id, workspace: workspace)
        #expect(coordinator.extraRPanels[key]?.filter { $0.pane?.id == extra.id }.count == 1)
    }

    @Test func revealingTheOnlyFloatingEditorPresentsItRatherThanANewPrimary() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let console = try rConsole(workspace)
        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        let coordinator = RelayToolWindowCoordinator()

        coordinator.revealR(paneID: editor.id, workspace: workspace)
        #expect(coordinator.presentationSnapshot(workspace: workspace).map(\.editorID) == [editor.id])
        #expect(coordinator.rPaneIDs.contains(editor.id))
        #expect(coordinator.extraRPanels[console.id.uuidString + ":RStudio", default: []].isEmpty)
        #expect(editorCount(workspace) == 1)
    }

    @Test func revealingAMinimizedExtraEditorRestoresItsOwnPanel() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let console = try rConsole(workspace)
        _ = try workspace.prepareFloatingRWorkspace(consoleID: console.id)
        let extra = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        let other = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        let coordinator = RelayToolWindowCoordinator()
        let key = console.id.uuidString + ":RStudio"
        coordinator.revealR(paneID: extra.id, workspace: workspace)
        coordinator.revealR(paneID: other.id, workspace: workspace)
        let panels = coordinator.extraRPanels[key] ?? []
        let extraKey = try #require(panels.first { $0.pane?.id == extra.id }).id.uuidString
        let otherKey = try #require(panels.first { $0.pane?.id == other.id }).id.uuidString
        coordinator.minimizedRPanels.formUnion([extraKey, otherKey])
        coordinator.minimizedRWorkspaces.insert(key)
        coordinator.selectedRWorkspace = nil

        coordinator.revealR(paneID: extra.id, workspace: workspace)
        #expect(!coordinator.minimizedRPanels.contains(extraKey))
        #expect(!coordinator.minimizedRWorkspaces.contains(key))
        #expect(coordinator.selectedRWorkspace == key)
        // Only the selected editor's panel is restored.
        #expect(coordinator.minimizedRPanels.contains(otherKey))
    }
}
