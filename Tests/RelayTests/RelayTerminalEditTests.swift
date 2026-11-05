import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Relay

private func edit(_ action: String = "key", key: String? = "escape", text: String? = nil,
                  flags: [String]? = nil, id: UUID = UUID(), token: UUID = UUID()) -> RelayTerminalEditRequest {
    .init(instance: UUID(), requestID: id, token: token, action: action, text: text, key: key, modifiers: flags)
}

@Suite("Terminal editing", .serialized)
struct RelayTerminalEditTests {
@Test func terminalEditingRejectsControlInjectionAndAmbiguousActions() {
    #expect(edit().isValid)
    #expect(edit("insert_text", key: nil, text: "safe\nmultiline\ttext").isValid)
    #expect(edit(key: "a", flags: ["control"]).isValid)
    for request in [edit(key: "unknown"), edit(key: "escape", text: "hidden"),
        edit(flags: ["command"]), edit(flags: ["control", "control"]),
        edit("insert_text", key: nil, text: "x\u{1b}[2J"),
        edit("insert_text", key: nil, text: "x\u{85}"),
        edit("insert_text", key: nil, text: String(repeating: "x", count: 8193)),
        edit("insert_text", key: nil, text: "text", flags: ["control"])] {
        #expect(!request.isValid)
    }
    for key in RelayTerminalEditKey.allCases { #expect(!key.native.characters.isEmpty) }
}

@Test func terminalEditingIDsCannotRedispatchOrCrossPanes() {
    var receipts = RelayTerminalEditReceipts()
    let pane = UUID(), request = edit()
    #expect(receipts.begin(pane: pane, request: request) == .admitted)
    #expect(receipts.begin(pane: pane, request: request) == .replay("dispatching"))
    #expect(receipts.begin(pane: UUID(), request: request) == .conflict)
    #expect(receipts.begin(pane: pane, request: edit(id: request.requestID)) == .conflict)
    receipts.finish(request.requestID, status: "sent")
    #expect(receipts.begin(pane: pane, request: request) == .replay("sent"))
    #expect(receipts.status(pane: pane, id: request.requestID) == "sent")
    #expect(receipts.status(pane: UUID(), id: request.requestID) == nil)
    let before = receipts.status(pane: pane, id: request.requestID)
    #expect(receipts.status(pane: pane, id: UUID()) == nil)
    #expect(receipts.status(pane: pane, id: request.requestID) == before)
    receipts.capacity = 1
    #expect(receipts.begin(pane: pane, request: edit()) == .full)
}

@MainActor
@Test("Terminal editing uses native key modes and paste without Return", .timeLimit(.minutes(2)))
func terminalEditingNativeTranslationDoesNotWriteBeforeTransportAdmission() async throws {
    _ = NSApplication.shared
    let session = InMemoryTerminalSession(write: { _ in Issue.record("Native translation escaped capture") }, resize: { _ in })
    let pane = PaneModel(profile: ConnectionProfile(name: "Owned terminal edit test", host: "owned-peer.invalid", backend: .relay))
    let view = pane.runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 440)
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.fitToSize()
    await Task.yield()
    defer { window.contentView = nil }
    session.receive("\u{1b}[?1h\u{1b}[?2004h")
    await Task.detached { session.waitForPendingOutput() }.value
    view.synchronizeAndRedraw()
    let cases: [(RelayTerminalEditRequest, Data)] = [
        (edit(), Data([27])), (edit(key: "enter"), Data([13])),
        (edit(key: "a", flags: ["control"]), Data([1])),
        (edit(key: "left"), Data("\u{1b}OD".utf8)),
        (edit("insert_text", key: nil, text: "hello"), Data("\u{1b}[200~hello\u{1b}[201~".utf8))
    ]
    for (request, expected) in cases {
        let packet = try #require(view.collectNativeInput { view.translateTerminalEdit(request) })
        #expect(packet == expected)
    }
}

private final class TerminalEditFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var inputCount = 0
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        guard type == .inputV2 || type == .automationInputV2 else { return }
        lock.lock(); inputCount += 1; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return inputCount }
}

