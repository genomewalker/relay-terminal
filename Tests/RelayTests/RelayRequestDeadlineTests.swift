import Foundation
import Testing
@testable import Relay

/// 2026-11-24: a relay_exec stamped 15:57:52Z waited in Relay's unserved
/// loopback queue while the main thread was stalled, its caller reported an
/// unknown outcome after 60 s, and Relay admitted and ran it at 16:21:56Z.
/// A mutation admitted after the caller's deadline must be refused instead.
@Suite("Request deadline")
struct RelayRequestDeadlineTests {
    private let sent = Date(timeIntervalSince1970: 1_795_535_872.347)

    private func request(_ headers: [String: String]) -> RelaySidePanelHTTPRequest {
        RelaySidePanelHTTPRequest(method: "POST", path: "/api/host/request", headers: headers,
                                  body: Data(#"{"operation":"exec"}"#.utf8))
    }

    private func stamp(_ date: Date) -> [String: String] {
        [RelayRequestDeadline.header: String(Int64(date.timeIntervalSince1970 * 1000))]
    }

    @Test func aRequestReachedAfterItsCallerGaveUpIsRefusedAndNotRun() throws {
        let deadline = sent.addingTimeInterval(60)
        let admittedLate = sent.addingTimeInterval(24 * 60 + 4)
        let refusal = try #require(RelayRequestDeadline.refusal(request(stamp(deadline)), now: admittedLate))
        #expect(refusal.status == 408)
        #expect(String(decoding: refusal.body, as: UTF8.self).contains("not executed"))
    }

    @Test func aRequestWithinItsDeadlineIsAdmitted() {
        let deadline = sent.addingTimeInterval(60)
        #expect(RelayRequestDeadline.refusal(request(stamp(deadline)), now: sent.addingTimeInterval(1)) == nil)
        #expect(RelayRequestDeadline.verdict(stamp(deadline), now: deadline) == .current)
    }

    @Test func olderClientsWithoutADeadlineAreAdmittedAsBefore() {
        #expect(RelayRequestDeadline.refusal(request([:]), now: .distantFuture) == nil)
    }

    @Test func anUnreadableDeadlineIsRefusedRatherThanIgnored() throws {
        for value in ["soon", "-5", "0", ""] {
            let refusal = try #require(RelayRequestDeadline.refusal(request([RelayRequestDeadline.header: value]), now: sent))
            #expect(refusal.status == 400)
        }
    }
}
