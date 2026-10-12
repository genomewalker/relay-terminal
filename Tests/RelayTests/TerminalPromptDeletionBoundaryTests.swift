import Testing
@testable import Relay

struct TerminalPromptDeletionBoundaryTests {
    @Test func deletionDoesNotInventCaretInsideJoinedFlag() {
        var buffer = TerminalPromptBuffer()
        buffer.insert("🇦x🇧")
        buffer.move(by: -1)
        let before = buffer.snapshot
        #expect(buffer.plannedDeletionSnapshot(characterCount: 1, movementOffset: 0) == nil)
        #expect(buffer.snapshot == before)
        buffer.backspace()
        #expect(!buffer.isReliable)
        #expect(buffer.snapshot == nil)
    }

    @Test func selectionAndForwardDeletionCheckJoinedBoundary() {
        var selection = TerminalPromptBuffer()
        selection.insert("🇦x🇧")
        selection.move(by: -2)
        let deleted = selection.deleteSelection(relativeToCursor: 1)
        #expect(!deleted)
        #expect(!selection.isReliable)
        var forward = TerminalPromptBuffer()
        forward.insert("🇦x🇧")
        forward.move(by: -2)
        forward.deleteForward()
        #expect(!forward.isReliable)
    }

    @Test func ordinaryDeletionKeepsExactTextAndCaret() {
        var buffer = TerminalPromptBuffer()
        buffer.insert("ab🙂cd")
        buffer.move(by: -2)
        let target = buffer.plannedDeletionSnapshot(characterCount: 1, movementOffset: 0)
        #expect(target?.text == "abcd")
        #expect(target?.cursor == 2)
        #expect(buffer.text == "ab🙂cd")
        buffer.backspace()
        #expect(buffer.snapshot == target)
    }

    @Test func restoreRejectsStaleGraphemeSegmentation() {
        var buffer = TerminalPromptBuffer()
        buffer.restore(.init(characters: ["🇦", "🇧"], cursor: 1))
        #expect(!buffer.isReliable)
    }
}
