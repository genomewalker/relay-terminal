import AppKit
import Testing
@testable import Relay

private let shownRequest = DesktopLinkRequest(id: String(repeating: "a", count: 64), sessionID: "5a30d83a-5222-48f3-93c7-42fa687d901b",
    accountRoot: "/Users/owner/.claude-max", paneID: "1652a003-70e9-4614-addb-68564fa8383b",
    createdAt: "2026-11-07T10:00:00Z", expiresAt: "2026-11-07T10:10:00Z",
    proposedCallers: ["f8b71215-6a42-4f00-808e-35f3f555b7eb"])

/// Records every daemon operation; `pendingReplies` answers the listing in order.
@MainActor private final class FakeDaemon {
    var operations: [(String, [String: Any])] = []
    var listings: [[DesktopLinkRequest]]
    /// Operations that fail, as the owner gate or a pin refusal would.
    var failing: Set<String> = []
    /// Replies for operations other than the listing.
    var replies: [String: [String: Any]] = [:]

    init(listings: [[DesktopLinkRequest]]) { self.listings = listings }

    func request(_ operation: String, _ packet: [String: Any]) async throws -> [String: Any] {
        operations.append((operation, packet))
        if failing.contains(operation) {
            throw NSError(domain: "FakeDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "refused: \(operation)"])
        }
        if operation == "route_desktop_link_list" {
            let next = listings.isEmpty ? [] : listings.removeFirst()
            let data = try JSONEncoder().encode(next)
            return ["requests": try JSONSerialization.jsonObject(with: data)]
        }
        return replies[operation] ?? ["status": "ok"]
    }

    func names() -> [String] { operations.map(\.0) }
}

@Test @MainActor func approvalSendsTheExactPairTheOwnerSaw() async throws {
    let daemon = FakeDaemon(listings: [[shownRequest], [shownRequest]])
    let approval = DesktopLinkApproval(requester: daemon.request) { alert, callback in
        #expect(alert.buttons.map(\.title) == ["Reject", "Approve"])
        callback(.alertSecondButtonReturn)
        return true
    }
    let current = try await approval.pending()
    #expect(try await approval.decide(shownRequest, current: current) == .approved)
    let approve = daemon.operations.last!
    #expect(approve.0 == "route_desktop_link_approve")
    #expect(approve.1["request_id"] as? String == shownRequest.id)
    #expect(approve.1["source_pane_id"] as? String == shownRequest.sessionID)
    #expect(approve.1["pane_id"] as? String == shownRequest.paneID)
    #expect(approve.1["allowed_callers"] as? [String] == shownRequest.proposedCallers)
}

@Test @MainActor func approvalRefusesARequestThatChangedBeforeTheClick() async throws {
    var changed = shownRequest
    changed = DesktopLinkRequest(id: shownRequest.id, sessionID: shownRequest.sessionID, accountRoot: shownRequest.accountRoot,
        paneID: "99999999-9999-4999-8999-999999999999", createdAt: shownRequest.createdAt, expiresAt: shownRequest.expiresAt)
    // The listing after the click shows another pane under the same request ID.
    let daemon = FakeDaemon(listings: [[changed]])
    let approval = DesktopLinkApproval(requester: daemon.request) { _, callback in
        callback(.alertSecondButtonReturn)
        return true
    }
    #expect(try await approval.decide(shownRequest, current: [shownRequest]) == .changed)
    #expect(!daemon.names().contains("route_desktop_link_approve"))
}

@Test @MainActor func approvalNeverRunsForARequestNoLongerListed() async throws {
    let daemon = FakeDaemon(listings: [])
    var showed = 0
    let approval = DesktopLinkApproval(requester: daemon.request) { _, _ in showed += 1; return true }
    #expect(try await approval.decide(shownRequest, current: []) == .changed)
    #expect(showed == 0)
    #expect(daemon.operations.isEmpty)
}

@Test @MainActor func rejectAndCancelNeverApprove() async throws {
    let daemon = FakeDaemon(listings: [])
    let reject = DesktopLinkApproval(requester: daemon.request) { _, callback in callback(.alertFirstButtonReturn); return true }
    #expect(try await reject.decide(shownRequest, current: [shownRequest]) == .rejected)
    #expect(daemon.names() == ["route_desktop_link_reject"])
    let cancel = DesktopLinkApproval(requester: daemon.request) { _, callback in callback(.abort); return true }
    #expect(try await cancel.decide(shownRequest, current: [shownRequest]) == .cancelled)
    #expect(!daemon.names().contains("route_desktop_link_approve"))
    let unavailable = DesktopLinkApproval(requester: daemon.request) { _, _ in false }
    #expect(try await unavailable.decide(shownRequest, current: [shownRequest]) == .unavailable)
    #expect(!daemon.names().contains("route_desktop_link_approve"))
}

@Test @MainActor func unapprovableRequestsAreNeverOffered() async throws {
    let daemon = FakeDaemon(listings: [])
    let refused = DesktopLinkRequest(id: shownRequest.id, sessionID: shownRequest.sessionID, accountRoot: shownRequest.accountRoot,
        paneID: shownRequest.paneID, createdAt: shownRequest.createdAt, expiresAt: shownRequest.expiresAt,
        proposedCallers: [], refusal: "pair the pane once from its host first")
    var showed = 0
    let approval = DesktopLinkApproval(requester: daemon.request) { _, _ in showed += 1; return true }
    #expect(try await approval.decide(refused, current: [refused]) == .unavailable)
    #expect(showed == 0)
    #expect(daemon.operations.isEmpty)
}

@Test func watchAsksOnceAboutEachLiveRequest() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T10:05:00Z")!
    let live = shownRequest
    let expired = DesktopLinkRequest(id: String(repeating: "b", count: 64), sessionID: shownRequest.sessionID,
        accountRoot: shownRequest.accountRoot, paneID: shownRequest.paneID, createdAt: "2026-11-07T09:00:00Z",
        expiresAt: "2026-11-07T09:10:00Z", proposedCallers: ["receiver"])
    #expect(DesktopLinkWatch.due([live, expired], asked: [], now: now) == [live])
    #expect(DesktopLinkWatch.due([live], asked: [DesktopLinkWatch.askKey(live)], now: now).isEmpty)
    #expect(DesktopLinkRequest.parse("2026-11-07T10:10:00.123456Z") != nil)
}

