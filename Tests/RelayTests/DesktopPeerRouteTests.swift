import Foundation
import Testing
@testable import Relay

@Test("Explicit route disconnect is persistent before the worker stops")
func desktopRoutePersistentDisconnect() {
    #expect(DesktopPeerRoute.serviceCommands(connected: false, target: "gui/1/route") ==
        [["disable", "gui/1/route"], ["kill", "SIGTERM", "gui/1/route"]])
    #expect(DesktopPeerRoute.serviceCommands(connected: true, target: "gui/1/route") ==
        [["enable", "gui/1/route"], ["kickstart", "gui/1/route"]])
}

@Test("Network navigation preserves the selected terminal and returns explicitly")
@MainActor func networkNavigationPreservesWorkspace() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTabID
    let pane = workspace.activePaneID
    let ids = Set(workspace.panes.keys)
    workspace.sidebarVisible = false
    workspace.showNetwork()
    #expect(workspace.networkVisible)
    #expect(!workspace.sidebarVisible)
    #expect(workspace.selectedTabID == tab)
    #expect(workspace.activePaneID == pane)
    #expect(Set(workspace.panes.keys) == ids)
    if let tab {
        workspace.selectTab(tab)
        #expect(workspace.networkVisible)
        #expect(workspace.activePaneID == pane)
    }
    if let pane {
        workspace.showNetwork()
        workspace.selectPane(pane)
        #expect(workspace.networkVisible)
        workspace.hideNetwork()
        #expect(!workspace.networkVisible)
        #expect(workspace.activePaneID == pane)
        workspace.showNetwork()
        workspace.revealPane(pane)
        #expect(!workspace.networkVisible)
        #expect(workspace.activePaneID == pane)
    }
}

@Test("Desktop route discovery binds only known installed service commands")
func desktopRouteDiscovery() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent(".local/share/relay/desktop-routing")
    let agents = home.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("test.json")
    let object: [String: Any] = ["host": "dandy-07", "localName": "desktop", "thread": "task-a", "remoteName": "codex", "remoteSession": "task-b", "remotePID": 123, "remoteStart": "456"]
    try JSONSerialization.data(withJSONObject: object).write(to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    let label = "dev.vaklab.relay-desktop-test"
    let service = agents.appendingPathComponent(label + ".plist")
    var plist: [String: Any] = ["Label": label, "ProgramArguments": [root.appendingPathComponent("venv/bin/python").path, root.appendingPathComponent("relay-desktop-route.py").path, "listen", "--config", config.path]]
    func save() throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: service)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: service.path)
    }
    try save()
    #expect(DesktopPeerRoute.read(home: home).first?.thread == "task-a")
    let route = try #require(DesktopPeerRoute.read(home: home).first)
    let raw = #"{"schema":1,"pid":99,"host":"dandy-07","localName":"desktop","localSession":"task-a","remoteName":"codex","remoteSession":"task-b","remotePID":123,"remoteStart":"456","state":"online","updatedAt":"2026-09-21T00:00:00Z","attempt":0,"rttMillis":-1}"#
    let status = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(raw.utf8))
    #expect(route.matches(status))
    let changed = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(raw.replacingOccurrences(of: "\"remoteStart\":\"456\"", with: "\"remoteStart\":\"457\"").utf8))
    #expect(!route.matches(changed))
    plist["ProgramArguments"] = ["/bin/sh", "-c", "arbitrary"]
    try save()
    #expect(DesktopPeerRoute.read(home: home).isEmpty)
    plist["Label"] = "unrelated-service"
    try save()
    #expect(DesktopPeerRoute.read(home: home).isEmpty)
}
