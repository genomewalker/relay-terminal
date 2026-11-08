import Foundation
import Testing
@testable import Relay

@Suite("One vocabulary for pane states and Go to pane")
struct PaneStateVocabularyTests {
    private typealias Index = RelayWorkOverviewIndex

    @Test("Each display state has one label")
    func displayLabels() {
        #expect(PaneDisplayState.allCases.map(\.label) ==
                ["Working", "Idle", "Needs input", "Exited", "Connecting", "Connection lost"])
    }

    @Test("Every agent phase is labelled through the shared vocabulary; idle is never Ready or Quiet")
    func everyPhase() {
        let expected: [AgentPhase: PaneDisplayState] = [
            .connecting: .connecting, .active: .working, .quiet: .idle, .needsInput: .needsInput, .exited: .exited
        ]
        #expect(Set(AgentPhase.allCases) == Set(expected.keys))
        for phase in AgentPhase.allCases {
            #expect(PaneDisplayState(phase) == expected[phase])
            #expect(phase.label == expected[phase]?.label)
        }
        #expect(!AgentPhase.allCases.map(\.label).contains("Ready"))
        #expect(!AgentPhase.allCases.map(\.label).contains("Quiet"))
    }

    @Test("Connection states share the connecting and connection-lost words")
    func connectionLabels() {
        #expect(PaneConnectionState.connecting.label == PaneDisplayState.connecting.label)
        #expect(PaneConnectionState.disconnected("reset").label == PaneDisplayState.connectionLost.label)
        #expect(RelayAttentionAlert.needsInput.label == PaneDisplayState.needsInput.label)
    }

    @Test("Go to pane status uses the shared state words for every source")
    func overviewStatus() {
        for phase in AgentPhase.allCases {
            #expect(Index.paneStatus(phase: phase, approvals: 0, programState: nil, programReportCurrent: true) == phase.label)
        }
        #expect(Index.paneStatus(phase: .quiet, approvals: 1, programState: nil, programReportCurrent: true)
                == "Needs input · 1 approval")
        #expect(Index.paneStatus(phase: .active, approvals: 3, programState: "working", programReportCurrent: true)
                == "Needs input · 3 approvals")
        #expect(Index.paneStatus(phase: .quiet, approvals: 0, programState: "blocked", programReportCurrent: true)
                == "Needs input · program report")
        #expect(Index.paneStatus(phase: .active, approvals: 0, programState: "idle", programReportCurrent: false)
                == "Idle · program report (stale)")
        #expect(Index.paneStatus(phase: .quiet, approvals: 0, programState: "working", programReportCurrent: true)
                == "Working · program report")
        // The program status badge and Go to pane use the same words.
        #expect(RelayProgramStatusBadge.label(for: "blocked") == PaneDisplayState.needsInput.label)
        #expect(RelayProgramStatusBadge.label(for: "idle") == PaneDisplayState.idle.label)
        #expect(RelayProgramStatusBadge.label(for: "working") == PaneDisplayState.working.label)
        #expect(Index.paneStatus(phase: .quiet, approvals: 0, programState: "error", programReportCurrent: true)
                == "Failed · program report")
    }

    @MainActor
    @Test("A pane's activity summary uses the shared label for its phase")
    func activitySummary() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newFloatingPane()
        let pane = workspace.activePane!
        #expect(pane.agentActivities.isEmpty)
        #expect(pane.activitySummary == pane.phase.label)
    }

    @Test("The Command-Shift-P command is called Go to pane everywhere")
    func commandNames() {
        #expect(RelayCommand.quickNavigate.label == "Go to pane")
        #expect(RelayQuickNavigate.title == RelayCommand.quickNavigate.label)
        #expect(RelayQuickNavigate.searchPlaceholder == "Go to a pane, workspace, setting or ask Miko")
        #expect(WorkspaceNavigator.searchPlaceholder == "Search workspaces, tabs and panes")
    }
}
