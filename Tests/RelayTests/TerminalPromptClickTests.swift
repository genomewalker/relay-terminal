#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
@testable import Relay

// These tests intentionally share AppKit's process-global key window and
// general pasteboard. Running them concurrently makes one test clear another
// test's clipboard or steal first responder, which is not representative of a
// single foreground Relay application.
@Suite(.serialized)
struct TerminalPromptClickTests {

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

@MainActor
private func presentInputFixture(_ pane: PaneModel) -> @MainActor () -> Void {
    let runtime = pane.runtime
    let lease = UUID()
    let generation = runtime.beginPresentationAttachment(lease: lease)
    runtime.setPresented(true, lease: lease, generation: generation)
    runtime.setKeyboardFocusEligible(true)
    runtime.view.setSurfaceVisible(true)
    return { runtime.endPresentationAttachment(lease: lease, generation: generation) }
}

@MainActor
@Test("Ordinary Claude typing and deletion do not require a draft mutation broker", .timeLimit(.minutes(1)))
func ordinaryClaudeInputDoesNotQuarantineWithoutKernelMutationService() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let profile = ConnectionProfile(name: "Owned Claude input", host: "owned-peer.invalid", backend: .relay)
    let pane = PaneModel(profile: profile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    defer { window.contentView = nil }
    view.fitToSize()
    session.receive("❯ original")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.setShellPromptActive(true)
    view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
    try #require(!view.promptInspectionBlocksInput)
    await view.waitForPendingPromptInspection()
    #expect(!view.promptInspectionBlocksInput)
    let deletion = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}",
        isARepeat: false, keyCode: 51))
    var writes = recorder.writes.makeAsyncIterator()
    view.keyDown(with: deletion)
    #expect(!view.promptInspectionBlocksInput)
    while !recorder.data.contains(0x7F) { _ = try #require(await writes.next()) }
    #expect(recorder.data.contains(0x7F))
}

@MainActor
@Test("Native cancellation releases preserved Claude input and stays released", .timeLimit(.minutes(1)), arguments: [false, true])
func nativeClaudeCancellationReleasesQuarantine(escape: Bool) async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: ConnectionProfile(name: "Owned Claude cancel", host: "owned-peer.invalid", backend: .relay))
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    defer { window.contentView = nil }
    view.fitToSize()
    session.receive("❯ original")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.setShellPromptActive(true)
    view.insertText("x", replacementRange: NSRange(location: 0, length: 1))
    try #require(view.promptInspectionBlocksInput)
    let key = escape ? "\u{001B}" : "\u{0003}"
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: escape ? [] : [.control], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: key,
        charactersIgnoringModifiers: escape ? key : "c", isARepeat: false, keyCode: escape ? 53 : 8))
    var writes = recorder.writes.makeAsyncIterator()
    view.keyDown(with: event)
    #expect(!view.promptInspectionBlocksInput)
    let byte: UInt8 = escape ? 0x1B : 0x03
    while !recorder.data.contains(byte) { _ = try #require(await writes.next()) }
    await view.waitForPendingPromptInspection()
    await Task.yield()
    #expect(!view.promptInspectionBlocksInput)
    #expect(recorder.data.contains(byte))
}

@MainActor
private final class ClipboardConfirmationRecorder: TerminalSurfaceClipboardConfirmationDelegate {
    let requests = AsyncStream<TerminalClipboardConfirmationRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var onRequest: ((TerminalClipboardConfirmationRequest) -> Void)?
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        onRequest?(request)
        requests.continuation.yield(request)
    }
}

@MainActor
@Test("Native captured paste confirms the captured value and never reads the changed clipboard", .timeLimit(.minutes(1)), arguments: [false, true])
func nativeCapturedPasteUsesOriginalValue(allow: Bool) async throws {
    _ = NSApplication.shared
    let input = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    let confirmation = ClipboardConfirmationRecorder()
    defer { confirmation.requests.continuation.finish() }
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    view.delegate = confirmation
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize()
    session.receive("\u{001B}[?2004l❯ ")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        let items = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents(); pasteboard.writeObjects(items)
    }
    pasteboard.clearContents(); pasteboard.setString("changed clipboard", forType: .string)
    var requests = confirmation.requests.stream.makeAsyncIterator()
    #expect(view.pasteCapturedText("captured\npaste"))
    let request = try #require(await requests.next())
    #expect(request.contents == "captured\npaste")
    #expect(pasteboard.string(forType: .string) == "changed clipboard")
    #expect(input.data.isEmpty)
    request.respond(allow: allow)
    if allow {
        var writes = input.writes.makeAsyncIterator()
        while !String(decoding: input.data, as: UTF8.self).contains("paste") {
            guard await writes.next() != nil else { break }
        }
        #expect(String(decoding: input.data, as: UTF8.self).contains("captured"))
        #expect(!String(decoding: input.data, as: UTF8.self).contains("changed clipboard"))
    } else {
        #expect(input.data.isEmpty)
    }
}

@MainActor
@Test("Paste approval replaces the selected draft while Cancel and changed context preserve it", .timeLimit(.minutes(1)), arguments: [(false, false), (true, false), (true, true)])
func nativePasteDecisionPreservesSelectionUntilApproval(allow: Bool, changeContext: Bool) async throws {
    _ = NSApplication.shared
    let input = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    let confirmation = ClipboardConfirmationRecorder()
    defer { confirmation.requests.continuation.finish() }
    var decision: UUID?
    confirmation.onRequest = { _ in decision = view.beginNativePasteConfirmation() }
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    view.delegate = confirmation
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("\u{001B}[?2004l❯ original")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw(); view.remoteTerminalStateWasRestored(); view.setShellPromptActive(true)
    #expect(view.handleApplicationClipboardAction(.selectAll))
    var requests = confirmation.requests.stream.makeAsyncIterator()
    let admitted = view.pasteCapturedText("first\nsecond")
    try #require(admitted, "Captured paste admission: \(view.capturedPasteRequestState)")
    let request = try #require(await requests.next())
    let token = try #require(decision)
    #expect(view.promptInspectionBlocksInput)
    #expect(input.data.isEmpty)
    if allow {
        view.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.data.isEmpty)
    }
    if changeContext { pane.userEnteredInput() }
    view.finishNativePasteConfirmation(token, request: request, allow: allow, ownerIsValid: true)
    #expect(view.promptInspectionBlocksInput == changeContext)
    if changeContext {
        #expect(input.data.isEmpty)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents(); pasteboard.writeObjects(items)
        }
        #expect(view.handleApplicationClipboardAction(.copy))
        #expect(pasteboard.string(forType: .string) == "first\nsecondtyped")
        #expect(input.data.isEmpty)
        #expect(view.discardPreservedPromptInput())
        #expect(!view.promptInspectionBlocksInput)
        #expect(input.data.isEmpty)
    } else if allow {
        var writes = input.writes.makeAsyncIterator()
        while !String(decoding: input.data, as: UTF8.self).contains("typed") {
            guard await writes.next() != nil else { break }
        }
        let text = String(decoding: input.data, as: UTF8.self)
        #expect(input.data.starts(with: Data(repeating: 0x7F, count: "original".count)))
        let first = try #require(text.range(of: "first"))
        let typed = try #require(text.range(of: "typed"))
        #expect(first.lowerBound < typed.lowerBound)
        #expect(!text.contains("original"))
        #expect(view.promptMirrorIsAwaitingHostOutput)
        let outputRevision = session.parsedHostOutputRevision
        var outputEvents = session.parsedHostOutputEvents().makeAsyncIterator()
        #expect(await outputEvents.next() == outputRevision)
        view.setMarkedText("renderer-only", selectedRange: NSRange(location: 13, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText(); view.synchronizeAndRedraw()
        #expect(session.parsedHostOutputRevision == outputRevision)
        #expect(view.promptMirrorIsAwaitingHostOutput)
        session.receive("\u{001B}[2J\u{001B}[H❯ secondtyped")
        await Task.detached { session.waitForPendingOutput() }.value
        #expect(session.parsedHostOutputRevision > outputRevision)
        let parsedRevision = await outputEvents.next()
        #expect(parsedRevision != nil && parsedRevision! > outputRevision)
        view.synchronizeAndRedraw()
        #expect(view.handleApplicationClipboardAction(.selectAll))
        #expect(!view.promptMirrorIsAwaitingHostOutput)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents(); pasteboard.writeObjects(items)
        }
        #expect(view.handleApplicationClipboardAction(.copy))
        #expect(pasteboard.string(forType: .string) == "secondtyped")
    } else {
        #expect(input.data.isEmpty)
        #expect(view.selectedText() == "original")
    }
}