// A new pair has no reviewed pane link. Its listing proposes the two directional
// callers, and Approve sends exactly them: the decision path is not a dead end.
@Test @MainActor func newPairWithoutPaneLinkIsApprovedWithItsDirectionalCallers() async throws {
    let json = """
    {"id":"\(String(repeating: "c", count: 64))","session_id":"5a30d83a-5222-48f3-93c7-42fa687d901b",\
    "account_root":"/Users/owner/.claude-max","pane_id":"1652a003-70e9-4614-addb-68564fa8383b",\
    "created_at":"2026-11-07T10:00:00Z","expires_at":"2026-11-07T10:10:00Z",\
    "proposed_callers":["desktop-5a30d83a-5222-48f3-93c7-42fa687d901b","pane-1652a003-70e9-4614-addb-68564fa8383b"]}
    """
    let request = try JSONDecoder().decode(DesktopLinkRequest.self, from: Data(json.utf8))
    #expect(request.refusal == nil)
    #expect(request.proposedCallers.count == 2)
    let daemon = FakeDaemon(listings: [[request], [request]])
    let approval = DesktopLinkApproval(requester: daemon.request) { alert, callback in
        #expect(alert.informativeText.contains("pane-1652a003-70e9-4614-addb-68564fa8383b"))
        callback(.alertSecondButtonReturn)
        return true
    }
    #expect(try await approval.decide(request, current: [request]) == .approved)
    let approve = daemon.operations.last!
    #expect(approve.0 == "route_desktop_link_approve")
    #expect(approve.1["allowed_callers"] as? [String] == request.proposedCallers)
}

private func listed(id: String = shownRequest.id, createdAt: String = shownRequest.createdAt, refusal: String? = nil,
                    callers: [String] = ["receiver"]) -> DesktopLinkRequest {
    DesktopLinkRequest(id: id, sessionID: shownRequest.sessionID, accountRoot: shownRequest.accountRoot, paneID: shownRequest.paneID,
        createdAt: createdAt, expiresAt: shownRequest.expiresAt, proposedCallers: callers, refusal: refusal)
}

