import XCTest
@testable import Relay

final class RelayAgentMaintenancePromptTests: XCTestCase {
    let codexFooter = "\n\nGPT-Rosalind Research xhigh · Context 33% left · /exact/cwd\n? for shortcuts\n"
    let claudeFooter = "\n────────────────\nterm:main | [Opus 5.5] | idle\n$118.19\n◈ v5.73.1\n+ Bash ×8\n⏵⏵ bypass permissions on\n"

    func testNativeFaintPlaceholderIsEmptyButTheSameTypedTextIsADraft() {
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[90mAsk Codex to do anything\u{1b}[39m" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› Ask Codex to do anything" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› Ask \u{1b}[90mCodex to do anything\u{1b}[39m" + codexFooter, provider: "codex"))
    }

    func testBlankPromptAndRGBFaintPlaceholder() {
        // Codex hides the placeholder once anything is typed, so a bare
        // marker may hold typed spaces: never empty (review M1, 0517c).
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› " + codexFooter, provider: "codex"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[38;2;128;128;128mAsk Codex to do anything\u{1b}[0m" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[38;2;230;230;230mAsk Codex to do anything\u{1b}[0m" + codexFooter, provider: "codex"))
    }

    func testTallTerminalEmptyGridTailDoesNotHideTheLivePrompt() {
        let padding = String(repeating: "     \n", count: 100)
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + claudeFooter + padding, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[2mAsk Codex to do anything\u{1b}[22m" + codexFooter + padding, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ unsent draft" + claudeFooter + padding, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ \n  wrapped draft" + claudeFooter + padding, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + claudeFooter + padding + "unknown dialog", provider: "claude"))
    }

    func testDraftWrappedAfterABlankFirstRowIsNotEmpty() {
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \n  a real multiline draft" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ \n  a real multiline draft" + claudeFooter, provider: "claude"))
    }

    func testClaudeQuestionDraftIsPreservedAndSuggestionsRemainEnabled() {
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ ?" + claudeFooter, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + claudeFooter, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ \u{1b}[2mTry fixing the tests\u{1b}[22m" + claudeFooter, provider: "claude"))
    }

    func testFooterAgentCountHoldsUnlessSubagentsAreVerifiedIdleAndShellsAlwaysHold() {
        // Claude also shows "← N agent" on idle panes; only relayd's proof that
        // the agents relayd accounts for let it through, up to that many.
        let screen = "❯ \u{a0}\n────────────────\n  fqdup:perf | [Opus 5.5] | 145h54m\n  26.7¢ $0.00/h | 7/m | wait 0% | cache 98% | 1 CLAUDE.md 9 MCPs 8 hooks\n"
            + "  ◈ v5.73.1 mem:148K pending:371\n  + Bash ×2\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · install gh for PR status · ← 1 agent\n"
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
        XCTAssertEqual(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude")?.hasSuffix("← 1 agent"), true)
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude", explainedAgents: 1))
        XCTAssertNil(RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude", explainedAgents: 1))
        XCTAssertEqual(RelayAgentMaintenancePrompt.footerAgentCount(screen, provider: "claude"), 1)
        let shells = screen.replacingOccurrences(of: "← 1 agent", with: "← 1 agent · 2 shells")
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(shells, provider: "claude", explainedAgents: 2))
        XCTAssertEqual(RelayAgentMaintenancePrompt.backgroundWork(shells, provider: "claude", explainedAgents: 2)?.hasSuffix("2 shells"), true)
        let task = screen.replacingOccurrences(of: "← 1 agent", with: "1 background task")
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(task, provider: "claude", explainedAgents: 2))
        XCTAssertNil(RelayAgentMaintenancePrompt.backgroundWork("❯ " + claudeFooter, provider: "claude"))
    }

    func testCentsCostAndSlashCommandNoticeFootersAreRecognized() {
        let cents = "\n────────────────\n~ | [Haiku 5.5>] | 4m | [=---] 94% 57K↓63↑\n0.7¢ $0.09/h | 14K/m | wait 1% | cache 46% | 1 CLAUDE.md 8 MCPs 12 hooks\n◈ v5.73.1 mem:7K\n⏵⏵ bypass permissions on\n"
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + cents, provider: "claude"))
        let notice = claudeFooter + "/rc failed\n"
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + notice, provider: "claude"))
        // Typed text and unknown lines still fail closed.
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ draft" + cents, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + claudeFooter + "/rc failed and more\n", provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + claudeFooter + "cents¢ text\n", provider: "claude"))
    }