@MainActor
@Test("Terminal drags cannot move the workspace window")
func relayTerminalOwnsMouseDrags() {
    _ = NSApplication.shared
    let pane = PaneModel(profile: terminalTestProfile)
    #expect(!pane.runtime.view.mouseDownCanMoveWindow)
}

@MainActor
@Test("Terminal input opts out of prose correction and Writing Tools")
func relayTerminalDisablesSystemTextPrediction() {
    _ = NSApplication.shared
    let view = RelayGhosttyView(frame: .zero)
    #expect(view.autocorrectionType == .no)
    #expect(view.textCompletionType == .no)
    #expect(view.inlinePredictionType == .no)
    if #available(macOS 15.0, *) {
        #expect(view.writingToolsBehavior == .none)
    }
}

@MainActor
@Test("Relay moves the shell cursor using the terminal's active keyboard mode")
func relayPromptClickMovesCursor() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()

    session.receive(
        "\u{001B}[?1h" + // DECCKM: arrows must be SS3, not hard-coded CSI.
            "\u{001B}]133;A;redraw=last;cl=line;aid=123\u{0007}" +
            "\u{001B}]133;P;k=i\u{0007}$ \u{001B}]133;B\u{0007}abcdefghij"
    )
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    // This fixture installs its backend directly on the view, bypassing the
    // runtime I/O parser that normally consumes OSC 133's editable marker.
    view.setShellPromptActive(true)
    pane.runtime.terminalDidChangeWorkingDirectory("/tmp")
    // Mirror the input as if the user had typed it locally. Cursor placement is
    // deliberately disabled for unknown/restored line-editor state, where a
    // grid delta could otherwise send thousands of arrows past prompt start.
    view.insertText("abcdefghij", replacementRange: NSRange(location: NSNotFound, length: 0))

    let cursorScreenRect = view.firstRect(
        forCharacterRange: NSRange(location: NSNotFound, length: 0),
        actualRange: nil
    )
    #expect(cursorScreenRect != .zero)
    let cursorWindowRect = window.convertFromScreen(cursorScreenRect)
    let cursorLocalRect = view.convert(cursorWindowRect, from: nil)
    let clickMetrics = try #require(view.currentGridMetrics())
    let cellWidth = CGFloat(clickMetrics.cellWidthPixels) / window.backingScaleFactor
    let cellHeight = CGFloat(clickMetrics.cellHeightPixels) / window.backingScaleFactor
    let targetLocal = NSPoint(
        x: cursorLocalRect.minX - cellWidth * 4,
        y: cursorLocalRect.midY + cellHeight
    )
    let targetWindow = view.convert(targetLocal, to: nil)
    let inputByteCountBeforeClick = recorder.data.count

    guard let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: targetWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ), let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: targetWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct prompt click events")
        return
    }

    view.mouseDown(with: down)
    view.mouseUp(with: up)
    try await Task.sleep(for: .milliseconds(50))

    #expect(window.firstResponder === view)
    let clickInput = recorder.data.dropFirst(inputByteCountBeforeClick)
    let expected = Data([0x1B, 0x4F, 0x44] + [0x1B, 0x4F, 0x44] +
        [0x1B, 0x4F, 0x44] + [0x1B, 0x4F, 0x44])
    #expect(Data(clickInput) == expected)
}

@MainActor
@Test("A focused host-managed Relay terminal forwards ordinary keyboard input")
func relayHostManagedTerminalForwardsKeyboardInput() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))

    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0
    ) else {
        Issue.record("AppKit could not construct a keyboard event")
        return
    }

    view.keyDown(with: event)
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data == Data("a".utf8))
}

@MainActor
@Test("Relay preserves Shift-Enter through the negotiated Kitty keyboard protocol")
func relayHostManagedTerminalForwardsShiftEnter() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))

    // Kitty disambiguation makes modified Enter distinct from ordinary CR.
    session.receive("\u{001B}[>1u")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let inputByteCountBeforeKey = recorder.data.count

    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .shift,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    ) else {
        Issue.record("AppKit could not construct a Shift-Enter event")
        return
    }

    #expect(view.performKeyEquivalent(with: event))
    try await Task.sleep(for: .milliseconds(30))
    let keyInput = recorder.data.dropFirst(inputByteCountBeforeKey)
    #expect(Data(keyInput) == Data("\u{001B}[13;2u".utf8))
}

@MainActor
@Test("Only the selected terminal may complete delayed focus recovery")
func selectedTerminalOwnsDelayedFocusRecovery() async throws {
    _ = NSApplication.shared
    let firstPane = PaneModel(profile: terminalTestProfile)
    let secondPane = PaneModel(profile: terminalTestProfile)
    let first = firstPane.runtime.view
    let second = secondPane.runtime.view
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    first.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    second.frame = NSRect(x: 400, y: 0, width: 400, height: 400)
    container.addSubview(first)
    container.addSubview(second)

    let window = NSWindow(
        contentRect: container.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = container
    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }

    let firstLease = UUID()
    let firstGeneration = firstPane.runtime.beginPresentationAttachment(lease: firstLease)
    firstPane.runtime.setPresented(true, lease: firstLease, generation: firstGeneration)
    let secondLease = UUID()
    let secondGeneration = secondPane.runtime.beginPresentationAttachment(lease: secondLease)
    secondPane.runtime.setPresented(true, lease: secondLease, generation: secondGeneration)

    firstPane.runtime.setKeyboardFocusEligible(true)
    firstPane.runtime.focus()
    firstPane.runtime.setKeyboardFocusEligible(false)
    secondPane.runtime.setKeyboardFocusEligible(true)
    secondPane.runtime.focus()

    try await Task.sleep(for: .milliseconds(260))
    #expect(window.firstResponder === second)
}

@MainActor
@Test("Claude Command-V uses Relay's synchronous bracketed paste path")
func claudeCommandVPastesCapturedClipboardText() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))

    session.receive("\u{001B}[?2004h")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    let multiline = "relay-claude-paste\nsecond editable line"
    pasteboard.setString(multiline, forType: .string)

    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "v",
        charactersIgnoringModifiers: "v",
        isARepeat: false,
        keyCode: 9
    ) else {
        Issue.record("AppKit could not construct a paste key event")
        return
    }

    #expect(view.performKeyEquivalent(with: event))
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data == Data("\u{001B}[200~\(multiline)\u{001B}[201~".utf8))
}

@MainActor
@Test("Codex prompt undo and redo use negotiated terminal input")
func relayCodexPromptUndoRedo() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.codex)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    session.receive("\u{001B}[>1u")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.insertText("undo-me", replacementRange: NSRange(location: NSNotFound, length: 0))

    guard let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: 6
    ), let redo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
        windowNumber: window.windowNumber, context: nil,
        characters: "Z", charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: 6
    ) else {
        Issue.record("AppKit could not construct undo events")
        return
    }

    #expect(view.performKeyEquivalent(with: undo))
    #expect(view.performKeyEquivalent(with: redo))
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data.suffix(7) == Data("undo-me".utf8))
    #expect(recorder.data.range(of: Data("\u{001B}[122;".utf8)) == nil)
}

@MainActor
@Test("Relay owns the standard macOS paste shortcut in a host-managed terminal")
func relayHostManagedTerminalPastesFromClipboard() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    #expect(pasteboard.setString("relay-paste-probe", forType: .string))

    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "v",
        charactersIgnoringModifiers: "v",
        isARepeat: false,
        keyCode: 9
    ) else {
        Issue.record("AppKit could not construct a paste key event")
        return
    }

    #expect(view.performKeyEquivalent(with: event))
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data == Data("relay-paste-probe".utf8))
}

