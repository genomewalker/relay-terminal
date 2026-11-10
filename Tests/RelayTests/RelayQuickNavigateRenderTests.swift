import AppKit
import SwiftUI
import Testing
@testable import Relay

/// Go to pane over panes in each status, light and dark.
@MainActor @Suite("Go to pane renders", .serialized)
struct RelayQuickNavigateRenderTests {
    @Test("Row icons show the pane's kind in its fleet board status role")
    func rowIconsAndRoles() throws {
        typealias Nav = RelayQuickNavigate
        // The kind symbol: agent, shell or editor, as the sidebar shows it.
        #expect(Nav.paneSymbol(contentKind: .terminal, kind: .claude) == AgentKind.claude.symbol)
        #expect(Nav.paneSymbol(contentKind: .terminal, kind: .codex) == AgentKind.codex.symbol)
        #expect(Nav.paneSymbol(contentKind: .terminal, kind: .shell) == "terminal")
        #expect(Nav.paneSymbol(contentKind: .editor, kind: .claude) == PaneContentKind.editor.symbol)
        // The colour role is the fleet board's; an editor stays neutral.
        for status in RelayWorkOverviewIndex.PaneStatus.allCases {
            #expect(Nav.paneRole(contentKind: .terminal, status: status) == status.role)
            #expect(Nav.paneRole(contentKind: .editor, status: status) == .neutral)
        }

        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        let entries = Nav.entries(for: f.workspace, query: "")
        func entry(_ pane: PaneModel) throws -> RelayWorkOverviewIndex.Entry {
            try #require(entries.first { $0.id == "pane:\(pane.id)" })
        }
        let expected: [(PaneModel, RelayTheme.StatusRole)] = [
            (f.waiting, .warning), (f.failed, .danger), (f.running, .success),
            (f.reconnecting, .pending), (f.clean, .neutral),
        ]
        for (pane, role) in expected {
            let row = try entry(pane)
            #expect(row.statusRole == role)
            #expect(row.symbol == pane.kind.symbol)
        }
        // A reconnecting agent's words match its grey icon and the fleet board.
        let reconnectingFact = try #require(RelayWorkOverviewIndex.paneFacts(f.workspace).first { $0.paneID == f.reconnecting.id })
        #expect(reconnectingFact.status == .reconnecting)
        #expect(try entry(f.reconnecting).status == reconnectingFact.detail)
        #expect(try entry(f.reconnecting).status.localizedCaseInsensitiveContains("reconnecting"))
        #expect(try entry(f.failed).status == "Exited with status 2")
        let tabs = entries.filter { $0.id.hasPrefix("tab:") }
        #expect(!tabs.isEmpty)
        #expect(tabs.allSatisfy { $0.statusRole == nil && $0.symbol == "rectangle.on.rectangle" })
    }

    @Test("Go to pane renders in light and dark")
    func renders() throws {
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
            let view = RelayQuickNavigate(workspace: f.workspace).environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(view, name: "go-to-pane", width: 620, appearance: appearance)
            #expect(shot.size.height > 200)
        }
    }
}
