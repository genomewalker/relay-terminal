import Testing
@testable import Relay

// A dedicated fallback route that attached without the input lease used to
// stay read-only forever (blank proxied Codex panes after a GUI relaunch).
@Test func readOnlyAttachWithLeaseSupportRetries() {
    #expect(RelayInputLeaseRetryPolicy.needsRetry(capabilities: ["input_lease_v1"], controlGranted: false, observeAgentsOnly: false))
    #expect(RelayInputLeaseRetryPolicy.needsRetry(capabilities: ["input_lease_v1"], controlGranted: nil, observeAgentsOnly: false))
}

@Test func grantedLegacyOrObserverRoutesDoNotRetry() {
    #expect(!RelayInputLeaseRetryPolicy.needsRetry(capabilities: ["input_lease_v1"], controlGranted: true, observeAgentsOnly: false))
    #expect(!RelayInputLeaseRetryPolicy.needsRetry(capabilities: [], controlGranted: nil, observeAgentsOnly: false))
    #expect(!RelayInputLeaseRetryPolicy.needsRetry(capabilities: ["input_lease_v1"], controlGranted: false, observeAgentsOnly: true))
}

@Test func leaseRetryBacksOffToThirtySeconds() {
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 1) == 5_000)
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 2) == 10_000)
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 3) == 20_000)
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 4) == 30_000)
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 50) == 30_000)
    #expect(RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: 0) == 5_000)
}
