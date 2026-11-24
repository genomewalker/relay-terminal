import Foundation

/// The client's deadline for one control request.
///
/// On 2026-11-24 Relay's main thread stopped for 26 minutes (15:55:46Z to
/// 16:21:56Z, released when the display woke). Loopback connections were
/// accepted but not served, relay-mcp gave up after 60 s and reported an
/// unknown outcome, and when the main thread resumed Relay admitted the
/// queued requests anyway: a relay_exec sent at 15:57:52Z started a second
/// FARO evidence service on dandy-07 at 16:21:58Z, long after its caller had
/// moved on. relay-mcp now stamps each request with the moment it stops
/// waiting, and Relay refuses a mutation admitted after it, so a request
/// nobody waits for any more never runs. Requests without the header
/// (older clients) are admitted as before.
enum RelayRequestDeadline {
    static let header = "x-relay-deadline-ms"

    enum Verdict: Equatable {
        case unstamped
        case current
        case expired(lateMilliseconds: Int64)
        case malformed
    }

    /// `now` is wall-clock time; both ends run on this Mac.
    static func verdict(_ headers: [String: String], now: Date) -> Verdict {
        guard let raw = headers[header] else { return .unstamped }
        guard let deadline = Int64(raw.trimmingCharacters(in: .whitespaces)), deadline > 0 else { return .malformed }
        let current = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        return current > deadline ? .expired(lateMilliseconds: current - deadline) : .current
    }

    /// The reply for a mutation that must not run, or nil to admit it.
    static func refusal(_ request: RelaySidePanelHTTPRequest, now: Date) -> RelaySidePanelHTTPResponse? {
        switch verdict(request.headers, now: now) {
        case .unstamped, .current:
            return nil
        case .malformed:
            return .text("Invalid \(header) header; operation not dispatched", status: 400, reason: "Bad Request")
        case .expired(let late):
            return .text("Request expired \(late) ms before Relay admitted it; it was not executed. Its caller had already stopped waiting.",
                         status: 408, reason: "Request Timeout")
        }
    }
}
