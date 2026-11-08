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
    // Genuinely idle: no routes before, none now, nothing queued.
    var quiet = RelayWorkCarrier.HostSchedule(routes: 0)
    #expect(RelayWorkCarrier.nextCheck(after: none, state: &quiet) == 600)
    #expect(RelayWorkCarrier.nextCheck(after: none, state: &quiet) == 600)
    var routed = RelayWorkCarrier.HostSchedule()
    #expect(RelayWorkCarrier.nextCheck(after: idle, state: &routed) == 30)
    #expect(RelayWorkCarrier.nextCheck(after: busy, state: &routed) == 5)
    let parsed = RelayWorkCarrier.outbox(hostKey: "k", reply: ["node_id": "n", "items": [], "native_routes": 2])
    #expect(parsed?.nativeRoutes == 2)
}

/// 2026-11-08: after an app restart the first check of dandy-07 failed, the
/// in-memory record was empty, and the next check came 600 s later, beyond
/// the 9-minute signed window. A failed check backs off 30, 60, 120, 240 s
/// and never jumps to 600 s, whatever the host reported before.
@Test func workCarrierRetriesAFailedCheckWithBackoffUnderTheSignedWindow() {
    for start in [RelayWorkCarrier.HostSchedule(), RelayWorkCarrier.HostSchedule(routes: 0), RelayWorkCarrier.HostSchedule(routes: 2)] {
        var state = start
        let delays = (0..<8).map { _ in RelayWorkCarrier.nextCheck(after: nil, state: &state) }
        #expect(delays == [30, 60, 120, 240, 240, 240, 240, 240], "from \(start)")
    }
    #expect(RelayWorkCarrier.failureBackoff.allSatisfy { $0 < 9 * 60 })
    // An answer ends the backoff.
    var state = RelayWorkCarrier.HostSchedule()
    _ = RelayWorkCarrier.nextCheck(after: nil, state: &state)
    _ = RelayWorkCarrier.nextCheck(after: nil, state: &state)
    let routed = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 1)
    #expect(RelayWorkCarrier.nextCheck(after: routed, state: &state) == 30)
    #expect(RelayWorkCarrier.nextCheck(after: nil, state: &state) == 30)
}

/// bc08: mid supervisor swap a host can answer with 0 routes right after
/// reporting some. That drop is treated like a failed check; only a host that
/// keeps reporting 0 settles back to the idle 600 s.
@Test func workCarrierTreatsARouteDropLikeAFailedCheck() {
    let routed = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 1)
    let none = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 0)
    var state = RelayWorkCarrier.HostSchedule()
    #expect(RelayWorkCarrier.nextCheck(after: routed, state: &state) == 30)
    let delays = (0..<6).map { _ in RelayWorkCarrier.nextCheck(after: none, state: &state) }
    #expect(delays == [30, 60, 120, 240, 600, 600])
    // Routes coming back resume the 30 s schedule.
    #expect(RelayWorkCarrier.nextCheck(after: routed, state: &state) == 30)
    // The first answer after launch has no earlier report, so 0 routes is not
    // yet known to be idle either.
    var fresh = RelayWorkCarrier.HostSchedule()
    #expect(RelayWorkCarrier.nextCheck(after: none, state: &fresh) == 30)
}

/// bc08 review of 0.5.30: after an outage long enough to exhaust the failure
/// backoff (relayd down for a supervisor swap), the first answer reporting 0
/// routes went straight to 600 s, past the 9 min signed window.
@Test func workCarrierRestartsTheBackoffWhenAHostAnswersAfterALongOutage() {
    let routed = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 1)
    let none = RelayWorkCarrier.Outbox(hostKey: "k", nodeID: "n", items: [], nativeRoutes: 0)
    var state = RelayWorkCarrier.HostSchedule()
    #expect(RelayWorkCarrier.nextCheck(after: routed, state: &state) == 30)
    let failures = (0..<5).map { _ in RelayWorkCarrier.nextCheck(after: nil, state: &state) }
    #expect(failures == [30, 60, 120, 240, 240])
    let zeros = (0..<5).map { _ in RelayWorkCarrier.nextCheck(after: none, state: &state) }
    #expect(zeros == [30, 60, 120, 240, 600])
    // The same after failures with no earlier answer at all.
    var unknown = RelayWorkCarrier.HostSchedule()
    _ = (0..<6).map { _ in RelayWorkCarrier.nextCheck(after: nil, state: &unknown) }
    #expect(RelayWorkCarrier.nextCheck(after: none, state: &unknown) == 30)
}

