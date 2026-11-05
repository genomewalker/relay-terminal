import XCTest
@testable import Relay

/// Rows serialized by the native engine from an idle Claude 2.1.301 pane with
/// a cc-status statusline (anonymised: tool counts and paths only).
final class RelayAgentMaintenanceCapturedPromptTests: XCTestCase {
    let separator = "\u{1b}[0m\u{1b}[38;2;136;136;136m────────────────────────────────────────────────────\u{1b}[0m\n"
    let footer =
        "  \u{1b}[0m\u{1b}[38;2;118;118;118m~\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;95;215;215m[Opus 5.5]\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;188;188;188m70h3m\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;135;215;175m[==\u{1b}[0m\u{1b}[38;2;118;118;118m-------------\u{1b}[0m\u{1b}[38;2;135;215;175m]\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;135;215;175m88%\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m118K↓360↑\u{1b}[0m\n" +
        "  \u{1b}[0m\u{1b}[38;2;135;215;175m$2.55 $0.04/h\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m28/m\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118mwait 0%\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;135;175;255mcache 99%\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m|\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118m3 CLAUDE.md 10 MCPs 24 hooks\u{1b}[0m\n" +
        "  \u{1b}[0m\u{1b}[38;2;215;135;215m◈\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118mv5.73.1\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118mmem:\u{1b}[0m\u{1b}[38;2;188;188;188m7K\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;215;215;135m70%\u{1b}[0m\u{1b}[38;2;153;153;153m \u{1b}[0m\u{1b}[38;2;118;118;118mhabits:\u{1b}[0m\u{1b}[38;2;95;215;215m4\u{1b}[0m\n" +
        "  \u{1b}[0m\u{1b}[38;2;135;215;175m+\u{1b}[0m\u{1b}[38;2;153;153;153m Bash \u{1b}[0m\u{1b}[38;2;118;118;118m×7\u{1b}[0m\u{1b}[38;2;153;153;153m | \u{1b}[0m\u{1b}[38;2;135;215;175m+\u{1b}[0m\u{1b}[38;2;153;153;153m mcp__relay__relay_message_pane \u{1b}[0m\u{1b}[38;2;118;118;118m×4\u{1b}[0m\u{1b}[38;2;153;153;153m | \u{1b}[0m\u{1b}[38;2;135;215;175m+\u{1b}[0m\u{1b}[38;2;153;153;153m mcp__relay__relay_read_viewport \u{1b}[0m\u{1b}[38;2;118;118;118m×3\u{1b}[0m\u{1b}[38;2;153;153;153m | \u{1b}[0m\u{1b}[38;2;135;215;175m+\u{1b}[0m\u{1b}[38;2;153;153;153m ToolSearch \u{1b}[0m\u{1b}[38;2;118;118;118m×1\u{1b}[0m\n" +
        "  \u{1b}[0m\u{1b}[38;2;255;107;128m⏵⏵ bypass permissions on\u{1b}[0m\u{1b}[38;2;153;153;153m (shift+tab to cycle) · ← for agents\u{1b}[0m\n"

    func testCapturedIdleClaudePromptIsEmpty() {
        let screen = separator + "\u{276f}\u{a0}\n" + separator + footer
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "claude"))
        XCTAssertNil(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude"))
    }

    func testTypedDraftInTheCapturedContextIsNotEmpty() {
        let screen = separator + "\u{276f}\u{a0}unsent draft\n" + separator + footer
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "claude"))
    }

    func testRunningToolRowInTheCapturedFooterHolds() {
        let running = "  \u{1b}[0m\u{1b}[38;2;215;215;135m~\u{1b}[0m\u{1b}[38;2;153;153;153m Bash: .../...\u{1b}[0m\n"
        let screen = separator + "\u{276f}\u{a0}\n" + separator + running + footer
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
    }
}
