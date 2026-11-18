import Foundation
import Testing
@testable import Relay

/// Case 6 (0.5.113, pane 9cc78978): Codex 0.170.0's /goal status in the
/// footer. No raw screen of that pane was captured. These screens are
/// SYNTHESIZED: the composer, status line and hint rows are the captured
/// 0.16x layout (RelayCodexSegmentedFooterTests), and the goal texts are the
/// 0.170.0 binary's own strings ("Pursuing goal (", "Goal achieved (",
/// "Goal unmet ("), shown both as their own footer row and as a status-line
/// item. Replace them with a capture when one exists.
private enum GoalScreens {
    static let contextLine = "  GPT-6 Rosalind (Research) xhigh · Context 91% left · ~"
    static let hintLine = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 60) + "⚠ 2 warnings · f2 to view"
    static let placeholder = "\u{1b}[2mAsk Codex to do anything\u{1b}[22m"

    static func screen(input: String = placeholder, footer: [String]) -> String {
        (["  Worked for 24s • 5:20 PM", " ", "› " + input, " "] + footer).joined(separator: "\r\n")
    }
}

/// REAL capture: pane 9cc78978 (Codex on GPT-6.2-Astra, idle, stalled goal),
/// relay_read_viewport by the team lead, 2026-11-18 ~06:30Z. Lines verbatim
/// apart from the elided recap text; the viewport carries no SGR, so the
/// native placeholder gets the faint style the screen export carries.
private enum CapturedStalledGoal {
    static let screen = [
        "  Worked for 33s • 05:58" + String(repeating: " ", count: 107),
        " ",
        "  ↳ Recap: The Relay 0.5.111 review found three issues. ...",
        "           Next: d415f009 will hand the fixes to 57c1dd5b for integration into candidate-05111." + String(repeating: " ", count: 36),
        " ", " ", " ",
        "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m",
        " ",
        "  GPT-6.2-Astra high · ~ · Introduce yourself to collaborator",
        "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 43) +
            "Goal stalled (/goal resume) · ⚠ 2 warnings · f2 to view",
    ].joined(separator: "\r\n")
}

@Suite("Codex 0.170 /goal footer")
struct RelayCodexGoalFooterTests {
    private func empty(_ screen: String) -> Bool { RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex") }

    @Test func theBaseScreenIsAnEmptyIdleComposer() {
        #expect(empty(GoalScreens.screen(footer: [GoalScreens.contextLine, GoalScreens.hintLine])))
    }

    @Test func aGoalStillBeingPursuedIsNeverIdleAndIsReasonCoded() throws {
        for footer in [[GoalScreens.contextLine, "  Pursuing goal (12m)", GoalScreens.hintLine],
                       [GoalScreens.contextLine + " · Pursuing goal (1h 4m)", GoalScreens.hintLine]] {
            let screen = GoalScreens.screen(footer: footer)
            #expect(!empty(screen), "\(footer)")
            let blocker = try #require(RelayAgentMaintenancePrompt.codexGoalBlocker(screen))
            #expect(RelayAgentMaintenancePrompt.isGoalBlocker(blocker))
            #expect(blocker.contains("Pursuing goal ("))
            #expect(RelayPaneOperationRefusal.classify(blocker) == .goalActive)
        }
    }

    @Test func aSettledGoalRowDoesNotHoldTheComposer() {
        for row in ["  Goal achieved (1h 2m)", "  Goal unmet (40m)", "  Goal achieved (3m) · /goal to view"] {
            let screen = GoalScreens.screen(footer: [GoalScreens.contextLine, row, GoalScreens.hintLine])
            #expect(empty(screen), "\(row)")
            #expect(RelayAgentMaintenancePrompt.codexGoalBlocker(screen) == nil)
        }
    }

    @Test func aSettledGoalDoesNotHideADraftOrARunningTurn() {
        let footer = [GoalScreens.contextLine, "  Goal achieved (1h 2m)", GoalScreens.hintLine]
        #expect(!empty(GoalScreens.screen(input: "continue the analysis", footer: footer)))
        let running = (["• Working (3s • esc to interrupt)", " ", "› " + GoalScreens.placeholder, " "] + footer)
            .joined(separator: "\r\n")
        #expect(!empty(running))
    }

    @Test func theCapturedStalledGoalScreenIsIdleWithAnInformationalNote() {
        #expect(empty(CapturedStalledGoal.screen))
        #expect(RelayAgentMaintenancePrompt.codexGoalBlocker(CapturedStalledGoal.screen) == nil)
        #expect(RelayAgentMaintenancePrompt.codexGoalNote(CapturedStalledGoal.screen) == "goal_stalled")
        #expect(RelayAgentMaintenancePrompt.codexGoalNote(GoalScreens.screen(footer: [GoalScreens.contextLine, GoalScreens.hintLine])) == nil)
    }

    @Test func theGoalSegmentShareTheHintRowWithOrWithoutWarnings() {
        let hint = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 30)
        #expect(empty(GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Goal stalled (/goal resume)"])))
        #expect(empty(GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Goal stalled (/goal resume) · ⚠ 1 warning · f2 to view"])))
        // Synthesized from the binary's strings, in the captured position.
        #expect(empty(GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Goal achieved (1h 2m) · ⚠ 2 warnings · f2 to view"])))
        let pursuing = GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Pursuing goal (4m) · ⚠ 2 warnings · f2 to view"])
        #expect(!empty(pursuing))
        #expect(RelayAgentMaintenancePrompt.codexGoalBlocker(pursuing) != nil)
        // Anything else in that segment stays unrecognized.
        #expect(!empty(GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Goal stalled (/goal resume) · foo"])))
        #expect(!empty(GoalScreens.screen(footer: [GoalScreens.contextLine, hint + "Goal paused · ⚠ 2 warnings · f2 to view"])))
    }