@MainActor
@Test("Terminal editing refuses changed process, screen, input, grant or expired proof", .timeLimit(.minutes(2)))
func terminalEditingRuntimeFencesRejectChangesBeforeNativeDispatch() async throws {
    _ = NSApplication.shared
    for change in ["process", "screen", "input", "grant", "expiry"] {
        let profile = ConnectionProfile(name: "Owned terminal edit fences", host: "owned-peer.invalid", backend: .relay)
        let pane = PaneModel(profile: profile)
        let runtime = pane.runtime
        let writer = TerminalEditFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
            capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
        runtime.ioForTesting.seedInitialViewport(.init(columns: 100, rows: 30))
        runtime.startForTesting(transport: transport)
        // Match production startup: register the pane before output is retained.
        _ = runtime.ioForTesting.restoreSnapshot(paneID: pane.id)
        defer { TerminalSnapshotStore.shared.remove(paneID: pane.id) }
        let session = runtime.ioForTesting.session
        let view = runtime.view
        // State now uses the worker snapshot; do not manufacture a live-view resize.
        #expect(runtime.ioForTesting.receive(Data("\u{1b}[2J\u{1b}[Howned terminal prompt > ".utf8), remoteSequence: 1))
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        pane.connectionState = .connected
        let binding = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
            nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
            provider: "shell", processId: 333, processStart: 2, sessionId: nil, transcriptIdentity: nil)
        var owner = RelayPromptOwnerIdentity(hostID: profile.id, binding: binding)
        runtime.promptOwnerBindingForTesting = { owner }
        var uptime: TimeInterval = 100
        runtime.terminalEditUptimeForTesting = { uptime }
        let state = await runtime.terminalEditState()
        #expect(state["status"] == "observed", "state for \(change): \(state)")
        let token = try #require(state["proof_id"].flatMap(UUID.init(uuidString:)))
        let request = edit(token: token)
        switch change {
        case "process":
            let successor = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
                nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 334, shellStart: 3,
                provider: "shell", processId: 334, processStart: 3, sessionId: nil, transcriptIdentity: nil)
            owner = RelayPromptOwnerIdentity(hostID: profile.id, binding: successor)
        case "screen":
            #expect(runtime.ioForTesting.receive(Data("changed after observation".utf8), remoteSequence: 2))
            await Task.detached { session.waitForPendingOutput() }.value
            view.synchronizeAndRedraw()
        case "input": pane.userEnteredInput()
        case "expiry": uptime += 31
        default: break
        }
        let result = await runtime.sendTerminalEdit(request, authorization: { change != "grant" })
        #expect(result == "not_sent", "must refuse \(change)")
        #expect(writer.count == 0, "no packet after \(change)")
        // A consumed token stays consumed, even if the process/grant recovers.
        #expect(await runtime.sendTerminalEdit(request) == "not_sent")
        #expect(writer.count == 0)
        _ = runtime.ioForTesting.removeTransport(); transport.detach()
        runtime.stop()
    }
}

