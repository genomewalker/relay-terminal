import Foundation
import Testing
@testable import Relay

@Suite("OSC program status display snapshots")
struct RelayProgramStatusTests {
    @Test func postAttachObservationRequiresSupportingTerminalWorker() throws {
        #expect(RelayRemoteTransport.programStatusNegotiationPayload(capabilities: [], observeAgentsOnly: false) == nil)
        #expect(RelayRemoteTransport.programStatusNegotiationPayload(capabilities: ["program_status_snapshot_v1"], observeAgentsOnly: false) == nil)
        #expect(RelayRemoteTransport.programStatusNegotiationPayload(capabilities: ["program_status_negotiation_v1"], observeAgentsOnly: true) == nil)
        let data = try #require(RelayRemoteTransport.programStatusNegotiationPayload(capabilities: ["program_status_negotiation_v1"], observeAgentsOnly: false))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        #expect(object == ["observe_program_status": true])
    }
    private func records(_ json: String) throws -> [RelayProgramStatusRecord] {
        try JSONDecoder().decode([RelayProgramStatusRecord].self, from: Data(json.utf8))
    }
    @Test func replacementRejectsStaleAndClearsExplicitly() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let initial = try records(#"[{"id":"build","state":"working","progress":42,"revision":1}]"#)
        let result1 = snapshot.replace(initial, revision: 1)
        #expect(result1)
        let result2 = !snapshot.replace(initial, revision: 1)
        #expect(result2)
        let result3 = !snapshot.replace([], revision: 0)
        #expect(result3)
        #expect(snapshot.records == initial)
        let result4 = snapshot.replace([], revision: 2)
        #expect(result4)
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.revision == 2)
    }
    @Test func malformedMetadataCannotReplaceGoodState() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let initial = try records(#"[{"state":"done"}]"#)
        let result5 = snapshot.replace(initial, revision: 1)
        #expect(result5)
        for json in [
            #"[{"state":"future"}]"#,
            #"[{"id":"bad//child","state":"done"}]"#,
            #"[{"id":"bad\u202e","state":"done"}]"#,
            #"[{"state":"working","progress":101}]"#,
            #"[{"state":"done","progress":10}]"#,
            #"[{"state":"done","title":"hidden\u001b"}]"#,
            #"[{"state":"done","message":"hidden\u202e"}]"#,
            #"[{"state":"done"},{"state":"working"}]"#
        ] {
            let result6 = !snapshot.replace(try records(json), revision: 2)
            #expect(result6)
            #expect(snapshot.records == initial)
            #expect(snapshot.revision == 1)
        }
    }
    @Test func idleAndBlockedProgressAreValidProtocolStates() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let idle = try records(#"[{"state":"idle"}]"#)
        let acceptedIdle = snapshot.replace(idle, revision: 1)
        #expect(acceptedIdle)
        let blocked = try records(#"[{"state":"blocked","kind":"auth","progress":50}]"#)
        let acceptedBlocked = snapshot.replace(blocked, revision: 2)
        #expect(acceptedBlocked)
    }
    @Test func daemonReplyOwnershipFiltersOnlyFixedDeviceReply() {
        let reply = Data([27, 93, 55, 53, 48, 49, 59, 63, 27, 92])
        #expect(!TerminalWriteForwardingPolicy.shouldForward(reply, filteringDeviceResponses: false, programStatusReplyOwnedByWorker: true))
        #expect(TerminalWriteForwardingPolicy.shouldForward(reply, filteringDeviceResponses: false))
        #expect(TerminalWriteForwardingPolicy.shouldForward(Data("x".utf8), filteringDeviceResponses: false, programStatusReplyOwnedByWorker: true))
    }
    @Test func wireSnapshotDecodesWithoutTransportAuthority() throws {
        let json = #"{"state":"program_status","program_status":[],"program_status_revision":8,"program_status_replay":true}"#
        let status = try JSONDecoder().decode(StatusWirePayload.self, from: Data(json.utf8))
        #expect(status.programStatus?.isEmpty == true)
        #expect(status.programStatusRevision == 8)
        #expect(status.programStatusReplay == true)
        #expect(status.controlGranted == nil)
        #expect(status.capabilities == nil)
    }
    @Test func omittedFalseReplayFlagMatchesActualGoWireEncoding() throws {
        let json = #"{"state":"program_status","program_status":[{"state":"blocked","kind":"question"}],"program_status_revision":2}"#
        let status = try JSONDecoder().decode(StatusWirePayload.self, from: Data(json.utf8))
        #expect(status.programStatusReplay == nil)
        #expect(status.normalizedProgramStatusReplay == false)
    }
    @Test func explicitReplayAndUnrelatedLegacyStatusRemainDistinct() throws {
        let replay = try JSONDecoder().decode(StatusWirePayload.self, from: Data(
            #"{"state":"program_status","program_status":[],"program_status_revision":2,"program_status_replay":true}"#.utf8))
        #expect(replay.normalizedProgramStatusReplay == true)
        let attached = try JSONDecoder().decode(StatusWirePayload.self, from: Data(#"{"state":"attached"}"#.utf8))
        #expect(attached.normalizedProgramStatusReplay == nil)
    }
    @Test func replayBeforeAttachIsNotErased() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let epoch = UUID()
        let done = try records(#"[{"state":"done","title":"retained"}]"#)
        let applied = snapshot.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: done, programStatusRevision: 7,
                programStatusReplay: true), deliveryEpoch: epoch)
        #expect(applied)
        _ = snapshot.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: epoch)
        #expect(snapshot.records == done)
        #expect(snapshot.revision == 7)
    }
    @Test func attachBeforeReplayAndDuplicateAttachPreserveSnapshot() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let epoch = UUID()
        _ = snapshot.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: epoch)
        let done = try records(#"[{"state":"done"}]"#)
        _ = snapshot.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: done, programStatusRevision: 2),
            deliveryEpoch: epoch)
        _ = snapshot.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: epoch)
        #expect(snapshot.records == done)
        #expect(snapshot.revision == 2)
    }
    @Test func newDeliveryAdmitsLowerRevisionAndExplicitEmptySnapshot() throws {
        var snapshot = RelayProgramStatusSnapshot()
        let done = try records(#"[{"state":"done"}]"#)
        _ = snapshot.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: done, programStatusRevision: 99),
            deliveryEpoch: UUID())
        let next = UUID()
        _ = snapshot.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: done, programStatusRevision: 1),
            deliveryEpoch: next)
        #expect(snapshot.revision == 1)
        _ = snapshot.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: next)
        #expect(snapshot.records == done)
        let cleared = snapshot.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: [], programStatusRevision: 2),
            deliveryEpoch: next)
        #expect(cleared)
        #expect(snapshot.records.isEmpty)
    }

}
