import Foundation
import Testing
@testable import Relay

private func control(_ lifecycle: String, provider: String = "claude", processStart: String = "kernel:123",
                     revision: String = "r1", checkedAt: Date = Date()) -> RelayAgentConversationControl {
    let binding = RelayAgentConversationBinding(hostID: "host", paneID: UUID(), provider: provider,
        processID: 42, processStart: processStart, sessionID: "session")
    return RelayAgentConversationControl(binding: binding, lifecycle: lifecycle, revision: revision,
        checkedAt: checkedAt, observedAt: checkedAt, inputRevision: 1)
}

@Test func composerReadinessAcceptsClaudeStopAndIdle() {
    // Claude's Stop hook ends the turn; the idle notification follows ~60 s later.
    #expect(control("stop_observed").permitsSend)
    #expect(control("quiet").permitsSend)
    #expect(control("quiet", provider: "codex").permitsSend)
}

@Test func composerReadinessRefusesEverythingElse() {
    // A Codex turn_aborted also maps to stop_observed; it keeps waiting for quiet.
    #expect(!control("stop_observed", provider: "codex").permitsSend)
    for lifecycle in ["active", "needs_input", "exited", "unknown", ""] {
        #expect(!control(lifecycle).permitsSend, "lifecycle \(lifecycle)")
    }
    // The remaining proofs still apply to a Stop observation.
    #expect(!control("stop_observed", processStart: "start-one").permitsSend)
    #expect(!control("stop_observed", revision: "").permitsSend)
    #expect(!control("stop_observed", checkedAt: Date().addingTimeInterval(-6)).permitsSend)
    // Interrupt stays limited to an active turn.
    #expect(control("active").permitsInterrupt)
    #expect(!control("stop_observed").permitsInterrupt)
}

@Test func composerReadinessRuleIsProviderScoped() {
    #expect(RelayAgentConversationControl.readyForInput(lifecycle: "stop_observed", provider: "claude"))
    #expect(!RelayAgentConversationControl.readyForInput(lifecycle: "stop_observed", provider: "codex"))
    #expect(!RelayAgentConversationControl.readyForInput(lifecycle: "needs_input", provider: "claude"))
}
