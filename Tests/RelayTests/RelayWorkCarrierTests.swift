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

@Test func workCarrierRecognisesOnlyACompletedWorkSend() {
    #expect(RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: "mcp__relay-work__relay_work_message"))
    #expect(RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: "mcp__relay-work__relay_work_send_file"))
    #expect(RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: "relay_work_message"))
    #expect(!RelayWorkCarrier.queuedWork(eventName: "PreToolUse", toolName: "mcp__relay-work__relay_work_message"))
    #expect(!RelayWorkCarrier.queuedWork(eventName: "PostToolUseFailure", toolName: "mcp__relay-work__relay_work_message"))
    #expect(!RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: "mcp__relay-work__relay_work_receipt"))
    #expect(!RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: "mcp__relay__relay_message_pane"))
    #expect(!RelayWorkCarrier.queuedWork(eventName: "PostToolUse", toolName: nil))
}

/// 46cea338: queued on dandy-07 at 09:55:08, carried at 09:55:17 because the
/// host was only checked on its schedule. A send from a pane on that host now
/// makes it due at once, without restarting what was learned about it.
@MainActor
@Test func workCarrierChecksTheSendingHostAsSoonAsAWorkMessageIsQueued() async {
    let hosts = FakeWorkHosts()
    hosts.failFirstChecks = 0
    hosts.queued = false
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { [hosts] profile, packet in try await hosts.request(profile, packet) })
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    hosts.now = hosts.now.addingTimeInterval(5)
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 1, "an idle route-bearing host waits 30 s")
    hosts.queued = true
    RelayWorkCarrier.workQueued(hosts.dandy)
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 2)
    #expect(hosts.carriedAt == hosts.now)
    // The carried item's own recheck 5 s later finds nothing queued.
    hosts.now = hosts.now.addingTimeInterval(5)
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 3)
    // Another host's send does not make dandy due.
    hosts.now = hosts.now.addingTimeInterval(5)
    RelayWorkCarrier.workQueued(ConnectionProfile(name: "other", kind: .ssh, host: "other-host"))
    await loop.tick(profiles: [hosts.mac, hosts.dandy], now: hosts.now)
    #expect(hosts.pendingChecks[hosts.dandy.connectionKey]?.count == 3)
}

/// The loop's sleep between passes ends as soon as a send is reported, and a
/// report that lands during a pass is not lost.
@MainActor
@Test func workCarrierPauseEndsWhenWoken() async {
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { _, _ in [:] })
    let clock = ContinuousClock()
    var started = clock.now
    async let paused: Void = loop.pause(.seconds(60))
    for _ in 0..<20 { await Task.yield() }
    loop.wake()
    await paused
    #expect(clock.now - started < .seconds(5))
    loop.wake()
    started = clock.now
    await loop.pause(.seconds(60))
    #expect(clock.now - started < .seconds(5))
    started = clock.now
    await loop.pause(.milliseconds(50))
    #expect(clock.now - started >= .milliseconds(50))
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

/// The pane's own PostToolUse hook for a Work send nudges the carrier for that
/// pane's host; a replayed or unrelated event does not.
@MainActor
@Test func paneWorkSendHookNudgesTheCarrierForItsHost() {
    let profile = ConnectionProfile(name: "dandy", kind: .ssh, host: "dandy-07")
    let pane = PaneModel(profile: profile)
    var nudged: [String] = []
    let observer = NotificationCenter.default.addObserver(forName: RelayWorkCarrier.workQueuedNotification, object: nil, queue: nil) { note in
        if let key = note.userInfo?["key"] as? String { nudged.append(key) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    func send(_ json: String) { pane.receivedAgentEvent(Data(json.utf8)) }
    send(#"{"agent":"claude","relay_event_seq":5,"event":{"hook_event_name":"PostToolUse","tool_name":"mcp__relay-work__relay_work_message","event_id":"w-1"}}"#)
    #expect(nudged == [profile.connectionKey])
    send(#"{"agent":"claude","relay_event_seq":6,"event":{"hook_event_name":"PostToolUse","tool_name":"Bash","event_id":"w-2"}}"#)
    send(#"{"agent":"claude","relay_event_seq":7,"event":{"hook_event_name":"PreToolUse","tool_name":"mcp__relay-work__relay_work_send_file","event_id":"w-3"}}"#)
    // An event at or before the cursor is a replay, not a new send.
    send(#"{"agent":"claude","relay_event_seq":4,"event":{"hook_event_name":"PostToolUse","tool_name":"mcp__relay-work__relay_work_send_file","event_id":"w-4"}}"#)
    #expect(nudged == [profile.connectionKey])
}

/// eede66c6: the Mac's relayd refused every delivery after the Codex app
/// restarted, and the carrier dropped the refusal. It now tells the sending
/// relayd why, never settles, and still drops an unreachable peer quietly.
@MainActor
@Test func workCarrierReportsAPeerRefusalToTheSenderWithoutSettling() async {
    let mac = ConnectionProfile(name: "mac", kind: .ssh, host: "mac-host")
    let dandy = ConnectionProfile(name: "dandy", kind: .ssh, host: "dandy-07")
    var deliverError: Error? = RemoteCatalogError.failed("relayd: Work target changed\n(incarnation 71513)\n")
    var sent: [(String, [String: Any])] = []
    let loop = RelayWorkCarrierLoop(workspace: nil, request: { profile, packet in
        let operation = packet["operation"] as? String ?? ""
        sent.append((profile.connectionKey, packet))
        switch operation {
        case "work_native_pending":
            if profile.connectionKey == mac.connectionKey { return ["node_id": "node-mac", "items": [], "native_routes": 1] }
            return ["node_id": "node-dandy", "items": [["message_id": "e1", "peer_node_id": "node-mac"]], "native_routes": 1]
        case "work_native_claim": return ["work_envelope": "signed"]
        case "deliver_signed_work":
            if let deliverError { throw deliverError }
            return [:]
        default: return [:]
        }
    })
    var now = Date(timeIntervalSince1970: 2_000_000)
    await loop.tick(profiles: [mac, dandy], now: now)
    let refusals = sent.filter { $0.1["operation"] as? String == "work_native_refused" }
    #expect(refusals.count == 1)
    #expect(refusals.first?.0 == dandy.connectionKey)
    #expect(refusals.first?.1["message_id"] as? String == "e1")
    #expect(refusals.first?.1["carrier_error"] as? String == "relayd: Work target changed (incarnation 71513)")
    #expect(!sent.contains { $0.1["operation"] as? String == "work_native_settle" })

    // An unreachable peer is not a refusal: nothing is reported or settled.
    sent.removeAll()
    deliverError = RemoteCatalogError.networkUnavailable
    now = now.addingTimeInterval(5)
    await loop.tick(profiles: [mac, dandy], now: now)
    #expect(sent.contains { $0.1["operation"] as? String == "deliver_signed_work" })
    #expect(!sent.contains { ["work_native_refused", "work_native_settle"].contains($0.1["operation"] as? String ?? "") })

    // A peer answer without a signed reply is reported, and still not settled.
    sent.removeAll()
    deliverError = nil
    now = now.addingTimeInterval(5)
    await loop.tick(profiles: [mac, dandy], now: now)
    #expect(sent.filter { $0.1["operation"] as? String == "work_native_refused" }.map { $0.1["carrier_error"] as? String }
            == ["the peer's relayd answered without a signed reply"])
    #expect(!sent.contains { $0.1["operation"] as? String == "work_native_settle" })
}
