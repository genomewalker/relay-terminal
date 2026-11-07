import AppKit
import Foundation
import Testing
@testable import GhosttyTerminal
@testable import Relay

/// Relay 0.5.17 refused same-pane Codex resume on idle panes 28711135 and
/// 635ad56a: the VT export pads the background-filled composer box with
/// spaces that the text API omits, so the viewport projection returned nil
/// and the resume proof saw no screen at all.
@Suite("Codex composer-box resume admission (0.5.17 refusal)")
struct RelayCodexComposerBoxResumeTests {
    private typealias Box = CapturedCodexComposerBox
    private static let owner = RelayPromptOwnerBinding(version: 1, paneId: "28711135-7f19-4eec-ad6e-21a2e6071f82",
        nodeBootId: "8284920b-c5d0-41d4-8e64-9bd95f22886f", workerPid: 1943831, workerStart: 17065417,
        shellPid: 1943890, shellStart: 17065420, provider: "codex", processId: 1136165, processStart: 23954217,
        sessionId: "01a191df-fe35-7b50-81b9-975a551bc209", transcriptIdentity: "70:110087718013")
    private static let placeholder = "\u{1b}[2m\u{1b}[48;2;50;52;56mAsk Codex to do anything"

    private func projected(_ vt: String, _ text: String) -> String? {
        TerminalScreenViewportProjection.project(vt, viewport: text)
    }

