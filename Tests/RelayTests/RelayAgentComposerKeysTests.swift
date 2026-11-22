import AppKit
import SwiftUI
import XCTest
@testable import Relay

final class RelayAgentComposerKeysTests: XCTestCase {
    private func action(_ key: RelayAgentComposerKeys.Key, _ modifiers: EventModifiers = [],
                        marked: Bool = false, first: Bool = true, last: Bool = true,
                        working: Bool = false, steer: Bool = false) -> RelayAgentComposerKeys.Action {
        RelayAgentComposerKeys.action(key: key, modifiers: modifiers, hasMarkedText: marked,
                                      caretOnFirstLine: first, caretOnLastLine: last, agentWorking: working,
                                      canSteer: steer)
    }

    func testReturnHoldsTheMessageWhileTheAgentWorks() {
        XCTAssertEqual(action(.returnKey, working: true), .queue)
        XCTAssertEqual(action(.returnKey, .command, working: true), .queue)
        XCTAssertEqual(action(.returnKey, .shift, working: true), .passThrough)
        // Tab stays with the text view unless Return steers.
        XCTAssertEqual(action(.tab, working: true), .passThrough)
        XCTAssertEqual(action(.tab, working: false, steer: true), .passThrough)
    }

    func testSteerableTransportUsesTheCodexKeys() {
        XCTAssertEqual(action(.returnKey, working: true, steer: true), .steer)
        XCTAssertEqual(action(.tab, working: true, steer: true), .queue)
        XCTAssertEqual(action(.tab, .shift, working: true, steer: true), .passThrough)
        XCTAssertEqual(action(.returnKey, working: false, steer: true), .send)
        XCTAssertEqual(action(.tab, marked: true, working: true, steer: true), .passThrough)
    }

    func testReturnSendsAndModifiedReturnInsertsNewline() {
        XCTAssertEqual(action(.returnKey), .send)
        XCTAssertEqual(action(.returnKey, .command), .send)
        XCTAssertEqual(action(.returnKey, .shift), .passThrough)
        XCTAssertEqual(action(.returnKey, .option), .passThrough)
        XCTAssertEqual(action(.returnKey, .control), .passThrough)
    }

    func testInputMethodCompositionKeepsEveryKey() {
        for key in [RelayAgentComposerKeys.Key.returnKey, .escape, .upArrow, .downArrow] {
            XCTAssertEqual(action(key, marked: true, working: true), .passThrough, "\(key)")
        }
    }

    func testEscapeInterruptsOnlyAWorkingAgent() {
        XCTAssertEqual(action(.escape, working: true), .interrupt)
        XCTAssertEqual(action(.escape, working: false), .passThrough)
        XCTAssertEqual(action(.escape, .shift, working: true), .passThrough)
    }

    func testArrowsRecallHistoryOnlyAtTheEdgeLines() {
        XCTAssertEqual(action(.upArrow, first: true), .historyPrevious)
        XCTAssertEqual(action(.upArrow, first: false), .passThrough)
        XCTAssertEqual(action(.downArrow, last: true), .historyNext)
        XCTAssertEqual(action(.downArrow, last: false), .passThrough)
        XCTAssertEqual(action(.upArrow, .shift), .passThrough)
    }

    func testCaretLines() {
        let text = "one\ntwo\nthree"
        XCTAssertTrue(RelayAgentComposerKeys.caretLines(text: text, selection: NSRange(location: 2, length: 0)).first)
        XCTAssertFalse(RelayAgentComposerKeys.caretLines(text: text, selection: NSRange(location: 2, length: 0)).last)
        XCTAssertFalse(RelayAgentComposerKeys.caretLines(text: text, selection: NSRange(location: 9, length: 0)).first)
        XCTAssertTrue(RelayAgentComposerKeys.caretLines(text: text, selection: NSRange(location: 9, length: 0)).last)
        XCTAssertEqual(RelayAgentComposerKeys.caretLines(text: "", selection: NSRange(location: 0, length: 0)).first, true)
        // An out-of-range selection is clamped rather than trapping.
        XCTAssertTrue(RelayAgentComposerKeys.caretLines(text: "a", selection: NSRange(location: 99, length: 5)).last)
    }

    func testHistoryWalksBackAndRestoresTheDraft() {
        var history = RelayAgentComposerHistory()
        let entries = ["first", "second", "third"]
        XCTAssertEqual(history.previous(entries: entries, current: "draft"), "third")
        XCTAssertEqual(history.previous(entries: entries, current: "third"), "second")
        XCTAssertEqual(history.previous(entries: entries, current: "second"), "first")
        XCTAssertNil(history.previous(entries: entries, current: "first"))
        XCTAssertEqual(history.next(entries: entries), "second")
        XCTAssertEqual(history.next(entries: entries), "third")
        XCTAssertEqual(history.next(entries: entries), "draft")
        XCTAssertFalse(history.browsing)
        XCTAssertNil(history.next(entries: entries))
    }

    func testHistorySkipsAnEntryEqualToTheDraftAndHandlesEmpty() {
        var history = RelayAgentComposerHistory()
        XCTAssertEqual(history.previous(entries: ["a", "b"], current: "b"), "a")
        var empty = RelayAgentComposerHistory()
        XCTAssertNil(empty.previous(entries: [], current: "x"))
        XCTAssertFalse(empty.browsing)
    }

    func testUserPromptsComeFromUserMarkdownOnly() {
        func item(_ id: String, _ role: RelayAgentConversationItem.Role,
                  _ blocks: [RelayAgentConversationItem.Block]) -> RelayAgentConversationItem {
            RelayAgentConversationItem(id: id, turnID: nil, role: role, blocks: blocks, revision: 1, complete: true)
        }
        let items = [
            item("1", .user, [.markdown("  hello  ")]),
            item("2", .assistant, [.markdown("hi")]),
            item("3", .user, [.providerImage(reference: "eA==")]),
            item("4", .user, [.markdown("a"), .markdown("b")]),
        ]
        XCTAssertEqual(RelayAgentComposerKeys.userPrompts(items), ["hello", "a\n\nb"])
    }
}
