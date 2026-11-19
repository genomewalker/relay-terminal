import Testing
@testable import Relay

@Suite("A node with no network route backs off instead of retrying every few seconds")
struct RelayNodeRetryPolicyTests {
    static let route = SSHConnectionFailure(kind: .networkRoute, detail: "No route to host")
    static let interrupted = SSHConnectionFailure(kind: .interrupted, detail: "Connection reset")

    @Test func aBriefDropStillRetriesFast() {
        #expect((1...5).map { RelayNodeRetryPolicy.delayMilliseconds(attempt: $0, failure: Self.route) } == [150, 300, 600, 1_200, 2_400])
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 40, failure: Self.interrupted) == 3_000)
    }

    @Test func aLongRouteOutageSettlesAtThirtySeconds() {
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 8, failure: Self.route) == 19_200)
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 9, failure: Self.route) == 30_000)
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 900, failure: Self.route) == 30_000)
    }

    @Test func aNameLookupFailureKeepsRetryingFast() {
        let dns = SSHConnectionFailure(kind: .networkRoute, detail: "ssh: Could not resolve hostname dandy-07: nodename nor servname provided")
        #expect(dns.isNameLookup)
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 40, failure: dns) == 3_000)
    }

    @Test func permanentFailuresKeepTheirSlowRetry() {
        let auth = SSHConnectionFailure(kind: .authentication, detail: "Permission denied")
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 1, failure: auth) == 30_000)
    }
}
