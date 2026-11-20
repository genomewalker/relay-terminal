import Foundation
import Testing
@testable import Relay

@Test func unconfirmedLifecycleIsAVerifiedControlThatPermitsNothing() throws {
    // relayd sends no time for an agent that has reported no hook since it started.
    let observed = try #require(RelayAgentConversationControl.observedAt("", lifecycle: "unknown"))
    #expect(observed == .distantPast)
    let binding = RelayAgentConversationBinding(hostID: "host", paneID: UUID(), provider: "claude",
        processID: 42, processStart: "kernel:123", sessionID: "session")
    let control = RelayAgentConversationControl(binding: binding, lifecycle: "unknown", revision: "r1",
        checkedAt: Date(), observedAt: observed, inputRevision: 1)
    #expect(!control.permitsSend)
    #expect(!control.permitsInterrupt)
}

@Test func lifecycleObservationTimesStayStrict() {
    #expect(RelayAgentConversationControl.observedAt("2026-11-15T09:58:08.675056292Z", lifecycle: "quiet") != nil)
    #expect(RelayAgentConversationControl.observedAt("2026-11-20T13:49:11.625843000Z", lifecycle: "unknown") != nil)
    // A known state without a valid hook time is still refused.
    for lifecycle in ["quiet", "stop_observed", "active", "needs_input", "exited"] {
        #expect(RelayAgentConversationControl.observedAt("", lifecycle: lifecycle) == nil, "lifecycle \(lifecycle)")
    }
    #expect(RelayAgentConversationControl.observedAt("not-a-time", lifecycle: "unknown") == nil)
    #expect(RelayAgentConversationControl.observedAt("2026-11-20T13:49:11Z", lifecycle: "quiet") == nil)
}