    func testAnyNamedModelStatusLineIsRecognized() {
        // Captured from an idle Fable pane that a move refused as unrecognised.
        let fable = "\n────────────────\n  term:main | [Fable 5.1] | 404h9m | +15336/-1728 | [====-----------] 73% 273K↓529↑\n"
            + "  $269.14 $0.67/h | 11/m | wait 1% | cache 100% | 1 CLAUDE.md 7 MCPs 12 hooks\n  ◈ v5.73.1 mem:13K pending:3K\n"
            + "  + Bash ×17 | + mcp__relay__relay_message_pane ×2 | + mcp__relay__relay_list_panes ×1\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n"
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + fable, provider: "claude"))
        let future = fable.replacingOccurrences(of: "[Fable 5.1]", with: "[Quill 6]")
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + future, provider: "claude"))
        // Drafts, background work and lines that only resemble a model stay held.
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ draft" + fable, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + fable + "  ← 1 agent\n", provider: "claude"))
        for line in ["term:main | [fable 5.1] | idle", "term:main | [Fable] | idle", "term:main [Fable 5.1] idle", "term:main | [Fable 5.1 | idle"] {
            let footer = fable.replacingOccurrences(of: "term:main | [Fable 5.1] | 404h9m | +15336/-1728 | [====-----------] 73% 273K↓529↑", with: line)
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + footer, provider: "claude"), line)
        }
    }

    func testTypedTextIsPositiveDraftEvidenceOnly() {
        // Typed text, including a draft wrapped below a blank first row.
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText("❯ unsent draft" + claudeFooter, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText("❯ \n  a real multiline draft" + claudeFooter, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText("› Ask Codex to do anything" + codexFooter, provider: "codex"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText("❯ ?" + claudeFooter, provider: "claude"))
        // Empty prompts, faint placeholders and predictions are not drafts.
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("❯ " + claudeFooter, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("❯ \u{1b}[2mTry fixing the tests\u{1b}[22m" + claudeFooter, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("› \u{1b}[90mAsk Codex to do anything\u{1b}[39m" + codexFooter, provider: "codex"))
        // Unreadable or prompt-less screens are unknown, not drafts.
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText(nil, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("unknown modal dialog", provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("❯unspaced" + claudeFooter, provider: "claude"))
    }

    func testUnknownScreensAndControlsFailClosed() {
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \nunknown modal dialog", provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("\u{1b}[2J› " + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[90mUnrecognized text\u{1b}[0m" + codexFooter, provider: "codex"))
    }

    func testArbitraryNativeClaudePredictionsAreEmptyButTypedAndWrappedDraftsAreHeld() {
        for prediction in ["yes check the current version", "Check the remaining panes", "?", "修正を確認"] {
            XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty(
                "❯ \u{1b}[2m" + prediction + "\u{1b}[22m" + claudeFooter, provider: "claude"))
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(
                "❯ " + prediction + claudeFooter, provider: "claude"))
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(
                "❯ typed \u{1b}[2m" + prediction + "\u{1b}[22m" + claudeFooter, provider: "claude"))
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(
                "❯ \u{1b}[2m" + prediction + "\u{1b}[22m\n  unsent continuation" + claudeFooter,
                provider: "claude"))
        }
    }

    func testCurrentChittaWaitStatusDoesNotMakeAnEmptyClaudePromptLookLikeADraft() {
        let footer = "\n────────────────\ndart:main | [Opus 5.5] | <1m | 100%\nwait 0% | 2 CLAUDE.md 9 MCPs 8 hooks\n◈ v5.73.1 mem:165K pending:5K\n⏵⏵ bypass permissions on\n"
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + footer, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ a real draft" + footer, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ \nwait 0% | 2 CLAUDE.md 9 MCPs 8 hooks" + footer,
            provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + footer.replacingOccurrences(
            of: "wait 0% | 2 CLAUDE.md 9 MCPs 8 hooks", with: "wait for a human answer"), provider: "claude"))
    }

    func testBackgroundJobsAndAgentsHoldAnOtherwiseEmptyClaudePrompt() {
        for jobs in ["5 shells", "1 shell", "2 agents", "1 background task"] {
            let footer = claudeFooter.replacingOccurrences(of: "bypass permissions on", with: "bypass permissions on · " + jobs)
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + footer, provider: "claude"))
        }
        // With the session's subagents verified idle, only agent counts pass.
        for agents in ["2 agents", "← 1 agent", "← 2 agents"] {
            let footer = claudeFooter.replacingOccurrences(of: "bypass permissions on", with: "bypass permissions on · " + agents)
            XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + footer, provider: "claude", explainedAgents: 2))
        }
        let three = claudeFooter.replacingOccurrences(of: "bypass permissions on", with: "bypass permissions on · ← 3 agents")
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("❯ " + three, provider: "claude", explainedAgents: 2))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ " + three, provider: "claude", explainedAgents: 3))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("transcript mentions 5 shells\n❯ " + claudeFooter,
            provider: "claude"))
    }

    func testExactRetainedShellPromptWithoutSemanticMarksRejectsDraftsAndContinuations() {
        let shell = "╭─ SUN1028888 · ~/Documents/ChatGPT/term git:main env:bioinfo\n╰─ ❯ "
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty(shell))
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty("history output\n\u{1b}[32m" + shell + "\u{1b}[0m\n"))
        for suffix in ["unsent draft", "\n> continuation", "\nunknown dialog"] {
            XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty(shell + suffix))
        }
        XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty("unrecognized heading\n╰─ ❯ "))
        XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty("❯ "))
    }

    /// The exact fresh dandy-07 prompt from the first live plan run.
    func testFreshBoxShellPromptFamilyIsEmptyAndDraftsAreTyped() {
        let fresh = "╭─ dandycomp07fl · ~\n╰─ ❯ "
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty(fresh))
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty(
            "\u{1b}[2m╭─ dandycomp07fl · ~\u{1b}[0m\n\u{1b}[35m╰─ ❯\u{1b}[0m "))
        // Faint text after the marker is typed input drawn faint, or a
        // suggestion that only follows typed input: never empty.
        XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty(fresh + "\u{1b}[2mcodex --sandbox read-only\u{1b}[0m"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellHasTypedText(fresh + "\u{1b}[2mcodex --sandbox read-only\u{1b}[0m"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty("╭─ host · ~/x\n└─ $ "))
        XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellIsEmpty("╭─ host · ~/x\n╰─ % "))
        // Real drafts stay drafts, including text ending in a marker character.
        for draft in ["ls", "echo $", "codex", "\u{1b}[2mfaint\u{1b}[0m typed"] {
            XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty(fresh + draft), draft)
            XCTAssertTrue(RelayAgentMaintenancePrompt.retainedShellHasTypedText(fresh + draft), draft)
        }
        XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellHasTypedText(fresh))
        // Still drawing (header only) is unrecognised, not a draft.
        XCTAssertEqual(RelayAgentMaintenancePrompt.retainedShellPrompt("╭─ dandycomp07fl · ~"), .unrecognized)
        XCTAssertFalse(RelayAgentMaintenancePrompt.retainedShellIsEmpty("╭─ host · ~\n╰─ ❯ ls\n> continuation"))
    }

    /// Root review 2026-10-17-a: colour or a caret alone is not proof of a
    /// prediction. False "typed/unknown" is safe; false "empty" is not.
    func testUnprovenGreyAndCaretShapesStayHeld() {
        let footer = "\n────────────────────────\n⏵⏵ bypass permissions on · shift+tab to cycle\n"
        for screen in ["❯ \u{1b}[38;5;250mdelete these files\u{1b}[39m", "❯ \u{1b}[38;2;190;190;190mdelete these files\u{1b}[39m",
                       "❯ \u{1b}[7mc\u{1b}[27m\u{1b}[2montinue working\u{1b}[22m", "❯ \u{1b}[38;5;244mdelete these files\u{1b}[39m",
                       "❯ \u{1b}[38;2;180;180;184mdelete these files\u{1b}[0m", "❯ delete these files"] {
            for suffix in [footer, claudeFooter] {
                XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(screen + suffix, provider: "claude"), screen)
                XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText(screen + suffix, provider: "claude"), screen)
            }
        }
        for screen in ["› \u{1b}[38;5;250mAsk a follow-up question\u{1b}[39m", "› \u{1b}[7mA\u{1b}[27m\u{1b}[2msk a follow-up question\u{1b}[22m"] {
            XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(screen + codexFooter, provider: "codex"), screen)
        }
        // The proven native faint styles remain predictions, including wrapped ones.
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ \u{1b}[2mcontinue\u{1b}[22m\n  \u{1b}[2mworking\u{1b}[22m" + footer, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ \u{1b}[38;5;8mcontinue working\u{1b}[39m" + footer, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("❯ \u{1b}[38;2;153;153;153mcontinue working\u{1b}[0m" + footer, provider: "claude"))
    }

    func testWrappedPredictionIsEmptyButWrappedDraftOrUnknownRowIsNot() {
        let wrapped = "❯ \u{1b}[2mcheck whether the remaining panes still hold their\u{1b}[22m\n  \u{1b}[2mdrafts after the restart\u{1b}[22m"
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty(wrapped + claudeFooter, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText(wrapped + claudeFooter, provider: "claude"))
        let typedTail = "❯ \u{1b}[2mcheck whether the remaining panes\u{1b}[22m\n  drafts after the restart"
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(typedTail + claudeFooter, provider: "claude"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText(typedTail + claudeFooter, provider: "claude"))
        // Faint rows below a blank marker row are unknown, not a prediction.
        let belowBlank = "❯ \n  \u{1b}[2mPress up to edit queued messages\u{1b}[22m"
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(belowBlank + claudeFooter, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText(belowBlank + claudeFooter, provider: "claude"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \n  \u{1b}[2mAsk a follow-up question\u{1b}[22m" + codexFooter,
            provider: "codex"))
        // A faint wrapped prediction does not excuse an unknown footer.
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty(wrapped + "\n────────────────\nunknown dialog\n", provider: "claude"))
    }

    func testCurrentCodexFollowUpPlaceholderIsEmptyButUnknownFaintTextIsNot() {
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[2mAsk a follow-up question\u{1b}[22m" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.hasTypedText("› \u{1b}[2mAsk a follow-up question\u{1b}[22m" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› Ask a follow-up question" + codexFooter, provider: "codex"))
        XCTAssertTrue(RelayAgentMaintenancePrompt.hasTypedText("› Ask a follow-up question" + codexFooter, provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[2mAsk a follow-up question now\u{1b}[22m" + codexFooter, provider: "codex"))
        // A narrow pane wraps the placeholder; its words still match exactly.
        XCTAssertTrue(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[2mAsk a follow-up\u{1b}[22m\n  \u{1b}[2mquestion\u{1b}[22m" + codexFooter,
            provider: "codex"))
        XCTAssertFalse(RelayAgentMaintenancePrompt.isEmpty("› \u{1b}[2mAsk a follow-up\u{1b}[22m\n  question" + codexFooter,
            provider: "codex"))
    }
}