@MainActor
@Test("Active-pane paste recovers from a transient first-responder gap")
func relayActivePanePasteRecoversTerminalFocus() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(nil))
    #expect(window.firstResponder !== view)

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    #expect(pasteboard.setString("relay-focus-gap-probe", forType: .string))

    #expect(pane.runtime.handleApplicationClipboardAction(.paste))
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === view)
    #expect(recorder.data == Data("relay-focus-gap-probe".utf8))
}

@MainActor
@Test("Keyboard prompt selection works before asynchronous agent detection")
func relayKeyboardSelectionDoesNotWaitForAgentLabel() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    view.insertText("copy-me", replacementRange: NSRange(location: NSNotFound, length: 0))
    session.receive("copy-me")
    try await Task.sleep(for: .milliseconds(30))

    guard let selectLeft = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .shift,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        isARepeat: false,
        keyCode: 123
    ), let copy = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
    ) else {
        Issue.record("AppKit could not construct keyboard-selection events")
        return
    }

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    for _ in 0..<4 { #expect(view.performKeyEquivalent(with: selectLeft)) }
    pasteboard.clearContents()
    #expect(view.copySelectedTextToPasteboard())
    #expect(pasteboard.string(forType: .string) == "y-me")
    for _ in 0..<3 { #expect(view.performKeyEquivalent(with: selectLeft)) }
    pasteboard.clearContents()
    #expect(view.copySelectedTextToPasteboard())
    #expect(pasteboard.string(forType: .string) == "copy-me")
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    #expect(pasteboard.string(forType: .string) == "copy-me")
}

@MainActor
@Test("Keyboard prompt selection follows wrapped terminal rows")
func relayKeyboardSelectionFollowsWrappedRows() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    try await Task.sleep(for: .milliseconds(50))

    let text = "0123456789abcdefghijklmnopqrstuvwxyzABCD"
    view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    session.receive(text)
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    try await Task.sleep(for: .milliseconds(30))

    guard let selectLeft = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .shift,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        isARepeat: false,
        keyCode: 123
    ) else {
        Issue.record("AppKit could not construct wrapped keyboard-selection events")
        return
    }

    for _ in text { #expect(view.performKeyEquivalent(with: selectLeft)) }
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    #expect(view.copySelectedTextToPasteboard())
    #expect(pasteboard.string(forType: .string) == text)
}

@MainActor
@Test("Option-Shift selects a prompt word for deletion and undo")
func relayKeyboardWordSelectionDeletesAndUndoes() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.codex)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    view.insertText("alpha beta", replacementRange: NSRange(location: NSNotFound, length: 0))

    let arrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    guard let selectWord = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.option, .shift],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: arrow,
        charactersIgnoringModifiers: arrow,
        isARepeat: false,
        keyCode: 123
    ), let delete = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\u{007F}",
        charactersIgnoringModifiers: "\u{007F}",
        isARepeat: false,
        keyCode: 51
    ) else {
        Issue.record("AppKit could not construct prompt word-selection events")
        return
    }

    #expect(view.performKeyEquivalent(with: selectWord))
    view.keyDown(with: delete)
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data.suffix(4) == Data(repeating: 0x7F, count: 4))

    #expect(view.performPromptHistoryAction(redo: false))
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data.suffix(10) == Data("alpha beta".utf8))
}

@MainActor
@Test("SSH-style terminal drag selection stays local while mouse reporting is active")
func relayRemoteShellTranscriptSelectionCopiesLocally() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))

    let firstProbe = "ABCDEF"
    let secondProbe = "GHIJKL"
    let probe = "\(firstProbe) \(secondProbe)"
    session.receive("\u{001B}[?1002h" + probe)
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()

    let cursorScreenRect = view.firstRect(
        forCharacterRange: NSRange(location: NSNotFound, length: 0),
        actualRange: nil
    )
    #expect(cursorScreenRect != .zero)
    let cursorWindowRect = window.convertFromScreen(cursorScreenRect)
    let cursorLocalRect = view.convert(cursorWindowRect, from: nil)
    let transcriptRowY = view.bounds.height - max(4, cursorLocalRect.height / 2)
    let startLocal = NSPoint(
        x: 5,
        y: transcriptRowY
    )
    let endLocal = NSPoint(
        x: cursorLocalRect.minX + 5,
        y: transcriptRowY
    )
    let startWindow = view.convert(startLocal, to: nil)
    let endWindow = view.convert(endLocal, to: nil)
    let now = ProcessInfo.processInfo.systemUptime

    guard let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: startWindow,
        modifierFlags: [],
        timestamp: now,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1
    ), let drag = NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: endWindow,
        modifierFlags: [],
        timestamp: now + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1
    ), let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: endWindow,
        modifierFlags: [],
        timestamp: now + 0.02,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct transcript selection events")
        return
    }

    view.mouseDown(with: down)
    view.mouseDragged(with: drag)
    view.mouseUp(with: up)
    try await Task.sleep(for: .milliseconds(50))

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    #expect(view.copySelectedTextToPasteboard())
    guard let copy = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: now + 0.03,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
    ) else {
        Issue.record("AppKit could not construct a copy key event")
        return
    }

    #expect(view.performKeyEquivalent(with: copy))
    try await Task.sleep(for: .milliseconds(30))
    #expect(pasteboard.string(forType: .string) == probe)

    // Starting a second drag must replace any renderer selection that still
    // remains, not extend the old anchor. Relay replays local drags with
    // Shift held, and Ghostty's Shift+press extends an existing selection —
    // which used to make a later selection intermittently include more
    // transcript text than the pointer covered.
    let cellWidth = max(
        1,
        (endLocal.x - startLocal.x) / CGFloat(probe.count)
    )
    let secondSelectionOffset = firstProbe.count + 1 + 3
    let secondStartLocal = NSPoint(
        x: startLocal.x + CGFloat(secondSelectionOffset) * cellWidth,
        y: transcriptRowY
    )
    let secondStartWindow = view.convert(secondStartLocal, to: nil)
    guard let secondDown = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: secondStartWindow,
        modifierFlags: [],
        timestamp: now + 0.04,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 3,
        // AppKit can report a quick focus-click followed by a drag as part of
        // a multi-click sequence. A drag must remain character-precise rather
        // than inheriting Ghostty's word-selection expansion.
        clickCount: 2,
        pressure: 1
    ), let secondDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: endWindow,
        modifierFlags: [],
        timestamp: now + 0.05,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 3,
        clickCount: 2,
        pressure: 1
    ), let secondUp = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: endWindow,
        modifierFlags: [],
        timestamp: now + 0.06,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 3,
        clickCount: 2,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct replacement selection events")
        return
    }
    view.mouseDown(with: secondDown)
    view.mouseDragged(with: secondDrag)
    view.mouseUp(with: secondUp)
    try await Task.sleep(for: .milliseconds(30))
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    try await Task.sleep(for: .milliseconds(30))
    #expect(pasteboard.string(forType: .string) == "KL")

    // A drag ending just inside the next cell should use the nearest text
    // insertion boundary. Raw terminal cell hit-testing includes that cell as
    // soon as the pointer crosses its leading edge, which feels like Relay
    // selected one character more than the user covered.
    let boundaryEndLocal = NSPoint(
        x: startLocal.x + cellWidth * 1.25,
        y: transcriptRowY
    )
    let boundaryEndWindow = view.convert(boundaryEndLocal, to: nil)
    guard let boundaryDown = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: startWindow,
        modifierFlags: [],
        timestamp: now + 0.07,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 4,
        clickCount: 1,
        pressure: 1
    ), let boundaryDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: boundaryEndWindow,
        modifierFlags: [],
        timestamp: now + 0.08,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 4,
        clickCount: 1,
        pressure: 1
    ), let boundaryUp = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: boundaryEndWindow,
        modifierFlags: [],
        timestamp: now + 0.09,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 4,
        clickCount: 1,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct boundary selection events")
        return
    }
    view.mouseDown(with: boundaryDown)
    view.mouseDragged(with: boundaryDrag)
    view.mouseUp(with: boundaryUp)
    try await Task.sleep(for: .milliseconds(30))
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    try await Task.sleep(for: .milliseconds(30))
    #expect(pasteboard.string(forType: .string) == "A")
    // Command-C is a local operation and must not write a control sequence to
    // the host-managed session. Mouse reports are likewise suppressed for the
    // drag by Relay's native-selection override.
    #expect(recorder.data.isEmpty)

    // Activating a tiled or floating pane can move its durable AppKit terminal
    // view between mouse-down and the first drag event. The selection anchor
    // must remain the cell under the initial pointer, not the obsolete window
    // coordinate stored in the original NSEvent.
    let container = NSView(frame: view.frame)
    window.contentView = container
    view.frame = container.bounds
    container.addSubview(view)
    let movingStartWindow = view.convert(secondStartLocal, to: nil)
    guard let movingDown = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: movingStartWindow,
        modifierFlags: [],
        timestamp: now + 0.10,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 5,
        clickCount: 1,
        pressure: 1
    ) else {
        Issue.record("AppKit could not construct moving-pane selection start")
        return
    }
    view.mouseDown(with: movingDown)
    view.setFrameOrigin(NSPoint(x: 90, y: 0))
    let movingEndWindow = view.convert(endLocal, to: nil)
    guard let movingDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: movingEndWindow,
        modifierFlags: [],
        timestamp: now + 0.11,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 5,
        clickCount: 1,
        pressure: 1
    ), let movingUp = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: movingEndWindow,
        modifierFlags: [],
        timestamp: now + 0.12,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 5,
        clickCount: 1,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct moving-pane selection events")
        return
    }
    view.mouseDragged(with: movingDrag)
    view.mouseUp(with: movingUp)
    try await Task.sleep(for: .milliseconds(30))
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    try await Task.sleep(for: .milliseconds(30))
    #expect(pasteboard.string(forType: .string) == "KL")
    #expect(recorder.data.isEmpty)
    view.setFrameOrigin(.zero)

    // Relay keeps the previous IOSurface visible while a remote resize waits
    // for its destination-sized PTY frame. Reproduce that retained-grid
    // interval: the visible text is scaled to half size, while Ghostty still
    // hit-tests the original grid. A drag over the scaled probe must select
    // the same text rather than cells at the unscaled pointer coordinates.
    let retainedSize = view.bounds.size
    view.setResizeSynchronizationSuspended(true)
    defer { view.setResizeSynchronizationSuspended(false) }
    window.setContentSize(NSSize(
        width: retainedSize.width / 2,
        height: retainedSize.height / 2
    ))
    view.layoutSubtreeIfNeeded()
    let xScale = view.bounds.width / retainedSize.width
    let yScale = view.bounds.height / retainedSize.height
    let scaledStartWindow = view.convert(
        NSPoint(x: startLocal.x * xScale, y: startLocal.y * yScale),
        to: nil
    )
    let scaledEndWindow = view.convert(
        NSPoint(x: endLocal.x * xScale, y: endLocal.y * yScale),
        to: nil
    )
    guard let scaledDown = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: scaledStartWindow,
        modifierFlags: [],
        timestamp: now + 0.14,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 6,
        clickCount: 1,
        pressure: 1
    ), let scaledDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: scaledEndWindow,
        modifierFlags: [],
        timestamp: now + 0.15,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 6,
        clickCount: 1,
        pressure: 1
    ), let scaledUp = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: scaledEndWindow,
        modifierFlags: [],
        timestamp: now + 0.16,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 6,
        clickCount: 1,
        pressure: 0
    ) else {
        Issue.record("AppKit could not construct retained-grid selection events")
        return
    }
    view.mouseDown(with: scaledDown)
    view.mouseDragged(with: scaledDrag)
    view.mouseUp(with: scaledUp)
    try await Task.sleep(for: .milliseconds(30))
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    try await Task.sleep(for: .milliseconds(30))
    #expect(pasteboard.string(forType: .string) == probe)
    #expect(recorder.data.isEmpty)
}

