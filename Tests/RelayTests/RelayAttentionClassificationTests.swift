import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// "Needs attention" lists only what needs the user; one predicate serves the
/// sidebar inbox, Go to pane and the fleet board.
@MainActor @Suite("Needs attention lists only what needs the user")
struct RelayAttentionClassificationTests {
    private typealias Index = RelayWorkOverviewIndex

    @Test("Waiting, approvals, blocked, error and a failed exit need attention; finished and idle do not")
    func predicate() {
        func needs(_ phase: AgentPhase, approvals: Int = 0, program: String? = nil, failedExit: Bool = false) -> Bool {
            Index.needsAttention(phase: phase, approvals: approvals, programState: program, failedExit: failedExit)
        }
        #expect(needs(.needsInput))
        #expect(needs(.active, approvals: 1))
        #expect(needs(.quiet, program: "blocked"))
        #expect(needs(.quiet, program: "error"))
        #expect(needs(.exited, failedExit: true))
        #expect(!needs(.quiet, program: "done"))
        #expect(!needs(.quiet, program: "idle"))
        #expect(!needs(.quiet, program: "working"))
        #expect(!needs(.exited))
        #expect(!needs(.quiet))
        #expect(!needs(.active))
    }

    private func event(_ pane: UUID, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert, _ title: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: kind, title: title,
                        occurredAt: Date(), sourceID: UUID().uuidString, alert: alert)
    }

    /// The panes of the inbox fixture, by role.
    struct Fixture {
        let workspace: WorkspaceModel
        let store: AgentIntelligenceStore
        let waiting, errored, finished, toolFailed, cleanExit, failedExit: PaneModel
    }

    static func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        func pane(_ name: String) throws -> PaneModel {
            workspace.newTab(profile: .sshConfigHost("attention.invalid"))
            let pane = try #require(workspace.activePane)
            pane.customName = name
            pane.connectionState = .connected
            return pane
        }
        func event(_ pane: PaneModel, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert, _ title: String) {
            store.record(AgentInboxEvent(paneID: pane.id, host: "dandy-07", provider: .codex, kind: kind, title: title,
                                         occurredAt: Date(), sourceID: UUID().uuidString, alert: alert))
        }
        let waiting = try pane("smdb-import"), errored = try pane("metadmg-sweep"), finished = try pane("relay-build")
        let toolFailed = try pane("chitta-dev"), cleanExit = try pane("notes"), failedExit = try pane("old-run")
        waiting.received("Do you want to proceed? (y/n)\n")
        event(errored, .failure, .error, "Build failed")
        event(finished, .completion, .done, "Claude completed a turn")
        event(toolFailed, .failure, .toolFailed, "Bash failed")
        cleanExit.exited(exitCode: 0)
        failedExit.exited(exitCode: 2)
        return Fixture(workspace: workspace, store: store, waiting: waiting, errored: errored, finished: finished,
                       toolFailed: toolFailed, cleanExit: cleanExit, failedExit: failedExit)
    }

    @Test("The sidebar inbox lists waits, errors and failed exits, not finished turns or clean exits")
    func inbox() throws {
        let f = try Self.makeFixture()
        defer { f.workspace.shutdown() }
        let rows = f.workspace.attentionInbox(inbox: f.store)
        #expect(Set(rows.map(\.paneID)) == [f.waiting.id, f.errored.id, f.failedExit.id])
        #expect(rows.first?.paneID == f.waiting.id)
        #expect(rows.first { $0.paneID == f.failedExit.id }?.title == "Exited with status 2")
        // The unread markers other surfaces use are untouched.
        #expect(f.store.marker(for: f.finished.id) == .done)
        #expect(f.store.marker(for: f.toolFailed.id) == .toolFailed)
        // The board's waiting is the inbox, less the unread agent error alert
        // (an event, not pane state, which the board does not read).
        let board = Set(Index.paneFacts(f.workspace).filter(\.status.needsUser).map(\.paneID))
        #expect(board == [f.waiting.id, f.failedExit.id])
        #expect(Set(rows.map(\.paneID)).subtracting(board) == [f.errored.id])
        // Dismissing a failed exit hides it until the exit changes.
        f.workspace.dismissAttention(f.failedExit.id, inbox: f.store)
        #expect(!f.workspace.attentionInbox(inbox: f.store).map(\.paneID).contains(f.failedExit.id))
    }

    @Test("Sidebar navigator shows only waits, errors and failed exits, light and dark")
    func snapshot() throws {
        let f = try Self.makeFixture()
        defer { f.workspace.shutdown() }
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store), "attention-sidebar-navigator",
                               size: NSSize(width: 300, height: 520), background: RelayTheme.sidebar)
    }
}

/// Offscreen render of a view in a borderless off-screen window, in both
/// appearances (also light for views product code forces dark).
@MainActor enum RelayUIShot {
    static func window<V: View>(_ view: V, _ name: String, size: NSSize, background: Color) throws {
        for (appearance, suffix, light) in [(NSAppearance.Name.darkAqua, "dark", false), (.aqua, "light", true)] {
            let base = view.frame(width: size.width, height: size.height).background(background)
            let host = light ? NSHostingView(rootView: AnyView(base.environment(\.colorScheme, .light)))
                             : NSHostingView(rootView: AnyView(base))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["RELAY_SNAPSHOT_DIR"], !dir.isEmpty,
               let png = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
            }
            #expect(rep.pixelsWide >= Int(size.width))
            window.contentView = nil
            window.close()
        }
    }
}