// A request with a refusal is never offered, even when it is live.
@Test func watchDoesNotOfferARefusedRequest() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T10:05:00Z")!
    #expect(DesktopLinkWatch.due([listed(refusal: "no active route to the requested host")], asked: [], now: now).isEmpty)
    #expect(DesktopLinkWatch.due([listed(callers: [])], asked: [], now: now).isEmpty)
    #expect(DesktopLinkWatch.due([listed()], asked: [], now: now).count == 1)
}

// The same pair requested again is a new request, and is offered again.
@Test func watchOffersAReRequestedPairAgain() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T10:05:00Z")!
    let first = listed()
    let asked = DesktopLinkWatch.answered(.rejected, shown: first, asked: [])
    #expect(DesktopLinkWatch.due([first], asked: asked, now: now).isEmpty)
    let again = listed(createdAt: "2026-11-07T10:04:00Z")
    #expect(DesktopLinkWatch.due([again], asked: asked, now: now) == [again])
}

// A sheet that could not be shown, or a listing that changed, is not an answer:
// the request is offered again on a later pass. A real answer is recorded once.
@Test func watchRecordsOnlyAnswersTheOwnerGave() throws {
    let shown = listed()
    #expect(DesktopLinkWatch.answered(.unavailable, shown: shown, asked: []).isEmpty)
    #expect(DesktopLinkWatch.answered(.changed, shown: shown, asked: []).isEmpty)
    #expect(DesktopLinkWatch.answered(nil, shown: shown, asked: []).isEmpty)
    #expect(DesktopLinkWatch.answered(.approved, shown: shown, asked: []) == [DesktopLinkWatch.askKey(shown)])
    #expect(DesktopLinkWatch.answered(.cancelled, shown: shown, asked: []) == [DesktopLinkWatch.askKey(shown)])
}

// The owner answered, then the daemon refused to carry the answer out. The answer
// still counts: the request is not offered again, and the failure is returned to
// be shown once. Before this, try? dropped the answer and the same sheet came
// back every pass while the request was live.
@Test @MainActor func watchKeepsTheOwnersAnswerWhenTheDaemonCallFails() async throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T10:05:00Z")!
    for (button, failing, expected) in [
        (NSApplication.ModalResponse.alertFirstButtonReturn, "route_desktop_link_reject", DesktopLinkDecision.rejected),
        (.alertSecondButtonReturn, "route_desktop_link_approve", .approved),
        (.alertSecondButtonReturn, "route_desktop_link_list", .approved),
    ] {
        let daemon = FakeDaemon(listings: [[shownRequest], [shownRequest]])
        daemon.failing = [failing]
        var showed = 0
        let approval = DesktopLinkApproval(requester: daemon.request) { _, callback in showed += 1; callback(button); return true }
        let (decision, failure) = await DesktopLinkWatch.outcome { try await approval.decide(shownRequest, current: [shownRequest]) }
        #expect(decision == expected)
        #expect(failure?.decision == expected)
        #expect(failure?.underlying.localizedDescription == "refused: \(failing)")
        let asked = DesktopLinkWatch.answered(decision, shown: shownRequest, asked: [])
        #expect(DesktopLinkWatch.due([shownRequest], asked: asked, now: now).isEmpty)
        #expect(showed == 1)
    }
}

// A failure before the owner answered is not an answer: nothing is recorded or
// reported, and the request is offered again on a later pass.
@Test @MainActor func watchOffersAgainWhenNothingWasAnswered() async throws {
    let (decision, failure) = await DesktopLinkWatch.outcome { throw NSError(domain: "listing", code: 2) }
    #expect(decision == nil)
    #expect(failure == nil)
    #expect(DesktopLinkWatch.answered(decision, shown: shownRequest, asked: []).isEmpty)
}

@MainActor private var hostChannelDispatch: [String: Any] { ["status": "dispatch", "carrier": "relay_host_channel", "peer_node_id": "node-b",
    "message_id": String(repeating: "c", count: 32), "establish_envelope": "signed-proposal"] }