@MainActor
@Test("A restored terminal redraws after a lazy SwiftUI reattachment")
func restoredTerminalRedrawsAfterReattachment() async throws {
    _ = NSApplication.shared
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    let terminal = pane.runtime.view
    terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }

    var firstHost: NSHostingView<Relay.TerminalSurface>? = NSHostingView(
        rootView: Relay.TerminalSurface(pane: pane)
    )
    window.contentView = firstHost
    firstHost?.frame = window.contentView?.bounds ?? window.frame
    session.receive("first attachment")
    await Task.detached { session.waitForPendingOutput() }.value
    try await Task.sleep(for: .milliseconds(300))
    #expect(terminal.window === window)
    #expect(terminal.alphaValue == 1)

    window.contentView = NSView(frame: window.frame)
    firstHost = nil
    try await Task.sleep(for: .milliseconds(80))
    #expect(terminal.window == nil)
    pane.runtime.setKeyboardFocusEligible(true)
    pane.runtime.focus()

    let secondHost = NSHostingView(rootView: Relay.TerminalSurface(pane: pane))
    window.contentView = secondHost
    secondHost.frame = window.contentView?.bounds ?? window.frame
    try await Task.sleep(for: .milliseconds(400))

    #expect(terminal.window === window)
    #expect(terminal.alphaValue == 1)
    #expect(window.firstResponder === terminal)

    NotificationCenter.default.post(
        name: .relayApplicationActivityChanged,
        object: false
    )
    try await Task.sleep(for: .milliseconds(30))
    #expect(!terminal.relaySurfaceIsVisible)
    NotificationCenter.default.post(
        name: .relayApplicationActivityChanged,
        object: true
    )
    try await Task.sleep(for: .milliseconds(30))
    #expect(terminal.relaySurfaceIsVisible)
}

@MainActor
@Test("Mouse selection deletes its exact prompt range like keyboard selection")
func mousePromptSelectionDeletesExactRange() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile); pane.setAgentKind(.codex)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    view.insertText("alpha beta", replacementRange: NSRange(location: NSNotFound, length: 0))
    session.receive("❯ alpha beta")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let rect = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: NSNotFound, length: 0), actualRange: nil)), from: nil)
    let metrics = try #require(view.currentGridMetrics())
    let width = CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor
    let height = CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor
    #expect(width > 3)
    let y = rect.midY + height
    let start = view.convert(NSPoint(x: rect.minX - 8 * width + 1, y: y), to: nil)
    let end = view.convert(NSPoint(x: rect.minX - 4 * width + 1, y: y), to: nil)
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    let now = ProcessInfo.processInfo.systemUptime
    view.mouseDown(with: try mouse(.leftMouseDown, start, now))
    view.mouseDragged(with: try mouse(.leftMouseDragged, end, now + 0.01))
    view.mouseUp(with: try mouse(.leftMouseUp, end, now + 0.02))
    let before = recorder.data.count
    let deletion = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now + 0.03, windowNumber: window.windowNumber, context: nil, characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}", isARepeat: false, keyCode: 51))
    view.keyDown(with: deletion)
    try await Task.sleep(for: .milliseconds(30))
    let edit = recorder.data.dropFirst(before)
    #expect(edit.filter { $0 == 0x7F }.count == 4)
    #expect(edit.suffix(4) == Data(repeating: 0x7F, count: 4))
}