/// A pane that reattaches after the host has settled to the idle schedule may
/// mean its relayd restarted: the host is checked now and, if it answers 0
/// routes, on the short backoff again rather than every 600 s.
@MainActor
@Test func workCarrierReattachRestartsTheBackoffAfterItWasExhausted() async {
    let hosts = FakeWorkHosts()
    hosts.failFirstChecks = 0
    hosts.queued = false
    hosts.dandyRoutes = 0
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    let start = hosts.now
    await runCarrier(hosts, loop, for: 1100, untilCarried: false)
    let settled = (hosts.pendingChecks[hosts.dandy.connectionKey] ?? []).map { $0.timeIntervalSince(start) }
    #expect(settled == [0, 30, 90, 210, 450, 1050])
    RelayWorkCarrier.hostReady(hosts.dandy)
    let reattached = hosts.now
    await runCarrier(hosts, loop, for: 100, untilCarried: false)
    let after = (hosts.pendingChecks[hosts.dandy.connectionKey] ?? []).map { $0.timeIntervalSince(reattached) }.filter { $0 >= 0 }
    #expect(after == [0, 30, 90])
}

@MainActor
private final class FakeWorkHosts {
    let mac = ConnectionProfile(name: "mac", kind: .ssh, host: "mac-host")
    let dandy = ConnectionProfile(name: "dandy", kind: .ssh, host: "dandy-07")
    var now = Date(timeIntervalSince1970: 1_000_000)
    let queuedAt: Date
    var dandyChecks = 0
    var failFirstChecks = 1
    var dandyRoutes = 1
    var queued = true
    var carriedAt: Date?
    var tooLate = false
    var pendingChecks: [String: [Date]] = [:]

    init() { queuedAt = now }

    func request(_ profile: ConnectionProfile, _ packet: [String: Any]) async throws -> [String: Any] {
        let host = profile.connectionKey
        switch packet["operation"] as? String {
        case "work_native_pending":
            pendingChecks[host, default: []].append(now)
            if host == mac.connectionKey { return ["node_id": "node-mac", "items": [], "native_routes": 1] }
            dandyChecks += 1
            if dandyChecks <= failFirstChecks { throw CancellationError() }
            let items: [[String: Any]] = queued ? [["message_id": "d1", "peer_node_id": "node-mac"]] : []
            return ["node_id": "node-dandy", "items": items, "native_routes": dandyRoutes]
        case "work_native_claim":
            #expect(host == dandy.connectionKey)
            return ["work_envelope": "signed"]
        case "deliver_signed_work":
            #expect(host == mac.connectionKey)
            // remoteNativeSignedWindow: the receiving relayd refuses after 9 min.
            if now.timeIntervalSince(queuedAt) > 9 * 60 { tooLate = true; return ["work_reply": "too_late"] }
            carriedAt = now
            return ["work_reply": "delivered"]
        case "work_native_settle":
            queued = false
            return [:]
        default:
            Issue.record("unexpected packet \(packet)")
            return [:]
        }
    }
}

@MainActor
private func runCarrier(_ hosts: FakeWorkHosts, _ loop: RelayWorkCarrierLoop, for seconds: TimeInterval, untilCarried: Bool) async {
    let start = hosts.now
    while hosts.now.timeIntervalSince(start) < seconds, !(untilCarried && hosts.carriedAt != nil) {
        await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
        hosts.now = hosts.now.addingTimeInterval(5)
    }
}

@MainActor
@Test func workCarrierCarriesAQueuedMessageAfterAFailedFirstCheck() async {
    let hosts = FakeWorkHosts()
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    await runCarrier(hosts, loop, for: 900, untilCarried: true)
    #expect(hosts.carriedAt.map { $0.timeIntervalSince(hosts.queuedAt) } == 30)
    #expect(!hosts.tooLate)
}

@MainActor
@Test func workCarrierRecoversWithinTheWindowAfterSeveralFailedChecks() async {
    let hosts = FakeWorkHosts()
    hosts.failFirstChecks = 3
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    await runCarrier(hosts, loop, for: 900, untilCarried: true)
    // Checks at 0, 30 and 90 s fail; the one at 210 s carries.
    #expect(hosts.carriedAt.map { $0.timeIntervalSince(hosts.queuedAt) } == 210)
    #expect(!hosts.tooLate)
}

@MainActor
@Test func workCarrierKeepsTheIdleScheduleForAHostWithNoRoutes() async {
    let hosts = FakeWorkHosts()
    hosts.failFirstChecks = 0
    hosts.queued = false
    hosts.dandyRoutes = 0
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    let start = hosts.now
    await runCarrier(hosts, loop, for: 3600, untilCarried: false)
    let offsets = (hosts.pendingChecks[hosts.dandy.connectionKey] ?? []).map { $0.timeIntervalSince(start) }
    // Four settling checks after launch, then every 600 s.
    #expect(offsets == [0, 30, 90, 210, 450, 1050, 1650, 2250, 2850, 3450])
}

@MainActor
@Test func workCarrierChecksAHostAgainWhenItsPaneReconnects() async {
    let hosts = FakeWorkHosts()
    hosts.failFirstChecks = 0
    hosts.queued = false
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 1)
    hosts.now = hosts.now.addingTimeInterval(5)
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 1)
    // An attached or caught_up pane on dandy makes its host due now.
    hosts.queued = true
    RelayWorkCarrier.hostReady(hosts.dandy)
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 2)
    #expect(hosts.carriedAt == hosts.now)
    // Another host's reconnect does not.
    RelayWorkCarrier.hostReady(ConnectionProfile(name: "other", kind: .ssh, host: "other-host"))
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 2)
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