    @Test func theCapturedIdleAstraScreenProjectsAndIsEmpty() throws {
        let screen = try #require(projected(Box.astraVT, Box.astraText))
        #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func theCapturedTerraScreenWithoutAContextSegmentIsEmpty() throws {
        let screen = try #require(projected(Box.terraVT, Box.terraText))
        let status = try #require(Box.terraText.split(separator: "\n").last { $0.contains("GPT-6.1 Terra high") })
        #expect(!status.localizedCaseInsensitiveContains("context"))
        #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func aContextFreeStatusLineStillNeedsTheModelAndSeparators() throws {
        let status = "GPT-6.1 Terra high"
        #expect(Box.terraVT.components(separatedBy: status).count == 2)
        for replacement in ["Terra high", "claude-opus high"] {
            let vt = Box.terraVT.replacingOccurrences(of: status, with: replacement)
            let text = Box.terraText.replacingOccurrences(of: status, with: replacement)
            let screen = try #require(projected(vt, text))
            #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"), "\(replacement)")
        }
        let line = "  GPT-6.1 Terra high · ~/Documents/Claude/Projects/Patent · Clarify FARO’s purpose"
        #expect(Box.terraText.contains(line))
        let bare = Box.terraText.replacingOccurrences(of: line, with: "  GPT-6.1 Terra high")
        let rows = Box.terraVT.components(separatedBy: "\r\n")
        let index = try #require(rows.lastIndex { $0.contains(status) })
        var edited = rows; edited[index] = "  " + status
        let screen = try #require(projected(edited.joined(separator: "\r\n"), bare))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    }

    @Test func aDraftOrRunningTurnOnTheContextFreeScreenIsNotEmpty() throws {
        let draft = try #require(projected(
            Box.terraVT.replacingOccurrences(of: Self.placeholder, with: "\u{1b}[48;2;50;52;56mship it"),
            Box.terraText.replacingOccurrences(of: "› Ask Codex to do anything", with: "› ship it")))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(draft, provider: "codex"))
        let box = "\r\n \r\n\u{1b}[0m\u{1b}[48;2;50;52;56m"
        #expect(Box.terraVT.components(separatedBy: box).count == 2)
        let running = try #require(projected(
            Box.terraVT.replacingOccurrences(of: box, with: "\r\n• Working (9s • esc to interrupt)\r\n\u{1b}[0m\u{1b}[48;2;50;52;56m"),
            Box.terraText.replacingOccurrences(of: "\n \n \n› Ask", with: "\n• Working (9s • esc to interrupt)\n \n› Ask")))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(running, provider: "codex"))
    }

    @Test func thePlaceholderWordsWithoutFaintStyleAreADraft() throws {
        #expect(Box.astraVT.contains(Self.placeholder))
        let vt = Box.astraVT.replacingOccurrences(of: Self.placeholder,
            with: "\u{1b}[48;2;50;52;56mAsk Codex to do anything")
        let screen = try #require(projected(vt, Box.astraText))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func aTypedDraftInTheBoxIsNotEmpty() throws {
        let vt = Box.astraVT.replacingOccurrences(of: Self.placeholder,
            with: "\u{1b}[48;2;50;52;56mdelete the release branch")
        let text = Box.astraText.replacingOccurrences(of: "› Ask Codex to do anything", with: "› delete the release branch")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(screen, provider: "codex"))
    }

    @Test func faintTextThatIsNotAPlaceholderIsNotEmpty() throws {
        let vt = Box.astraVT.replacingOccurrences(of: Self.placeholder,
            with: "\u{1b}[2m\u{1b}[48;2;50;52;56mdelete the release branch")
        let text = Box.astraText.replacingOccurrences(of: "› Ask Codex to do anything", with: "› delete the release branch")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    }

    @Test func aRunningTurnAboveTheBoxIsNotEmpty() throws {
        let box = "\r\n \r\n\u{1b}[0m\u{1b}[48;2;50;52;56m"
        #expect(Box.astraVT.components(separatedBy: box).count == 2)
        let vt = Box.astraVT.replacingOccurrences(of: box,
            with: "\r\n• Working (3s • esc to interrupt)\r\n\u{1b}[0m\u{1b}[48;2;50;52;56m")
        let text = Box.astraText.replacingOccurrences(of: "\n \n \n› Ask", with: "\n• Working (3s • esc to interrupt)\n \n› Ask")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    }

    @Test func anApprovalChoiceInPlaceOfTheComposerIsNotEmpty() throws {
        let vt = Box.astraVT.replacingOccurrences(of: Self.placeholder,
            with: "\u{1b}[48;2;50;52;56m1. Yes, proceed (y)")
        let text = Box.astraText.replacingOccurrences(of: "› Ask Codex to do anything", with: "› 1. Yes, proceed (y)")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    }

    @Test func aBackgroundTerminalRowInTheFooterIsNotEmpty() throws {
        let hint = "\r\n  \u{1b}[0m\u{1b}[1m\u{1b}[38;2;230;230;230m←"
        #expect(Box.astraVT.components(separatedBy: hint).count == 2)
        let vt = Box.astraVT.replacingOccurrences(of: hint, with: "\r\n  1 background terminal running · /ps to view" + hint)
        let text = Box.astraText.replacingOccurrences(of: "\n  ← for agents", with: "\n  1 background terminal running · /ps to view\n  ← for agents")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    }

    @Test func onlyTrailingSpacesMayDiffer() {
        // One changed word in the text only: the export proves nothing.
        let changed = Box.astraText.replacingOccurrences(of: "Context 61% left", with: "Context 62% left")
        #expect(projected(Box.astraVT, changed) == nil)
        // A leading or inner space is content, not padding.
        #expect(projected("a b  \r\nc", "ab\nc") == nil)
        #expect(projected(" ab\r\nc", "ab\nc") != nil) // tail of a longer first row
        #expect(projected("ab\r\nc", "ab\n c") == nil)
        #expect(projected("ab   \r\nc  ", "ab\nc") == "ab   \r\nc  ")
        #expect(projected("ab\r\nc", "ab\nc\nd") == nil)
        #expect(projected("ab\r\nc\r\nd", "c\nx") == nil)
    }

    /// Codex hides its placeholder once anything is typed, so a draft of
    /// spaces is "›" and blanks: never idle-empty, for resume or for
    /// maintenance/rotation (`agentEmpty` and `agentEmptyIgnoringAgents`).
    @Test func aSpaceOnlyDraftInTheCapturedBoxIsNotEmpty() throws {
        for (vt, text) in [(Box.astraVT, Box.astraText), (Box.terraVT, Box.terraText)] {
            #expect(vt.contains(Self.placeholder))
            let spaces = vt.replacingOccurrences(of: Self.placeholder,
                with: "\u{1b}[48;2;50;52;56m" + String(repeating: " ", count: 3))
            let blank = text.replacingOccurrences(of: "› Ask Codex to do anything", with: "›    ")
            let screen = try #require(projected(spaces, blank))
            #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
            #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex", explainedAgents: .max))
            // Also no admission through the agent resume screen check.
            #expect(!TerminalRuntime.agentResumePromptAdmits(expected: Self.owner, vt: screen,
                pendingApprovals: 0, composerBusy: false))
        }
    }

    @Test func aModelRowWithoutAHintRowIsNotEmpty() throws {
        let rows = Box.astraVT.components(separatedBy: "\r\n")
        let hint = try #require(rows.lastIndex { $0.contains("for shortcuts") })
        #expect(hint == rows.count - 1)
        let vt = rows.dropLast().joined(separator: "\r\n")
        let text = Box.astraText.split(separator: "\n", omittingEmptySubsequences: false).dropLast().joined(separator: "\n")
        let screen = try #require(projected(vt, text))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        // The hint row alone, without the model row above it, is not a footer either.
        let noModel = rows.enumerated().filter { $0.offset != hint - 1 }.map(\.element).joined(separator: "\r\n")
        let noModelText = Box.astraText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("GPT-6-Astra medium") }.joined(separator: "\n")
        let alone = try #require(projected(noModel, noModelText))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(alone, provider: "codex"))
    }

    /// The same shape through the real ghostty export and text API: a box
    /// row filled by erase-in-line with a background colour.
    @MainActor
    @Test func aBackgroundFilledComposerThroughTheNativeExportIsEmpty() async throws {
        _ = NSApplication.shared
        let viewport = RelayViewport(columns: 100, rows: 12)
        let bg = "\u{1b}[48;2;50;52;56m"
        func frame(_ input: String) -> String {
            "\u{1b}[2J\u{1b}[H• Finished the review.\r\n\r\n" +
            bg + " \u{1b}[K\r\n" +
            bg + "\u{1b}[1m›\u{1b}[22m " + input + "\u{1b}[K\r\n" +
            bg + " \u{1b}[K\u{1b}[0m\r\n" +
            "  GPT-6-Astra medium · Context 61% left · /maps/projects/x\r\n" +
            "  ← for agents · ? for shortcuts"
        }
        let idle = try #require(await RelayAgentMaintenanceScreen.read(
            Data(frame("\u{1b}[2mAsk Codex to do anything\u{1b}[22m").utf8), viewport: viewport))
        #expect(RelayAgentMaintenancePrompt.isEmpty(idle, provider: "codex"), "\(String(reflecting: idle))")
        let draft = try #require(await RelayAgentMaintenanceScreen.read(
            Data(frame("rm -rf build").utf8), viewport: viewport))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(draft, provider: "codex"))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(draft, provider: "codex"))
        let spaces = try #require(await RelayAgentMaintenanceScreen.read(
            Data(frame("   ").utf8), viewport: viewport))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(spaces, provider: "codex"), "\(String(reflecting: spaces))")
        #expect(!RelayAgentMaintenancePrompt.isEmpty(spaces, provider: "codex", explainedAgents: .max))
    }
}
