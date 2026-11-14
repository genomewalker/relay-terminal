#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

/// Keyboard selection in a multi-line provider composer: the on-screen
/// highlight and the copied text, with arrow presses as fast as key repeat.
@Suite(.serialized)
struct TerminalMultilinePromptSelectionTests {
    private static let line1 = "0123456789abcdefghijklmnopqrstuvwxyzABCD"
    private static let line2 = "second line"

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let view: RelayGhosttyView
        let release: () -> Void

        init(agent: AgentKind) async throws {
            _ = NSApplication.shared
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let pane = PaneModel(profile: ConnectionProfile(name: "Multiline", kind: .local, backend: .direct))
            pane.setAgentKind(agent)
            view = pane.runtime.view
            view.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            let runtime = pane.runtime
            let lease = UUID()
            let generation = runtime.beginPresentationAttachment(lease: lease)
            runtime.setPresented(true, lease: lease, generation: generation)
            runtime.setKeyboardFocusEligible(true)
            view.setSurfaceVisible(true)
            release = { runtime.endPresentationAttachment(lease: lease, generation: generation); _ = pane }
            window.makeKeyAndOrderFront(nil)
            view.fitToSize()
            #expect(window.makeFirstResponder(view))
            session.receive("\u{1B}[?2004h\u{1B}[>1u")
            // The in-memory surface can be rebuilt while the first output is
            // parsed, which leaves the cursor partway through that output.
            // Settle on a first clear so the composer paint lands on the
            // final surface and the cursor ends where the paint ends.
            session.receive("\u{1B}[2J\u{1B}[H")
            await Task.detached { session.waitForPendingOutput() }.value
            view.synchronizeAndRedraw()
            try await Task.sleep(for: .milliseconds(300))
            view.setShellPromptActive(true)

            // Type the draft so Relay's mirror holds it, then paint the
            // provider composer: hard rows with a two-cell hanging indent.
            view.insertText(Self.line1, replacementRange: NSRange(location: NSNotFound, length: 0))
            let shiftEnter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            #expect(view.performKeyEquivalent(with: shiftEnter))
            view.insertText(Self.line2, replacementRange: NSRange(location: NSNotFound, length: 0))
            let columns = Int(try #require(view.currentGridMetrics()).columns)
            #expect(columns == 17)
            let glyph = agent == .claude ? "❯ " : "› "
            var rows: [String] = []
            for (index, logical) in [Self.line1, Self.line2].enumerated() {
                var rest = Substring(logical)
                var first = true
                repeat {
                    let chunk = rest.prefix(columns - 2)
                    rest = rest.dropFirst(chunk.count)
                    rows.append((index == 0 && first ? glyph : "  ") + chunk)
                    first = false
                } while !rest.isEmpty
            }
            session.receive("\u{1B}[2J\u{1B}[H" + rows.joined(separator: "\r\n"))
            await Task.detached { session.waitForPendingOutput() }.value
            view.synchronizeAndRedraw()
            try await Task.sleep(for: .milliseconds(30))
        }

        private static var line1: String { TerminalMultilinePromptSelectionTests.line1 }
        private static var line2: String { TerminalMultilinePromptSelectionTests.line2 }

        /// Shift-Left `count` times with no pause, as key repeat sends them.
        func selectLeft(_ count: Int) throws {
            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            for _ in 0..<count {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: left, charactersIgnoringModifiers: left, isARepeat: false, keyCode: 123))
                #expect(view.performKeyEquivalent(with: event))
            }
        }

        func close() {
            release()
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// On screen, a selection that crosses rows includes each row's indent.
    @MainActor
    @Test("Fast Shift-Left highlights exactly the selected cells across wrapped rows and lines",
          .timeLimit(.minutes(1)),
          arguments: [AgentKind.codex, .claude], [
              (5, " line"),
              (11, "second line"),
              (13, "D\n  second line"),
              (14, "CD\n  second line"),
              (17, "zABCD\n  second line"),
              (26, "qrst\n  uvwxyzABCD\n  second line"),
          ])
    func highlight(agent: AgentKind, selection: (count: Int, onScreen: String)) async throws {
        let fixture = try await Fixture(agent: agent)
        defer { fixture.close() }
        try fixture.selectLeft(selection.count)
        #expect(fixture.view.selectedText() == selection.onScreen)
    }

    /// Copy takes the logical draft, without the composer's indent.
    @MainActor
    @Test("Copy of a multi-line selection uses the draft within a line and across the newline",
          .timeLimit(.minutes(1)),
          arguments: [AgentKind.codex, .claude], [
              (5, " line"),
              (17, "zABCD\nsecond line"),
              (26, "qrstuvwxyzABCD\nsecond line"),
          ])
    func copy(agent: AgentKind, selection: (count: Int, copied: String)) async throws {
        let fixture = try await Fixture(agent: agent)
        defer { fixture.close() }
        try fixture.selectLeft(selection.count)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        pasteboard.clearContents()
        #expect(fixture.view.handleApplicationClipboardAction(.copy))
        #expect(pasteboard.string(forType: .string) == selection.copied)
    }
}
#endif
