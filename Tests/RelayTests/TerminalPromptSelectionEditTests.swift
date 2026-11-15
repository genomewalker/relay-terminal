#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

/// Copy, cut, delete, type-over and paste-over a keyboard selection in a
/// multi-line provider composer, then select again. A fake provider applies
/// the bytes Relay writes to a logical draft and repaints the composer after
/// every write, so each assertion is against the draft a real provider would
/// hold, not against Relay's own mirror.
@Suite(.serialized)
struct TerminalPromptSelectionEditTests {
    static let line1 = "0123456789abcdefghijklmnopqrstuvwxyzABCD"
    static let line2 = "second line"
    static var full: String { line1 + "\n" + line2 }

    /// A minimal provider line editor: printable text, Backspace, Delete,
    /// Left/Right, Shift-Enter (Kitty CSI 13;2u) and bracketed paste.
    final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var pasting: Data?
        private(set) var draft: [Character] = []
        private(set) var cursor = 0
        private(set) var unknown: [String] = []
        private(set) var submitted = 0

        func snapshot() -> (draft: String, cursor: Int, unknown: [String], submitted: Int) {
            lock.lock(); defer { lock.unlock() }
            return (String(draft), cursor, unknown, submitted)
        }

        func feed(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            var bytes = [UInt8](pending)
            var index = 0
            var text = [UInt8]()
            func flushText() {
                guard !text.isEmpty else { return }
                insert(String(decoding: text, as: UTF8.self))
                text.removeAll()
            }
            parsing: while index < bytes.count {
                if var paste = pasting {
                    let rest = Data(bytes[index...])
                    let end = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
                    guard let range = rest.range(of: end) else {
                        paste.append(rest); pasting = paste
                        index = bytes.count
                        break parsing
                    }
                    paste.append(rest[rest.startIndex..<range.lowerBound])
                    insert(String(decoding: paste, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n"))
                    pasting = nil
                    index += range.upperBound - rest.startIndex
                    continue
                }
                let byte = bytes[index]
                if byte == 0x1B {
                    flushText()
                    guard index + 1 < bytes.count else { break parsing }
                    guard bytes[index + 1] == 0x5B else { unknown.append("ESC \(bytes[index + 1])"); index += 2; continue }
                    var end = index + 2
                    while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                    guard end < bytes.count else { break parsing }
                    let params = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
                    let final = Character(UnicodeScalar(bytes[end]))
                    index = end + 1
                    let fields = params.split(separator: ";").map(String.init)
                    switch final {
                    case "D": cursor = max(0, cursor - 1)
                    case "C": cursor = min(draft.count, cursor + 1)
                    case "~" where fields.first == "3": if cursor < draft.count { draft.remove(at: cursor) }
                    case "~" where fields.first == "200": pasting = Data()
                    case "u":
                        let key = Int(fields.first?.split(separator: ":").first ?? "") ?? -1
                        let modifiers = fields.count > 1 ? Int(fields[1].split(separator: ":").first ?? "") ?? 1 : 1
                        if key == 127 { backspace() }
                        else if key == 13, (modifiers - 1) & 1 == 1 { insert("\n") }
                        else if key == 13 { submitted += 1 }
                        else if let scalar = UnicodeScalar(key), key >= 32 { insert(String(Character(scalar))) }
                        else { unknown.append("CSI \(params)u") }
                    default: unknown.append("CSI \(params)\(final)")
                    }
                    continue
                }
                if byte == 0x7F || byte == 0x08 { flushText(); backspace(); index += 1; continue }
                if byte == 0x0D { flushText(); submitted += 1; index += 1; continue }
                if byte < 0x20 { flushText(); unknown.append("C0 \(byte)"); index += 1; continue }
                text.append(byte); index += 1
            }
            flushText()
            bytes.removeFirst(min(index, bytes.count))
            pending = Data(bytes)
        }

        private func insert(_ string: String) {
            for character in string { draft.insert(character, at: cursor); cursor += 1 }
        }

        private func backspace() {
            guard cursor > 0 else { return }
            cursor -= 1; draft.remove(at: cursor)
        }

        /// The composer as Claude and Codex paint it: hard rows with a
        /// two-cell hanging indent, and the cursor at the logical caret.
        func paint(columns: Int, glyph: String) -> String {
            let state = snapshot()
            let width = columns - 2
            var rows: [String] = []
            var caret: (row: Int, column: Int)?
            var offset = 0
            for (index, logical) in state.draft.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let characters = Array(logical)
                var start = 0
                repeat {
                    let chunk = characters[start..<min(start + width, characters.count)]
                    if caret == nil, state.cursor >= offset + start, state.cursor < offset + start + width,
                       state.cursor <= offset + characters.count {
                        caret = (rows.count + 1, 3 + state.cursor - offset - start)
                    }
                    rows.append((index == 0 && start == 0 ? glyph : "  ") + String(chunk))
                    start += width
                } while start < characters.count
                offset += characters.count + 1
            }
            let position = caret ?? (rows.count, 3 + (rows.last.map { $0.count - 2 } ?? 0))
            return "\u{1B}[2J\u{1B}[H" + rows.joined(separator: "\r\n") + "\u{1B}[\(position.row);\(position.column)H"
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    }

    @MainActor
    final class Fixture {
        let window: NSWindow
        let view: RelayGhosttyView
        let pane: PaneModel
        let provider = Provider()
        let recorder = Recorder()
        let session: InMemoryTerminalSession
        private let release: () -> Void
        private var painter: Task<Void, Never>?
        private var consumed = 0
        private(set) var columns = 0
        let glyph: String

        init(agent: AgentKind, lines: [String] = [TerminalPromptSelectionEditTests.line1, TerminalPromptSelectionEditTests.line2]) async throws {
            _ = NSApplication.shared
            let recorder = recorder
            session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
            pane = PaneModel(profile: ConnectionProfile(name: "Selection edits", kind: .local, backend: .direct))
            pane.setAgentKind(agent)
            glyph = agent == .claude ? "❯ " : "› "
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
            let pane = pane
            release = { runtime.endPresentationAttachment(lease: lease, generation: generation); _ = pane }
            window.makeKeyAndOrderFront(nil)
            view.fitToSize()
            #expect(window.makeFirstResponder(view))
            session.receive("\u{1B}[?2004h\u{1B}[>1u")
            // The surface can be rebuilt while the first output is parsed.
            session.receive("\u{1B}[2J\u{1B}[H")
            await drain()
            try await Task.sleep(for: .milliseconds(300))
            columns = Int(try #require(view.currentGridMetrics()).columns)
            #expect(columns == 17)
            session.receive(provider.paint(columns: columns, glyph: glyph))
            await drain()
            view.setShellPromptActive(true)
            painter = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.pump()
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            for (index, line) in lines.enumerated() {
                if index > 0 { press(try key("\r", 36, modifiers: .shift)) }
                try type(line)
            }
            try await settle()
            #expect(provider.snapshot().draft == lines.joined(separator: "\n"),
                    "written: \(String(decoding: recorder.data, as: UTF8.self).debugDescription) unknown: \(provider.snapshot().unknown)")
        }

        private func drain() async {
            let session = session
            await Task.detached { session.waitForPendingOutput() }.value
            view.synchronizeAndRedraw()
        }

        /// Apply every new byte to the provider and repaint the composer.
        private func pump() async {
            let data = recorder.data
            guard data.count > consumed else { return }
            provider.feed(data.subdata(in: consumed..<data.count))
            consumed = data.count
            session.receive(provider.paint(columns: columns, glyph: glyph))
            await drain()
        }

        /// Wait until the provider has applied all input and painted it.
        func settle() async throws {
            for _ in 0..<200 {
                await pump()
                try await Task.sleep(for: .milliseconds(20))
                if recorder.data.count == consumed {
                    try await Task.sleep(for: .milliseconds(60))
                    if recorder.data.count == consumed { return }
                }
            }
            Issue.record("Provider never settled")
        }

        func key(_ characters: String, _ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }

        /// Press a key the way AppKit delivers it: key equivalent first.
        func press(_ event: NSEvent) {
            if !view.performKeyEquivalent(with: event) { view.keyDown(with: event) }
        }

        /// Type each character as its own key press, as a user does.
        func type(_ text: String) throws {
            for character in text { press(try key(String(character), 0)) }
        }

        func selectLeft(_ count: Int) throws {
            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            for _ in 0..<count { press(try key(left, 123, modifiers: .shift)) }
        }

        func close() {
            painter?.cancel()
            release()
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    enum SelectionEdit: String, CaseIterable, CustomStringConvertible {
        case copy, cut, backspace, forwardDelete, type, paste
        var description: String { rawValue }
    }

    /// Every pasteboard item, so a test can put back exactly what was there.
    @MainActor
    static func savePasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Put the saved items back only while the pasteboard still holds what
    /// this test last left there. If anything else copied meanwhile (the user
    /// keeps working while tests run), leave that newer copy alone.
    @MainActor
    static func restorePasteboard(_ saved: [[(NSPasteboard.PasteboardType, Data)]], ifStill changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }

    @MainActor
    @Test("A selection edit leaves the provider with the right draft, and selection still works after it",
          .timeLimit(.minutes(3)),
          arguments: [AgentKind.codex, .claude], [5, 14, 26])
    func editsOverSelection(agent: AgentKind, count: Int) async throws {
        for edit in SelectionEdit.allCases {
            let fixture = try await Fixture(agent: agent)
            defer { fixture.close() }
            let full = Self.full
            let selected = String(full.suffix(count))
            let remaining = String(full.dropLast(count))
            try fixture.selectLeft(count)
            let expected: String
            let saved = Self.savePasteboard()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var ours = pasteboard.changeCount
            defer { Self.restorePasteboard(saved, ifStill: ours) }
            do {
                switch edit {
                case .copy:
                    #expect(fixture.view.handleApplicationClipboardAction(.copy), "\(edit)")
                case .cut:
                    #expect(fixture.view.handleApplicationClipboardAction(.cut), "\(edit)")
                case .backspace:
                    fixture.press(try fixture.key("\u{7F}", 51))
                case .forwardDelete:
                    fixture.press(try fixture.key(String(UnicodeScalar(NSDeleteFunctionKey)!), 117))
                case .type:
                    try fixture.type("XY")
                case .paste:
                    pasteboard.setString("PASTED", forType: .string)
                    ours = pasteboard.changeCount
                    #expect(fixture.view.handleApplicationClipboardAction(.paste), "\(edit)")
                }
                let written = pasteboard.changeCount
                try await fixture.settle()
                // Something outside the test copied meanwhile: the result is
                // not this test's, and the newer copy must be left alone.
                try #require(pasteboard.changeCount == written, "\(agent) \(edit) over \(count): the clipboard changed while settling")
                ours = written
            }
            let clipboard = pasteboard.string(forType: .string)
            switch edit {
            case .copy: expected = full
            case .cut, .backspace, .forwardDelete: expected = remaining
            case .type: expected = remaining + "XY"
            case .paste: expected = remaining + "PASTED"
            }
            let state = fixture.provider.snapshot()
            #expect(state.draft == expected, "\(agent) \(edit) over \(count): provider draft")
            #expect(state.cursor == expected.count, "\(agent) \(edit) over \(count): provider caret")
            #expect(state.unknown.isEmpty, "\(agent) \(edit) over \(count): unexpected input \(state.unknown)")
            #expect(state.submitted == 0, "\(agent) \(edit) over \(count): draft was submitted")
            if edit == .copy || edit == .cut {
                #expect(clipboard == selected, "\(agent) \(edit) over \(count): clipboard")
            }
            #expect(!fixture.view.promptInspectionBlocksInput, "\(agent) \(edit) over \(count): input held")

            // Selection keeps working on the edited draft.
            if edit == .copy {
                fixture.press(try fixture.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
                try await fixture.settle()
            }
            RelayDiagnostics.shared.resetInputSamplerForTesting()
            let mark = RelayDiagnostics.shared.snapshot().events.count
            try fixture.selectLeft(3)
            let id = fixture.pane.id.uuidString.lowercased()
            let events = RelayDiagnostics.shared.snapshot().events.dropFirst(mark)
                .filter { $0.details["pane_id"] == id && !["ghostty-write", "bridge-send", "transport-send", "key-down"].contains($0.name) }
                .map { "\($0.name) \($0.details.filter { $0.key != "pane_id" })" }
            #expect(fixture.view.selectedText()?.replacingOccurrences(of: "\n  ", with: "") == String(expected.suffix(3)),
                    "\(agent) \(edit) over \(count): selection after the edit; events \(events); mirror \(fixture.view.promptInspectionDraftState); rows \((0..<5).map { fixture.view.readViewportRow($0, columns: fixture.columns) ?? "nil" }); provider \(fixture.provider.snapshot())")
        }
    }

    /// The caret in the last column, or just after a soft wrap, with no edit.
    @MainActor
    @Test("Shift-Left at the end of a freshly typed draft selects the last characters",
          .timeLimit(.minutes(2)),
          arguments: [AgentKind.codex, .claude], [
              ["0123456789abcdefghijklmnopPASTED"],
              ["0123456789abcdefghijklmnopqrstuvwxyzABPASTED"],
              ["0123456789abcdefghijklmnopqrstuvwxyzABXY"],
              ["0123456789abcdefghijklmnopqrstuvwxyzABCD", "second"],
          ])
    func selectionAtTheEndOfAFreshDraft(agent: AgentKind, lines: [String]) async throws {
        let fixture = try await Fixture(agent: agent, lines: lines)
        defer { fixture.close() }
        let draft = lines.joined(separator: "\n")
        for count in 1...3 {
            // A plain Right arrow ends the selection, as a user would.
            fixture.press(try fixture.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
            try await fixture.settle()
            try fixture.selectLeft(count)
            let selected = fixture.view.selectedText()
            #expect(selected?.replacingOccurrences(of: "\n  ", with: "") == String(draft.suffix(count)),
                    "\(agent) \(draft.count) chars, \(count) left: \(selected.debugDescription); rows \((0..<4).map { fixture.view.readViewportRow($0, columns: fixture.columns) ?? "nil" })")
        }
    }

    /// The live geometry: 8-pixel cells from x = 9, caret IME origin at a
    /// cell centre and the reported caret x half a cell further right.
    @Test("Selection geometry uses the caret's own column, not the column its x reaches")
    func selectionGeometryUsesTheCaretColumn() {
        let cell = CGSize(width: 8, height: 15.5)
        // Caret in the last of 17 columns: x 145 is the grid's right edge.
        #expect(TerminalKeyboardSelectionGeometry.anchor(for: CGPoint(x: 145, y: 47.75), cellSize: cell,
            columns: 17, gridOriginX: 9) == nil)
        #expect(TerminalKeyboardSelectionGeometry.anchor(for: CGPoint(x: 145, y: 47.75), cellSize: cell,
            columns: 17, gridOriginX: 9, caretColumn: 16) == CGPoint(x: 145, y: 47.75))
        // Caret in column 4; five cells back is the previous row's last column.
        #expect(TerminalKeyboardSelectionGeometry.endpoint(from: CGPoint(x: 49, y: 47.75), visualCellDelta: -5,
            cellSize: cell, columns: 17, gridOriginX: 9, caretColumn: 4) == CGPoint(x: 145, y: 32.25))
        // Without the caret column the same move stays on the caret's row.
        #expect(TerminalKeyboardSelectionGeometry.endpoint(from: CGPoint(x: 49, y: 47.75), visualCellDelta: -5,
            cellSize: cell, columns: 17, gridOriginX: 9) == CGPoint(x: 9, y: 47.75))
    }
}
#endif
