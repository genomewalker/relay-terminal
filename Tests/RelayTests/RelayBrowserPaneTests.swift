import Foundation
import Testing
@testable import Relay

@Suite("Browser panes", .serialized)
@MainActor struct RelayBrowserPaneTests {
    @Test func aShownBrowserGivesItsSlotBackToASavedStackMate() throws {
        let a = UUID(), b = UUID(), c = UUID(), split = UUID()
        let floating = FloatingPanePlacement.initial(paneID: b, index: 0)
        // Two members: the stack disappears and its terminal takes the slot.
        let two = try #require(BrowserPaneSave.strip(layout: .split(id: split, axis: .horizontal, first: .pane(b), second: .pane(c)),
                                                     stacks: [PaneStack(id: UUID(), members: [a, b], selected: b)],
                                                     floating: [floating], browsers: [b]))
        #expect(two.layout == .split(id: split, axis: .horizontal, first: .pane(a), second: .pane(c)))
        #expect(two.stacks.isEmpty && two.floating.isEmpty)
        // Three members: the stack keeps its saved members, shown by a saved one.
        let stack = PaneStack(id: UUID(), members: [a, b, c], selected: b)
        let three = try #require(BrowserPaneSave.strip(layout: .pane(b), stacks: [stack], floating: [], browsers: [b]))
        #expect(three.layout == .pane(a) && three.stacks == [PaneStack(id: stack.id, members: [a, c], selected: a)])
        // A hidden browser leaves the layout as it is.
        let hidden = try #require(BrowserPaneSave.strip(layout: .pane(a), stacks: [PaneStack(id: stack.id, members: [a, b], selected: a)],
                                                        floating: [], browsers: [b]))
        #expect(hidden.layout == .pane(a) && hidden.stacks.isEmpty)
        // Nothing saved is left.
        #expect(BrowserPaneSave.strip(layout: .pane(b), stacks: [], floating: [], browsers: [b]) == nil)
        #expect(BrowserPaneSave.savedFocus(b, stacks: [stack], browsers: [b]) == a)
        #expect(BrowserPaneSave.savedFocus(c, stacks: [stack], browsers: [b]) == c)
    }

    @Test func aBrowserPaneIsNeverSavedOrListedToTheUpdater() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let browser = try workspace.newBrowserPane(onto: anchor, url: nil)
        #expect(browser.contentKind == .browser && browser.connectionState == .connected)
        #expect(workspace.activePaneID == browser.id)                     // shown and focused in the stack
        #expect(workspace.stackedBrowserPane(for: anchor) === browser)
        #expect(workspace.stackedBrowserPane(for: browser.id) === browser)

        let data = try JSONEncoder().encode(workspace.currentWorkspaceSnapshot())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains(browser.id.uuidString) && !json.contains("\"browser\""))
        let saved = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        #expect(saved.activePaneID == anchor)
        #expect(saved.panes.map(\.id).contains(anchor))
        #expect(saved.tabs.allSatisfy { $0.layout.paneIDs.contains(anchor) || !$0.layout.paneIDs.isEmpty })

        let live = workspace.sidePanelState()
        #expect(live.selectedPaneID == anchor.uuidString.lowercased())
        let listed = live.sessions.flatMap(\.tabs).flatMap(\.panes).map(\.id)
        #expect(listed.contains(anchor.uuidString.lowercased()) && !listed.contains(browser.id.uuidString.lowercased()))
        #expect(throws: (any Error).self) { try workspace.newBrowserPane(onto: browser.id, url: nil) } // not onto itself
    }

    /// WebKit aborts the app when a web view is first made off the main
    /// thread; 0.5.87 crashed this way on its first stacked browser, from the
    /// default action handler. This uses that handler, on a closed port.
    @Test func theDefaultHandlerMakesTheStackedBrowserOnTheMainThread() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let instance = UUID()
        let proposal = MCPDirectTabRequests.BrowserProposal(instance: instance, requestID: UUID(), paneID: anchor, action: .open,
                                                           url: "http://127.0.0.1:9/", placement: "stack")
        let handler = MCPDirectTabRequests()
        let refused = await handler.browser(try JSONEncoder().encode(proposal), instance: instance,
                                            permits: { $0 != .create }, workspace: workspace)
        #expect(refused.status == 403)
        #expect(workspace.stackedBrowserPane(for: anchor) == nil)
        let response = await handler.browser(try JSONEncoder().encode(proposal), instance: instance,
                                             permits: { _ in true }, workspace: workspace)
        #expect(response.status == 200)
        let browser = try #require(workspace.stackedBrowserPane(for: anchor))
        browser.browserSession.close()
    }

    /// What a save of this workspace holds, as JSON text and decoded.
    static func saved(_ workspace: WorkspaceModel) throws -> (json: String, snapshot: WorkspaceSnapshot) {
        let data = try JSONEncoder().encode(workspace.currentWorkspaceSnapshot())
        return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode(WorkspaceSnapshot.self, from: data))
    }

    @Test func aSplitBrowserIsLeftOutAndItsSplitWithIt() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let before = try Self.saved(workspace).snapshot
        let browser = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .split)
        let tab = try #require(workspace.selectedTab)
        #expect(tab.layout.paneIDs == [anchor, browser.id] && tab.stacks.isEmpty)
        #expect(workspace.activePaneID == browser.id)

        let (json, saved) = try Self.saved(workspace)
        #expect(!json.contains(browser.id.uuidString) && !json.contains("\"browser\""))
        let savedTab = try #require(saved.tabs.first { $0.id == tab.id })
        #expect(savedTab.layout == .pane(anchor))                       // the split is gone with the browser
        #expect(savedTab.splitRatios?.isEmpty ?? true)
        #expect(saved.activePaneID == anchor && saved.selectedTabID == tab.id)
        #expect(saved.tabs.map(\.id) == before.tabs.map(\.id))
        #expect(workspace.stackedBrowserPane(for: anchor) === browser)
    }

    @Test func aBrowserTabIsLeftOutAndFocusReturnsToItsPane() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let home = try #require(workspace.selectedTabID)
        let browser = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .tab)
        let browserTab = try #require(workspace.tabs.first { $0.allPaneIDs == [browser.id] })
        #expect(workspace.tabs.firstIndex { $0 === browserTab } == (workspace.tabs.firstIndex { $0.id == home } ?? -1) + 1)
        #expect(workspace.selectedTabID == browserTab.id && workspace.activePaneID == browser.id)

        let (json, saved) = try Self.saved(workspace)
        #expect(!json.contains(browser.id.uuidString) && !json.contains(browserTab.id.uuidString))
        #expect(saved.selectedTabID == home && saved.activePaneID == anchor)   // what the updater compares

        let live = workspace.sidePanelState()
        #expect(live.selectedPaneID == anchor.uuidString.lowercased())
        #expect(!live.sessions.flatMap(\.tabs).map(\.id).contains(browserTab.id.uuidString.lowercased()))
    }

    @Test func anAgentsBrowserNeverSwitchesTheUsersTab() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let home = try #require(workspace.selectedTabID)
        let tabbed = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .tab, select: false)
        #expect(workspace.selectedTabID == home && workspace.activePaneID == anchor)
        #expect(workspace.tabs.contains { $0.allPaneIDs == [tabbed.id] })
        let split = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .split, select: false)
        #expect(workspace.selectedTabID == home && workspace.activePaneID == anchor)
        #expect(workspace.selectedTab?.layout.paneIDs.contains(split.id) == true)
        #expect(throws: (any Error).self) { try workspace.newBrowserPane(onto: split.id, url: nil, placement: .tab) }
    }

    @Test func eachPlacementFindsItsOwnBrowserAndActionsUseTheNewest() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let anchor = try #require(workspace.activePaneID)
        let split = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .split, select: false)
        #expect(workspace.browserPlacement(split) == .split)
        #expect(workspace.stackedBrowserPane(for: anchor, placement: .tab) == nil)   // so a tab is made, not the split reused
        let tabbed = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .tab, select: false)
        let stacked = try workspace.newBrowserPane(onto: anchor, url: nil, placement: .stack, select: false)
        #expect(workspace.browserPlacement(tabbed) == .tab && workspace.browserPlacement(stacked) == .stack)
        #expect(workspace.stackedBrowserPane(for: anchor, placement: .split) === split)
        #expect(workspace.stackedBrowserPane(for: anchor, placement: .tab) === tabbed)
        #expect(workspace.stackedBrowserPane(for: anchor) === stacked)                // the newest
    }

    @Test func agentsSeeTheHostsAddressNotTheMacPort() {
        let carried = URL(string: "http://127.0.0.1:61345/form.html?q=1")!
        #expect(RelayBrowserRouting.hostURL(carried, tunnels: [5173: 61345]).absoluteString == "http://localhost:5173/form.html?q=1")
        #expect(RelayBrowserRouting.hostURL(carried, tunnels: [:]) == carried)
        let web = URL(string: "https://example.org/")!
        #expect(RelayBrowserRouting.hostURL(web, tunnels: [5173: 61345]) == web)
    }

    @Test func stackPlacementIsOnlyForOpen() {
        func proposal(_ action: RelayBrowserAgentAction, placement: String?) -> MCPDirectTabRequests.BrowserProposal {
            MCPDirectTabRequests.BrowserProposal(instance: UUID(), requestID: UUID(), paneID: UUID(), action: action,
                                                 url: action == .open ? "http://localhost:5173/" : nil, placement: placement)
        }
        for placement in ["stack", "split", "tab", "floating"] { #expect(proposal(.open, placement: placement).isValid) }
        #expect(!proposal(.open, placement: "window").isValid && !proposal(.read, placement: "stack").isValid)
        #expect(!proposal(.click, placement: "tab").isValid)
    }
}
