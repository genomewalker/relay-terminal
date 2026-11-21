import XCTest
@testable import Relay

final class RelayAgentPromptQueueTests: XCTestCase {
    private let pane = UUID()
    private func binding(session: String = "s1", pid: Int = 42, source: String? = nil) -> RelayAgentConversationBinding {
        RelayAgentConversationBinding(hostID: "h", paneID: pane, provider: "codex", processID: pid,
                                      processStart: "t0", sessionID: session, sourceIdentity: source)
    }

    func testBlankTextIsNotHeld() {
        var queue = RelayAgentPromptQueue()
        XCTAssertFalse(queue.enqueue("  \n", binding: binding()))
        XCTAssertTrue(queue.isEmpty)
    }

    func testMessagesLeaveOnceInOrder() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding()); queue.enqueue("two", binding: binding())
        XCTAssertEqual(queue.takeNext(for: binding())?.text, "one")
        XCTAssertEqual(queue.takeNext(for: binding())?.text, "two")
        XCTAssertNil(queue.takeNext(for: binding()))
    }

    func testPausedQueueSendsNothingUntilResumed() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding())
        queue.pause("stopped")
        XCTAssertNil(queue.takeNext(for: binding()))
        XCTAssertEqual(queue.items.count, 1)
        queue.resume()
        XCTAssertEqual(queue.takeNext(for: binding())?.text, "one")
    }

    func testPausingAnEmptyQueueDoesNothing() {
        var queue = RelayAgentPromptQueue()
        queue.pause("stopped")
        XCTAssertFalse(queue.paused)
    }

    func testDifferentConversationPausesInsteadOfSending() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding())
        XCTAssertNil(queue.takeNext(for: binding(session: "s2")))
        XCTAssertTrue(queue.paused)
        XCTAssertEqual(queue.items.count, 1)
        // Resuming alone keeps refusing; the view rebinds first.
        queue.resume()
        XCTAssertNil(queue.takeNext(for: binding(pid: 43)))
        queue.rebind(to: binding(pid: 43)); queue.resume()
        XCTAssertEqual(queue.takeNext(for: binding(pid: 43))?.text, "one")
    }

    func testNoBindingPausesInsteadOfSending() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding())
        XCTAssertNil(queue.takeNext(for: nil))
        XCTAssertTrue(queue.paused)
    }

    func testRefreshedSourcePathIsTheSameConversation() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding(source: "a.jsonl"))
        XCTAssertEqual(queue.takeNext(for: binding(source: "b.jsonl"))?.text, "one")
    }

    func testPutBackReturnsToFrontPausedWithoutDuplicating() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding()); queue.enqueue("two", binding: binding())
        let first = queue.takeNext(for: binding())!
        queue.putBack(first, reason: "uncertain")
        queue.putBack(first, reason: "uncertain")
        XCTAssertEqual(queue.items.map(\.text), ["one", "two"])
        XCTAssertEqual(queue.pausedReason, "uncertain")
        XCTAssertNil(queue.takeNext(for: binding()))
    }

    func testCancelLastMessageClearsPause() {
        var queue = RelayAgentPromptQueue()
        queue.enqueue("one", binding: binding(), id: UUID())
        queue.pause("stopped")
        XCTAssertNotNil(queue.cancel(queue.items[0].id))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(queue.paused)
        XCTAssertNil(queue.cancel(UUID()))
    }

    func testSavedTextKeepsDraftThenHeldMessages() {
        var queue = RelayAgentPromptQueue()
        XCTAssertEqual(queue.textForSaving("draft"), "draft")
        queue.enqueue("one", binding: binding()); queue.enqueue("two", binding: binding())
        XCTAssertEqual(queue.textForSaving(""), "one\n\ntwo")
        XCTAssertEqual(queue.textForSaving("draft"), "draft\n\none\n\ntwo")
    }

    @MainActor
    func testComposerStatePersistsHeldMessagesAsDraftText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RelayAgentDraftStore(directory: dir)
        let state = PaneComposerState()
        state.queue.enqueue("held", binding: binding())
        state.persist(hostID: "h", paneID: pane, immediate: true, store: store)
        XCTAssertEqual(store.loadDraft(hostID: "h", paneID: pane)?.text, "held")
        // A restored draft is only text in the composer; nothing is queued to send.
        let restored = PaneComposerState()
        restored.restoreIfNeeded(hostID: "h", paneID: pane, store: store)
        XCTAssertEqual(restored.draft, "held")
        XCTAssertTrue(restored.queue.isEmpty)
    }
}