@MainActor
@Test("Mouse selection recovers a restored shell prompt before deleting")
func mouseRestoredShellPromptSelectionDeletesExactRange() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    view.insertText("alpha beta", replacementRange: NSRange(location: NSNotFound, length: 0))
    session.receive("╰─ ❯ alpha beta")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let rect = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: NSNotFound, length: 0), actualRange: nil)), from: nil)
    let metrics = try #require(view.currentGridMetrics())
    let width = CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor
    let height = CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor
    #expect(width > 3)
    let y = rect.midY + height
    let start = view.convert(NSPoint(x: rect.minX - 8 * width + 1, y: y), to: nil)
    let end = view.convert(NSPoint(x: rect.minX - 4 * width + 1, y: y), to: nil)
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    view.setShellPromptActive(true)
    view.remoteTerminalStateWasRestored()
    let now = ProcessInfo.processInfo.systemUptime
    view.mouseDown(with: try mouse(.leftMouseDown, start, now))
    view.mouseDragged(with: try mouse(.leftMouseDragged, end, now + 0.01))
    view.mouseUp(with: try mouse(.leftMouseUp, end, now + 0.02))
    let before = recorder.data.count
    let deletion = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now + 0.03, windowNumber: window.windowNumber, context: nil, characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}", isARepeat: false, keyCode: 51))
    view.keyDown(with: deletion)
    try await Task.sleep(for: .milliseconds(30))
    let edit = recorder.data.dropFirst(before)
    #expect(edit.filter { $0 == 0x7F }.count == 4)
    #expect(edit.suffix(4) == Data(repeating: 0x7F, count: 4))
}


@MainActor
@Test("Select All followed by Delete removes the whole editable prompt")
func selectAllDeletesEntirePrompt() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.codex)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    view.insertText("alpha beta", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.handleApplicationClipboardAction(.selectAll))
    let deletion = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{007F}", charactersIgnoringModifiers: "\u{007F}", isARepeat: false, keyCode: 51))
    view.keyDown(with: deletion)
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data.suffix(10) == Data(repeating: 0x7F, count: 10))
}

@MainActor
@Test("A shell prompt suppresses stale TUI mouse reports after provider exit")
func shellPromptSuppressesStaleProviderMouseReports() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude) // Conversation classification survives CLI exit.
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("\u{001B}[?1003h\u{001B}[?1006h╰─ exit:135 ❯ ")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    #expect(view.applicationIsCapturingMouse)
    view.setShellPromptActive(true)
    let before = recorder.data
    let motion = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 150, y: 200), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    view.mouseMoved(with: motion)
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data == before)
    view.setShellPromptActive(false)
    // A newly running TUI negotiates its own mouse modes again.
    session.receive("\u{001B}[?1003h\u{001B}[?1006h")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    #expect(view.applicationIsCapturingMouse)
    let tuiMotion = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 200, y: 210), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    view.mouseMoved(with: tuiMotion)
    try await Task.sleep(for: .milliseconds(30))
    #expect(recorder.data.count > before.count)
}

@Test("Native resize subscriptions finish when their terminal session is released", .timeLimit(.minutes(1)))
func nativeResizeSubscriptionFinishesWithSession() async {
    var session: InMemoryTerminalSession? = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    weak var releasedSession = session
    var iterator = session!.nativeResizeEvents().makeAsyncIterator()
    session = nil
    #expect(releasedSession == nil)
    let next = await iterator.next()
    #expect(next == nil)
}

@Test("Parsed output subscriptions finish when their terminal session is released", .timeLimit(.minutes(1)))
func parsedOutputSubscriptionFinishesWithSession() async {
    var session: InMemoryTerminalSession? = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    weak var releasedSession = session
    var iterator = session!.parsedHostOutputEvents().makeAsyncIterator()
    #expect(await iterator.next() == 0)
    session = nil
    #expect(releasedSession == nil)
    #expect(await iterator.next() == nil)
}

@MainActor
@Test("Temporary prompt inspection reads exact provider whitespace and restores the original grid", .timeLimit(.minutes(1)))
func temporaryPromptInspectionPreservesDraftAndGrid() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    var resizeIterator = session.nativeResizeEvents().makeAsyncIterator()
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { view.finishViewportInspection(); window.orderOut(nil); window.contentView = nil }
    view.fitToSize()
    session.receive("❯ initial")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let original = try #require(view.currentGridMetrics())
    while let resized = await resizeIterator.next() {
        if resized.columns == original.columns { break }
    }
    let frame = view.frame
    let columns = min(400, 8_000 / Int(original.cellWidthPixels))
    #expect(columns > Int(original.columns))
    #expect(view.beginViewportInspection(columns: columns))
    #expect(!view.beginViewportInspection(columns: columns + 1))
    // UI size changes precede the parser's IO-thread resize. A provider
    // repaints after the native resize notification, never the UI metrics.
    while let resized = await resizeIterator.next() {
        if Int(resized.columns) == columns { break }
    }
    let fixture = "Exact  double   triple spaces 🧬 remain intact"
    // Real Claude optimizes spaces into CHA commands in its repaint. The
    // native terminal parser must recover those blank cells as exact text.
    session.receive("\u{001B}[2J\u{001B}[H❯ Exact\u{001B}[10Gdouble\u{001B}[19Gtriple\u{001B}[26Gspaces 🧬 remain intact\u{001B}[7m \u{001B}[27m\u{001B}[1D")
    await Task.detached { session.waitForPendingOutput() }.value
    let inspected = try #require(view.currentGridMetrics())
    #expect(Int(inspected.columns) == columns)
    #expect(view.parsedGridHasColumns(columns))
    #expect(!view.parsedGridHasColumns(columns - 1))
    #expect(!view.parsedGridHasColumns(columns + 1))
    let fullViewport = try #require(view.readViewportText())
    #expect(fullViewport.contains(fixture))
    let rowRange = try #require(view.readViewportRange(startRow: 0, endRow: 0, columns: columns))
    #expect(rowRange.trimmingCharacters(in: .whitespacesAndNewlines) == "❯ " + fixture)
    let line = try #require(view.readViewportRow(0, columns: columns))
    #expect(line.trimmingCharacters(in: .whitespacesAndNewlines) == "❯ " + fixture)
    #expect(view.frame == frame)
    view.restoreViewportAfterInspection()
    while let resized = await resizeIterator.next() {
        if resized.columns == original.columns { break }
    }
    session.receive("\u{001B}[2J\u{001B}[H❯ initial")
    await Task.detached { session.waitForPendingOutput() }.value
    view.finishViewportInspection()
    view.synchronizeAndRedraw()
    #expect(view.currentGridMetrics()?.columns == original.columns)
    #expect(view.currentGridMetrics()?.rows == original.rows)
    #expect(view.parsedGridHasColumns(Int(original.columns)))
    #expect(view.frame == frame)
    #expect(recorder.data.isEmpty)
}

@MainActor
@Test("Command A selects restored Claude and Codex prompts without shell markers", arguments: ["claude", "codex"])
func selectAllUnmarkedProviderPrompt(provider: String) async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(provider == "claude" ? .claude : .codex)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("old transcript must stay unselected\r\n❯ accepted suggestion first row\r\n  continuation at the live caret")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.remoteTerminalStateWasRestored()
    view.setShellPromptActive(false)
    let before = recorder.data
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        let items = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents(); pasteboard.writeObjects(items)
    }
    pasteboard.clearContents(); pasteboard.setString("unchanged clipboard", forType: .string)
    let commandA = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    #expect(view.handleApplicationClipboardShortcut(commandA))
    #expect(view.handleApplicationClipboardAction(.copy))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("accepted suggestion first row"))
    #expect(copied.contains("continuation at the live caret"))
    #expect(!copied.contains("old transcript"))
    #expect(recorder.data == before)
    await view.waitForPendingPromptInspection()
}

@MainActor
@Test("Select All copies a provider wrapped composer without recovering guessed logical text")
func selectAllRenderedProviderComposer() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("old transcript must stay unselected\r\n❯ accepted suggestion first row\r\n  continuation at the live caret")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.remoteTerminalStateWasRestored()
    view.setShellPromptActive(true)
    let before = recorder.data
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
    #expect(view.handleApplicationClipboardAction(.selectAll))
    #expect(view.handleApplicationClipboardAction(.copy))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("accepted suggestion first row"))
    #expect(copied.contains("continuation at the live caret"))
    #expect(!copied.contains("old transcript"))
    #expect(recorder.data == before)
}

@MainActor
@Test("Select All inspects a provider draft before queued replacement and Undo", .timeLimit(.minutes(1)))
func selectAllInspectsExactProviderDraftBeforeReplacement() async throws {
    try await exerciseExactProviderInspectionReplacement(paste: false)
}

