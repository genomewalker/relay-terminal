#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

private final class TerminalInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let writeEvents = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
    var writes: AsyncStream<Data> { writeEvents.stream }

    deinit { writeEvents.continuation.finish() }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
        writeEvents.continuation.yield(data)
    }
}

// These tests replace Ghostty's backend with an in-memory session. Keep the
// pane on the direct local path so the production persistent-local transport
// cannot install a second input owner behind the fixture.
private let terminalTestProfile = ConnectionProfile(
    name: "Terminal test",
    kind: .local,
    backend: .direct
)


@Suite(.serialized)
struct TerminalReadOnlyRecoveryTests {
    @MainActor
    @Test("Completed read-only failure resumes typing and retains the original queued text", .timeLimit(.minutes(1)))
    func completedReadOnlyFailureResumesNativeTypingWithoutReplay() async throws {
        _ = NSApplication.shared
        let recorder = TerminalInputRecorder()
        let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        let pane = PaneModel(profile: terminalTestProfile)
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
        session.receive("❯ first row\r\n  continuation")
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        view.remoteTerminalStateWasRestored()
        view.setShellPromptActive(true)
        try #require(view.handleApplicationClipboardAction(.selectAll))
        try #require(view.promptInspectionBlocksInput)
        let retained = "Keep  double spaces 🧬"
        view.insertText(retained, replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(window.makeFirstResponder(nil))
        await view.waitForPendingPromptInspection()
        try #require(view.promptInspectionBlocksInput)
        #expect(recorder.data.isEmpty)
        view.setSurfaceVisible(true)
        try #require(window.makeFirstResponder(view))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        view.keyDown(with: key)
        #expect(!view.promptInspectionBlocksInput)
        var writes = recorder.writes.makeAsyncIterator()
        while !String(decoding: recorder.data, as: UTF8.self).contains("z") {
            _ = try #require(await writes.next())
        }
        #expect(!String(decoding: recorder.data, as: UTF8.self).contains(retained))
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try #require(view.menu(for: click))
        #expect(menu.items.contains { $0.title == "Copy Preserved Text" && $0.isEnabled })
        let restoreClipboard = snapshotClipboard()
        defer { restoreClipboard() }
        try #require(view.copyPreservedPromptText())
        #expect(NSPasteboard.general.string(forType: .string) == retained)
        #expect(view.discardPreservedPromptInput())
        #expect(!view.promptInspectionBlocksInput)
        let cleanMenu = try #require(view.menu(for: click))
        #expect(!cleanMenu.items.contains { $0.title == "Copy Preserved Text" })
    }

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
    @Test("Typing recovery cannot bypass approvals, retained files, or uncertain mutations",
          .timeLimit(.minutes(1)), arguments: ["approval", "files", "mutation"])
    func typingRecoveryRetainsUnsafeInputGuards(scenario: String) async throws {
        _ = NSApplication.shared
        let recorder = TerminalInputRecorder()
        let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        let profile = scenario == "mutation"
            ? ConnectionProfile(name: "Owned mutation guard", host: "owned-peer.invalid", backend: .relay)
            : terminalTestProfile
        let pane = PaneModel(profile: profile)
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
        if scenario == "approval" {
            try #require(view.beginNativePasteConfirmation() != nil)
        } else if scenario == "files" {
            try #require(view.handleApplicationClipboardAction(.selectAll))
            try #require(view.promptInspectionBlocksInput)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([URL(fileURLWithPath: "/private/tmp/retained-file.png") as NSURL])
            try #require(view.handleApplicationClipboardAction(.paste))
            try #require(window.makeFirstResponder(nil))
            await view.waitForPendingPromptInspection()
            view.setSurfaceVisible(true)
            try #require(window.makeFirstResponder(view))
        } else {
            view.insertText("replacement", replacementRange: NSRange(location: 0, length: 1))
            await view.waitForPendingPromptInspection()
        }
        try #require(view.promptInspectionBlocksInput)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        view.keyDown(with: key)
        #expect(view.promptInspectionBlocksInput)
        #expect(recorder.data.isEmpty)
        if scenario == "approval" { #expect(!view.discardPreservedPromptInput()) }
        else {
            #expect(view.discardPreservedPromptInput())
            #expect(!view.promptInspectionBlocksInput)
        }
    }
}
#endif
