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
        workspace.selectPane(pane, origin: .user)
        #expect(workspace.networkVisible)
        workspace.hideNetwork()
        #expect(!workspace.networkVisible)
        #expect(workspace.activePaneID == pane)
        workspace.showNetwork()
        workspace.revealPane(pane, origin: .user)
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
    var plist: [String: Any] = ["Label": label, "ProgramArguments": [DesktopPeerRoute.runtimeExecutable.path, "desktop-route", "listen", "--config", config.path]]
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

@Test("Native desktop discovery markers are exact, bounded and fail closed")
func nativeDesktopDiscoveryMarkerParser() {
    let prefix = "relayd: relay-desktop-discovery-go-v1:"
    let combinations: [(DesktopPeerRoute.DiscoveryFailure.Work, DesktopPeerRoute.DiscoveryFailure.Legacy)] = [
        (.noSaved, .empty), (.noSaved, .unavailable),
        (.savedUnverified, .empty), (.savedUnverified, .unavailable), (.savedUnverified, .conflict),
        (.unavailable, .notChecked),
    ]
    var valid = Set<Data>()
    for (work, legacy) in combinations {
        let bytes = Data((prefix + work.rawValue + ":" + legacy.rawValue + "\n").utf8)
        valid.insert(bytes)
        #expect(DesktopPeerRoute.discoveryFailure(bytes) == .init(work: work, legacy: legacy))
        #expect(DesktopPeerRoute.discoveryFailure(bytes.dropLast()) == nil)
        #expect(DesktopPeerRoute.discoveryFailure(bytes.dropLast() + Data("x".utf8)) == nil)
        #expect(DesktopPeerRoute.discoveryFailure(bytes + Data("private".utf8)) == nil)
    }
    #expect(DesktopPeerRoute.discoveryFailure(Data((prefix + "no_saved_work_refs:identity_conflict\n").utf8)) == nil)
    #expect(DesktopPeerRoute.discoveryFailure(Data((prefix + "private:empty\n").utf8)) == nil)
    #expect(DesktopPeerRoute.discoveryFailure(Data(repeating: 65, count: 161)) == nil)
    var state: UInt64 = 0x1a2b3c4d5e6f7788
    for _ in 0..<10_000 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let count = Int((state >> 32) % 200)
        var bytes = Data(); bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        #expect((DesktopPeerRoute.discoveryFailure(bytes) != nil) == valid.contains(bytes))
    }
}

@Test("Native desktop discovery API failure remains 503 and hides arbitrary errors")
func nativeDesktopDiscoveryFailureResponse() {
    let known = DesktopPeerRoute.DiscoveryFailure(work: .savedUnverified, legacy: .conflict)
    let response = RelaySidePanelHTTPResponse.desktopDiscoveryFailure(known)
    #expect(response.status == 503)
    #expect(String(decoding: response.body, as: UTF8.self) == known.errorDescription)
    let secret = NSError(domain: "private-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-secret"])
    let unknown = RelaySidePanelHTTPResponse.desktopDiscoveryFailure(secret)
    #expect(unknown.status == 503)
    #expect(String(decoding: unknown.body, as: UTF8.self) == "Desktop task discovery unavailable.")
}
