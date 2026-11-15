import Foundation
import Testing
@testable import Relay

/// QA-F04: the idle Codex screen on scratch pane 8cb82332 (dandy-07,
/// 2026-11-03 ~17:45 CET), rebuilt from relay_read_viewport's text
/// (viewport-8cb82332-tail.txt, sha256 c6bc6417…) with the same characters and
/// spacing. The text viewport carries no SGR; the faint style on the native
/// placeholder is the style the screen export carries (as in
/// RelayAgentMaintenanceCodexPromptTests). The raw VT of that pane was not captured.
private enum CapturedCodex {
    static let weekly = String(repeating: " ", count: 69) + "⚠ weekly limit: 7% left · resets at 11:02 PM on 8 Nov · /status"
    static let contextLine = "  GPT-6 Rosalind (Research) xhigh · Context 91% left · ~ · GPT-6 Rosalind (Research) · Context 9% used"
    static let hintLine = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 171) + "⚠ 2 warnings · f2 to view"
    static let placeholder = "\u{1b}[2mAsk Codex to do anything\u{1b}[22m"

    static func screen(input: String = placeholder, above: String = weekly, footer: [String] = [contextLine, hintLine]) -> String {
        (["  Worked for 24s • 5:20 PM", " ", above, " ", "› " + input, " "] + footer).joined(separator: "\r\n")
    }
}

@Suite("Codex segmented idle footer (QA-F04)")
struct RelayCodexSegmentedFooterTests {
    private func empty(_ screen: String) -> Bool { RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex") }

    @Test func theCapturedIdleScreenIsEmpty() {
        let screen = CapturedCodex.screen()
        #expect(empty(screen))
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func typedTextAfterTheMarkerIsADraft() {
        let screen = CapturedCodex.screen(input: "coordinate with claude")
        #expect(!empty(screen))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func thePlaceholderWordsTypedWithoutFaintStyleAreADraft() {
        // Same visible text as the placeholder; only the raw VT style differs.
        let screen = CapturedCodex.screen(input: "Ask Codex to do anything")
        #expect(!empty(screen))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func faintTextThatIsNotAPlaceholderIsNotEmpty() {
        #expect(!empty(CapturedCodex.screen(input: "\u{1b}[2mdelete every branch\u{1b}[22m")))
    }

    @Test func aRunningTurnAboveTheComposerIsNotEmpty() {
        #expect(!empty(CapturedCodex.screen(above: "• Working (3s • esc to interrupt)")))
    }

    @Test func unknownFooterSegmentsAreRefused() {
        let base = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 40)
        for line in [base + "⚠ 2 warnings · f2 to view · foo",
                     base + "⚠ 2 warnings · f2 to view" + String(repeating: " ", count: 4) + "something else",
                     base + "something else",
                     "  ← for agents · ? for shortcuts · foo",
                     "  ← for agents"] {
            #expect(!empty(CapturedCodex.screen(footer: [CapturedCodex.contextLine, line])), "\(line)")
        }
        #expect(!empty(CapturedCodex.screen(footer: [CapturedCodex.contextLine, CapturedCodex.hintLine, "  something else"])))
    }

    @Test func warningsAloneAreNotAHint() {
        #expect(!empty(CapturedCodex.screen(footer: [CapturedCodex.contextLine, "  ⚠ 2 warnings · f2 to view"])))
        #expect(!empty(CapturedCodex.screen(footer: [CapturedCodex.contextLine,
            String(repeating: " ", count: 60) + "⚠ 1 warning · f2 to view"])))
    }

    @Test func twoContextLinesAreRefused() {
        #expect(!empty(CapturedCodex.screen(footer: [CapturedCodex.contextLine, CapturedCodex.contextLine, CapturedCodex.hintLine])))
    }

    /// Pane 372a79db (dandy-07, 2026-11-15): the status line wrapped onto a
    /// second row in a narrow pane, and every account move was refused with
    /// "the screen's prompt or footer was not recognised".
    @Test func aWrappedStatusLineIsStillTheIdleFooter() {
        let model = "  GPT-6.1 Terra medium · /maps/projects/fernandezguerra/apps/repos/convergence · GPT-6.1 Terra"
        let wrapped = "  · convergence · fix/compound-linkage-routing-20261007"
        let hint = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 36) + "⚠ 3 warnings · f2 to view"
        let above = String(repeating: " ", count: 55) + "⚠ weekly limit: only 1% left · /status"
        #expect(empty(CapturedCodex.screen(above: above, footer: [model, wrapped, hint])))
        #expect(empty(CapturedCodex.screen(footer: [model, wrapped, wrapped, hint])))
        // Still refused: a hint row is required, at most two wrapped rows,
        // a typed draft, and unknown rows after the hint.
        #expect(!empty(CapturedCodex.screen(footer: [model, wrapped])))
        #expect(!empty(CapturedCodex.screen(footer: [model, wrapped, wrapped, wrapped, hint])))
        #expect(!empty(CapturedCodex.screen(input: "run the pilot", footer: [model, wrapped, hint])))
        #expect(!empty(CapturedCodex.screen(footer: [model, wrapped, hint, "  something else"])))
        for marker in ["› typed", "• Working (3s • esc to interrupt)", "↳ queued message", "⚠ something"] {
            #expect(!empty(CapturedCodex.screen(footer: [model, "  " + marker, hint])), "\(marker)")
        }
    }

    /// The same pane at a wider size: Codex wrapped mid-word, so the
    /// continuation row has no leading "· ".
    @Test func aStatusLineWrappedMidWordIsStillTheIdleFooter() {
        let model = "  GPT-6.1 Terra medium · /maps/projects/fernandezguerra/apps/repos/convergence · GPT-6.1 Terra · convergence · fix/compound-"
        let hint = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 73) + "⚠ 3 warnings · f2 to view"
        #expect(empty(CapturedCodex.screen(footer: [model, "  linkage-routing-20261007", hint])))
        #expect(!empty(CapturedCodex.screen(footer: [model, "  linkage-routing-20261007"])))
    }

    @Test func theSegmentRuleItself() {
        #expect(RelayAgentMaintenancePrompt.codexSegmentedIdleHint("← for agents · ? for shortcuts"))
        #expect(RelayAgentMaintenancePrompt.codexSegmentedIdleHint("← for agents · ? for shortcuts   ⚠ 1 warning · f2 to view"))
        #expect(!RelayAgentMaintenancePrompt.codexSegmentedIdleHint("⚠ 2 warnings · f2 to view"))
        #expect(!RelayAgentMaintenancePrompt.codexSegmentedIdleHint("← for agents · ? for shortcuts   ⚠ 2 warnings · f2 to view   ⚠ 2 warnings · f2 to view"))
        #expect(!RelayAgentMaintenancePrompt.codexSegmentedIdleHint("← for agents · ? for shortcuts   ⚠ two warnings · f2 to view"))
    }
}
