import Foundation
import Testing
@testable import Relay

@Test func workCarrierPairsEachPendingItemWithThePeerHostInBothDirections() {
    let mac = RelayWorkCarrier.Outbox(hostKey: "local", nodeID: "node-mac", items: [.init(messageID: "m1", peerNodeID: "node-dandy")])
    let dandy = RelayWorkCarrier.Outbox(hostKey: "ssh:dandy", nodeID: "node-dandy", items: [.init(messageID: "d1", peerNodeID: "node-mac")])
    #expect(RelayWorkCarrier.plan([mac, dandy]) == [
        .init(fromHost: "local", toHost: "ssh:dandy", messageID: "m1"),
        .init(fromHost: "ssh:dandy", toHost: "local", messageID: "d1"),
    ])
}

@Test func workCarrierWaitsWhenThePeerIsMissingSelfOrAmbiguous() {
    let mac = RelayWorkCarrier.Outbox(hostKey: "local", nodeID: "node-mac", items: [
        .init(messageID: "absent", peerNodeID: "node-other"),
        .init(messageID: "self", peerNodeID: "node-mac"),
        .init(messageID: "twice", peerNodeID: "node-dandy"),
    ])
    let dandyA = RelayWorkCarrier.Outbox(hostKey: "ssh:a", nodeID: "node-dandy", items: [])
    let dandyB = RelayWorkCarrier.Outbox(hostKey: "ssh:b", nodeID: "node-dandy", items: [])
    #expect(RelayWorkCarrier.plan([mac, dandyA, dandyB]).isEmpty)
    // A host reporting the same node under two keys is the same ambiguity.
    let echo = RelayWorkCarrier.Outbox(hostKey: "ssh:a", nodeID: "node-mac", items: [])
    #expect(RelayWorkCarrier.plan([mac, echo]).isEmpty)
}

@Test func workCarrierParsesOnlyCompleteOutboxReplies() {
    #expect(RelayWorkCarrier.outbox(hostKey: "k", reply: nil) == nil)
    #expect(RelayWorkCarrier.outbox(hostKey: "k", reply: ["items": []]) == nil)
    let box = RelayWorkCarrier.outbox(hostKey: "k", reply: ["node_id": "n", "items": [
        ["message_id": "m", "peer_node_id": "p"], ["message_id": "", "peer_node_id": "p"], ["message_id": "x"],
    ]])
    #expect(box == .init(hostKey: "k", nodeID: "n", items: [.init(messageID: "m", peerNodeID: "p")]))
}

@Test func workCarrierPacketsCarryOnlyIdentifiersAndSignedEnvelopes() {
    #expect(RelayWorkCarrier.pendingPacket as NSDictionary == ["operation": "work_native_pending"] as NSDictionary)
    #expect(RelayWorkCarrier.claimPacket(messageID: "m") as NSDictionary == ["operation": "work_native_claim", "message_id": "m"] as NSDictionary)
    #expect(RelayWorkCarrier.deliverPacket(envelope: "e") as NSDictionary == ["operation": "deliver_signed_work", "work_envelope": "e"] as NSDictionary)
    #expect(RelayWorkCarrier.settlePacket(messageID: "m", reply: "r") as NSDictionary == ["operation": "work_native_settle", "message_id": "m", "work_reply": "r"] as NSDictionary)
    #expect(RelayWorkCarrier.tick == .seconds(5))
}

@Test func workCarrierCostsNothingUntilARouteUsesTheHostChannel() {
    let none = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 0)
    let idle = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 1)
    let busy = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [.init(messageID: "m", peerNodeID: "p")], nativeRoutes: 1)
    #expect(RelayWorkCarrier.nextCheck(after: none) == 600)
    #expect(RelayWorkCarrier.nextCheck(after: idle) == 30)
    #expect(RelayWorkCarrier.nextCheck(after: busy) == 5)
    #expect(RelayWorkCarrier.nextCheck(after: nil) == 600)
    #expect(RelayWorkCarrier.nextCheck(after: nil, previous: idle) == 30)
    #expect(RelayWorkCarrier.nextCheck(after: nil, previous: none) == 600)
    let parsed = RelayWorkCarrier.outbox(hostKey: "k", reply: ["node_id": "n", "items": [], "native_routes": 2])
    #expect(parsed?.nativeRoutes == 2)
}

@Test func workCarrierRequestsGoOnlyToTheWorkOwningRelayd() {
    #expect(RelayWorkCarrier.carries(["operation": "work_native_pending"]))
    #expect(RelayWorkCarrier.carries(["operation": "deliver_signed_work"]))
    #expect(!RelayWorkCarrier.carries(["operation": "deliver_signed"]))
    #expect(!RelayWorkCarrier.carries(["operation": "question_notices"]))
    #expect(!RelayWorkCarrier.carries([:]))
    let remote = ConnectionProfile(name: "dandy", kind: .ssh, host: "dandy-07")
    let command = RelayHostExecution.workCarrierCommand(profile: remote, verb: "communication")
    #expect(command.contains("relayd-work-communication\" communication"))
    #expect(command.contains("exit 1"))
    #expect(!command.contains("relayd-communication\""))
}

/// A stale home-directory helper on this Mac (relayd 0.5.6) refused
/// caller_admin_info, so every attach, caller policy import and Miko
/// supervisor proof failed with "Invalid host request".
@Test func localCommunicationUsesTheBundledRelaydNotAHomeHelper() {
    let local = ConnectionProfile(name: "This Mac", kind: .local)
    for packet: [String: Any] in [["operation": "caller_admin_info"], ["operation": "attest_consume"],
                                  ["operation": "caller_policy_import"], ["shepherd_report": true]] {
        let command = RelayHostExecution.communicationCommand(profile: local, packet: packet)
        #expect(!command.contains("relayd-communication"), "local must not use the home helper: \(packet)")
        #expect(command.hasPrefix("'") && command.contains("/Contents/MacOS/relayd' "), "bundled relayd: \(command)")
    }
    #expect(RelayHostExecution.communicationCommand(profile: local, packet: ["operation": "x"]).hasSuffix(" 'communication'"))
    #expect(RelayHostExecution.communicationCommand(profile: local, packet: ["shepherd_report": true]).hasSuffix(" 'communication-shepherd'"))
    let remote = ConnectionProfile(name: "dandy", kind: .ssh, host: "dandy-07")
    let command = RelayHostExecution.communicationCommand(profile: remote, packet: ["operation": "caller_admin_info"])
    #expect(command.contains("relayd-communication\" communication; else \"$HOME/.local/bin/relayd\" 'communication'; fi"))
    #expect(RelayHostExecution.communicationCommand(profile: local, packet: ["operation": "work_native_pending"])
        == RelayHostExecution.workCarrierCommand(profile: local, verb: "communication"))
}

@Test func workCarrierReadsTheLargestSignedFileEnvelope() {
    #expect(RelayHostExecution.captureLimit(RelayWorkCarrier.claimPacket(messageID: "m")) == 256 << 10)
    #expect(RelayHostExecution.captureLimit(RelayWorkCarrier.pendingPacket) == 256 << 10)
    #expect(RelayHostExecution.captureLimit(["operation": "deliver_signed"]) == 128 << 10)
    #expect(RelayHostExecution.captureLimit([:]) == 128 << 10)
}
