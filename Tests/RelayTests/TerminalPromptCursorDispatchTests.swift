#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

private final class CursorDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let writeEvents = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
    var writes: AsyncStream<Data> { writeEvents.stream }
    deinit { writeEvents.continuation.finish() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ data: Data) {
        lock.lock(); storage.append(data); lock.unlock()
        writeEvents.continuation.yield(data)
    }
}

/// An owned remote pane with an in-memory session and no attached transport:
/// every controlled packet is refused before anything is dispatched.
@MainActor
private final class RefusingPromptPane {
    let recorder = CursorDispatchRecorder()
    let session: InMemoryTerminalSession
    let pane: PaneModel
    let view: RelayGhosttyView
    let window: NSWindow
    private let lease = UUID()
    private let generation: UInt64

    init(kind: AgentKind) throws {
        _ = NSApplication.shared
        // Event assertions below need this test's diagnostics admitted.
        RelayDiagnostics.shared.resetInputSamplerForTesting()
        let recorder = recorder
        session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        pane = PaneModel(profile: ConnectionProfile(name: "Owned refused dispatch",
            host: "owned-peer.invalid", backend: .relay))
        pane.setAgentKind(kind)
        let runtime = pane.runtime
        view = runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        generation = runtime.beginPresentationAttachment(lease: lease)
        runtime.setPresented(true, lease: lease, generation: generation)
        runtime.setKeyboardFocusEligible(true)
        view.setSurfaceVisible(true)
        view.fitToSize()
        try #require(window.makeFirstResponder(view))
    }

    func close() {
        pane.runtime.endPresentationAttachment(lease: lease, generation: generation)
        window.orderOut(nil)
        window.contentView = nil
    }

    func render(_ text: String) async {
        session.receive(text)
        let session = session
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        view.remoteTerminalStateWasRestored()
        view.setShellPromptActive(true)
    }

    func key(_ characters: String, _ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    func left(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123, modifiers: modifiers)
    }

    func events(_ name: String) -> [RelayDiagnosticEvent] {
        let id = pane.id.uuidString.lowercased()
        return RelayDiagnostics.shared.snapshot().events.filter {
            $0.category == "terminal-input" && $0.name == name && $0.details["pane_id"] == id
        }
    }

    /// Wait until the recorder holds `count` bytes or more.
    func waitForBytes(_ count: Int) async throws {
        var writes = recorder.writes.makeAsyncIterator()
        while recorder.data.count < count { _ = try #require(await writes.next()) }
    }
}

private func occurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    var index = haystack.startIndex
    while let range = haystack.range(of: needle, in: index..<haystack.endIndex) {
        count += 1
        index = range.upperBound
    }
    return count
}

/// Kapk 07fa914c on 2026110303: a Left/Right arrow in a remote Claude prompt
/// is sent as one controlled packet. The remote transport refuses that packet
/// while earlier input awaits acknowledgement (or without an input lease), and
/// a refused packet dispatches nothing. The arrow then paused typing
/// ("The prompt cursor move could not be dispatched") although nothing was
/// uncertain.
@Suite(.serialized)
struct TerminalPromptCursorDispatchTests {
    /// The live refusal: a lease is never admitted with input in flight.
    @Test func controlledInputIsRefusedWhileEarlierInputAwaitsAcknowledgement() {
        func admits(pending: Bool) -> Bool {
            RelayPromptEditorLeasePolicy.admits(attached: true, detached: false, writerAvailable: true,
                controlGranted: true, observer: false, acknowledgedInput: true,
                pendingInput: pending, overflowed: false)
        }
        #expect(admits(pending: false))
        #expect(!admits(pending: true))
    }

