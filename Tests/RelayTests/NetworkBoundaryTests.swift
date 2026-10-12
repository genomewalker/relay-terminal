import Foundation
import Testing
@testable import Relay

@Test func networkBoundaryDoesNotExpandUnrelatedSessions() throws {
    func link(_ pid: Int, _ source: String, _ target: String) throws -> PeerNetworkStatus {
        let data = Data("{\"schema\":1,\"pid\":\(pid),\"host\":\"remote\",\"localName\":\"desktop\",\"localSession\":\"\(source)\",\"remoteName\":\"agent\",\"remoteSession\":\"\(target)\",\"state\":\"online\",\"updatedAt\":\"2026-09-21T10:00:00Z\",\"attempt\":0,\"rttMillis\":1}".utf8)
        return try JSONDecoder().decode(PeerNetworkStatus.self, from: data)
    }
    let a = try link(1, "desktop", "pane-agent")
    let unrelated = try link(2, "other-desktop", "other-agent")
    let pane = NetworkParticipant(id: a.destinationIdentity, name: "Pane")
    let result = NetworkParticipant.withBoundaryEndpoints([pane], links: [a, a, unrelated])
    #expect(result.count == 2)
    #expect(result.first { $0.id == a.sourceIdentity }?.externalEndpoint == true)
    #expect(result.first { $0.id == a.sourceIdentity }?.links.count == 1)
    #expect(!result.contains { $0.id == unrelated.destinationIdentity })
    #expect(NetworkParticipant.withBoundaryEndpoints([], links: [a]).isEmpty)
}

@Test("Configured link endpoints remain visible without a matching Relay pane")
func configuredLinkEndpointsRemainVisible() throws {
    let link = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(#"{"schema":1,"pid":41,"host":"dandy-07","localName":"desktop-task","localSession":"thread-1","remoteName":"remote-agent","remoteSession":"session-1","state":"online","updatedAt":"2026-09-22T12:00:00Z","attempt":0,"rttMillis":3}"#.utf8))
    let unrelatedPane = NetworkParticipant(
        id: .init(host: "dandy-07", session: "pane-unrelated", local: false),
        name: "Unrelated pane")
    let unrelatedLocalPane = NetworkParticipant(
        id: .init(host: "This Mac", session: "pane-local", local: true),
        name: "Local shell")

    let result = NetworkParticipant.withActiveLinkEndpoints([unrelatedPane, unrelatedLocalPane], links: [link, link])

    #expect(result.count == 4)
    #expect(result.first { $0.id == link.sourceIdentity }?.externalEndpoint == true)
    #expect(result.first { $0.id == link.destinationIdentity }?.externalEndpoint == true)
    #expect(result.first { $0.id == link.sourceIdentity }?.links.count == 1)
    #expect(result.first { $0.id == link.destinationIdentity }?.links.count == 1)
    #expect(result.contains { $0.id == unrelatedPane.id && !$0.externalEndpoint })
    #expect(result.firstIndex { $0.id == link.sourceIdentity }! < result.firstIndex { $0.id == unrelatedLocalPane.id }!)
}
