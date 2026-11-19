import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

/// Claude Code 2.1.327's real composer, captured 2026-11-19 on dandy-07 in a
/// 120x40 pty (Tests/RelayTests/ClaudeComposerFixtures). Relay's installed
/// input journal showed every refused prompt click (138, against 5 for Codex)
/// in Claude panes: the prompt mirror could not be recovered from Claude's
/// rendered row, so mouse selection, Delete, Cut and Copy had no exact range.
///
/// marks.json gives byte offsets after each step: start (idle composer),
/// typed ("hello selection test words"), left5 (caret five cells left),
/// wrapped, newline (Option-Enter), second_line.
final class ComposerInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
}

@MainActor
@Suite("Claude 2.1.327 composer mouse selection edits exactly", .serialized)
struct TerminalClaudeComposerSelectionTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("ClaudeComposerFixtures")

    static func capture(through mark: String) throws -> Data {
        let data = try Data(contentsOf: directory.appendingPathComponent("claude-2.1.327-composer.bin"))
        let marks = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("marks.json")))
            as? [[Any]] ?? []
        let end = try #require(marks.first { ($0.first as? String) == mark }?.last as? Int)
        return data.prefix(end)
    }

    struct Fixture {
        let recorder: ComposerInputRecorder
        let session: InMemoryTerminalSession
        let pane: PaneModel
        let view: RelayGhosttyView
        let window: NSWindow
        let release: @MainActor () -> Void
    }

    static let profile = ConnectionProfile(name: "Claude composer", kind: .local, backend: .direct)

    /// Exactly the capture's 120x40 grid: Claude addresses rows absolutely.
    func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let recorder = ComposerInputRecorder()
        let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        let pane = PaneModel(profile: Self.profile)
        pane.setAgentKind(.claude)
        let view = pane.runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 652)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let runtime = pane.runtime
        let lease = UUID()
        let generation = runtime.beginPresentationAttachment(lease: lease)
        runtime.setPresented(true, lease: lease, generation: generation)
        runtime.setKeyboardFocusEligible(true)
        runtime.view.setSurfaceVisible(true)
        window.makeKeyAndOrderFront(nil)
        view.fitToSize()
        // Resize to exactly 120x40 cells, correcting by whole cells.
        for _ in 0..<6 {
            let metrics = try #require(view.currentGridMetrics())
            if metrics.columns == 120 && metrics.rows == 40 { break }
            let scale = window.backingScaleFactor
            let cellW = CGFloat(metrics.cellWidthPixels) / scale, cellH = CGFloat(metrics.cellHeightPixels) / scale
            let size = NSSize(width: view.bounds.width + CGFloat(120 - Int(metrics.columns)) * cellW,
                              height: view.bounds.height + CGFloat(40 - Int(metrics.rows)) * cellH)
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.fitToSize()
        }
        #expect(window.makeFirstResponder(view))
        return Fixture(recorder: recorder, session: session, pane: pane, view: view, window: window, release: {
            runtime.endPresentationAttachment(lease: lease, generation: generation)
            window.orderOut(nil); window.contentView = nil
        })
    }

    func show(_ f: Fixture, _ data: Data) async {
        // Claude moves relative to the grid; parse only at the captured size.
        for _ in 0..<200 {
            if let state = f.session.screenState, state.columns == 120, state.rows == 40 { break }
            f.view.fitToSize(); f.view.synchronizeAndRedraw()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.session.screenState?.columns == 120 && f.session.screenState?.rows == 40,
                "session grid \(String(describing: f.session.screenState))")
        f.session.receive(data)
        await Task.detached { f.session.waitForPendingOutput() }.value
        f.view.synchronizeAndRedraw()
    }

    /// The 0-based (row, column) of the capture's final cursor position.
    static func finalCursor(_ data: Data) throws -> (row: Int, column: Int) {
        let text = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "\u{1B}\\[(\\d+);(\\d+)H")
        let match = try #require(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last)
        let row = Int((text as NSString).substring(with: match.range(at: 1)))!
        let column = Int((text as NSString).substring(with: match.range(at: 2)))!
        return (row - 1, column - 1)
    }

    /// Drags between the centres of two absolute cells (0-based row, column).
    func drag(_ f: Fixture, caretAt caretCell: (row: Int, column: Int),
              from: (row: Int, column: Int), to: (row: Int, column: Int)) throws {
        let caret = f.view.convert(f.window.convertFromScreen(f.view.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0), actualRange: nil)), from: nil)
        let metrics = try #require(f.view.currentGridMetrics())
        #expect(metrics.columns == 120 && metrics.rows == 40, "grid \(metrics.columns)x\(metrics.rows)")
        let width = CGFloat(metrics.cellWidthPixels) / f.window.backingScaleFactor
        let height = CGFloat(metrics.cellHeightPixels) / f.window.backingScaleFactor
        // The IME rect lies one row below the caret's text row.
        let caretRowMidY = caret.minY + height * 1.5
        // Start in the left quarter of the first cell and end in the right
        // quarter of the last, so both cells are inside the selection.
        func point(_ cell: (row: Int, column: Int), fraction: CGFloat) -> NSPoint {
            f.view.convert(NSPoint(x: caret.minX + CGFloat(cell.column - caretCell.column) * width + width * fraction,
                                   y: caretRowMidY + CGFloat(caretCell.row - cell.row) * height), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
        }
        let now = ProcessInfo.processInfo.systemUptime
        f.view.mouseDown(with: try mouse(.leftMouseDown, point(from, fraction: 0.0), now))
        f.view.mouseDragged(with: try mouse(.leftMouseDragged, point(to, fraction: 1.0), now + 0.01))
        f.view.mouseUp(with: try mouse(.leftMouseUp, point(to, fraction: 1.0), now + 0.02))
    }

    func pressDelete(_ f: Fixture) async throws -> Data {
        let before = f.recorder.data.count
        let deletion = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber, context: nil,
            characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}", isARepeat: false, keyCode: 51))
        f.view.keyDown(with: deletion)
        try await Task.sleep(for: .milliseconds(40))
        return Data(f.recorder.data.dropFirst(before))
    }

    func withClipboard<T>(_ body: () async throws -> T) async rethrows -> T {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
        pasteboard.clearContents(); pasteboard.setString("unchanged clipboard", forType: .string)
        return try await body()
    }

    // "❯ hello selection test words" is on the caret row; "selection" is
    // columns 8...16, and both end cells are inside the drag.

    func copySelection(_ f: Fixture, cut: Bool = false) async -> String? {
        await withClipboard { () -> String? in
            #expect(f.view.handleApplicationClipboardAction(cut ? .cut : .copy))
            return NSPasteboard.general.string(forType: .string)
        }
    }

    /// Types locally, then shows Claude's real echo of each step. A nil text
    /// sends the five Left arrows the capture sent.
    func liveTyped(_ f: Fixture, typing: [(text: String?, after: String)]) async throws -> Data {
        var shown = try Self.capture(through: "start")
        await show(f, shown)
        for step in typing {
            if let text = step.text {
                f.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                let arrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
                for _ in 0..<5 {
                    f.view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: f.window.windowNumber, context: nil, characters: arrow,
                        charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 123)))
                }
            }
            let next = try Self.capture(through: step.after)
            await show(f, next.dropFirst(shown.count))
            shown = next
        }
        return shown
    }

    @Test(arguments: ["copy", "delete", "cut"])
    func aLiveTypedDraftEditsTheDraggedWord(action: String) async throws {
        let f = try makeFixture(); defer { f.release() }
        let shown = try await liveTyped(f, typing: [("hello selection test words", "typed")])
        let caret = try Self.finalCursor(shown)
        #expect(caret.column == 28)
        let before = f.recorder.data.count
        try drag(f, caretAt: caret, from: (caret.row, 8), to: (caret.row, 16))
        switch action {
        case "copy":
            #expect(await copySelection(f) == "selection")
        case "delete":
            let edit = try await pressDelete(f)
            #expect(edit.filter { $0 == 0x7F }.count == 9, "delete sent \(Array(edit))")
        default:
            #expect(await copySelection(f, cut: true) == "selection")
            try await Task.sleep(for: .milliseconds(40))
            #expect(Data(f.recorder.data.dropFirst(before)).filter { $0 == 0x7F }.count == 9)
        }
    }

    /// A draft Relay did not type (accepted suggestion, history, queued
    /// prompt) under the reliable empty mirror every submit leaves: the
    /// journal's mirror_reliable=true state. Recovery reads the real row.
    @Test(arguments: ["copy", "delete"])
    func aProviderDraftUnderAnEmptyMirrorEditsTheDraggedWord(action: String) async throws {
        let f = try makeFixture(); defer { f.release() }
        let shown = try Self.capture(through: "typed")
        await show(f, shown)
        let caret = try Self.finalCursor(shown)
        try drag(f, caretAt: caret, from: (caret.row, 8), to: (caret.row, 16))
        if action == "copy" {
            #expect(await copySelection(f) == "selection")
        } else {
            let edit = try await pressDelete(f)
            #expect(edit.filter { $0 == 0x7F }.count == 9, "delete sent \(Array(edit))")
        }
    }

    /// Claude wraps a long draft itself and indents its continuation row by
    /// two spaces with no "❯" (the journal's reason=prefix when it is the
    /// caret row). A word on the first row still copies exactly.
    @Test func aWrappedLiveDraftCopiesAWordOnItsFirstRow() async throws {
        let f = try makeFixture(); defer { f.release() }
        let long = " and then a much longer continuation that will certainly wrap past the right edge of a one hundred twenty column terminal row"
        let shown = try await liveTyped(f, typing: [
            ("hello selection test words", "typed"), (nil, "left5"), (long, "wrapped")])
        let caret = try Self.finalCursor(shown)
        let row = caret.row - 1
        #expect((f.session.readViewportRows() ?? []).indices.contains(row))
        try drag(f, caretAt: caret, from: (row, 8), to: (row, 16))
        #expect(await copySelection(f) == "selection")
    }

    /// The recovery journal carries a row's shape, never its text.
    @Test func rowShapeNamesOnlySymbols() {
        #expect(TerminalPromptSelectionEdit.rowShape("❯\u{00A0}hello") == (0, "U+276F"))
        #expect(TerminalPromptSelectionEdit.rowShape("  continuation") == (2, "text"))
        #expect(TerminalPromptSelectionEdit.rowShape("   ") == (3, "blank"))
        #expect(TerminalPromptSelectionEdit.rowShape("7 items") == (0, "text"))
    }
}