    @MainActor
    @Test("A refused controlled cursor move does not pause typing and is written exactly once", .timeLimit(.minutes(1)))
    func refusedCursorMoveFallsBackWithoutPausingTyping() async throws {
        let p = try RefusingPromptPane(kind: .claude)
        defer { p.close() }
        await p.render("❯ hello")
        // The live sequence: type, then press an arrow before the typed input
        // is acknowledged. Local typing keeps the mirror's caret known.
        p.view.keyDown(with: try p.key("q", 12))
        try await p.waitForBytes(1)
        #expect(p.recorder.data == Data("q".utf8))
        let left = try p.left()

        // AppKit offers a key to performKeyEquivalent before keyDown. The
        // refused move must decline there without writing, and the keyDown
        // that follows must write the arrow once (no double handling).
        #expect(!p.view.performKeyEquivalent(with: left))
        #expect(p.recorder.data == Data("q".utf8), "performKeyEquivalent writes nothing")
        #expect(p.events("prompt-cursor-native-fallback").count == 1, "the refusal ran in performKeyEquivalent")
        p.view.keyDown(with: left)
        // keyDown re-synchronizes the mirror from the renderer and attempts
        // the controlled move once more. Each attempt is all-or-nothing, so a
        // second refusal also dispatches nothing; the bytes below prove the
        // arrow is still written exactly once.
        #expect(p.events("prompt-cursor-native-fallback").count == 2, "one refused attempt per handler")

        // Typing is not paused and nothing was preserved for recovery.
        #expect(!p.view.promptInspectionBlocksInput)
        #expect(p.events("prompt-inspection-input-preserved").isEmpty)
        #expect(p.pane.terminalInputDraftMessage == nil)
        try await p.waitForBytes(2)
        let arrowBytes = p.recorder.data.dropFirst()
        let knownLeft = [Data("\u{1B}[D".utf8), Data("\u{1B}OD".utf8)]
        #expect(knownLeft.contains(Data(arrowBytes)), "exactly one native Left arrow: \(Array(arrowBytes))")

        // Later typing is written normally, after the arrow, with no replay.
        p.view.keyDown(with: try p.key("x", 7))
        #expect(!p.view.promptInspectionBlocksInput)
        try await p.waitForBytes(1 + arrowBytes.count + 1)
        let all = p.recorder.data
        #expect(all == Data("q".utf8) + arrowBytes + Data("x".utf8), "exact sequence: \(Array(all))")
        #expect(occurrences(of: Data(arrowBytes), in: all) == 1, "the arrow is written exactly once")
    }

    /// applyPromptEdit: deleting a local selection is N moves + M deletions in
    /// one controlled packet. Refused, it dispatches nothing, and there is no
    /// single native key that deletes the selection, so the hold is kept.
    /// Held keys, including a later arrow, keep their order: none is written.
    @MainActor
    @Test("A refused selection edit writes nothing and keeps held keys in order", .timeLimit(.minutes(1)))
    func refusedSelectionEditKeepsHoldWithoutPartialBytes() async throws {
        let p = try RefusingPromptPane(kind: .codex)
        defer { p.close() }
        await p.render("❯ hello")
        p.view.keyDown(with: try p.left(modifiers: .shift))
        #expect(p.recorder.data.isEmpty, "selection is local")

        p.view.keyDown(with: try p.key("\u{7F}", 51))
        #expect(p.events("prompt-control-refused").contains { $0.details["reason"] == "edit" })
        #expect(p.recorder.data.isEmpty, "a refused edit dispatches no partial bytes")
        #expect(p.view.promptInspectionBlocksInput, "no native equivalent: the hold is kept")

        // While held, an arrow and typing queue behind the held deletion; the
        // arrow never takes the native fallback ahead of them.
        p.view.keyDown(with: try p.left())
        p.view.keyDown(with: try p.key("x", 7))
        #expect(p.recorder.data.isEmpty, "held keys are never sent")
        #expect(p.events("prompt-cursor-native-fallback").isEmpty)
        #expect(p.events("input-blocked").count >= 2)

        // Escape resumes typing (and, as since f9fe388b, is itself delivered
        // natively); held keys are not replayed blindly.
        p.view.keyDown(with: try p.key("\u{1b}", 53))
        #expect(!p.view.promptInspectionBlocksInput)
        #expect(p.events("input-resumed").contains { $0.details["reason"] == "native_cancel" })
        p.view.keyDown(with: try p.key("z", 6))
        try await p.waitForBytes(2)
        #expect(p.recorder.data == Data("\u{1B}z".utf8), "only Escape and new typing: \(Array(p.recorder.data))")
    }

