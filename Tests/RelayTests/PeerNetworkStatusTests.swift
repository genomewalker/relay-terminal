import Foundation
import Testing
@testable import Relay

@Test("Remote-to-remote links retain both remote endpoint identities")
func remoteNetworkEndpoints() throws {
    let json = #"{"schema":1,"pid":123,"sourceHost":"dandy-07","host":"dandy-07","localName":"pan-barley","localSession":"a","remoteName":"codex","remoteSession":"b","state":"online","updatedAt":"2026-09-20T10:00:00Z","attempt":0,"rttMillis":-1}"#
    let link = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(json.utf8))
    let participants = NetworkParticipant.collect(local: [], links: [link])
    #expect(participants.count == 2)
    #expect(participants.allSatisfy { !$0.id.local && $0.id.host == "dandy-07" })
    #expect(Set(participants.map(\.id)) == Set([link.sourceIdentity, link.destinationIdentity]))
    let crossHost = json.replacingOccurrences(of: "\"sourceHost\":\"dandy-07\"", with: "\"sourceHost\":\"dandy-08\"")
    let remote = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(crossHost.utf8))
    #expect(remote.sourceIdentity.host == "dandy-08")
    #expect(remote.destinationIdentity.host == "dandy-07")
}

@Test("Peer network status never treats old snapshots as connected")
func peerNetworkStatusFreshness() throws {
    let json = #"{"schema":1,"pid":123,"host":"test","localName":"a","localSession":"a","remoteName":"b","remoteSession":"b","state":"online","updatedAt":"2026-09-20T10:00:00.000Z","attempt":0,"rttMillis":12}"#
    let value = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(json.utf8))
    let now = ISO8601DateFormatter().date(from: "2026-09-20T10:00:01Z")!
    #expect(value.displayState(now: now) == "Connected")
    #expect(value.evidence(now: now) == .connected)
    #expect(value.evidenceLabel(now: now) == "Connected transport")
    #expect(value.latencyLabel == "12 ms")
    let unknown = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(json.replacingOccurrences(of: "\"rttMillis\":12", with: "\"rttMillis\":-1").utf8))
    #expect(unknown.latencyLabel == "Not measured")
    #expect(value.displayState(now: now.addingTimeInterval(60)) == "Offline · stale status")
    #expect(value.evidence(now: now.addingTimeInterval(60)) == .earlier)
    #expect(value.evidenceLabel(now: now.addingTimeInterval(60)) == "Earlier connection · not verified now")
    let attention = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(json.replacingOccurrences(of: "\"online\"", with: "\"needs_attention\"").utf8))
    #expect(attention.displayState(now: now.addingTimeInterval(600)) == "Needs attention")
    #expect(attention.evidence(now: now.addingTimeInterval(600)) == .needsReview)
    #expect(attention.evidenceLabel(now: now.addingTimeInterval(600)) == "Needs review · remote identity changed")
    #expect(value.displayState(now: now.addingTimeInterval(-60)) == "Offline · stale status")
    let wholeSeconds = json.replacingOccurrences(of: "10:00:00.000Z", with: "10:00:00Z")
    let wholeValue = try JSONDecoder().decode(PeerNetworkStatus.self, from: Data(wholeSeconds.utf8))
    #expect(wholeValue.displayState(now: now) == "Connected")
}

@Test("Peer network reader ignores malformed snapshots and symbolic links")
func peerNetworkStatusFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("bad.json")
    try Data("null".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.json"), withDestinationURL: file)
    #expect(PeerNetworkStatus.read(directory: folder).isEmpty)
}

@Test("Recent network snapshots are not hidden behind old process files")
func peerNetworkStatusRecentCandidates() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 1...257 {
        let json = """
        {"schema":1,"pid":\(index),"host":"test","localName":"a","localSession":"a","remoteName":"b","remoteSession":"b","state":"stopped","updatedAt":"2026-09-20T10:00:00Z","attempt":0,"rttMillis":0}
        """
        let file = folder.appendingPathComponent(index == 257 ? "zz-latest.json" : "\(index).json")
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
    }
    let snapshots = PeerNetworkStatus.read(directory: folder)
    #expect(snapshots.count == 256)
    #expect(snapshots.contains { $0.pid == 257 })
    #expect(!snapshots.contains { $0.pid == 1 })
}
