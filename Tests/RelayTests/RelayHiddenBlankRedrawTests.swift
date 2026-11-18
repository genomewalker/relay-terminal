import Foundation
import Testing
@testable import Relay

/// Case f52d610f (0.5.113, 2026-11-18 15:47Z): resuming a hidden Codex pane
/// asked its worker for a fresh screen. The worker reset the screen and sent
/// Codex the redraw signal at the unchanged grid; Codex 0.170 redraws only
/// what changed, so it answered with colour resets and a cursor move and no
/// visible character. The blank screen was accepted as complete and the
/// resume was refused as prompt_unverified, with a misleading how-to-clear.
///
/// Fixtures (Tests/RelayTests/HiddenRedrawFixtures):
/// - f52d610f-blank-fresh-redraw.bin: REAL, the pane's saved screen after
///   that fresh redraw, from its terminal snapshot (header and checksum
///   removed).
/// - codex-0.170-same-grid-redraw.bin / codex-0.170-row-bounce-redraw.bin:
///   REAL, an idle Codex 0.170 started in a scratch pty at 120x40: a reset
///   plus its answer to a same-grid redraw signal, and the same followed by a
///   one-row bounce (39 rows, then 40).
@Suite("A hidden pane's blank fresh redraw is bounced, never proven")
struct RelayHiddenBlankRedrawTests {
    static let owner = RelayPromptOwnerBinding(version: 1, paneId: "f52d610f-8231-45de-b196-307188d47f06", nodeBootId: "b",
        workerPid: 1, workerStart: 2, shellPid: 3, shellStart: 4, provider: "codex", processId: 5, processStart: 6,
        sessionId: "01a1ce7a-1644-7043-8d5d-99dedff5d2cf", transcriptIdentity: "1:2")
    static let viewport = RelayViewport(columns: 120, rows: 40)

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("HiddenRedrawFixtures").appendingPathComponent(name))
    }

    private func screen(_ name: String) async throws -> String? {
        await RelayAgentMaintenanceScreen.read(try fixture(name), viewport: Self.viewport)
    }

    @Test func theCapturedF52dScreenIsBlankAndNamedAsNoScreen() async throws {
        let vt = try await screen("f52d610f-blank-fresh-redraw.bin")
        #expect(TerminalRuntime.screenIsBlank(vt))
        let refusal = TerminalRuntime.agentResumePromptBlocker(expected: Self.owner, vt: vt,
            pendingApprovals: 0, composerBusy: false)
        // Before the fix this was .promptUnverified ("not recognized as idle").
        #expect(refusal?.code == .noRendererForIdleProof)
    }

    @Test func codexDrawsNothingAtAnUnchangedGrid() async throws {
        #expect(TerminalRuntime.screenIsBlank(try await screen("codex-0.170-same-grid-redraw.bin")))
    }

    @Test func aOneRowBounceGivesAnIdleCodexPromptThatIsAdmitted() async throws {
        let vt = try #require(try await screen("codex-0.170-row-bounce-redraw.bin"))
        #expect(!TerminalRuntime.screenIsBlank(vt))
        #expect(vt.contains("Ask Codex to do anything"))
        #expect(TerminalRuntime.agentResumePromptBlocker(expected: Self.owner, vt: vt,
            pendingApprovals: 0, composerBusy: false) == nil)
    }

    @Test func theBounceEndsOnTheOriginalGrid() throws {
        let steps = try #require(TerminalRuntime.hiddenRowBounce(Self.viewport))
        #expect(steps == [RelayViewport(columns: 120, rows: 39), Self.viewport])
        #expect(steps.last == Self.viewport)
        #expect(TerminalRuntime.hiddenRowBounce(RelayViewport(columns: 120, rows: 5)) == nil)
        #expect(TerminalRuntime.hiddenRowBounce(RelayViewport(columns: 19, rows: 40)) == nil)
    }

    @Test func noScreenAndWhitespaceAreBlankButTextIsNot() {
        #expect(TerminalRuntime.screenIsBlank(nil))
        #expect(TerminalRuntime.screenIsBlank(" \r\n  \n"))
        #expect(!TerminalRuntime.screenIsBlank("› "))
    }
}
