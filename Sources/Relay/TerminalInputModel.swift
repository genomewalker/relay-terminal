import Foundation

enum TerminalPastePayload {
    private static let begin = "\u{001B}[200~"
    private static let end = "\u{001B}[201~"

    /// The native paste encoding, assembled synchronously for an already
    /// authorized prompt transaction. Native key translation still supplies
    /// movement/deletion/caret bytes; text must not escape via the IO mailbox.
    static func encodedPayload(for text: String, bracketed: Bool) -> Data? {
        guard !text.isEmpty, text.utf8.count <= 65_536 else { return nil }
        var result = Data()
        if bracketed { result.append(contentsOf: begin.utf8) }
        for byte in text.utf8 {
            switch byte {
            case 0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F, 0x03, 0x1C,
                 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F:
                result.append(0x20)
            case 0x0A where !bracketed:
                result.append(0x0D)
            default:
                result.append(byte)
            }
        }
        if bracketed { result.append(contentsOf: end.utf8) }
        return result
    }

    /// Captured clipboard text is sent directly so clipboard managers cannot
    /// change it between Relay's read and Ghostty's asynchronous callback.
    /// Multi-line text is only sent directly when bracketed paste is active;
    /// otherwise Ghostty retains its normal unsafe-paste confirmation.
    static func directPayload(for text: String, bracketed: Bool) -> String? {
        guard !text.isEmpty else { return nil }
        if bracketed { return begin + text + end }
        guard !text.contains(where: \Character.isNewline) else { return nil }
        return text
    }

    /// ghostty_surface_text treats its argument as a paste and supplies mode
    /// 2004 framing itself. Only direct PTY writers use directPayload above.
    static func rendererPayload(for text: String, bracketed: Bool) -> String? {
        guard !text.isEmpty, bracketed || !text.contains(where: \Character.isNewline) else { return nil }
        return text
    }
}

enum LegacyTerminalModeCompatibility {
    static let durableCapability = "terminal_mode_state_v1"

    /// Workers released before durable terminal-mode replay cannot recover a
    /// Codex session's one-time Kitty keyboard negotiation after its startup
    /// bytes leave the bounded replay ring. This migration prelude is applied
    /// only to those old workers; current relayd sessions replay their exact
    /// tracked state instead.
    static func prelude(agentKind: AgentKind, capabilities: [String]) -> Data? {
        guard agentKind == .codex,
              !capabilities.contains(durableCapability) else { return nil }
        return Data("\u{001B}[<65535u\u{001B}[>7u\u{001B}[?2004h".utf8)
    }
}

/// Tracks DEC bracketed-paste mode from the ordered terminal output. The
/// tracker keeps at most a seven-byte sequence prefix, so packet boundaries do
/// not matter and ordinary output takes a constant-time fast path.
final class TerminalBracketedPasteStateTracker: @unchecked Sendable {
    private static let enable = Data("\u{001B}[?2004h".utf8)
    private static let disable = Data("\u{001B}[?2004l".utf8)
    private static let maximumPrefix = max(enable.count, disable.count) - 1

    private let lock = NSLock()
    private var pending = Data()
    private var active = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func observe(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if pending.isEmpty,
           data.range(of: Self.enable) == nil,
           data.range(of: Self.disable) == nil {
            pending = Self.candidateSuffix(in: data)
            return
        }

        var combined = pending
        combined.append(data)
        let lastEnable = combined.range(of: Self.enable, options: .backwards)?.lowerBound
        let lastDisable = combined.range(of: Self.disable, options: .backwards)?.lowerBound
        if let lastEnable, lastDisable == nil || lastEnable > lastDisable! {
            active = true
        } else if lastDisable != nil {
            active = false
        }
        pending = Self.candidateSuffix(in: combined)
    }

    private static func candidateSuffix(in data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let limit = min(maximumPrefix, data.count)
        guard limit > 0 else { return Data() }
        for length in stride(from: limit, through: 1, by: -1) {
            let suffix = data.suffix(length)
            if enable.prefix(length).elementsEqual(suffix) ||
                disable.prefix(length).elementsEqual(suffix) {
                return Data(suffix)
            }
        }
        return Data()
    }
}