@MainActor
@Test("Paste during Select All preserves the captured clipboard and Undo", .timeLimit(.minutes(1)))
func pasteDuringPromptInspectionPreservesClipboard() async throws {
    try await exerciseExactProviderInspectionReplacement(paste: true)
}

@MainActor
@Test("A queued key event replaces the recovered provider draft and supports Undo", .timeLimit(.minutes(1)))
func queuedKeyEventReplacesRecoveredProviderDraft() async throws {
    try await exerciseExactProviderInspectionReplacement(paste: false, keyboard: true)
}

@MainActor
@Test("Queued IME composition commits only the final text and supports Undo", .timeLimit(.minutes(1)))
func queuedIMECompositionReplacesRecoveredProviderDraft() async throws {
    try await exerciseExactProviderInspectionReplacement(paste: false, composition: true)
}

@MainActor
@Test("Parsed host output completes prompt inspection without renderer repaint callbacks", .timeLimit(.minutes(1)))
func providerInspectionWithoutRendererCallbacks() async throws {
    try await exerciseExactProviderInspectionReplacement(paste: false, keyboard: true, omitPaintCallbacks: true)
}

@MainActor
@Test("Provider inspection remains exact across repeated clipboard keyboard and IME transactions", .timeLimit(.minutes(1)), arguments: Array(0..<12))
func repeatedProviderInspectionTransactions(iteration: Int) async throws {
    try await exerciseExactProviderInspectionReplacement(paste: iteration % 3 == 0,
        keyboard: iteration % 3 == 1, composition: iteration % 3 == 2)
}

@MainActor
private func exerciseExactProviderInspectionReplacement(paste: Bool, keyboard: Bool = false, composition: Bool = false,
    omitPaintCallbacks: Bool = false) async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    var resizeIterator = session.nativeResizeEvents().makeAsyncIterator()
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    let presentationLease = UUID()
    let presentationGeneration = pane.runtime.beginPresentationAttachment(lease: presentationLease)
    pane.runtime.setPresented(true, lease: presentationLease, generation: presentationGeneration)
    pane.runtime.setKeyboardFocusEligible(true)
    view.setSurfaceVisible(true)
    defer { pane.runtime.endPresentationAttachment(lease: presentationLease, generation: presentationGeneration) }

    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    let original = try #require(view.currentGridMetrics())
    while let resized = await resizeIterator.next() {
        if resized.columns == original.columns { break }
    }
    let draft = "Exact  double   triple spaces 🧬 remain intact accepted suggestion tail"
    let narrow = "\u{001B}[2J\u{001B}[Hold transcript\r\n❯ Exact  double   triple spaces\r\n  🧬 remain intact accepted suggestion tail\u{001B}[7m \u{001B}[27m\u{001B}[1D"
    let wide = "\u{001B}[2J\u{001B}[H❯ " + draft + "\u{001B}[7m \u{001B}[27m\u{001B}[1D"
    session.receive(narrow)
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw(); view.remoteTerminalStateWasRestored(); view.setShellPromptActive(true)
    let providerEvents = session.nativeResizeEvents()
    let provider = Task { @MainActor in
        for await viewport in providerEvents {
            guard !Task.isCancelled else { break }
            session.receive(viewport.columns == original.columns ? narrow : wide)
            await Task.detached { session.waitForPendingOutput() }.value
            view.synchronizeAndRedraw()
        }
    }
    defer { provider.cancel() }
    if omitPaintCallbacks { view.onTerminalContentUpdate = nil }
    let before = recorder.data
    #expect(view.handleApplicationClipboardAction(.selectAll))
    let pasteboard = NSPasteboard.general
    let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        if paste {
            let items = savedItems.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents(); pasteboard.writeObjects(items)
        }
    }
    let replacement = composition ? "漢字 🧬" : keyboard ? "r" : "replacement"
    if paste {
        pasteboard.clearContents(); pasteboard.setString("replacement", forType: .string)
        #expect(view.handleApplicationClipboardAction(.paste))
        pasteboard.clearContents(); pasteboard.setString("mutated after queuing", forType: .string)
    } else if composition {
        let marked = NSMutableAttributedString(string: "preedit-only")
        view.setMarkedText(marked, selectedRange: NSRange(location: marked.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        marked.mutableString.setString("mutated preedit")
        view.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        view.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
    } else if keyboard {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: replacement,
            charactersIgnoringModifiers: replacement, isARepeat: false, keyCode: 15))
        view.keyDown(with: event)
    } else {
        let committed = NSMutableAttributedString(string: "replacement")
        view.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        committed.mutableString.setString("mutated after queuing")
    }
    #expect(recorder.data == before)
    await view.waitForPendingPromptInspection()
    try #require(!view.promptInspectionBlocksInput, "Inspection phase: \(view.promptInspectionPhase); draft: \(view.promptInspectionDraftState)")
    var writes = recorder.writes.makeAsyncIterator()
    while !String(decoding: recorder.data, as: UTF8.self).contains(replacement) {
        guard await writes.next() != nil else { break }
    }
    #expect(recorder.data.count > before.count)
    #expect(view.currentGridMetrics()?.columns == original.columns)
    #expect(view.performPromptHistoryAction(redo: false))
    while !String(decoding: recorder.data, as: UTF8.self).contains(draft) {
        guard await writes.next() != nil else { break }
    }
    #expect(String(decoding: recorder.data, as: UTF8.self).contains(draft))
    #expect(!String(decoding: recorder.data, as: UTF8.self).contains("old transcript"))
    #expect(!String(decoding: recorder.data, as: UTF8.self).contains("mutated after queuing"))
    #expect(!String(decoding: recorder.data, as: UTF8.self).contains("preedit-only"))
    #expect(!String(decoding: recorder.data, as: UTF8.self).contains("mutated preedit"))
}

@MainActor
@Test("Select All alone never starts inspection or blocks the keyboard", .timeLimit(.minutes(1)))
func failedPromptInspectionReleasesEmptyInputQueue() async throws {
    try await exerciseFailedPromptInspection(preserve: false)
}

@MainActor
@Test("Failed selection preserves typed text for copying and explicit discard", .timeLimit(.minutes(1)))
func failedPromptInspectionPreservesCopyableInput() async throws {
    try await exerciseFailedPromptInspection(preserve: true)
}

@MainActor
private func exerciseFailedPromptInspection(preserve: Bool) async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    let presentationLease = UUID()
    let presentationGeneration = pane.runtime.beginPresentationAttachment(lease: presentationLease)
    pane.runtime.setPresented(true, lease: presentationLease, generation: presentationGeneration)
    pane.runtime.setKeyboardFocusEligible(true)
    view.setSurfaceVisible(true)
    defer { pane.runtime.endPresentationAttachment(lease: presentationLease, generation: presentationGeneration) }

    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("❯ first row\r\n  continuation")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw(); view.remoteTerminalStateWasRestored(); view.setShellPromptActive(true)
    let original = try #require(view.currentGridMetrics())
    #expect(view.handleApplicationClipboardAction(.selectAll))
    // Command-A is local; only an edit of the selection starts inspection.
    #expect(!view.promptInspectionBlocksInput)
    let retained = "Saved  double spaces 🧬"
    if preserve {
        view.insertText(retained, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.promptInspectionBlocksInput)
    }
    #expect(window.makeFirstResponder(nil))
    await view.waitForPendingPromptInspection()
    #expect(view.promptInspectionBlocksInput == preserve)
    #expect(view.currentGridMetrics()?.columns == original.columns)
    #expect(recorder.data.isEmpty)
    if preserve {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents(); pasteboard.writeObjects(items)
        }
        #expect(view.handleApplicationClipboardAction(.copy))
        #expect(pasteboard.string(forType: .string) == retained)
        #expect(view.promptInspectionBlocksInput)
        #expect(recorder.data.isEmpty)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
            location: NSPoint(x: 30, y: 30), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try #require(view.menu(for: event))
        #expect(menu.items.contains { $0.title == "Copy Preserved Text" && $0.isEnabled })
        #expect(menu.items.contains { $0.title == "Discard Preserved Input" && $0.isEnabled })
        #expect(view.discardPreservedPromptInput())
        #expect(!view.promptInspectionBlocksInput)
        #expect(recorder.data.isEmpty)
    }
}

