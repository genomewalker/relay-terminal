import Foundation
import Testing
@testable import Relay

/// 0.5.59: prompt_empty=false also means "could not be read". Pane health and
/// the installed-update receipt (which carries these facts) say which.
@MainActor
@Suite(.serialized)
struct RelayPanePromptBlockerTests {
    @Test("A held prompt names its blocker; a disconnected pane is not read as typed text")
    func disconnectedPaneNamesItsBlocker() {
        let pane = PaneModel(profile: .local)
        let facts = RelayPaneHealthFacts.read(pane, proof: nil)
        #expect(facts.value["prompt_empty"]?.boolean == false)
        #expect(facts.value["prompt_blocker"]?.string == "the pane is not connected")
        #expect(pane.runtime.viewIsMadeForTesting == false)
        #expect(pane.runtime.agentMaintenancePromptBlocker(explainedAgents: 0) == "the pane is not connected")
    }

    @Test("A connected Relay pane whose terminal was never opened reports that, not typed text")
    func unopenedRelayPaneNamesItsBlocker() throws {
        let pane = PaneModel(profile: .sshConfigHost("prompt-blocker.invalid"))
        #expect(pane.profile.backend == .relay)
        pane.connectionState = .connected
        let facts = RelayPaneHealthFacts.read(pane, proof: nil)
        #expect(facts.value["prompt_empty"]?.boolean == false)
        let blocker = try #require(facts.value["prompt_blocker"]?.string)
        #expect(blocker.hasPrefix("the pane's terminal has not been opened since Relay started"))
        // Reading the reason never builds the pane's renderer.
        #expect(pane.runtime.viewIsMadeForTesting == false)
    }

    @Test("The reason is explanatory: it never changes the health signal or the hold")
    func blockerDoesNotChangeTheSignal() {
        let pane = PaneModel(profile: .local)
        let facts = RelayPaneHealthFacts.read(pane, proof: nil)
        guard case .object(var changed) = facts.value else { Issue.record("not an object"); return }
        changed["prompt_blocker"] = .string("a different reason")
        #expect(RelayPaneHealthCoordinator.healthSignal([facts])
            == RelayPaneHealthCoordinator.healthSignal([.seal(changed)]))
        #expect(!facts.allowedActions.contains("apply_update"))
    }
}