/// Keeps a small, memory-only sample of readable agent output for the sidebar.
/// Structured events remain authoritative; raw terminal output is never
/// persisted as agent state.
struct TerminalConversationContextBuffer: Sendable {
    private var controlStripper = TerminalControlSequenceStripper()
    private var partialLine = ""
    private(set) var lines: [String] = []

    mutating func ingest(_ text: String) {
        let plain = controlStripper.ingest(text).replacingOccurrences(of: "\r", with: "\n")
        let combined = partialLine + plain
        let pieces = combined.split(separator: "\n", omittingEmptySubsequences: false)
        partialLine = String(String(pieces.last ?? "").suffix(512))
        for piece in pieces.dropLast() {
            guard let line = Self.normalized(String(piece)) else { continue }
            if lines.last != line { lines.append(line) }
        }
        if lines.count > 28 { lines.removeFirst(lines.count - 28) }
    }

    private static func normalized(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count >= 3,
              collapsed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        else { return nil }
        return String(collapsed.prefix(320))
    }
}

/// A conservative mirror of the line currently edited in the terminal. It is
/// used only for local cursor placement and selection editing. Unfamiliar
/// cursor operations invalidate it instead of guessing remote state.
struct TerminalPromptBuffer: Equatable, Sendable {
    enum NavigationGranularity: Equatable, Sendable {
        case character
        case word
        case line
    }

    struct Snapshot: Equatable, Sendable {
        let characters: [Character]
        let cursor: Int

        var text: String { String(characters) }
    }

    private(set) var characters: [Character] = []
    private(set) var cursor = 0
    private(set) var isReliable = true

    var text: String { String(characters) }
    var isAtEnd: Bool { cursor == characters.count }
    var snapshot: Snapshot? {
        isReliable ? Snapshot(characters: characters, cursor: cursor) : nil
    }

    mutating func insert(_ text: String) {
        guard isReliable else {
            invalidate()
            return
        }
        guard !text.isEmpty else { return }
        // String insertion can join a new combining mark, emoji modifier or
        // regional indicator to the preceding grapheme. Re-segment the actual
        // resulting bytes rather than retaining separate Character entries.
        let beforeCaret = String(characters.prefix(cursor)) + text
        let combined = beforeCaret + String(characters.dropFirst(cursor))
        let revised = Array(combined)
        let revisedCursor = beforeCaret.count
        guard revised.count <= 4_096, revisedCursor <= revised.count,
              String(revised.prefix(revisedCursor)).utf8.elementsEqual(beforeCaret.utf8) else {
            // This model cannot authorize a caret inside a newly joined
            // grapheme; refuse that snapshot instead of moving the caret.
            invalidate()
            return
        }
        characters = revised
        cursor = revisedCursor
    }

    mutating func restore(_ snapshot: Snapshot) {
        guard snapshot.characters.count <= 4_096,
              snapshot.cursor >= 0,
              snapshot.cursor <= snapshot.characters.count,
              Array(snapshot.text) == snapshot.characters else {
            invalidate()
            return
        }
        characters = snapshot.characters
        cursor = snapshot.cursor
        isReliable = true
    }

    mutating func move(by delta: Int) {
        guard isReliable else { return }
        cursor = min(max(0, cursor + delta), characters.count)
    }

    mutating func moveToStart() {
        guard isReliable else { return }
        cursor = 0
    }

    mutating func moveToEnd() {
        guard isReliable else { return }
        cursor = characters.count
    }

    mutating func backspace() {
        guard isReliable, cursor > 0 else { return }
        _ = removePromptRange((cursor - 1)..<cursor)
    }

    mutating func deleteForward() {
        guard isReliable, cursor < characters.count else { return }
        _ = removePromptRange(cursor..<(cursor + 1))
    }

