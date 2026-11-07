import AppKit
import Testing
@testable import Relay

private let shownRequest = DesktopLinkRequest(id: String(repeating: "a", count: 64), sessionID: "5a30d83a-5222-48f3-93c7-42fa687d901b",
    accountRoot: "/Users/owner/.claude-max", paneID: "1652a003-70e9-4614-addb-68564fa8383b",
    createdAt: "2026-11-07T10:00:00Z", expiresAt: "2026-11-07T10:10:00Z")

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