    /// restorePromptSnapshot: undo is a whole-draft restore in one controlled
    /// packet. Refused, it dispatches nothing; it has no native single-key
    /// equivalent, so the history action is held rather than dropped.
    @MainActor
    @Test("A refused undo restore writes nothing and keeps the hold", .timeLimit(.minutes(1)))
    func refusedUndoRestoreKeepsHoldWithoutPartialBytes() async throws {
        let p = try RefusingPromptPane(kind: .codex)
        defer { p.close() }
        await p.render("❯ ")
        p.view.keyDown(with: try p.key("a", 0))
        try await p.waitForBytes(1)
        #expect(p.recorder.data == Data("a".utf8))

        p.view.keyDown(with: try p.key("z", 6, modifiers: .command))
        #expect(p.events("prompt-control-refused").contains { $0.details["reason"] == "restore" })
        #expect(p.recorder.data == Data("a".utf8), "a refused restore dispatches no partial bytes")
        #expect(p.view.promptInspectionBlocksInput, "no native equivalent: the hold is kept")

        p.view.keyDown(with: try p.key("y", 16))
        #expect(p.recorder.data == Data("a".utf8), "held typing is never sent")

        p.view.keyDown(with: try p.key("\u{1b}", 53))
        #expect(!p.view.promptInspectionBlocksInput)
        p.view.keyDown(with: try p.key("w", 13))
        try await p.waitForBytes(3)
        #expect(p.recorder.data == Data("a\u{1B}w".utf8), "only Escape and new typing: \(Array(p.recorder.data))")
    }