@MainActor
@Test("An attached native renderer remains editable without complete replay history", .timeLimit(.minutes(2)))
func terminalEditingAttachedRendererFallbackKeepsLiveFences() async throws {
    _ = NSApplication.shared
    let keyWindow = NSApp.keyWindow
    for change in ["none", "output", "detach", "owner", "hidden", "hidden_output", "hidden_input", "hidden_replay", "retired"] {
        let profile = ConnectionProfile(name: "Owned renderer fallback", kind: .local, backend: .relay)
        let pane = PaneModel(profile: profile), writer = TerminalEditFrameWriter()
        let runtime = pane.runtime
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
            capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
        runtime.startForTesting(transport: transport)
        let session = runtime.ioForTesting.session, view = runtime.view
        let (bridgeViewports, bridgeViewportSink) = AsyncStream<RelayViewport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        runtime.ioForTesting.onViewportReady = { bridgeViewportSink.yield($0) }
        let bridgeDeadline = Task {
            try? await Task.sleep(for: .seconds(2))
            bridgeViewportSink.finish()
        }
        defer { bridgeDeadline.cancel(); bridgeViewportSink.finish() }
        var bridgeSizes = bridgeViewports.makeAsyncIterator()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        var sizes = session.nativeResizeEvents().makeAsyncIterator()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; _ = runtime.ioForTesting.removeTransport(); transport.detach(); runtime.stop(); window.close() }
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.fitToSize()
        _ = try #require(await sizes.next())
        let hidden = change.hasPrefix("hidden") || change == "retired"
        if hidden { window.contentView = nil }
        await Task.yield()
        // No replay buffer registration: only the existing renderer can prove it.
        var firstParsed = session.parsedHostOutputEvents().makeAsyncIterator()
        _ = await firstParsed.next()
        #expect(runtime.ioForTesting.receive(Data("\u{1b}[2J\u{1b}[Howned live menu > ".utf8), remoteSequence: 1))
        _ = try #require(await firstParsed.next())
        await Task.detached { session.waitForPendingOutput() }.value
        if !hidden { view.synchronizeAndRedraw() }
        pane.connectionState = .connected
        let nativeState = try #require(session.screenState)
        let nativeViewport = RelayViewport(columns: try #require(nativeState.columns), rows: try #require(nativeState.rows))
        // The native resize event is published before the bridge callback.
        // Cross that actual callback instead of guessing offscreen pixel scale.
        while runtime.ioForTesting.currentViewport != nativeViewport {
            _ = try #require(await bridgeSizes.next())
        }
        let binding = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
            nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
            provider: "shell", processId: 333, processStart: 2, sessionId: nil, transcriptIdentity: nil)
        let successor = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
            nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 334, shellStart: 3,
            provider: "shell", processId: 334, processStart: 3, sessionId: nil, transcriptIdentity: nil)
        var ownerReads = 0
        runtime.promptOwnerBindingForTesting = {
            ownerReads += 1
            return .init(hostID: profile.id, binding: change == "owner" && ownerReads > 1 ? successor : binding)
        }
        #expect(runtime.ioForTesting.maintenanceScreenSnapshot() == nil)
        let viewport = runtime.ioForTesting.currentViewport
        let state = await runtime.terminalEditState()
        if change == "owner" {
            #expect(state["status"] == "changed")
            #expect(state["proof_id"] == nil)
            #expect(writer.count == 0)
            continue
        }
        #expect(state["status"] == "observed", "renderer state: \(state)")
        #expect(state["screen_source"] == (hidden ? "retained_native_renderer" : "attached_native_renderer"))
        #expect(state["viewport_tail"]?.contains("owned live menu") == true)
        if hidden { #expect(runtime.ioForTesting.currentViewport == viewport, "case: \(change)") }
        let proof = try #require(state["proof_id"].flatMap(UUID.init(uuidString:)))
        if change == "output" || change == "hidden_output" {
            var parsed = session.parsedHostOutputEvents().makeAsyncIterator()
            _ = await parsed.next()
            #expect(runtime.ioForTesting.receive(Data("new screen".utf8), remoteSequence: 2))
            _ = try #require(await parsed.next())
            await Task.detached { session.waitForPendingOutput() }.value
            if !hidden { view.synchronizeAndRedraw() }
        } else if change == "detach" { window.contentView = nil }
        else if change == "hidden_input" { pane.userEnteredInput() }
        else if change == "hidden_replay" { runtime.ioForTesting.beginReplay() }
        else if change == "retired" { _ = runtime.ioForTesting.removeTransport(); transport.detach() }
        let request = edit(key: "left", token: proof)
        let accepted = ["none", "hidden", "detach"].contains(change)
        #expect(await runtime.sendTerminalEdit(request) == (accepted ? "input_submitted" : "not_sent"))
        #expect(writer.count == (accepted ? 1 : 0))
        #expect(await runtime.sendTerminalEdit(request) == "not_sent")
        if change == "hidden_output" {
            let refreshed = await runtime.terminalEditState()
            #expect(refreshed["status"] == "observed")
            #expect(refreshed["viewport_tail"]?.contains("new screen") == true)
        } else if change == "hidden_replay" || change == "retired" {
            #expect((await runtime.terminalEditState())["status"] != "observed")
        }
        window.contentView = nil
        #expect(view.window == nil)
        if hidden { #expect(runtime.ioForTesting.currentViewport == viewport, "case: \(change)") }
        #expect(NSApp.keyWindow === keyWindow)
    }
}

