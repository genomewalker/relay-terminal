#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

private final class PreservedInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let writeEvents = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
    var writes: AsyncStream<Data> { writeEvents.stream }

    deinit { writeEvents.continuation.finish() }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
        writeEvents.continuation.yield(data)
    }
}

/// Kapk e0f864c9: a placeholder mirror and a rejected click left an exact edit
/// unverifiable, so input was held with recovery required and no inspection
/// running. Every later key was queued and the only exits discarded the text.
@Suite(.serialized)
struct TerminalPreservedInputRecoveryTests {
    @MainActor
    private func snapshotClipboard() -> @MainActor () -> Void {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return {
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            board.writeObjects(items)
        }
    }

    @MainActor
    private func key(_ characters: String, _ keyCode: UInt16, _ window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    @MainActor
    private func events(_ name: String, pane: PaneModel) -> [RelayDiagnosticEvent] {
        let id = pane.id.uuidString.lowercased()
        return RelayDiagnostics.shared.snapshot().events.filter {
            $0.category == "terminal-input" && $0.name == name && $0.details["pane_id"] == id
        }
    }

    @MainActor
    @Test("Placeholder mirror, rejected click and typing never deadlock or silently drop held input",
          .timeLimit(.minutes(1)))
    func idleRecoveryHoldResumesOnEscapeWithoutLossOrReplay() async throws {
        _ = NSApplication.shared
        let recorder = PreservedInputRecorder()
        let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        // The production exact-mutation path: an owned remote Claude pane.
        let pane = PaneModel(profile: ConnectionProfile(name: "Owned held input",
            host: "owned-peer.invalid", backend: .relay))
        pane.setAgentKind(.claude)
        let runtime = pane.runtime
        let view = runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let lease = UUID()
        let generation = runtime.beginPresentationAttachment(lease: lease)
        runtime.setPresented(true, lease: lease, generation: generation)
        runtime.setKeyboardFocusEligible(true)
        view.setSurfaceVisible(true)
        defer {
            runtime.endPresentationAttachment(lease: lease, generation: generation)
            window.orderOut(nil)
            window.contentView = nil
        }
        view.fitToSize()
        try #require(window.makeFirstResponder(view))
        // Claude's dim placeholder: the caret sits at the start of the
        // composer with text after it, so the mirror stays unknown.
        session.receive("❯ Try \"fix lint errors\"\r\u{1b}[2C")
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        view.remoteTerminalStateWasRestored()
        view.setShellPromptActive(true)
        let restoreClipboard = snapshotClipboard()
        defer { restoreClipboard() }

        // A click on the composer is rejected; it never discards or dispatches.
        let point = NSPoint(x: 40, y: view.frame.height - 6)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { view.mouseDown(with: click) } else { view.mouseUp(with: click) }
        }
        try #require(!view.promptInspectionBlocksInput)

        // An exact edit that cannot be verified: recovery required, no task.
        view.insertText("replacement", replacementRange: NSRange(location: 0, length: 1))
        await view.waitForPendingPromptInspection()
        try #require(view.promptInspectionBlocksInput)
        let preserved = try #require(events("prompt-inspection-input-preserved", pane: pane).last)
        #expect(preserved.details["reason"] == "recovery_required")
        #expect(preserved.details["inspection_active"] == "false")
        #expect(Int(preserved.details["line"] ?? "") != nil)
        #expect(events("insert-text-route", pane: pane).contains { $0.details["reason"] == "exact_replacement" })

        // Typing stays held: the uncertain-mutation guard is unchanged.
        for (character, code) in [("a", UInt16(0)), ("b", 11), ("c", 8)] {
            view.keyDown(with: try key(character, code, window))
        }
        view.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.promptInspectionBlocksInput)
        #expect(recorder.text.isEmpty, "held input is never written")
        #expect(pane.terminalInputDraftMessage ==
                TerminalRuntime.preservedTypingNotice(inspectionActive: false, files: false))
        #expect(pane.terminalInputDraftMessage?.contains("Press Escape to resume typing") == true)
        #expect(events("insert-text-route", pane: pane).contains { $0.details["reason"] == "preserved" })

        // A later click changes nothing.
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(view.promptInspectionBlocksInput)
        try #require(view.copyPreservedPromptText())
        #expect(NSPasteboard.general.string(forType: .string) == "replacementabcq")

        // Escape resumes typing without discarding or replaying.
        view.keyDown(with: try key("\u{1b}", 53, window))
        #expect(!view.promptInspectionBlocksInput)
        #expect(events("input-resumed", pane: pane).contains { $0.details["reason"] == "native_cancel" })
        #expect(events("prompt-inspection-preserved-input-discarded", pane: pane).isEmpty)
        view.keyDown(with: try key("z", 6, window))
        var writes = recorder.writes.makeAsyncIterator()
        while !recorder.text.contains("z") { _ = try #require(await writes.next()) }
        #expect(recorder.text.filter { $0 == "z" }.count == 1, "native typing is written once")
        for held in ["replacement", "a", "b", "c", "q"] {
            #expect(!recorder.text.contains(held), "held input \(held) is never replayed")
        }
        NSPasteboard.general.clearContents()
        try #require(view.copyPreservedPromptText(), "retained text stays copyable after native typing")
        #expect(NSPasteboard.general.string(forType: .string) == "replacementabcq")
        let menuClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(try #require(view.menu(for: menuClick)).items.contains {
            $0.title == "Copy Preserved Text" && $0.isEnabled })

        // A second hold and Escape appends; it never overwrites retained text.
        view.insertText("again", replacementRange: NSRange(location: 0, length: 1))
        await view.waitForPendingPromptInspection()
        try #require(view.promptInspectionBlocksInput)
        view.keyDown(with: try key("d", 2, window))
        view.keyDown(with: try key("\u{1b}", 53, window))
        #expect(!view.promptInspectionBlocksInput)
        try #require(view.copyPreservedPromptText())
        #expect(NSPasteboard.general.string(forType: .string) == "replacementabcqagaind")
        #expect(!recorder.text.contains("again") && !recorder.text.contains("d"))

        // Only the explicit Discard clears retained content.
        #expect(view.discardPreservedPromptInput())
        #expect(!view.copyPreservedPromptText())
        #expect(!(try #require(view.menu(for: menuClick)).items.contains { $0.title == "Copy Preserved Text" }))
    }

    @MainActor
    @Test("Escape keeps a hold with retained files and points to the menu", .timeLimit(.minutes(1)))
    func escapeKeepsRetainedFilesHold() async throws {
        _ = NSApplication.shared
        let recorder = PreservedInputRecorder()
        let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        let pane = PaneModel(profile: ConnectionProfile(name: "Terminal test", kind: .local, backend: .direct))
        pane.setAgentKind(.claude)
        let runtime = pane.runtime
        let view = runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let lease = UUID()
        let generation = runtime.beginPresentationAttachment(lease: lease)
        runtime.setPresented(true, lease: lease, generation: generation)
        runtime.setKeyboardFocusEligible(true)
        view.setSurfaceVisible(true)
        defer {
            runtime.endPresentationAttachment(lease: lease, generation: generation)
            window.orderOut(nil)
            window.contentView = nil
        }
        view.fitToSize()
        try #require(window.makeFirstResponder(view))
        session.receive("❯ original\r\n  continuation")
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        view.remoteTerminalStateWasRestored()
        view.setShellPromptActive(true)
        let restoreClipboard = snapshotClipboard()
        defer { restoreClipboard() }
        try #require(view.handleApplicationClipboardAction(.selectAll))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: "/private/tmp/retained-file.png") as NSURL])
        try #require(view.handleApplicationClipboardAction(.paste))
        try #require(view.promptInspectionBlocksInput)
        try #require(window.makeFirstResponder(nil))
        await view.waitForPendingPromptInspection()
        view.setSurfaceVisible(true)
        try #require(window.makeFirstResponder(view))
        try #require(view.promptInspectionBlocksInput)

        view.keyDown(with: try key("\u{1b}", 53, window))
        #expect(view.promptInspectionBlocksInput, "retained files are never dropped by Escape")
        #expect(events("input-hold-kept", pane: pane).contains { $0.details["reason"] == "files" })
        #expect(events("prompt-inspection-preserved-input-discarded", pane: pane).isEmpty)
        #expect(pane.terminalInputDraftMessage ==
                TerminalRuntime.preservedTypingNotice(inspectionActive: false, files: true))
        let menuClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let titles = try #require(view.menu(for: menuClick)).items.filter(\.isEnabled).map(\.title)
        #expect(titles.contains("Copy Preserved Files"))
        #expect(titles.contains("Discard Preserved Input"))
        #expect(view.discardPreservedPromptInput())
        #expect(!view.promptInspectionBlocksInput)
    }
}
#endif
