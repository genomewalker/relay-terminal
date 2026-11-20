import Foundation
import Testing
@testable import Relay

private func decodeCard(_ json: String) -> RelayToolCard? {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode(RelayToolCard.Lenient.self, from: Data(json.utf8)))?.value
}

@Test func toolCardDecodesReaderShellAndEditShapes() throws {
    let shell = try #require(decodeCard(#"{"kind":"shell","command":"go test ./...","output":"FAIL x\n","exit_code":1,"duration_ms":1800}"#))
    #expect(shell.isValid)
    #expect(shell.title == "go test ./...")
    #expect(shell.facts == ["exit 1", "1.8 s"])
    #expect(shell.failed(status: "completed"))
    let claude = try #require(decodeCard(#"{"kind":"shell","command":"ls","stdout":"a","tool_error":true}"#))
    // Claude reports no exit status or duration, so none is shown.
    #expect(claude.facts.isEmpty)
    #expect(claude.failed(status: "completed"))
    let edit = try #require(decodeCard(#"{"kind":"edit","files":[{"path":"/w/src/preview.ts","change":"update","added":2,"removed":1,"hunks":[{"header":"@@ -24,3 +24,4 @@","lines":["  return {","-  a","+  b","+  c"]}]},{"path":"/w/b.swift","change":"add","added":3,"removed":0,"hunks":[]}],"omitted_files":2}"#))
    #expect(edit.isValid)
    #expect(edit.title == "preview.ts and 3 more")
    #expect(edit.facts == ["+5", "−1"])
    #expect(!edit.failed(status: "completed"))
    let lines = RelayToolCard.lines(try #require(edit.files?.first))
    #expect(lines.map(\.kind) == [.hunk, .plain, .removed, .added, .added])
}

@Test func toolCardMarksInferredEditsAndRefusesUnknownShapes() throws {
    let inferred = try #require(decodeCard(#"{"kind":"edit","files":[{"path":"/w/a.go","change":"update","added":1,"removed":1,"inferred":true,"hunks":[{"header":"","lines":["-x","+y"]}]}]}"#))
    #expect(inferred.facts == ["+1", "−1", "inferred"])
    #expect(RelayToolCard.lines(try #require(inferred.files?.first)).count == 2)
    // Malformed cards decode to nil instead of failing the snapshot; unknown kinds are invalid.
    #expect(decodeCard(#"{"kind":"shell","exit_code":"one"}"#) == nil)
    #expect(decodeCard(#"{"kind":"image"}"#)?.isValid == false)
    #expect(decodeCard(#"{"kind":"edit","files":[]}"#)?.isValid == false)
    #expect(decodeCard(#"{"kind":"edit","files":[{"path":"/a","change":"rename","added":0,"removed":0,"hunks":[]}]}"#)?.isValid == false)
}

@Test func toolCardFoldsOnlyCallsWithACardedResult() {
    let folded = RelayToolCard.foldedCalls([
        ("tu1", false, "requested"),  // folded: its result has a card
        ("tu1", true, "completed"),
        ("tu2", false, "requested"),  // kept: result has no card
        ("tu2", false, "completed"),
        ("tu3", false, "requested"),  // kept: no result yet (may be running)
        (nil, false, "requested"),
    ])
    #expect(folded == [0])
}

@Test func toolCardDurationLabels() {
    #expect(RelayToolCard.duration(450) == "450 ms")
    #expect(RelayToolCard.duration(1800) == "1.8 s")
    #expect(RelayToolCard.duration(125_000) == "2 min 5 s")
}

// RelayAgentMessageView is a main-actor view; its static helper runs there too.
@MainActor @Test func toolCardBlockKeepsConversationValidation() throws {
    let card = try #require(decodeCard(#"{"kind":"shell","command":"ls"}"#))
    let item = RelayAgentConversationItem(id: "u1:tool:0", turnID: nil, role: .tool,
        blocks: [.tool(name: "Bash", status: "completed", summary: "a"), .toolCard(card)], revision: 1, complete: true)
    #expect(item.isValid)
    let oversized = RelayToolCard(kind: "shell", command: "ls", stdout: String(repeating: "x", count: RelayToolCard.maximumBytes + 1))
    let bad = RelayAgentConversationItem(id: "u2:tool:0", turnID: nil, role: .tool,
        blocks: [.tool(name: "Bash", status: "completed", summary: "a"), .toolCard(oversized)], revision: 1, complete: true)
    #expect(!bad.isValid)
    #expect(RelayAgentMessageView.plainText(item.blocks) == "Bash\na")
}