    /// A bash readline prompt holding a character readline deletes in two
    /// units (base emoji + skin-tone modifier). Composite Backspace sends both
    /// units in one controlled packet; here that packet is refused.
    @MainActor
    private func refusedCompositeDeletion() async throws -> (RefusingPromptPane, Data) {
        let p = try RefusingPromptPane(kind: .shell)
        await p.render("❯ ")
        p.pane.runtime.setReadlineShellIdentityForTesting("4242:Tue Nov  3 12:00:00 2026")
        let emoji = "\u{1F44D}\u{1F3FD}"
        p.view.keyDown(with: try p.key(emoji, 0))
        let typed = Data(emoji.utf8)
        try await p.waitForBytes(typed.count)
        try #require(p.recorder.data == typed, "typed: \(Array(p.recorder.data))")
        p.view.keyDown(with: try p.key("\u{7F}", 51))
        // applyPromptEdit sets recovery only on its refused-dispatch branch.
        try #require(p.view.promptInspectionRecoveryPendingForTesting,
            "the composite deletion reached the refused controlled path")
        try #require(p.events("prompt-control-refused").contains { $0.details["reason"] == "edit" })
        return (p, typed)
    }

    /// F1 (a): a refused composite deletion keeps the whole draft. It never
    /// falls through to a native Backspace that deletes part of a character.
    @MainActor
    @Test("A refused composite deletion keeps the whole draft", .timeLimit(.minutes(1)))
    func refusedCompositeDeletionKeepsWholeDraft() async throws {
        let (p, typed) = try await refusedCompositeDeletion()
        defer { p.close() }
        #expect(p.recorder.data == typed, "no partial native Backspace: \(Array(p.recorder.data))")
        p.view.keyDown(with: try p.key("z", 6))
        // Writes are asynchronous: flush with a sentinel after Escape. The
        // writer is FIFO, so once the sentinel is recorded, any partial
        // Backspace or the held "z" would already be visible.
        p.view.keyDown(with: try p.key("\u{1b}", 53))
        p.view.keyDown(with: try p.key("w", 13))
        try await p.waitForBytes(typed.count + 2)
        #expect(p.recorder.data == typed + Data("\u{1B}w".utf8),
            "whole draft kept, nothing held was sent: \(Array(p.recorder.data))")
    }

    /// F1 (b): recovery is never left set without a hold, so the auto-resume
    /// at keyDown stays available and later holds do not stick; Escape clears
    /// both and typing resumes with nothing replayed.
    @MainActor
    @Test("A refused composite deletion never leaves recovery set without a hold", .timeLimit(.minutes(1)))
    func refusedCompositeDeletionLeavesNoStaleRecovery() async throws {
        let (p, typed) = try await refusedCompositeDeletion()
        defer { p.close() }
        #expect(!p.view.promptInspectionRecoveryPendingForTesting || p.view.promptInspectionBlocksInput,
            "recovery pending only with a visible hold")
        p.view.keyDown(with: try p.key("\u{1b}", 53))
        #expect(!p.view.promptInspectionBlocksInput)
        #expect(!p.view.promptInspectionRecoveryPendingForTesting, "Escape leaves no stale recovery")
        p.view.keyDown(with: try p.key("z", 6))
        try await p.waitForBytes(typed.count + 2)
        #expect(p.recorder.data == typed + Data("\u{1B}z".utf8), "only Escape and new typing: \(Array(p.recorder.data))")
    }

    /// A Codex relay pane with a local one-character selection; any selection
    /// deletion is an applyPromptEdit packet that is refused.
    @MainActor
    private func selectedRefusingPane() async throws -> RefusingPromptPane {
        let p = try RefusingPromptPane(kind: .codex)
        await p.render("❯ hello")
        p.view.keyDown(with: try p.left(modifiers: .shift))
        #expect(p.recorder.data.isEmpty, "selection is local")
        return p
    }

    /// M6 (replay): a replayed .deleteSelection whose dispatch is refused is
    /// kept, once, ahead of the keys replayed after it, behind a visible hold.
    @MainActor
    @Test("A refused replayed selection deletion stays first behind a visible hold", .timeLimit(.minutes(1)))
    func refusedReplayedDeletionKeepsOrderBehindHold() async throws {
        let p = try await selectedRefusingPane()
        defer { p.close() }
        p.view.replaySelectionDeletionThenKeysForTesting([try p.key("x", 7), try p.key("y", 16)])
        #expect(p.events("prompt-control-refused").contains { $0.details["reason"] == "edit" })
        #expect(p.view.promptInspectionBlocksInput, "visible hold")
        #expect(!p.view.promptInspectionRecoveryPendingForTesting || p.view.promptInspectionBlocksInput)
        #expect(p.view.deferredPromptInputSummaryForTesting == ["deleteSelection", "key:x", "key:y"],
            "original order, no duplicate: \(p.view.deferredPromptInputSummaryForTesting)")
        p.view.keyDown(with: try p.key("\u{1b}", 53))
        #expect(!p.view.promptInspectionBlocksInput)
        #expect(!p.view.promptInspectionRecoveryPendingForTesting, "Escape clears recovery")
        p.view.keyDown(with: try p.key("z", 6))
        try await p.waitForBytes(2)
        #expect(p.recorder.data == Data("\u{1B}z".utf8), "no native bytes, nothing replayed: \(Array(p.recorder.data))")
    }

    /// M6 (menu): a refused "Delete Prompt Selection" keeps the original
    /// deletion behind a visible hold; later typing queues after it.
    @MainActor
    @Test("A refused menu selection deletion is kept behind a visible hold", .timeLimit(.minutes(1)))
    func refusedMenuDeletionKeepsHold() async throws {
        let p = try await selectedRefusingPane()
        defer { p.close() }
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let item = try #require(p.view.menu(for: click)?.items.first { $0.title == "Delete Prompt Selection" })
        try #require(item.isEnabled)
        let action = try #require(item.action)
        _ = p.view.perform(action, with: item)
        #expect(p.events("prompt-control-refused").contains { $0.details["reason"] == "edit" })
        #expect(p.view.promptInspectionBlocksInput, "visible hold")
        #expect(!p.view.promptInspectionRecoveryPendingForTesting || p.view.promptInspectionBlocksInput)
        #expect(p.view.deferredPromptInputSummaryForTesting == ["deleteSelection"])
        p.view.keyDown(with: try p.key("x", 7))
        #expect(p.view.deferredPromptInputSummaryForTesting == ["deleteSelection", "key:x"],
            "later typing queues after the deletion: \(p.view.deferredPromptInputSummaryForTesting)")
        p.view.keyDown(with: try p.key("\u{1b}", 53))
        #expect(!p.view.promptInspectionBlocksInput)
        #expect(!p.view.promptInspectionRecoveryPendingForTesting, "Escape clears recovery")
        p.view.keyDown(with: try p.key("z", 6))
        try await p.waitForBytes(2)
        #expect(p.recorder.data == Data("\u{1B}z".utf8), "no native bytes, nothing replayed: \(Array(p.recorder.data))")
    }
}
#endif