@MainActor
@Test("Preserved file pastes copy the original file URLs without terminal input", .timeLimit(.minutes(1)))
func preservedFilePasteCopiesCapturedURLs() async throws {
    _ = NSApplication.shared
    let input = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    pane.setAgentKind(.claude)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize(); #expect(window.makeFirstResponder(view))
    session.receive("❯ first row\r\n  continuation")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw(); view.remoteTerminalStateWasRestored(); view.setShellPromptActive(true)
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        let items = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents(); pasteboard.writeObjects(items)
    }
    let original = [URL(fileURLWithPath: "/private/tmp/relay-preserved-one with spaces.png"),
                    URL(fileURLWithPath: "/private/tmp/relay-preserved-two.pdf")]
    #expect(view.handleApplicationClipboardAction(.selectAll))
    pasteboard.clearContents(); #expect(pasteboard.writeObjects(original.map { $0 as NSURL }))
    #expect(view.handleApplicationClipboardAction(.paste))
    pasteboard.clearContents(); pasteboard.writeObjects([NSURL(fileURLWithPath: "/private/tmp/changed-file.png")])
    #expect(window.makeFirstResponder(nil))
    await view.waitForPendingPromptInspection()
    #expect(view.promptInspectionBlocksInput)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 30, y: 30),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let menu = try #require(view.menu(for: event))
    let item = try #require(menu.items.first { $0.title == "Copy Preserved Files" })
    #expect(item.isEnabled)
    let target = try #require(item.target as? NSObject)
    let action = try #require(item.action)
    _ = target.perform(action)
    let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []
    #expect(copied.map(\.path) == original.map(\.path).map(Optional.some))
    #expect(input.data.isEmpty)
    #expect(view.discardPreservedPromptInput())
    #expect(!view.promptInspectionBlocksInput)
    #expect(input.data.isEmpty)
}

@MainActor
@Test("Remote-restored Select All selects output without sending remote keys")
func restoredRemoteSelectAllDoesNotDisappear() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in })
    let pane = PaneModel(profile: terminalTestProfile)
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releaseInputPresentation = presentInputFixture(pane)
    defer { releaseInputPresentation() }

    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    session.receive("remote restored output\r\n$ ")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    view.setShellPromptActive(true)
    view.remoteTerminalStateWasRestored()
    let before = recorder.data
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }
    #expect(view.handleApplicationClipboardAction(.selectAll))
    #expect(view.handleApplicationClipboardAction(.copy))
    #expect(pasteboard.string(forType: .string)?.contains("remote restored output") == true)
    #expect(recorder.data == before)
}

// MARK: - Local agent Select All (no PTY bytes, editor bridge or resize)

private final class ResizeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

@MainActor
private struct LocalSelectAllFixture {
    let pane: PaneModel
    let view: RelayGhosttyView
    let window: NSWindow
    let session: InMemoryTerminalSession
    let recorder: TerminalInputRecorder
    let resizes: ResizeCounter
    let release: @MainActor () -> Void

    var commandA: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    }

    func key(_ characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}

@MainActor
private func localSelectAllFixture(kind: AgentKind?, screen: String, restored: Bool = true) async throws -> LocalSelectAllFixture {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let resizes = ResizeCounter()
    let session = InMemoryTerminalSession(write: { recorder.append($0) }, resize: { _ in resizes.increment() })
    let pane = PaneModel(profile: terminalTestProfile)
    if let kind { pane.setAgentKind(kind) }
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let releasePresentation = presentInputFixture(pane)
    window.makeKeyAndOrderFront(nil)
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    session.receive(screen)
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    if restored { view.remoteTerminalStateWasRestored() }
    view.setShellPromptActive(true)
    // Let the initial fit's native resizes settle before counting.
    try await Task.sleep(for: .milliseconds(200))
    return LocalSelectAllFixture(pane: pane, view: view, window: window, session: session, recorder: recorder,
        resizes: resizes, release: { releasePresentation(); window.orderOut(nil); window.contentView = nil })
}

@MainActor
private func withClipboard(_ body: () async throws -> Void) async rethrows {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        let items = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents(); pasteboard.writeObjects(items)
    }
    try await body()
}

/// Asserts the Command-A was local: no PTY bytes (including Ctrl+G), no
/// editor or inspection lease, no blocked input and no native resize.
@MainActor
private func expectNoSideEffects(_ f: LocalSelectAllFixture, bytes: Data, resizes: Int, columns: UInt16?) async throws {
    try await Task.sleep(for: .milliseconds(150))
    #expect(f.recorder.data == bytes)
    #expect(!f.recorder.data.dropFirst(bytes.count).contains(0x07))
    #expect(f.resizes.count == resizes)
    #expect(f.view.currentGridMetrics()?.columns == columns)
    #expect(!f.view.promptInspectionBlocksInput)
    #expect(!f.pane.runtime.holdsConversationInputLease)
}

@MainActor
@Test("Agent Command-A over the rendered composer is local and copies only the composer",
      .timeLimit(.minutes(1)), arguments: [AgentKind.claude, .codex])
func agentSelectAllRenderedComposerIsLocal(kind: AgentKind) async throws {
    let f = try await localSelectAllFixture(kind: kind,
        screen: "old transcript must stay unselected\r\n❯ composer first row\r\n  continuation at the live caret")
    defer { f.release() }
    let bytes = f.recorder.data, resizes = f.resizes.count, columns = f.view.currentGridMetrics()?.columns
    #expect(f.view.handleApplicationClipboardShortcut(f.commandA))
    try await expectNoSideEffects(f, bytes: bytes, resizes: resizes, columns: columns)
    try await withClipboard {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("sentinel", forType: .string)
        #expect(f.view.handleApplicationClipboardAction(.copy))
        let copied = try #require(NSPasteboard.general.string(forType: .string))
        #expect(copied.contains("composer first row") && copied.contains("continuation at the live caret"))
        #expect(!copied.contains("old transcript"))
    }
    try await expectNoSideEffects(f, bytes: bytes, resizes: resizes, columns: columns)
}

@MainActor
@Test("Agent Command-A with a trusted mirror selects and copies the exact draft locally")
func agentSelectAllMirrorIsLocal() async throws {
    let f = try await localSelectAllFixture(kind: .codex, screen: "old transcript must stay unselected\r\n", restored: false)
    defer { f.release() }
    f.view.insertText("alpha  beta", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(30))
    let bytes = f.recorder.data, resizes = f.resizes.count, columns = f.view.currentGridMetrics()?.columns
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    try await expectNoSideEffects(f, bytes: bytes, resizes: resizes, columns: columns)
    try await withClipboard {
        #expect(f.view.handleApplicationClipboardAction(.copy))
        #expect(NSPasteboard.general.string(forType: .string) == "alpha  beta")
    }
    #expect(f.recorder.data == bytes)
}

@MainActor
@Test("Agent Command-A without a recognisable composer selects nothing, never the transcript")
func agentSelectAllUnknownSelectsNothing() async throws {
    let f = try await localSelectAllFixture(kind: .claude, screen: "transcript line one\r\ntranscript line two")
    defer { f.release() }
    let bytes = f.recorder.data, resizes = f.resizes.count, columns = f.view.currentGridMetrics()?.columns
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    try await expectNoSideEffects(f, bytes: bytes, resizes: resizes, columns: columns)
    #expect((f.view.selectedText() ?? "").isEmpty)
    try await withClipboard {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("sentinel", forType: .string)
        _ = f.view.handleApplicationClipboardAction(.copy)
        #expect(NSPasteboard.general.string(forType: .string) == "sentinel")
    }
    // A following edit has no local selection to replace and is ordinary input.
    f.view.keyDown(with: f.key("x", keyCode: 7))
    #expect(!f.view.promptInspectionBlocksInput)
}

