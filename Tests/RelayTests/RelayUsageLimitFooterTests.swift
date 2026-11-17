import Foundation
import Testing
@testable import Relay

/// Pane 07fa914c (dandy-07, 2026-11-17) stopped at the business usage limit.
/// Claude shows two notice rows under the idle prompt; the account move must
/// still recognise the prompt as empty, because moving the pane is the remedy.
@Suite("Usage-limit footer")
struct RelayUsageLimitFooterTests {
    static let separator = String(repeating: "─", count: 120) + "\n"
    static func screen(prompt: String = "❯ \n", notices: [String] = [
        "  ⚠ Usage limit reached · limit resets 3:50pm · clau.de/wrap-up",
        "    Continuing automatically at 3:50pm · Esc to cancel",
    ], tail: String = "") -> String {
        "✻ Churned for 2m 11s · done 2:48 PM\n"
            + "                                                    1% until auto-compact\n"
            + separator + prompt + separator
            + notices.map { $0 + "\n" }.joined()
            + "  ~ | [Opus 5.5] | 296h52m | [=====----------] 64% 364K↓799↑\n"
            + "  $679.73 $2.29/h | 20/m | wait 6% | cache 100% | 1 CLAUDE.md 8 MCPs 8 hooks\n"
            + "  ◈ v5.74.1 mem:311K pending:17K\n"
            + "  + Bash ×14 | + Edit ×2 | + mcp__chitta__remember ×2 | + Write ×1\n"
            + "  ⏵⏵ bypass permissions on (shift+tab to cycle)" + tail
    }

    @Test("07fa914c: an idle prompt under the usage-limit notice is empty")
    func usageLimitNoticeIsKnown() {
        #expect(RelayAgentMaintenancePrompt.isEmpty(Self.screen(), provider: "claude"))
    }

    @Test("Without the notice the same screen is empty too (control)")
    func controlWithoutNotice() {
        #expect(RelayAgentMaintenancePrompt.isEmpty(Self.screen(notices: []), provider: "claude"))
    }

    @Test("Typed text under a usage-limit notice still holds the move")
    func typedDraftStillHolds() {
        #expect(!RelayAgentMaintenancePrompt.isEmpty(Self.screen(prompt: "❯ keep going\n"), provider: "claude"))
    }

    @Test("Footer agents are still counted next to the notice")
    func footerAgentsStillHold() {
        #expect(!RelayAgentMaintenancePrompt.isEmpty(Self.screen(tail: " · ← 3 agents"), provider: "claude"))
    }

    @Test("Other warning rows stay unrecognised")
    func otherWarningsStayUnknown() {
        let screen = Self.screen(notices: ["  ⚠ Something else happened"])
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
    }
}
