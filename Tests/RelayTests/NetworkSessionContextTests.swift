import Foundation
import Testing
@testable import Relay

@Test func networkSessionContextSearch() {
    var peer = NetworkParticipant(id: .init(host: "dandy-07", session: "abc", local: false), name: "Research")
    peer.directory = "/projects/pan-barley"
    peer.tabName = "Genomics"
    peer.provider = "Codex"
    #expect(peer.matches("barley codex genomics"))
    #expect(!peer.matches("barley claude"))
    #expect(peer.lastTurnAt == nil)
    let enriched = NetworkParticipant.withBoundaryEndpoints([peer], links: [])
    #expect(enriched.first?.directory == peer.directory)
}
