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

    @Test func repeatedRouteFailuresPauseWithExponentialBackoff() {
        #expect(!RelayNodeRetryPolicy.isPaused(pausingFailures: 5))
        #expect(RelayNodeRetryPolicy.isPaused(pausingFailures: 6))
        let proxied = (6...12).map { RelayNodeRetryPolicy.delayMilliseconds(attempt: 900, failure: Self.route, pausingFailures: $0, throughLocalProxy: true) }
        #expect(proxied == [30_000, 60_000, 120_000, 240_000, 300_000, 300_000, 300_000])
        // A direct host (dandy-07) never waits more than 30 s, paused or not.
        let direct = (6...12).map { RelayNodeRetryPolicy.delayMilliseconds(attempt: 900, failure: Self.route, pausingFailures: $0) }
        #expect(direct.allSatisfy { $0 == 30_000 })
        // Below the pause the existing schedule is unchanged.
        #expect(RelayNodeRetryPolicy.delayMilliseconds(attempt: 3, failure: Self.route, pausingFailures: 3) == 600)
    }

    @Test func onlyRouteAndPermanentFailuresCountTowardThePause() {
        let dns = SSHConnectionFailure(kind: .networkRoute, detail: "ssh: Could not resolve hostname x")
        let auth = SSHConnectionFailure(kind: .authentication, detail: "Permission denied")
        #expect(RelayNodeRetryPolicy.countsTowardPause(Self.route))
        #expect(RelayNodeRetryPolicy.countsTowardPause(auth))
        #expect(!RelayNodeRetryPolicy.countsTowardPause(dns))
        #expect(!RelayNodeRetryPolicy.countsTowardPause(Self.interrupted))
    }

    @Test func demandRestartsWaitOutAPause() {
        let second: UInt64 = 1_000_000_000
        // Not paused: every 5 s, as before.
        #expect(RelayNodeRetryPolicy.demandRestartAllowed(now: 10 * second, lastStart: 5 * second, notBefore: 0))
        #expect(!RelayNodeRetryPolicy.demandRestartAllowed(now: 9 * second, lastStart: 5 * second, notBefore: 0))
        // Paused until 60 s: a host request or waiting pane cannot start ssh earlier.
        #expect(!RelayNodeRetryPolicy.demandRestartAllowed(now: 30 * second, lastStart: 5 * second, notBefore: 60 * second))
        #expect(RelayNodeRetryPolicy.demandRestartAllowed(now: 60 * second, lastStart: 5 * second, notBefore: 60 * second))
    }

    @Test func aLocalProxyPortIsReadFromTheProxyCommand() {
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "/opt/homebrew/bin/socat - socks4a:localhost:10.133.24.5:22,socksport=7777") == 7777)
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "nc -X 5 -x 127.0.0.1:1080 %h %p") == 1080)
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "connect --proxy socks5h://localhost:9050 %h %p") == 9050)
        // A remote jump or proxy is not gated.
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "ssh -W %h:%p bastion.example.org") == nil)
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "nc -X 5 -x proxy.example.org:1080 %h %p") == nil)
        #expect(RelayLocalProxyGate.localPort(proxyCommand: "socat - socks4a:proxy.example.org:%h:%p,socksport=7777") == nil)
    }

    @Test func aClosedLocalProxyNamesItsPort() {
        let failure = SSHConnectionFailure.localProxyUnavailable(port: 7777)
        #expect(failure.isLocalProxy)
        #expect(failure.userMessage.contains("7777"))
        #expect(RelayNodeRetryPolicy.countsTowardPause(failure))
    }
}