    @Test func claudeScreensAreUnaffected() {
        #expect(RelayAgentMaintenancePrompt.codexGoalBlocker(nil) == nil)
    }
}

/// REAL capture: pane d415f009 (Codex 0.170.0, GPT-6.2-Sol, idle, stalled
/// goal), relay_read_viewport read-only, 2026-11-18. Bottom rows verbatim; the
/// viewport carries no SGR, so the placeholder gets the faint style.
private enum CapturedStalledGoalD415 {
    static let screen = [
        "• Hook failed",
        "  └ hook timed out after 30s",
        " ",
        "  Worked for 59s • 09:10" + String(repeating: " ", count: 88),
        " ", " ",
        "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m",
        " ",
        "  GPT-6.2-Sol medium · ~/dev/term/work · Complete the task",
        "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 24) +
            "Goal stalled (/goal resume) · ⚠ 3 warnings · f2 to view",
    ].joined(separator: "\r\n")
}

/// 0.5.113 item 2: 9cc78978 and d415f009 were refused on 0.5.112 with "no
/// verified idle empty Codex prompt (busy, draft, approval, ...)". The resume
/// admission uses the same goal classification, and each cause that still
/// holds is named by its own code.
@Suite("Resume idle proof names each blocker")
struct RelayResumePromptBlockerTests {
    static let owner = RelayPromptOwnerBinding(version: 1, paneId: "9cc78978-7791-4d31-8a98-ac29a95d7423", nodeBootId: "b",
        workerPid: 1, workerStart: 2, shellPid: 3, shellStart: 4, provider: "codex", processId: 5, processStart: 6,
        sessionId: "01a1d43d-606c-7f91-8288-edf53495c685", transcriptIdentity: "1:2")
    private func blocker(_ vt: String?, approvals: Int = 0, composerBusy: Bool = false) -> RelayPaneOperationRefusal.Code? {
        TerminalRuntime.agentResumePromptBlocker(expected: Self.owner, vt: vt, pendingApprovals: approvals, composerBusy: composerBusy)?.code
    }

    @Test func bothCapturedStalledGoalPanesAreAdmitted() {
        for screen in [CapturedStalledGoal.screen, CapturedStalledGoalD415.screen] {
            #expect(TerminalRuntime.agentResumePromptAdmits(expected: Self.owner, vt: screen, pendingApprovals: 0, composerBusy: false))
            #expect(blocker(screen) == nil)
            #expect(RelayAgentMaintenancePrompt.codexGoalNote(screen) == "goal_stalled")
        }
    }

    @Test func eachRemainingCauseHasItsOwnCode() {
        let idle = CapturedStalledGoalD415.screen
        #expect(blocker(idle, approvals: 1) == .approvalPending)
        #expect(blocker(idle, composerBusy: true) == .draftPresent)
        #expect(blocker(nil) == .noRendererForIdleProof)
        #expect(blocker(idle.replacingOccurrences(of: "\u{1b}[2mAsk Codex to do anything\u{1b}[22m", with: "continue")) == .draftPresent)
        #expect(blocker(idle.replacingOccurrences(of: "Goal stalled (/goal resume)", with: "Pursuing goal (12m)")) == .goalActive)
        let running = idle.replacingOccurrences(of: "  Worked for 59s • 09:10", with: "• Working (3s • esc to interrupt)")
        #expect(blocker(running) == .turnActive)
    }

    @Test func aSessionMismatchIsTargetSession() {
        let session = UUID(uuidString: Self.owner.sessionId!)!
        let plan = RelayCodexPaneResume.Plan(owner: Self.owner, sessionId: Self.owner.sessionId!, directory: "/w", command: "x", configDir: "/c")
        #expect(RelayCodexPaneResume.sessionRefusal(.init(instance: UUID(), requestID: UUID(), expectedSession: session, targetSession: session), plan: plan) == nil)
        #expect(RelayCodexPaneResume.sessionRefusal(.init(instance: UUID(), requestID: UUID(), expectedSession: UUID(), targetSession: session), plan: plan)?.code == .targetSession)
        #expect(RelayCodexPaneResume.sessionRefusal(.init(instance: UUID(), requestID: UUID(), expectedSession: session, targetSession: UUID()), plan: plan)?.code == .targetSession)
    }
}
