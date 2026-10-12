import Testing
@testable import Relay

@Test func sharedConversationResolvesByExactPaneAndProcess() {
    let a = DiscoveredPeer(name: "convergence-a", sessionId: "shared", pid: 10, procStart: "100", paneID: "pane-a")
    let b = DiscoveredPeer(name: "convergence-b", sessionId: "shared", pid: 20, procStart: "200", paneID: "pane-b")
    #expect(NetworkParticipant.peersForPane([a,b], paneID: "pane-b", roots: []).map(\.pid) == [20])
    #expect(NetworkParticipant.peersForPane([a,b], paneID: "pane-a", roots: ["claude:20:200"]).map(\.pid) == [10])
    #expect(NetworkParticipant.peersForPane([a,b], paneID: "other", roots: []).isEmpty)
    let collision = DiscoveredPeer(name: "other", sessionId: "another", pid: 30, procStart: "300", paneID: "pane-b")
    #expect(NetworkParticipant.peersForPane([a,b,collision], paneID: "pane-b", roots: []).count == 2)
}

@Test func networkProcessScopeRequiresIncarnation() {
    let peer = DiscoveredPeer(name: "codex", sessionId: "session", pid: 42, procStart: "100")
    #expect(NetworkParticipant.matchesProcess(peer, roots: ["codex:42:100"]))
    #expect(!NetworkParticipant.matchesProcess(peer, roots: ["codex:42:99"]))
    #expect(!NetworkParticipant.matchesProcess(peer, roots: ["codex:41:100"]))
    #expect(!NetworkParticipant.matchesProcess(peer, roots: ["codex", "session"]))
    #expect(!NetworkParticipant.matchesProcess(.init(name: "codex", sessionId: "session", pid: 42), roots: ["codex:42:100"]))
    #expect(!NetworkParticipant.matchesProcess(.init(name: "codex", sessionId: "session", pid: 42, procStart: "0"), roots: ["codex:42:0"]))
}