@MainActor
@Test("Hidden local editing refuses missing and truncated replay without a native surface")
func terminalEditingHiddenLocalMissingAndTruncatedReplayRefuse() async throws {
    for truncated in [false, true] {
        let profile = ConnectionProfile(name: "Owned missing hidden renderer", kind: .local, backend: .relay)
        let pane = PaneModel(profile: profile), writer = TerminalEditFrameWriter()
        let runtime = pane.runtime
        let viewport = RelayViewport(columns: 100, rows: 30)
        runtime.ioForTesting.seedInitialViewport(viewport)
        if truncated {
            TerminalSnapshotStore.shared.saveSynchronously(Data("suffix only".utf8),
                paneID: pane.id, viewport: viewport, remoteSequence: 20, truncated: true)
        }
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
            capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
        runtime.startForTesting(transport: transport)
        _ = runtime.ioForTesting.restoreSnapshot(paneID: pane.id)
        defer { runtime.stop(); TerminalSnapshotStore.shared.remove(paneID: pane.id) }
        pane.connectionState = .connected
        runtime.promptOwnerBindingForTesting = {
            .init(hostID: profile.id, binding: RelayPromptOwnerBinding(version: 1,
                paneId: pane.id.uuidString.lowercased(), nodeBootId: "owned-boot",
                workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
                provider: "shell", processId: 333, processStart: 2, sessionId: nil, transcriptIdentity: nil))
        }
        #expect(runtime.view.window == nil)
        #expect(runtime.ioForTesting.session.screenState == nil)
        #expect(runtime.ioForTesting.maintenanceScreenSnapshot() == nil)
        let state = await runtime.terminalEditState()
        #expect(state["status"] == "unavailable")
        #expect(state["proof_id"] == nil)
        #expect(writer.count == 0)
    }
}

@Test func terminalEditingSubmissionIsTransportEvidenceAndLegacyUnknownStaysUnknown() {
    #expect(RelayAssistantActions.classify(status: 200, body: Data(#"{"status":"input_submitted"}"#.utf8)) == "ran")
    #expect(RelayAssistantActions.classify(status: 200, body: Data(#"{"status":"dispatching"}"#.utf8)) == "unknown")
    #expect(RelayAssistantActions.classify(status: 200, body: Data(#"{"status":"sent"}"#.utf8)) == "unknown")
}

@Test func terminalEditingProofWireNameRemainsUsableWithoutRelaxingSecretRedaction() throws {
    let request = edit()
    let data = try JSONEncoder().encode(request)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("proofID"))
    #expect(!text.contains("\"token\""))
    #expect(RelayAssistantRedaction.redact(text) == text)
    #expect(RelayTerminalEditRequest.decode(data) == request)
    #expect(RelayAssistantRedaction.redact("access_token=never-expose-this-credential").contains("[REDACTED]"))
}

