import Testing
@testable import Relay

@Test func providerRowMappingPreservesKnownTrailingSpacesWithoutCopyingPadding() {
    func match(_ body: String, _ rendered: String, _ draft: String, _ start: Int = 0) -> String? {
        RelayProviderPromptRowMatch.retainingKnownTrailingSpaces(Array(body), rendered: Array(rendered),
            draft: Array(draft), start: start).map { String($0) }
    }
    #expect(match("Alpha 🧬 tail", "Alpha 🧬 tail      ", "Alpha 🧬 tail  ") == "Alpha 🧬 tail  ")
    #expect(match("tail", "tail      ", "tail") == "tail")
    #expect(match("tail", "tail  ", "tail     ") == "tail  ")
    #expect(match("", "   ", "     ", 2) == "   ")
    #expect(match("next", "next      ", "first next  ", 6) == "next  ")
    #expect(match("tail", "tail   ", "tail\nnext  ") == "tail")
    #expect(match("tail", "tail   ", "tail\t") == "tail")
    #expect(match("tail", "tail   ", "tail  \nnext") == "tail  ")
    #expect(match("tail", "tail   ", "tail word") == "tail ")
    #expect(match("tail", "tailfooter", "tail  ") == nil)
    #expect(match("wrong", "wrong   ", "right  ") == nil)
    #expect(match("tail", "tail   ", "tail  ", -1) == nil)
}

@Test func providerRowContinuationPreservesExplicitBlankLinesAndWrappedWhitespace() {
    func start(_ body: String, _ draft: String, _ from: Int) -> Int? {
        RelayProviderPromptRowMatch.continuationStart(Array(body), draft: Array(draft), from: from)
    }
    #expect(start("next", "first  next", 5) == 7)
    #expect(start("next", "first  \nnext", 5) == 8)
    #expect(start("next", "first\n\nnext", 5) == nil)
    #expect(start("", "first\n\nnext", 5) == 6)
    #expect(start("next", "first\n\nnext", 6) == 7)
    #expect(start("", "first\n", 5) == 6)
    #expect(start("", "first\nnext", 5) == nil)
    #expect(start("", "first\n  \nnext", 5) == 6)
    #expect(start("", "first  \nnext", 5) == 5)
    #expect(start("other", "first\nnext", 5) == nil)
    #expect(start("next", "first\tnext", 5) == nil)
}

@Test func providerOriginalFrameRecoversCaretAndRejectsAmbiguity() {
    typealias Match = RelayProviderPromptRowMatch
    let rows: [Match.PaintedRow] = [
        .init(row: 4, prefix: "❯ ", rendered: Array("one 🧬    ")),
        .init(row: 5, prefix: "  ", rendered: Array("two    "))
    ]
    let frame = Match.Frame(caretRow: 5, caretColumn: 4, columns: 80,
        beforeCaret: "  tw", candidates: [rows])
    let draft = Array("one 🧬  \ntwo  ")
    let mapped = Match.map(draft: draft, frame: frame)
    #expect(mapped?.cursor == Array("one 🧬  \ntw").count)
    #expect(mapped?.rows.last?.end == draft.count)
    let ambiguous = Match.Frame(caretRow: 5, caretColumn: 4, columns: 80,
        beforeCaret: "  tw", candidates: [rows, rows])
    #expect(Match.map(draft: draft, frame: ambiguous) == nil)
    let mismatch = Match.Frame(caretRow: 5, caretColumn: 4, columns: 80,
        beforeCaret: "  other", candidates: [rows])
    #expect(Match.map(draft: draft, frame: mismatch) == nil)
}

@Test func providerOriginalFrameRejectsHiddenTextAndUnmappedRows() {
    typealias Match = RelayProviderPromptRowMatch
    let token: [Match.PaintedRow] = [.init(row: 4, prefix: "❯ ", rendered: Array("[Pasted text #1]"))]
    let frame = Match.Frame(caretRow: 4, caretColumn: 17, columns: 80,
        beforeCaret: "❯ [Pasted text #1]", candidates: [token])
    #expect(Match.map(draft: Array("expanded original pasted contents"), frame: frame) == nil)
    let tabbed: [Match.PaintedRow] = [.init(row: 4, prefix: "❯ ", rendered: Array("a\tb"))]
    #expect(Match.map(draft: Array("a\tb"), paintedRows: tabbed, caretRow: 4, beforeCaret: "❯ a") == nil)
    let gap: [Match.PaintedRow] = [
        .init(row: 4, prefix: "❯ ", rendered: Array("one")),
        .init(row: 6, prefix: "  ", rendered: Array("two"))
    ]
    #expect(Match.map(draft: Array("one\ntwo"), paintedRows: gap, caretRow: 6, beforeCaret: "  tw") == nil)
    #expect(Match.map(draft: Array("one"), paintedRows: [gap[0]], caretRow: 6, beforeCaret: "  tw") == nil)
}

@Test func providerEmptyDraftRequiresBlankComposerAndExactCaret() {
    typealias Match = RelayProviderPromptRowMatch
    let blank = Match.PaintedRow(row: 4, prefix: "❯ ", rendered: Array("     "))
    func frame(_ rows: [[Match.PaintedRow]], row: Int = 4, before: String = "❯ ") -> Match.Frame {
        .init(caretRow: row, caretColumn: 2, columns: 80, beforeCaret: before, candidates: rows)
    }
    #expect(Match.map(draft: [], frame: frame([[blank]]))?.cursor == 0)
    #expect(Match.map(draft: [], frame: frame([[blank]]))?.rows.first?.body.isEmpty == true)
    #expect(Match.map(draft: [], frame: frame([[blank]], row: 5)) == nil)
    #expect(Match.map(draft: [], frame: frame([[blank]], before: "❯  ")) == nil)
    #expect(Match.map(draft: [], frame: frame([[blank], [blank]])) == nil)
    let placeholder = Match.PaintedRow(row: 4, prefix: "❯ ", rendered: Array("Try a prompt"))
    #expect(Match.map(draft: [], frame: frame([[placeholder]])) == nil)
    let whitespaceDraft = Match.PaintedRow(row: 4, prefix: "❯ ", rendered: Array("\t"))
    #expect(Match.map(draft: [], frame: frame([[whitespaceDraft]])) == nil)
    let noBoundary = Match.PaintedRow(row: 4, prefix: "", rendered: Array("     "))
    #expect(Match.map(draft: [], frame: frame([[noBoundary]], before: "")) == nil)
}
