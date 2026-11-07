import AppKit
import Foundation
import Testing
@testable import Relay

/// Relay 0.5.18 held a same-pane Codex resume on pane 5408bcd5: after Codex
/// exited, the retained shell showed a box prompt whose info rows sit
/// between the header and the closing row, and the recognizer required the
/// header directly above "╰─ ❯ ". These screens go through the real ghostty
/// VT export, as the resume proof reads them.
@Suite("Retained shell box prompt recognition (0.5.18 hold)")
struct RelayRetainedShellBoxPromptTests {
    static let header = "╭─ SUN1028888 · ~/dev/term"
    /// The live prompt, exactly as relay_read_viewport returned it.
    static let live = header + "\r\ngit:main ~ ↑18\r\nenv:bioinfo\r\n╰─ ❯ "

    @MainActor
    private func exported(_ screen: String, columns: Int = 100) async throws -> String {
        _ = NSApplication.shared
        return try #require(await RelayAgentMaintenanceScreen.read(Data(("\u{1b}[2J\u{1b}[H" + screen).utf8),
            viewport: RelayViewport(columns: columns, rows: 14)))
    }

    @MainActor
    private func classify(_ screen: String, columns: Int = 100) async throws -> RelayAgentMaintenancePrompt.RetainedShellPrompt {
        RelayAgentMaintenancePrompt.retainedShellPrompt(try await exported(screen, columns: columns))
    }

    @MainActor @Test func theLiveFourRowPromptIsEmpty() async throws {
        #expect(try await classify(Self.live) == .empty)
    }

    @MainActor @Test func infoOnTheHeaderRowIsEmpty() async throws {
        #expect(try await classify(Self.header + " git:main ~ ↑18 env:bioinfo\r\n╰─ ❯ ") == .empty)
    }

    /// A narrow pane soft-wraps the header; the export rejoins it.
    @MainActor @Test func aSoftWrappedHeaderIsEmpty() async throws {
        let screen = Self.header + " git:main ~ ↑18 env:bioinfo\r\n╰─ ❯ "
        #expect(try await classify(screen, columns: 24) == .empty)
    }

    @MainActor @Test func aStyledLivePromptIsEmpty() async throws {
        let styled = "\u{1b}[36m╭─\u{1b}[0m SUN1028888 · ~/dev/term\r\n\u{1b}[35mgit:main\u{1b}[0m ~ ↑18\r\n" +
            "\u{1b}[33menv:bioinfo\u{1b}[0m\r\n\u{1b}[36m╰─\u{1b}[0m \u{1b}[32m❯\u{1b}[0m "
        #expect(try await classify(styled) == .empty)
    }

    /// A shell shows a suggestion only after typed text, and a theme may draw
    /// typed text grey or dim: anything after the separator is a draft.
    @MainActor @Test func faintOrGreyTextAfterTheMarkerIsTyped() async throws {
        for styled in ["\u{1b}[90mcd ~/dev\u{1b}[39m", "\u{1b}[38;2;128;128;128mrm -rf build\u{1b}[39m",
                       "\u{1b}[38;5;8mrm -rf build\u{1b}[39m", "\u{1b}[2mrm -rf build\u{1b}[22m"] {
            #expect(try await classify(Self.live + styled) == .typed, "\(String(reflecting: styled))")
        }
    }

    @MainActor @Test func aTypedCommandIsTyped() async throws {
        #expect(try await classify(Self.live + "codex resume 01a1") == .typed)
    }

    /// The Codex M1 rule for the shell: only spaces typed is a draft.
    @MainActor @Test func spacesTypedAfterThePromptAreTyped() async throws {
        #expect(try await classify(Self.live + "   ") == .typed)
        #expect(try await classify(Self.live + " ") == .typed)
    }

    @MainActor @Test func refusedShapesAreUnrecognized() async throws {
        let cases: [(String, String)] = [
            ("output below the prompt", Self.live + "\r\nrunning output"),
            ("top row missing", "git:main ~ ↑18\r\nenv:bioinfo\r\n╰─ ❯ "),
            ("seven info rows", Self.header + "\r\n" + (1...7).map { "info \($0)" }.joined(separator: "\r\n") + "\r\n╰─ ❯ "),
            ("blank row inside the box", Self.header + "\r\ngit:main\r\n\r\nenv:bioinfo\r\n╰─ ❯ "),
            ("different glyph", Self.header + "\r\ngit:main ~ ↑18\r\nenv:bioinfo\r\n╰─ > "),
            ("header without separator", "╭─ SUN1028888 ~/dev/term\r\ngit:main\r\n╰─ ❯ "),
            ("an older closed prompt between", Self.header + "\r\n╰─ ❯ ls\r\nREADME.md\r\n╰─ ❯ "),
        ]
        for (name, screen) in cases {
            #expect(try await classify(screen) == .unrecognized, "\(name)")
        }
    }

    /// The export carries no cursor, so a submitted command still running
    /// reads like typed text: never empty, and only clearable.
    @MainActor @Test func aCommandStillRunningIsNeverEmpty() async throws {
        #expect(try await classify(Self.live + "sleep 30\r\n") != .empty)
        #expect(try await classify(Self.live + "sleep 30\r\n\u{1b}[?25l") != .empty)
    }

    @MainActor @Test func sixInfoRowsAreTheBound() async throws {
        let screen = Self.header + "\r\n" + (1...6).map { "info \($0)" }.joined(separator: "\r\n") + "\r\n╰─ ❯ "
        #expect(try await classify(screen) == .empty)
    }
}