    mutating func deleteToStart() {
        guard isReliable, cursor > 0 else { return }
        _ = removePromptRange(0..<cursor)
    }

    mutating func deleteToEnd() {
        guard isReliable, cursor < characters.count else { return }
        _ = removePromptRange(cursor..<characters.count)
    }

    mutating func deletePreviousWord() {
        guard isReliable, cursor > 0 else { return }
        var start = cursor
        while start > 0, characters[start - 1].isWhitespace { start -= 1 }
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        _ = removePromptRange(start..<cursor)
    }

    @discardableResult
    mutating func deleteSelection(relativeToCursor offset: Int) -> Bool {
        guard isReliable, offset != 0, abs(offset) <= 4_096 else { return false }
        let otherEnd = cursor + offset
        guard otherEnd >= 0, otherEnd <= characters.count else { return false }
        let lower = min(cursor, otherEnd)
        let upper = max(cursor, otherEnd)
        guard lower < upper else { return false }
        return removePromptRange(lower..<upper)
    }

    /// Removes the characters between two cursor-relative offsets and leaves
    /// the caret at the lower end — the exact effect of moving the remote caret
    /// to `upperOffset` and erasing backwards to `lowerOffset`. Unlike
    /// deleteSelection this does not assume the range touches the caret.
    @discardableResult
    mutating func deleteRange(relativeToCursor lowerOffset: Int, _ upperOffset: Int) -> Bool {
        guard isReliable else { return false }
        let lower = cursor + min(lowerOffset, upperOffset)
        let upper = cursor + max(lowerOffset, upperOffset)
        guard lower >= 0, upper <= characters.count, lower < upper,
              upper - lower <= 4_096 else { return false }
        return removePromptRange(lower..<upper)
    }

    /// Removing a separator can join the remaining scalars into a grapheme.
    /// Preserve the byte position of the editor's caret; never round it to a
    /// different boundary when this character-based mirror cannot represent it.
    private mutating func removePromptRange(_ range: Range<Int>) -> Bool {
        let beforeCaret = String(characters.prefix(range.lowerBound))
        let combined = beforeCaret + String(characters.dropFirst(range.upperBound))
        let revised = Array(combined)
        let revisedCursor = beforeCaret.count
        guard revisedCursor <= revised.count,
              String(revised.prefix(revisedCursor)).utf8.elementsEqual(beforeCaret.utf8) else {
            invalidate()
            return false
        }
        characters = revised
        cursor = revisedCursor
        return true
    }

    /// Validate a selection edit without changing the mirror or sending keys.
    func plannedDeletionSnapshot(characterCount: Int, movementOffset: Int) -> Snapshot? {
        guard characterCount > 0, characterCount <= 4_096,
              movementOffset >= -4_096, movementOffset <= 4_096 else { return nil }
        var planned = self
        guard planned.deleteRange(relativeToCursor: movementOffset - characterCount, movementOffset) else { return nil }
        return planned.snapshot
    }

    mutating func submit() -> String? {
        let value = isReliable ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        clear()
        return value.isEmpty ? nil : value
    }

    mutating func clear() {
        characters.removeAll(keepingCapacity: true)
        cursor = 0
        isReliable = true
    }

    mutating func invalidate() {
        characters.removeAll(keepingCapacity: true)
        cursor = 0
        isReliable = false
    }

    func logicalMovementOffset(forVisualCellDelta delta: Int) -> Int? {
        guard isReliable else { return nil }
        let target = cursor + delta
        guard target >= 0, target <= characters.count else { return nil }
        return delta
    }

    /// Returns the text selected relative to the current logical cursor.
    /// A negative offset selects characters before the cursor; a positive
    /// offset selects characters after it. Relay keeps this as a fallback for
    /// agent composers whose rapid repaint can temporarily clear Ghostty's
    /// visual selection between Shift-arrow and Command-C.
    func selectedText(relativeToCursor offset: Int) -> String? {
        guard isReliable, offset != 0, abs(offset) <= 4_096 else { return nil }
        let otherEnd = cursor + offset
        guard otherEnd >= 0, otherEnd <= characters.count else { return nil }
        let lower = min(cursor, otherEnd)
        let upper = max(cursor, otherEnd)
        guard lower < upper else { return nil }
        return String(characters[lower..<upper])
    }