@MainActor private func hostChannelApproval(mac: FakeDaemon, peer: FakeDaemon?, asked: @escaping (String) -> Void) -> DesktopLinkApproval {
    DesktopLinkApproval(requester: mac.request, present: { _, callback in callback(.alertSecondButtonReturn); return true }, peer: { node in
        asked(node)
        return peer.map { $0.request }
    })
}

// A route carried by the Relay host channel: the signed proposal goes to the
// peer host's relayd and its signed reply back to this host's relayd.
@Test @MainActor func hostChannelApprovalCarriesTheSignedExchange() async throws {
    let mac = FakeDaemon(listings: [[shownRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch, "route_desktop_link_settle": ["status": "established"]]
    let peer = FakeDaemon(listings: [])
    peer.replies = ["deliver_signed_desktop_establish": ["status": "delivered_reply", "establish_reply": "signed-reply"]]
    var resolved: [String] = []
    let approval = hostChannelApproval(mac: mac, peer: peer) { resolved.append($0) }
    #expect(try await approval.decide(shownRequest, current: [shownRequest]) == .approved)
    #expect(resolved == ["node-b"])
    #expect(mac.names() == ["route_desktop_link_list", "route_desktop_link_approve", "route_desktop_link_settle"])
    #expect(peer.names() == ["deliver_signed_desktop_establish"])
    #expect(peer.operations[0].1["establish_envelope"] as? String == "signed-proposal")
    let settle = mac.operations[2].1
    #expect(settle["message_id"] as? String == String(repeating: "c", count: 32))
    #expect(settle["establish_reply"] as? String == "signed-reply")
}

// No connected host reports the peer node: nothing is sent, and the failure
// keeps the owner's answer so it is reported once and not asked again.
@Test @MainActor func hostChannelApprovalWithoutAConnectedPeerHostIsAnAnsweredFailure() async throws {
    let mac = FakeDaemon(listings: [[shownRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch]
    let approval = hostChannelApproval(mac: mac, peer: nil) { _ in }
    let (decision, failure) = await DesktopLinkWatch.outcome { try await approval.decide(shownRequest, current: [shownRequest]) }
    #expect(decision == .approved)
    #expect(failure?.underlying as? DesktopLinkCarrierError == .noConnectedHost("node-b"))
    #expect(failure?.underlying.localizedDescription.contains("node-b") == true)
    #expect(!mac.names().contains("route_desktop_link_settle"))
    #expect(DesktopLinkWatch.answered(decision, shown: shownRequest, asked: []) == [DesktopLinkWatch.askKey(shownRequest)])
}

// The peer refuses the proposal: nothing is settled and the answer is kept.
@Test @MainActor func hostChannelApprovalPeerRefusalIsAnAnsweredFailure() async throws {
    let mac = FakeDaemon(listings: [[shownRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch]
    let peer = FakeDaemon(listings: [])
    peer.failing = ["deliver_signed_desktop_establish"]
    let approval = hostChannelApproval(mac: mac, peer: peer) { _ in }
    let (decision, failure) = await DesktopLinkWatch.outcome { try await approval.decide(shownRequest, current: [shownRequest]) }
    #expect(decision == .approved)
    #expect(failure != nil)
    #expect(!mac.names().contains("route_desktop_link_settle"))
}

// An HTTPS route establishes inside approve: no peer lookup and no settle.
@Test @MainActor func httpsApprovalNeedsNoCarrier() async throws {
    let mac = FakeDaemon(listings: [[shownRequest]])
    mac.replies = ["route_desktop_link_approve": ["status": "established"]]
    var resolved = 0
    let approval = hostChannelApproval(mac: mac, peer: nil) { _ in resolved += 1 }
    #expect(try await approval.decide(shownRequest, current: [shownRequest]) == .approved)
    #expect(resolved == 0)
    #expect(mac.names() == ["route_desktop_link_list", "route_desktop_link_approve"])
}

/// A peer relayd that predates the operation and refuses it as an older relayd does.
@MainActor private final class OlderPeer {
    var operations: [String] = []
    func request(_ operation: String, _ packet: [String: Any]) async throws -> [String: Any] {
        operations.append(operation)
        // The exact stderr a pre-0.5.22 relayd prints for this operation.
        throw RemoteCatalogError.failed("relayd: unknown daemon communication operation\n")
    }
}

// An older peer relayd fails closed at once with a named error; nothing is settled.
@Test @MainActor func hostChannelApprovalOlderPeerNamesTheUpdate() async throws {
    let mac = FakeDaemon(listings: [[shownRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch]
    let older = OlderPeer()
    let approval = DesktopLinkApproval(requester: mac.request, present: { _, callback in callback(.alertSecondButtonReturn); return true },
        peer: { _ in older.request })
    let (decision, failure) = await DesktopLinkWatch.outcome { try await approval.decide(shownRequest, current: [shownRequest]) }
    #expect(decision == .approved)
    #expect(failure?.underlying as? DesktopLinkCarrierError == .peerUnsupported("node-b"))
    #expect(failure?.underlying.localizedDescription.contains("does not support native desktop link approval; update it") == true)
    #expect(older.operations == ["deliver_signed_desktop_establish"])
    #expect(!mac.names().contains("route_desktop_link_settle"))
}

/// The same request as listed for a route carried by the Relay host channel.
private let nativeRequest = DesktopLinkRequest(id: shownRequest.id, sessionID: shownRequest.sessionID, accountRoot: shownRequest.accountRoot,
    paneID: shownRequest.paneID, createdAt: shownRequest.createdAt, expiresAt: shownRequest.expiresAt,
    proposedCallers: shownRequest.proposedCallers, peerNodeID: "node-b", carrier: "relay_host_channel")

// F1: the peer host is resolved before anything is spent. With no connected
// host for the node, approve is never called and the answer is kept.
@Test @MainActor func hostChannelApprovalResolvesThePeerBeforeSpendingTheApproval() async throws {
    let mac = FakeDaemon(listings: [[nativeRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch]
    let approval = hostChannelApproval(mac: mac, peer: nil) { _ in }
    let (decision, failure) = await DesktopLinkWatch.outcome { try await approval.decide(nativeRequest, current: [nativeRequest]) }
    #expect(decision == .approved)
    #expect(failure?.underlying as? DesktopLinkCarrierError == .noConnectedHost("node-b"))
    #expect(mac.names() == ["route_desktop_link_list"])
}

// The peer is resolved before approve, then the exchange is carried.
@Test @MainActor func hostChannelApprovalResolvesThenApprovesThenCarries() async throws {
    let mac = FakeDaemon(listings: [[nativeRequest]])
    mac.replies = ["route_desktop_link_approve": hostChannelDispatch, "route_desktop_link_settle": ["status": "established"]]
    let peer = FakeDaemon(listings: [])
    peer.replies = ["deliver_signed_desktop_establish": ["status": "delivered_reply", "establish_reply": "signed-reply"]]
    var callsAtResolution: [String] = []
    let approval = hostChannelApproval(mac: mac, peer: peer) { _ in callsAtResolution = mac.names() }
    #expect(try await approval.decide(nativeRequest, current: [nativeRequest]) == .approved)
    #expect(callsAtResolution == ["route_desktop_link_list"])
    #expect(mac.names() == ["route_desktop_link_list", "route_desktop_link_approve", "route_desktop_link_settle"])
    #expect(peer.names() == ["deliver_signed_desktop_establish"])
}

@Test func olderListingWithoutPeerNodeStillDecodes() throws {
    let json = #"[{"id":"\#(String(repeating: "a", count: 64))","session_id":"s","account_root":"/r","pane_id":"p","created_at":"2026-11-07T10:00:00Z","expires_at":"2026-11-07T10:10:00Z","proposed_callers":["c"]}]"#
    let decoded = try JSONDecoder().decode([DesktopLinkRequest].self, from: Data(json.utf8))
    #expect(decoded.count == 1)
    #expect(decoded[0].peerNodeID == nil && decoded[0].carrier == nil && decoded[0].hostChannelPeer == nil)
    let current = #"[{"id":"x","session_id":"s","account_root":"/r","pane_id":"p","created_at":"t","expires_at":"t","peer_node_id":"node-b","carrier":"relay_host_channel"}]"#
    #expect(try JSONDecoder().decode([DesktopLinkRequest].self, from: Data(current.utf8))[0].hostChannelPeer == "node-b")
}

private let lookupPEM = "-----BEGIN CERTIFICATE-----\n" + Data("relay-fixture-certificate".utf8).base64EncodedString() + "\n-----END CERTIFICATE-----"

private func lookupPin(_ host: ConnectionProfile, _ node: String) -> RelayNodeTrust.Pin {
    RelayNodeTrust.Pin(hostID: host.id, nodeID: node, certificatePEM: lookupPEM,
                       certificateSHA256: RelayNodeTrust.certificateFingerprint(lookupPEM)!, pinnedAt: Date())
}

@Test @MainActor func peerLookupPrefersSavedPinsWithoutContactingHosts() async throws {
    let a = ConnectionProfile(host: "a.invalid"), b = ConnectionProfile(host: "b.invalid")
    var asked = 0
    let lookup = DesktopLinkPeerLookup(hosts: [a, b], pins: [a.id: lookupPin(a, "node-a"), b.id: lookupPin(b, "node-b")], mismatches: [:],
        identify: { host in asked += 1; return lookupPin(host, "node-b") })
    #expect(try await lookup.resolve("node-b")?.id == b.id)
    #expect(asked == 0)
}

@Test @MainActor func peerLookupIsNotHeldUpByASlowHost() async throws {
    let slow = ConnectionProfile(host: "slow.invalid"), fast = ConnectionProfile(host: "fast.invalid")
    var lookup = DesktopLinkPeerLookup(hosts: [slow, fast], pins: [:], mismatches: [:], identify: { host in
        if host.id == slow.id { try await Task.sleep(for: .seconds(30)) }
        return lookupPin(host, host.id == fast.id ? "node-b" : "node-c")
    })
    lookup.timeout = .milliseconds(300)
    let clock = ContinuousClock()
    let started = clock.now
    let found = try await lookup.resolve("node-b")
    let elapsed = clock.now - started
    #expect(found?.id == fast.id)
    #expect(elapsed < .seconds(3))
}

@Test @MainActor func peerLookupFindsNoSingleHost() async throws {
    let a = ConnectionProfile(host: "a.invalid"), b = ConnectionProfile(host: "b.invalid")
    let none = DesktopLinkPeerLookup(hosts: [a], pins: [:], mismatches: [:], identify: { lookupPin($0, "node-c") })
    #expect(try await none.resolve("node-b") == nil)
    let two = DesktopLinkPeerLookup(hosts: [a, b], pins: [:], mismatches: [:], identify: { lookupPin($0, "node-b") })
    #expect(try await two.resolve("node-b") == nil)
}

// F3: a host whose recorded key changed is reported as an identity change.
@Test @MainActor func peerLookupNamesAChangedHostKey() async throws {
    let a = ConnectionProfile(host: "a.invalid")
    let mismatch = RelayNodeTrust.Mismatch(pinned: lookupPin(a, "node-b"), offered: lookupPin(a, "node-b"))
    let lookup = DesktopLinkPeerLookup(hosts: [a], pins: [a.id: lookupPin(a, "node-b")], mismatches: [a.id: mismatch],
        identify: { lookupPin($0, "node-b") })
    await #expect(throws: DesktopLinkCarrierError.identityChanged("node-b")) { try await lookup.resolve("node-b") }
    #expect(DesktopLinkCarrierError.identityChanged("node-b").localizedDescription.contains("signing key"))
    #expect(DesktopLinkCarrierError.identityChanged("node-b").localizedDescription != DesktopLinkCarrierError.noConnectedHost("node-b").localizedDescription)
}

// F2: selecting the carrier pins and saves nothing, even for an unpinned host.
@Test @MainActor func peerLookupSavesNoPin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-lookup-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = RelayNodeTrust(directory: directory, request: { _, _ in
        ["authority": "relayd", "node_id": "node-b", "certificate_pem": lookupPEM,
         "certificate_sha256": RelayNodeTrust.certificateFingerprint(lookupPEM)!]
    })
    let host = ConnectionProfile(host: "b.invalid")
    let lookup = DesktopLinkPeerLookup(hosts: [host], pins: trust.pins, mismatches: trust.mismatches, identify: { try await trust.identify($0) })
    #expect(try await lookup.resolve("node-b")?.id == host.id)
    #expect(trust.pins.isEmpty && trust.mismatches.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pins.json").path))
}