@MainActor
@Test("Agent Command-A sends no mouse report while the TUI captures the mouse")
func agentSelectAllUnderMouseCaptureIsLocal() async throws {
    let f = try await localSelectAllFixture(kind: .claude,
        screen: "old transcript\r\n❯ composer first row\r\n  continuation at the live caret")
    defer { f.release() }
    f.view.setShellPromptActive(false)
    f.session.receive("\u{001B}[?1003h\u{001B}[?1006h")
    await Task.detached { f.session.waitForPendingOutput() }.value
    f.view.synchronizeAndRedraw()
    #expect(f.view.applicationIsCapturingMouse)
    let bytes = f.recorder.data, resizes = f.resizes.count, columns = f.view.currentGridMetrics()?.columns
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    try await expectNoSideEffects(f, bytes: bytes, resizes: resizes, columns: columns)
}

@MainActor
@Test("An edit after a local agent Command-A starts exact inspection and queues the edit",
      .timeLimit(.minutes(1)), arguments: ["text", "delete", "paste", "cut"])
func editAfterLocalSelectAllStartsExactInspection(edit: String) async throws {
    let f = try await localSelectAllFixture(kind: .claude,
        screen: "old transcript must stay unselected\r\n❯ composer first row\r\n  continuation at the live caret")
    defer { f.release() }
    let bytes = f.recorder.data
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    #expect(!f.view.promptInspectionBlocksInput)
    try await withClipboard {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("pasted", forType: .string)
        switch edit {
        case "text": f.view.keyDown(with: f.key("x", keyCode: 7))
        case "delete": f.view.keyDown(with: f.key("\u{007F}", keyCode: 51))
        case "paste": #expect(f.view.handleApplicationClipboardAction(.paste))
        default: #expect(f.view.handleApplicationClipboardAction(.cut))
        }
        // The edit waits for the exact draft; nothing reached the PTY yet.
        #expect(f.view.promptInspectionBlocksInput)
        #expect(!String(decoding: f.recorder.data.dropFirst(bytes.count), as: UTF8.self).contains("x"))
        #expect(!f.recorder.data.dropFirst(bytes.count).contains(0x7F))
        #expect(f.window.makeFirstResponder(nil))
        await f.view.waitForPendingPromptInspection()
        if f.view.promptInspectionBlocksInput { _ = f.view.discardPreservedPromptInput() }
    }
}

@MainActor
@Test("Navigation after a local agent Command-A ends the selection without inspection")
func navigationAfterLocalSelectAllDoesNotInspect() async throws {
    let f = try await localSelectAllFixture(kind: .claude,
        screen: "old transcript\r\n❯ composer first row\r\n  continuation at the live caret")
    defer { f.release() }
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    f.view.keyDown(with: f.key("\u{F702}", keyCode: 123))
    #expect(!f.view.promptInspectionBlocksInput)
    f.view.keyDown(with: f.key("x", keyCode: 7))
    #expect(!f.view.promptInspectionBlocksInput)
}

@MainActor
@Test("Shell Command-A still uses the terminal's own select-all")
func shellSelectAllUnchanged() async throws {
    let f = try await localSelectAllFixture(kind: nil, screen: "shell history line\r\n$ ")
    defer { f.release() }
    f.view.setShellPromptActive(false)
    let bytes = f.recorder.data
    #expect(f.view.handleApplicationClipboardAction(.selectAll))
    #expect(!f.view.promptInspectionBlocksInput)
    try await withClipboard {
        #expect(f.view.handleApplicationClipboardAction(.copy))
        #expect(NSPasteboard.general.string(forType: .string)?.contains("shell history line") == true)
    }
    #expect(f.recorder.data == bytes)
}

}
#endif

@Test("Prompt mirror deleteRange removes an exact cursor-relative range without assuming caret adjacency")
func promptBufferDeleteRangeExactness() {
    // A mouse selection need not touch the caret. deleteRange must mirror the
    // remote edit exactly: caret to the range's upper end, erase back to lower.
    var buffer = TerminalPromptBuffer()
    buffer.insert("hello world") // caret at 11
    let removedMiddle = buffer.deleteRange(relativeToCursor: -8, -4) // "lo w", indices 3..<7
    #expect(removedMiddle)
    #expect(buffer.text == "helorld")
    #expect(buffer.cursor == 3)

    // Offset order is irrelevant.
    var other = TerminalPromptBuffer()
    other.insert("abcdef")
    other.move(by: -6) // caret at 0
    let removedReversed = other.deleteRange(relativeToCursor: 4, 2) // removes "cd"
    #expect(removedReversed)
    #expect(other.text == "abef")
    #expect(other.cursor == 2)

    // Rejections leave the mirror untouched: empty range, out of bounds, unreliable.
    var guarded = TerminalPromptBuffer()
    guarded.insert("abc")
    let rejectedEmpty = guarded.deleteRange(relativeToCursor: 0, 0)
    #expect(!rejectedEmpty)
    let rejectedOutOfBounds = guarded.deleteRange(relativeToCursor: -5, -1)
    #expect(!rejectedOutOfBounds)
    #expect(guarded.text == "abc")
    guarded.invalidate()
    let rejectedUnreliable = guarded.deleteRange(relativeToCursor: -1, 0)
    #expect(!rejectedUnreliable)
}

@Test("Cut is a first-class clipboard action")
func clipboardActionIncludesCut() {
    #expect(RelayClipboardAction(rawValue: "cut") == .cut)
    #expect(RelayClipboardAction.allCases.contains(.cut))
}


@Test("Restored input recovery recognizes decorated Relay shell prompts")
func decoratedPromptPrefixRecovery() {
    #expect(TerminalPromptSelectionEdit.inputPrefixLength("╰─ ❯ hello", shell: true) == 5)
    #expect(TerminalPromptSelectionEdit.inputPrefixLength("╰─ exit:1 root ❯ hello", shell: true) == 17)
    #expect(TerminalPromptSelectionEdit.inputPrefixLength("❯ hello", shell: false) == 2)
    #expect(TerminalPromptSelectionEdit.inputPrefixLength("╰─ ❯ hello", shell: false) == nil)
    #expect(TerminalPromptSelectionEdit.inputPrefixLength("output ❯ hello", shell: true) == nil)
}

@Test("Repeated pointer clicks require a proven editable rendered range")
func repeatedPointerClickRangeProof() {
    let input = Array("alpha beta alpha")
    #expect(TerminalPromptSelectionEdit.clickedRange(rendered: "alpha", characters: input, clickedIndex: 13, lineSelection: false, shell: false) == 11..<16)
    #expect(TerminalPromptSelectionEdit.clickedRange(rendered: "❯ alpha beta alpha", characters: input, clickedIndex: 3, lineSelection: true, shell: false) == 0..<16)
    #expect(TerminalPromptSelectionEdit.clickedRange(rendered: "╰─ ❯ alpha beta alpha", characters: input, clickedIndex: 3, lineSelection: true, shell: true) == 0..<16)
    #expect(TerminalPromptSelectionEdit.clickedRange(rendered: "old output", characters: input, clickedIndex: 3, lineSelection: false, shell: false) == nil)
    #expect(TerminalPromptSelectionEdit.clickedRange(rendered: "alpha", characters: input, clickedIndex: 7, lineSelection: false, shell: false) == nil)
}

@Test("Selection deletion plans reject stale ranges before mirror mutation")
func promptBufferDeletionPlanValidatesBeforeDispatch() {
    var buffer = TerminalPromptBuffer()
    buffer.insert("hello world")
    let original = buffer.snapshot
    let planned = buffer.plannedDeletionSnapshot(characterCount: 4, movementOffset: -4)
    #expect(planned?.text == "helorld")
    #expect(planned?.cursor == 3)
    #expect(buffer.snapshot == original)
    for (count, offset) in [(0, 0), (4, -9), (1, 1), (Int.max, 0), (1, Int.min)] {
        #expect(buffer.plannedDeletionSnapshot(characterCount: count, movementOffset: offset) == nil)
        #expect(buffer.snapshot == original)
    }
    buffer.invalidate()
    #expect(buffer.plannedDeletionSnapshot(characterCount: 1, movementOffset: 0) == nil)
}
