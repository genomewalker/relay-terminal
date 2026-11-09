import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// The sidebar and top bar say each thing once: no host chip a row's
/// workspace already implies, no breadcrumb above the switcher and tab that
/// show the same names, and inbox rows that do not repeat the place.
@MainActor @Suite("Sidebar redundancy")
struct RelaySidebarRedundancyTests {
    struct Fixture {
        let workspace: WorkspaceModel
        let store: AgentIntelligenceStore
        let uniformID, mixedID: UUID
        let aegis, math, build, cluster: PaneModel
    }

    /// One workspace entirely on dandy-07 and one mixing This Mac and
    /// dandy-07, with tab names as long as the live ones.
    static func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let uniformID = workspace.createWorkspace(named: "Pan-barley")
        let mixedID = workspace.createWorkspace(named: "Relay")
        func pane(_ tabName: String, _ paneName: String, profile: ConnectionProfile, in workspaceID: UUID) throws -> PaneModel {
            workspace.newTab(profile: profile)
            let pane = try #require(workspace.activePane)
            let tab = try #require(workspace.tabs.first { $0.allPaneIDs.contains(pane.id) })
            tab.name = tabName
            pane.customName = paneName
            pane.connectionState = .connected
            try workspace.performDrop(.tabOnWorkspace(tabID: tab.id, workspaceID: workspaceID, index: nil))
            return pane
        }
        let dandy = ConnectionProfile.sshConfigHost("dandy-07")
        let aegis = try pane("AEGIS-LINEAGE reconstruction", "aegis-lineage", profile: dandy, in: uniformID)
        let math = try pane("Math & Guarantees", "math-guarantees", profile: dandy, in: uniformID)
        _ = try pane("smdb-import", "smdb-import", profile: dandy, in: uniformID)
        let build = try pane("Relay build", "relay-build", profile: .local, in: mixedID)
        _ = try pane("Release notes", "notes", profile: .local, in: mixedID)
        let cluster = try pane("Cluster sync", "cluster-sync", profile: dandy, in: mixedID)
        math.received("Do you want to proceed? (y/n)\n")
        cluster.exited(exitCode: 2)
        workspace.selectWorkspace(uniformID, origin: .user)
        if let tab = workspace.tabs.first(where: { $0.allPaneIDs.contains(aegis.id) }) {
            workspace.selectTab(tab.id, origin: .user)
        }
        return Fixture(workspace: workspace, store: store, uniformID: uniformID, mixedID: mixedID,
                       aegis: aegis, math: math, build: build, cluster: cluster)
    }

    @Test("A tab row names its host only when it differs from the workspace's main host")
    func hostChip() throws {
        typealias Hosts = WorkspaceNavigatorHosts
        #expect(Hosts.main(["dandy-07", "dandy-07", "This Mac"]) == "dandy-07")
        #expect(Hosts.main(["This Mac", "dandy-07"]) == "This Mac")
        #expect(Hosts.main([]) == nil)
        // Same host as the workspace: no chip. Different or mixed: the chip stays.
        #expect(Hosts.chip(tabHosts: ["dandy-07", "dandy-07"], main: "dandy-07") == nil)
        #expect(Hosts.chip(tabHosts: ["This Mac"], main: "dandy-07") == "This Mac")
        #expect(Hosts.chip(tabHosts: ["dandy-07", "This Mac"], main: "dandy-07") == "This Mac, dandy-07")
        #expect(Hosts.chip(tabHosts: [], main: "dandy-07") == nil)
        #expect(Hosts.chip(tabHosts: ["dandy-07"], main: nil) == "dandy-07")
        // The workspace row names its main host once, unless its name does.
        #expect(Hosts.workspaceCaption(name: "Pan-barley", main: "dandy-07") == "dandy-07")
        #expect(Hosts.workspaceCaption(name: "Dandy-07 jobs", main: "dandy-07") == nil)
        #expect(Hosts.workspaceCaption(name: "Empty", main: nil) == nil)

        let f = try Self.makeFixture()
        defer { f.workspace.shutdown() }
        func main(_ id: UUID) -> String? {
            Hosts.main(f.workspace.tabs(inWorkspace: id).flatMap(\.allPaneIDs).compactMap { f.workspace.panes[$0] }
                .map { Hosts.label($0.profile) })
        }
        #expect(main(f.uniformID) == "dandy-07")
        #expect(main(f.mixedID) == "This Mac")
        #expect(Hosts.chip(tabHosts: [Hosts.label(f.aegis.profile)], main: main(f.uniformID)) == nil)
        #expect(Hosts.chip(tabHosts: [Hosts.label(f.build.profile)], main: main(f.mixedID)) == nil)
        #expect(Hosts.chip(tabHosts: [Hosts.label(f.cluster.profile)], main: main(f.mixedID)) == "dandy-07")
    }

    @Test("An inbox row names the pane once, then the status and workspace once")
    func attentionRowText() {
        let text = AttentionInboxRowText(pane: "math-guarantees", tab: "Math & Guarantees", workspace: "Pan-barley",
                                         status: "Needs input", closed: false)
        #expect(text.title == "math-guarantees")
        #expect(text.subtitle == "Needs input · Pan-barley")
        #expect(!text.title.contains("Pan-barley") && !text.title.contains("Math & Guarantees"))
        // No pane name: the tab names the row.
        #expect(AttentionInboxRowText(pane: "  ", tab: "Cluster sync", workspace: "Relay", status: "Exited with status 2",
                                      closed: false).title == "Cluster sync")
        // A closed pane says so; a workspace the status already names is not repeated.
        #expect(AttentionInboxRowText(pane: nil, tab: nil, workspace: "Relay", status: "Needs input", closed: true)
            == AttentionInboxRowText(pane: "Pane", tab: nil, workspace: "Relay", status: "Closed", closed: false))
        #expect(AttentionInboxRowText(pane: "a", tab: nil, workspace: "Relay", status: "Relay build failed",
                                      closed: false).subtitle == "Relay build failed")
        #expect(AttentionInboxRowText(pane: "a", tab: nil, workspace: nil, status: "Needs input", closed: false)
            .subtitle == "Needs input")
    }

    @Test("Sidebar navigator (narrow and wide) and top bar, light and dark")
    func snapshots() throws {
        let f = try Self.makeFixture()
        defer { f.workspace.shutdown() }
        for width: CGFloat in [244, 300, 380] {
            try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store),
                                   "sidebar-navigator-\(Int(width))",
                                   size: NSSize(width: width, height: 560), background: RelayTheme.sidebar)
        }
        try RelayUIShot.window(WorkspaceNavigationHeader(workspace: f.workspace) { WorkspaceTabRail(workspace: f.workspace) },
                               "sidebar-top-bar", size: NSSize(width: 900, height: 72), background: RelayTheme.canvas)
    }
}
