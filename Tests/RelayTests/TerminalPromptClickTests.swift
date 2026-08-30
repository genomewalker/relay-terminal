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

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

@MainActor
@Test("Terminal drags cannot move the workspace window")
func relayTerminalOwnsMouseDrags() {
    _ = NSApplication.shared
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let cellWidth = max(cursorLocalRect.width, 8)
    let targetLocal = NSPoint(
        x: cursorLocalRect.minX - cellWidth * 4,
        y: cursorLocalRect.midY
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
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let firstPane = PaneModel(profile: .local)
    let secondPane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    let pane = PaneModel(profile: .local)
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
    window.makeKeyAndOrderFront(nil)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.fitToSize()
    #expect(window.makeFirstResponder(view))
    view.insertText("copy-me", replacementRange: NSRange(location: NSNotFound, length: 0))

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

    for _ in 0..<7 { #expect(view.performKeyEquivalent(with: selectLeft)) }
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
    pasteboard.clearContents()
    #expect(view.performKeyEquivalent(with: copy))
    #expect(pasteboard.string(forType: .string) == "copy-me")
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
    let pane = PaneModel(profile: .local)
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
@Test("Agent transcript drag selection stays local while mouse reporting is active")
func relayAgentTranscriptSelectionCopiesLocally() async throws {
    _ = NSApplication.shared
    let recorder = TerminalInputRecorder()
    let session = InMemoryTerminalSession(
        write: { recorder.append($0) },
        resize: { _ in }
    )
    let pane = PaneModel(profile: .local)
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

    // Starting a second drag must replace the retained renderer selection,
    // not extend the old anchor. Relay deliberately keeps the highlight after
    // copying, which used to make a later selection intermittently include
    // more transcript text than the pointer covered.
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
}

@MainActor
@Test("A restored terminal redraws after a lazy SwiftUI reattachment")
func restoredTerminalRedrawsAfterReattachment() async throws {
    _ = NSApplication.shared
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let pane = PaneModel(profile: .local)
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

}
#endif
