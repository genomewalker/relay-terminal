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

    init(listings: [[DesktopLinkRequest]]) { self.listings = listings }

    func request(_ operation: String, _ packet: [String: Any]) async throws -> [String: Any] {
        operations.append((operation, packet))
        if operation == "route_desktop_link_list" {
            let next = listings.isEmpty ? [] : listings.removeFirst()
            let data = try JSONEncoder().encode(next)
            return ["requests": try JSONSerialization.jsonObject(with: data)]
        }
        return ["status": "ok"]
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