    /// Resolve macOS-style horizontal movement without changing the mirrored
    /// caret. Selection keeps the remote caret fixed at its anchor, so the
    /// returned value is always relative to that anchor even when an existing
    /// selection is extended or contracted.
    func navigationOffset(
        from currentOffset: Int = 0,
        direction: Int,
        granularity: NavigationGranularity
    ) -> Int? {
        guard isReliable, direction == -1 || direction == 1 else { return nil }
        let current = cursor + currentOffset
        guard current >= 0, current <= characters.count else { return nil }

        let target: Int
        switch granularity {
        case .character:
            target = min(max(0, current + direction), characters.count)
        case .word:
            if direction < 0 {
                var index = current
                while index > 0, characters[index - 1].isWhitespace { index -= 1 }
                while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
                target = index
            } else {
                var index = current
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                target = index
            }
        case .line:
            if direction < 0 {
                var index = current
                while index > 0, !characters[index - 1].isNewline { index -= 1 }
                target = index
            } else {
                var index = current
                while index < characters.count, !characters[index].isNewline { index += 1 }
                target = index
            }
        }
        return target - cursor
    }
}

/// Bounded macOS-style undo/redo for the locally mirrored prompt. Relay keeps
/// terminal applications authoritative; history is discarded whenever an
/// unfamiliar remote edit makes the mirror unreliable.
struct TerminalPromptEditHistory: Sendable {
    enum Kind: Equatable, Sendable {
        case typing
        case deleting
        case paste

        var coalesces: Bool {
            self == .typing || self == .deleting
        }
    }

    private struct Entry: Sendable {
        let snapshot: TerminalPromptBuffer.Snapshot
        let kind: Kind
        let timestamp: TimeInterval
    }

    private static let maximumEntries = 128
    private static let coalescingWindow: TimeInterval = 0.7
    private var undoStack: [Entry] = []
    private var redoStack: [TerminalPromptBuffer.Snapshot] = []
    private var coalescingBroken = true

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(
        before snapshot: TerminalPromptBuffer.Snapshot,
        kind: Kind,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let previous = undoStack.last
        let continuesGroup = !coalescingBroken && kind.coalesces &&
            previous?.kind == kind &&
            timestamp >= (previous?.timestamp ?? timestamp) &&
            timestamp - (previous?.timestamp ?? timestamp) <= Self.coalescingWindow
        if !continuesGroup {
            undoStack.append(Entry(snapshot: snapshot, kind: kind, timestamp: timestamp))
            if undoStack.count > Self.maximumEntries {
                undoStack.removeFirst(undoStack.count - Self.maximumEntries)
            }
        } else if let previous {
            // Retain the original pre-edit snapshot while extending the time
            // window for a natural burst of typing or deletion.
            undoStack[undoStack.count - 1] = Entry(
                snapshot: previous.snapshot,
                kind: previous.kind,
                timestamp: timestamp
            )
        }
        redoStack.removeAll(keepingCapacity: true)
        coalescingBroken = !kind.coalesces
    }

    mutating func breakCoalescing() {
        coalescingBroken = true
    }

    mutating func undo(current: TerminalPromptBuffer.Snapshot) -> TerminalPromptBuffer.Snapshot? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(current)
        coalescingBroken = true
        return entry.snapshot
    }

    mutating func redo(current: TerminalPromptBuffer.Snapshot) -> TerminalPromptBuffer.Snapshot? {
        guard let target = redoStack.popLast() else { return nil }
        undoStack.append(Entry(
            snapshot: current,
            kind: .paste,
            timestamp: ProcessInfo.processInfo.systemUptime
        ))
        coalescingBroken = true
        return target
    }

    mutating func reset() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        coalescingBroken = true
    }
}
