import Foundation
import Testing
@testable import Relay

@Test func topologyMergesExactEndpointsAndFindsEitherSide() throws {
    func link(_ pid: Int, _ source: String, _ target: String, state: String = "online") throws -> PeerNetworkStatus {
        let value: [String: Any] = ["schema": 1, "pid": pid, "host": "remote", "localName": "Source",
            "localSession": source, "remoteName": "Target", "remoteSession": target, "state": state,
            "updatedAt": "2026-09-26T12:00:00Z", "attempt": 0, "rttMillis": -1]
        return try JSONDecoder().decode(PeerNetworkStatus.self, from: JSONSerialization.data(withJSONObject: value))
    }
    let a = try link(1, "same", "first")
    let b = try link(2, "same", "second")
    let stopped = try link(3, "unrelated", "third", state: "stopped")
    let owner = NetworkParticipant(id: a.sourceIdentity, name: "Human readable task")
    let graph = NetworkTopologyProjection(links: [a, b, stopped], participants: [owner], query: "")
    #expect(graph.nodes.count == 3)
    #expect(graph.links.count == 2)
    #expect(graph.hosts == ["This Mac", "remote"])
    #expect(NetworkTopologyProjection(links: [a, b], participants: [owner], query: "readable").links.count == 2)
    #expect(NetworkTopologyProjection(links: [a, b], participants: [], query: "second").links.count == 1)
}

@Test func topologySupportsAllHostPairingsWithoutSplittingDesktopIdentity() throws {
    func link(_ pid: Int, sourceHost: String?, targetHost: String, source: String, target: String) throws -> PeerNetworkStatus {
        var value: [String: Any] = ["schema": 1, "pid": pid, "host": targetHost, "localName": source,
            "localSession": source, "remoteName": target, "remoteSession": target, "state": "online",
            "updatedAt": "2026-09-26T12:00:00Z", "attempt": 0, "rttMillis": -1]
        if let sourceHost { value["sourceHost"] = sourceHost }
        return try JSONDecoder().decode(PeerNetworkStatus.self, from: JSONSerialization.data(withJSONObject: value))
    }
    let desktop = try link(1, sourceHost: nil, targetHost: "This Mac", source: "desktop-a", target: "desktop-b")
    let cross = try link(2, sourceHost: "This Mac", targetHost: "remote", source: "desktop-b", target: "remote-a")
    let remote = try link(3, sourceHost: "remote", targetHost: "remote", source: "remote-a", target: "remote-b")
    let graph = NetworkTopologyProjection(links: [desktop, cross, remote], participants: [], query: "")
    #expect(graph.nodes.count == 4)
    #expect(desktop.destinationIdentity == cross.sourceIdentity)
    #expect(cross.destinationIdentity == remote.sourceIdentity)
    #expect(desktop.destinationIdentity.local)
    #expect(!remote.sourceIdentity.local)
    #expect(graph.hosts == ["This Mac", "remote"])
}

@Test func sameHostCurveStaysOutsideNodeLabelsAndMatchesHitTesting() {
    let curve = NetworkTopologyCurve(source: .init(x: 24, y: 58), target: .init(x: 24, y: 158),
        nodeWidth: 220, sameHost: true, clearance: 40)
    #expect(curve.point(at: 0) == curve.a)
    #expect(curve.point(at: 1) == curve.b)
    #expect(curve.point(at: 0.5).x > 244)
    #expect(curve.point(at: 0.5).y == 126)
}
