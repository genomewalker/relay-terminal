#if canImport(AppKit)
import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

@MainActor
private final class ConsumedTextNativeView: AppTerminalView {
    var takesText = true
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        // Simulate a host's committed-text interception synchronously inside
        // the actual native handler, leaving its text collector empty.
        if takesText { consumeCurrentTextInputEvent() }
    }
}

private final class NativeInputWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    let events: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() {
        let pair = AsyncStream<Data>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); chunks.append(data); lock.unlock()
        continuation.yield(data)
    }
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return chunks.reduce(into: Data()) { $0.append($1) }
    }
    deinit { continuation.finish() }
}

private final class NativeOutputOwnedWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

private final class NativeClipboardWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    let events = AsyncStream<Data>.makeStream()
    deinit { events.continuation.finish() }
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        guard type == .inputV2 else { return }
        lock.lock(); packets.append(payload); lock.unlock()
        events.continuation.yield(payload)
    }
    var inputs: [Data] { lock.lock(); defer { lock.unlock() }; return packets }
}

@MainActor private final class NativeClipboardDelegate: TerminalSurfaceClipboardConfirmationDelegate {
    let requests = AsyncStream<TerminalClipboardConfirmationRequest>.makeStream()
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        requests.continuation.yield(request)
    }
}

@Suite(.serialized)
struct RelayPromptEditorNativeFrameTests {
    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func nativeCapturePublishesSingleOrderedPacket(kitty: Bool, bracketed: Bool) async throws {
        let (window, view, io, controller) = try await terminal()
        let writer = NativeClipboardWriter()
        let profile = ConnectionProfile(name: "Owned native keys", host: "owned-peer.invalid")
        let paneID = UUID()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
            capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
        defer {
            _ = io.removeTransport(); transport.detach()
            window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {}
        }
        io.session.receive(kitty ? "\u{001B}[>11u" : "\u{001B}[<u")
        await Task.detached { io.session.waitForPendingOutput() }.value
        io.session.receive(bracketed ? "\u{001B}[?2004h" : "\u{001B}[?2004l")
        await Task.detached { io.session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        io.installTransport(transport)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        let translated = try #require(view.collectNativeInput {
        for (code, text) in [(UInt16(123), String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                             (UInt16(51), "\u{007F}")] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        view.sendText("界abc")
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!), isARepeat: false, keyCode: 123)!)
        })
        #expect(!translated.isEmpty)
        if !kitty {
            let paste = try #require(TerminalPastePayload.encodedPayload(for: "界abc", bracketed: bracketed))
            #expect(translated == Data("\u{001B}[D\u{007F}".utf8) + paste + Data("\u{001B}[D".utf8))
        }
        #expect(writer.inputs.isEmpty)
        #expect(io.sendPromptEditorControlInput(translated, expectedControlLease: lease))
        var packets = writer.events.stream.makeAsyncIterator()
        let single = try #require(await packets.next())
        #expect(Data(single.dropFirst(24)) == translated)
        #expect(writer.inputs.count == 1)
        let fresh = view.collectNativeInput {
            #expect(view.collectNativeInput {} == nil)
            view.sendText("z")
        }
        #expect(fresh == TerminalPastePayload.encodedPayload(for: "z", bracketed: bracketed))
        let overflow = view.collectNativeInput {
            view.sendText("prefix")
            view.sendText(String(repeating: "x", count: 128 * 1024 + 1))
        }
        #expect(overflow == nil)
        let afterOverflow = view.collectNativeInput { view.sendText("fresh") }
        #expect(afterOverflow == TerminalPastePayload.encodedPayload(for: "fresh", bracketed: bracketed))
        #expect(writer.inputs.count == 1)

    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nativeEditingKeysPublishOutsideThreadBoundCapture(kitty: Bool) async throws {
        let (window, view, io, controller) = try await terminal()
        let writer = NativeClipboardWriter()
        let profile = ConnectionProfile(name: "Owned native keys", host: "owned-peer.invalid")
        let paneID = UUID()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
            capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
        defer {
            _ = io.removeTransport(); transport.detach()
            window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {}
        }
        io.session.receive(kitty ? "\u{001B}[>11u" : "\u{001B}[<u")
        await Task.detached { io.session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        io.installTransport(transport)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        for (code, text) in [(UInt16(123), String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                             (UInt16(51), "\u{007F}")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        #expect(!io.endPromptControlCapture())
        var packets = writer.events.stream.makeAsyncIterator()
        let arrow = Data(try #require(await packets.next()).dropFirst(24))
        let deletion = Data(try #require(await packets.next()).dropFirst(24))
        #expect(!arrow.isEmpty && !deletion.isEmpty)
        if !kitty { #expect(arrow + deletion == Data("\u{001B}[D\u{007F}".utf8)) }
    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func synchronousPasteEncodingMatchesInstalledNativeRenderer(bracketed: Bool) async throws {
        let (window, view, io, controller) = try await terminal()
        let writer = NativeClipboardWriter()
        let profile = ConnectionProfile(name: "Owned paste encoding", host: "owned-peer.invalid")
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: UUID(),
            capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
        defer {
            _ = io.removeTransport(); transport.detach()
            window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {}
        }
        io.session.receive(bracketed ? "\u{001B}[?2004h" : "\u{001B}[?2004l")
        await Task.detached { io.session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        io.installTransport(transport)
        let controls = [UInt8](arrayLiteral: 0, 8, 5, 4, 27, 127, 3, 28, 21, 26, 17, 19, 23, 22, 18, 15)
        let text = "first\r\nsecond\t界👩🏽‍💻" + String(decoding: controls, as: UTF8.self) + "tail"
        let expected = try #require(TerminalPastePayload.encodedPayload(for: text, bracketed: bracketed))
        var packets = writer.events.stream.makeAsyncIterator()
        view.sendText(text)
        var received = Data()
        while received.count < expected.count {
            let packet = try #require(await packets.next())
            received.append(packet.dropFirst(24))
        }
        #expect(received == expected, "Native bytes: \(Array(received.prefix(128)))")
    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func isolatedNativePastePublishesOutsideThreadBoundCapture(approvedClipboard: Bool) async throws {
        let (window, view, io, controller) = try await terminal()
        TerminalDebugLog.enable([.input, .lifecycle])
        defer { TerminalDebugLog.isEnabled = false }
        let delegate = NativeClipboardDelegate(), writer = NativeClipboardWriter()
        let profile = ConnectionProfile(name: "Owned native clipboard", host: "owned-peer.invalid")
        let paneID = UUID()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
            capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
        defer {
            delegate.requests.continuation.finish()
            _ = io.removeTransport(); transport.detach()
            window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {}
        }
        view.delegate = delegate
        io.session.receive("\u{001B}[?2004l❯ original")
        await Task.detached { io.session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        io.installTransport(transport)
        var requests = delegate.requests.stream.makeAsyncIterator()
        var request: TerminalClipboardConfirmationRequest?
        if approvedClipboard {
            #expect(view.pasteCapturedText("first\nsecond"))
            request = try #require(await requests.next())
        }
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data(repeating: 0x7F, count: 8))
        if let request { request.respond(allow: true) }
        else { view.sendText("first\nsecond") }
        // Ghostty's I/O thread publishes the paste on its own schedule. Wait for
        // it instead of racing it: it must leave while the capture is still
        // open, outside the thread-bound buffer.
        var packets = writer.events.stream.makeAsyncIterator()
        let later = Data(try #require(await packets.next()).dropFirst(24))
        let pasted = String(decoding: later, as: UTF8.self)
        #expect(pasted.contains("first") && pasted.contains("second"), "Later bytes: \(Array(later.prefix(128)))")
        #expect(!later.contains(0x7F))
        // The paste is unacknowledged input ahead of the captured edit, so the
        // edit is refused rather than applied to a prompt the user changed.
        #expect(!io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
    }

    @MainActor private func terminal() async throws -> (NSWindow, AppTerminalView, TerminalIOBridge, TerminalController) {
        _ = NSApplication.shared
        TerminalDebugLog.enable([.lifecycle])
        defer { TerminalDebugLog.isEnabled = false }
        let controller = TerminalController()
        let io = TerminalIOBridge()
        var viewports = io.session.nativeResizeEvents().makeAsyncIterator()
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io.session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Attach a hidden in-memory surface: no focus claim, PTY, or provider.
        window.contentView = view
        #expect(view.window === window)
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        view.controller = controller
        view.fitToSize()
        #expect(!window.isVisible)
        let metrics = view.currentGridMetrics()
        _ = try #require(metrics)
        _ = try #require(await viewports.next())
        return (window, view, io, controller)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func promptEditorRestorationReportsActualNativeParseCompletion() async throws {
        let (window, view, io, controller) = try await terminal()
        defer { window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {} }
        let barrier = io.beginPromptEditorRestorationBarrier()
        defer { io.endPromptEditorRestorationBarrier(barrier.id) }
        var events = barrier.events.makeAsyncIterator()
        let armed = try #require(await events.next())
        guard case .armed(let baseline) = armed else { Issue.record("Barrier did not arm"); return }
        let frame = Data("\u{1b}[?2026h".utf8) + Data(repeating: 0x78, count: 512) + Data("\u{1b}[?2026l".utf8)
        #expect(io.receive(frame))
        let parsed = try #require(await events.next())
        guard case .parsedFrame(let revision) = parsed else { Issue.record("No parsed provider frame"); return }
        #expect(revision > baseline)
        #expect(io.session.parsedHostOutputRevision >= revision)
        view.synchronizeAndRedraw()
        #expect(view.readViewportText()?.contains("x") == true)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func promptEditorRestorationIgnoresNativeC1TitlePayload() async throws {
        let (window, view, io, controller) = try await terminal()
        defer { window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {} }
        let barrier = io.beginPromptEditorRestorationBarrier()
        var events = barrier.events.makeAsyncIterator()
        guard case .armed = try #require(await events.next()) else { Issue.record("Barrier did not arm"); return }
        var output = io.session.parsedHostOutputEvents().makeAsyncIterator()
        _ = await output.next()
        let frame = Data("\u{1b}[?2026h".utf8) + Data([0x1b, 0x9d]) + Data("0;".utf8) + Data(repeating: 0x78, count: 512) + Data([7]) + Data("\u{1b}[?2026l".utf8)
        #expect(io.receive(frame))
        _ = try #require(await output.next())
        io.endPromptEditorRestorationBarrier(barrier.id)
        #expect(await events.next() == nil)
        view.synchronizeAndRedraw()
        #expect(view.readViewportText()?.contains("x") == false)
    }
    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func consumedNativeTextDoesNotFallThroughAndNextKeyStillDispatches(kitty: Bool) async throws {
        _ = NSApplication.shared
        let writes = NativeInputWrites()
        let session = InMemoryTerminalSession(write: { writes.append($0) }, resize: { _ in })
        var resizes = session.nativeResizeEvents().makeAsyncIterator()
        let controller = TerminalController()
        let view = ConsumedTextNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.controller = controller
        view.fitToSize()
        _ = try #require(await resizes.next())
        defer { window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {} }
        #expect(!window.isVisible)
        func event(_ type: NSEvent.EventType, _ text: String, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        var inputs = writes.events.makeAsyncIterator()
        var expected = [Data("b".utf8)]
        var baseline = Data()
        if kitty {
            var parsed = session.parsedHostOutputEvents().makeAsyncIterator()
            _ = await parsed.next()
            // Disambiguation + event types + all keys, per the Kitty spec.
            session.receive("\u{1b}[>11u")
            _ = try #require(await parsed.next())
            view.takesText = false
            view.keyDown(with: try event(.keyDown, "b", 11))
            view.keyUp(with: try event(.keyUp, "b", 11))
            expected = [try #require(await inputs.next()), try #require(await inputs.next())]
            #expect(String(data: expected[1], encoding: .utf8)?.contains(":3u") == true)
            baseline = expected.reduce(into: Data()) { $0.append($1) }
            view.takesText = true
        }
        view.keyDown(with: try event(.keyDown, "a", 0))
        view.keyUp(with: try event(.keyUp, "a", 0))
        view.takesText = false
        view.keyDown(with: try event(.keyDown, "b", 11))
        view.keyUp(with: try event(.keyUp, "b", 11))
        // The following normal key is a real backend write sentinel after the
        // intercepted event, not a delay or a predicate-only dispatch model.
        for chunk in expected {
            let dispatched = try #require(await inputs.next())
            #expect(dispatched == chunk)
        }
        #expect(writes.data == baseline + expected.reduce(into: Data()) { $0.append($1) })
    }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func retiredProducerCannotPaintIntoSuccessor(reentrant: Bool) async throws {
        let (window, view, io, controller) = try await terminal()
        defer { window.contentView = nil; view.controller = nil; withExtendedLifetime(controller) {} }
        let profile = ConnectionProfile(name: "Owned output fixture", host: "owned-output.invalid")
        let paneID = UUID()
        func transport() -> RelayRemoteTransport {
            RelayRemoteTransport(attachedFrameWriter: NativeOutputOwnedWriter(), profile: profile,
                paneID: paneID, capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
        }
        let original = transport(), successor = transport()
        defer { original.detach(); successor.detach() }
        io.installTransport(original)
        if reentrant {
            io.onSemanticPromptStateChanged = { _ in io.installTransport(successor) }
        } else {
            io.installTransport(successor)
            #expect(!io.performForTransport(original) { io.beginReplay() })
            #expect(io.performForTransport(successor) {})
        }
        var output = io.session.parsedHostOutputEvents().makeAsyncIterator()
        let baseline = try #require(await output.next())
        #expect(!io.receive(Data("\u{1b}]133;B\u{7}RETIRED_OUTPUT".utf8),
            remoteSequence: 999, sourceTransport: original))
        #expect(io.session.parsedHostOutputRevision == baseline)
        #expect(io.receive(Data("CURRENT_OUTPUT".utf8), remoteSequence: 1, sourceTransport: successor))
        _ = try #require(await output.next())
        view.synchronizeAndRedraw()
        let text = try #require(view.readViewportText())
        #expect(text.contains("CURRENT_OUTPUT"))
        #expect(!text.contains("RETIRED_OUTPUT"))
    }

}
#endif
