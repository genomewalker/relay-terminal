import Foundation
import Testing
@testable import Relay

/// Claude's "← N agent(s)" footer nudge counts the user's *other* sessions
/// that are waiting for input (Claude's fleet list, which skips the current
/// session). It is not this pane's work. Maintenance ignores it only when
/// relayd shows the pane has no work of its own: no subagent work, no native
/// child agent or shell process, Claude's harness idle and no active
/// subagents in relayd's events. Every other footer work count still holds.
@Suite("Fleet footer: other sessions waiting")
struct RelayAgentFleetFooterTests {
    /// Pane 827a5c's screen on 2026-11-10 (kaiku), held by "← 1 agent" while
    /// Claude's "Update installed · Restart to update" was pending. The prompt
    /// shows Claude's faint suggestion, not typed text.
    static let headsUp = "✦ Heads up · kaiku's snapshot run can crash on one kind of input file, and nobody has checked whether the real C-cal inputs\n"
        + "  are that kind.\n"
        + "  1: Learn more   2: Knew this already   0: Dismiss\n"
        + "\n"
        + "next:\n"
        + "  1: Send A/B/E proposal to Rosalind\n"
        + "↓ 3 more\n"
        + "                                                  new task? /clear to save 159.8k tokens · ✔ Update installed · Restart to update\n"
        + "───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n"
    static let suggestion = "❯ \u{1b}[2mSend the A/B/E sign-test alternative for the union rule to Rosalind 24e74f7c as input for the next prospective hypothesis, with …\u{1b}[22m\n"
    static func footer(_ tail: String = " · ← 1 agent") -> String {
        "───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n"
        + "  kaiku:main | [Opus 5.5] | 398h59m | +2/-1 | [==-------------] 84% 158K↓859↑\n"
        + "  $132.77 $0.33/h | 7/m | wait 1% | cache 98% | 1 CLAUDE.md 7 MCPs 8 hooks\n"
        + "  ◈ v5.74.1 mem:280K pending:15K\n"
        + "  + Bash ×14 | + Read ×4 | + mcp__relayDesktopR__relay_message_pane ×2\n"
        + "  ⏵⏵ bypass permissions on (shift+tab to cycle)" + tail
    }
    static func screen(prompt: String = suggestion, tail: String = " · ← 1 agent") -> String {
        headsUp + prompt + footer(tail)
    }

    private func proof(subagentWork: Bool? = false, backgroundWork: Bool? = false, harness: String? = "idle",
                       hostJobs: Int? = nil) throws -> RelayAgentMaintenanceProbe {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var value = try decoder.decode(RelayAgentMaintenanceProbe.self,
            from: Data(#"{"version":1,"provider":"claude"}"#.utf8))
        value.subagentWork = subagentWork
        value.backgroundWork = backgroundWork
        value.harnessStatus = harness
        value.backgroundAgentJobs = hostJobs
        return value
    }

    private func empty(_ screen: String, _ proof: RelayAgentMaintenanceProbe, activeSubagents: Int = 0) -> Bool {
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: activeSubagents)
        return RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude", explainedAgents: explained)
    }

    @Test("827a5c: '← 1 agent' is explained when relayd shows no own work")
    func explainedWhenPaneHasNoWork() throws {
        let screen = Self.screen()
        #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(try proof(), activeSubagents: 0)
            == RelayAgentMaintenancePrompt.waitingSessionsExplained)
        #expect(empty(screen, try proof()))
        #expect(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude",
            explainedAgents: RelayAgentMaintenancePrompt.waitingSessionsExplained) == nil)
        #expect(RelayAgentMaintenancePrompt.footerOtherAgentCount(screen, provider: "claude") == 0)
        // Up to "99+": every count of other sessions waiting is the same nudge.
        for count in ["2 agents", "14 agents", "99+ agents"] {
            #expect(empty(Self.screen(tail: " · ← " + count), try proof()))
        }
    }

    @Test("827a5c: any missing piece of relayd evidence keeps the pane held")
    func heldWhenNotExplained() throws {
        let screen = Self.screen()
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
        #expect(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude")?.hasSuffix("← 1 agent") == true)
        #expect(!empty(screen, try proof(subagentWork: true)))
        #expect(!empty(screen, try proof(subagentWork: nil)))
        #expect(!empty(screen, try proof(backgroundWork: nil)))
        #expect(!empty(screen, try proof(backgroundWork: true)))
        #expect(!empty(screen, try proof(harness: "busy")))
        #expect(!empty(screen, try proof(harness: nil)))
        #expect(!empty(screen, try proof(), activeSubagents: 1))
        // "99+" is parsed as a count, so it holds without evidence too.
        #expect(!RelayAgentMaintenancePrompt.isEmpty(Self.screen(tail: " · ← 99+ agents"), provider: "claude"))
        #expect(RelayAgentMaintenancePrompt.footerAgentCount(Self.screen(tail: " · ← 99+ agents"), provider: "claude") > 99)
    }

    @Test("827a5c: the Heads-up and next: rows are neither agents nor a draft")
    func headsUpRowsAreNotWorkOrDraft() throws {
        let screen = Self.screen()
        #expect(RelayAgentMaintenancePrompt.footerAgentCount(screen, provider: "claude") == 1)
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "claude"))
        let plain = Self.screen(tail: "")
        #expect(RelayAgentMaintenancePrompt.footerAgentCount(plain, provider: "claude") == 0)
        #expect(RelayAgentMaintenancePrompt.isEmpty(plain, provider: "claude"))
        // An empty prompt under the same block is empty too; typed text is a draft.
        #expect(empty(Self.screen(prompt: "❯ \n"), try proof()))
        #expect(!empty(Self.screen(prompt: "❯ Send the proposal\n"), try proof()))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(Self.screen(prompt: "❯ Send the proposal\n"), provider: "claude"))
    }

    @Test("Footer work that is not other sessions waiting stays held")
    func otherFooterWorkHolds() throws {
        for tail in [" · 3 agents · working", " · ← 1 agent · 3 agents · working", " · 2 shells",
                     " · ← 1 agent · 2 shells", " · 1 background task", " · 2 agents", " · 1 agent"] {
            let screen = Self.screen(tail: tail)
            #expect(!empty(screen, try proof()), "\(tail)")
            #expect(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude",
                explainedAgents: RelayAgentMaintenancePrompt.waitingSessionsExplained) != nil, "\(tail)")
        }
        #expect(RelayAgentMaintenancePrompt.footerOtherAgentCount(Self.screen(tail: " · 3 agents · working"),
            provider: "claude") == 3)
        #expect(RelayAgentMaintenancePrompt.footerOtherAgentCount(Self.screen(tail: " · ← 1 agent · 2 agents"),
            provider: "claude") == 2)
    }

    @Test("'← N done' and '← for agents' carry no agent count")
    func doneAndHintAreIdle() throws {
        for tail in [" · ← 3 done", " · ← 1 done", " · ← for agents"] {
            let screen = Self.screen(tail: tail)
            #expect(RelayAgentMaintenancePrompt.footerAgentCount(screen, provider: "claude") == 0, "\(tail)")
            #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"), "\(tail)")
            #expect(empty(screen, try proof()), "\(tail)")
        }
    }
}