@MainActor
@Test("Hidden editing replays native modes without focusing a window or sending replay replies", .timeLimit(.minutes(2)))
func terminalEditingBackgroundNativeModesKeepUserFocusAndClipboard() async throws {
    _ = NSApplication.shared
    let keyWindow = NSApp.keyWindow, mainWindow = NSApp.mainWindow
    let pasteboard = NSPasteboard(name: .init("relay.hidden.edit.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboard = pasteboard.changeCount
    var observed = 0
    let inspect: @MainActor (NSWindow) -> Void = { window in
        observed += 1
        #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(NSApp.keyWindow === keyWindow && NSApp.mainWindow === mainWindow)
    }
    // Includes terminal reply requests and a hostile clipboard escape. None
    // may enter the captured input packet or touch the user's clipboard.
    let frame = Data("\u{1b}[2J\u{1b}[Howned hidden prompt > \u{1b}[?1h\u{1b}[?2004h\u{1b}[6n\u{1b}]52;c;c2VjcmV0\u{7}".utf8)
    for (request, expected) in [(edit(), Data([27])), (edit(key: "left"), Data("\u{1b}OD".utf8)),
        (edit("insert_text", key: nil, text: "hello"), Data("\u{1b}[200~hello\u{1b}[201~".utf8))] {
        let packet = await RelayAgentMaintenanceScreen.$observeWindow.withValue(inspect) {
            await RelayAgentMaintenanceScreen.editingInput(frame, viewport: .init(columns: 100, rows: 30),
                request: request, pasteboard: pasteboard)
        }
        #expect(packet == expected)
    }
    #expect(observed >= 9)
    #expect(pasteboard.changeCount == clipboard)
    #expect(NSApp.keyWindow === keyWindow && NSApp.mainWindow === mainWindow)
}

@MainActor
@Test("A never-presented pane can be read and edited through its exact ordered worker buffer", .timeLimit(.minutes(2)))
func terminalEditingBackgroundRuntimeDoesNotRequireAVisibleView() async throws {
    _ = NSApplication.shared
    let keyWindow = NSApp.keyWindow, mainWindow = NSApp.mainWindow
    let profile = ConnectionProfile(name: "Owned background terminal edit", kind: .local, backend: .relay)
    let pane = PaneModel(profile: profile), writer = TerminalEditFrameWriter()
    let runtime = pane.runtime
    let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
        capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
    runtime.ioForTesting.seedInitialViewport(.init(columns: 100, rows: 30))
    runtime.startForTesting(transport: transport)
    // Match production startup while keeping the live view unattached.
    _ = runtime.ioForTesting.restoreSnapshot(paneID: pane.id)
    defer {
        _ = runtime.ioForTesting.removeTransport(); transport.detach(); runtime.stop()
        TerminalSnapshotStore.shared.remove(paneID: pane.id)
    }
    pane.connectionState = .connected
    let binding = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
        nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
        provider: "shell", processId: 333, processStart: 2, sessionId: nil, transcriptIdentity: nil)
    runtime.promptOwnerBindingForTesting = { .init(hostID: profile.id, binding: binding) }
    #expect(runtime.ioForTesting.receive(Data("\u{1b}[2J\u{1b}[Howned hidden prompt > ".utf8), remoteSequence: 1))
    #expect(runtime.view.window == nil)
    let state = await runtime.terminalEditState()
    #expect(state["status"] == "observed")
    #expect(state["host"] == "This Mac")
    #expect(state["viewport_tail"]?.contains("owned hidden prompt") == true)
    let proof = try #require(state["proof_id"].flatMap(UUID.init(uuidString:)))
    #expect(await runtime.sendTerminalEdit(edit(token: proof)) == "input_submitted")
    #expect(writer.count == 1)
    #expect(await runtime.sendTerminalEdit(edit(token: proof)) == "not_sent")
    #expect(writer.count == 1)
    #expect(runtime.view.window == nil)
    #expect(NSApp.keyWindow === keyWindow && NSApp.mainWindow === mainWindow)
}

@MainActor
@Test("Background state reuses its parser and applies only appended output", .timeLimit(.minutes(2)))
func terminalEditingBackgroundReusesParsedStateAndAppliesOnlyDelta() async throws {
    let owner = UUID(), viewport = RelayViewport(columns: 100, rows: 30)
    let first = Data("\u{1b}[2J\u{1b}[Hcached prompt > \u{1b}[?1h".utf8)
    let delta = Data("new output".utf8)
    var replayed = 0
    try await RelayAgentMaintenanceScreen.$observeReplay.withValue({ replayed += $0 }) {
        #expect(await RelayAgentMaintenanceScreen.editingScreen(first, viewport: viewport, identity: owner) != nil)
        let afterCold = replayed
        #expect(afterCold == first.count)
        #expect(await RelayAgentMaintenanceScreen.editingInput(first, viewport: viewport, request: edit(), identity: owner) == Data([27]))
        #expect(replayed == afterCold)
        let updated = try #require(await RelayAgentMaintenanceScreen.editingScreen(first + delta, viewport: viewport, identity: owner))
        #expect(updated.contains("new output"))
        #expect(replayed == afterCold + delta.count)
        // A worker-incarnation change must not reuse another worker's parser.
        #expect(await RelayAgentMaintenanceScreen.editingScreen(first + delta, viewport: viewport, identity: UUID()) != nil)
        #expect(replayed == afterCold + delta.count + first.count + delta.count)
    }
    // Concurrent callers with different keyboard modes keep separate ownership
    // while sharing the single bounded cache, even across parser suspension.
    let ordinary = Data("\u{1b}[2J\u{1b}[Hplain".utf8)
    let application = ordinary + Data("\u{1b}[?1h".utf8)
    let a = Task { @MainActor in await RelayAgentMaintenanceScreen.editingInput(ordinary, viewport: viewport, request: edit(key: "left"), identity: UUID()) }
    let b = Task { @MainActor in await RelayAgentMaintenanceScreen.editingInput(application, viewport: viewport, request: edit(key: "left"), identity: UUID()) }
    #expect(await a.value == Data("\u{1b}[D".utf8))
    #expect(await b.value == Data("\u{1b}OD".utf8))
}

}
