import AppKit
import XCTest
@testable import Relay

final class RelayClaudeQuotaScreenTests: XCTestCase {
    @MainActor func testUnopenedPreflightRestoresSelectionAndHonorsUserSelection() async throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("quota-screen.invalid"))
        let pane = try XCTUnwrap(workspace.activePane)
        pane.connectionState = .connected
        workspace.newTab(profile: .local)
        let previous = try XCTUnwrap(workspace.activePane)
        let mover = RelayAgentAccountMove()
        var readable = false
        var presents = 0
        mover.screenRefusal = { _ in readable ? nil : "not yet shown" }
        mover.presentPane = { pane, workspace in
            presents += 1; workspace.revealPane(pane.id); readable = true
        }
        let result = await RelayClaudeQuotaScheduler.ensureReadable(pane, in: workspace, mover: mover)
        XCTAssertTrue(result)
        XCTAssertEqual(workspace.activePaneID, previous.id)
        XCTAssertEqual(presents, 1)
        readable = false
        mover.presentPane = { pane, workspace in
            workspace.revealPane(pane.id); workspace.revealPane(previous.id); readable = true
        }
        let userSelection = await RelayClaudeQuotaScheduler.ensureReadable(pane, in: workspace, mover: mover)
        XCTAssertTrue(userSelection)
        XCTAssertEqual(workspace.activePaneID, previous.id)
        mover.sendExit = { _, _, _, _ in XCTFail("preflight is read-only"); return false }
        mover.resume = { _, _, _, _, _ in XCTFail("preflight is read-only"); return false }
        readable = false
        mover.screenTimeout = 0.01; mover.screenInterval = 0.001
        mover.presentPane = { pane, workspace in workspace.revealPane(pane.id) }
        let timedOut = await RelayClaudeQuotaScheduler.ensureReadable(pane, in: workspace, mover: mover)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(workspace.activePaneID, previous.id)
    }
}
