import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Relay

// The boundary, node-ready and Monaco surface tests come from root's review of
// relay-editor-start-1631-c (editor-start-c-review-20261020).

private struct LookupInterrupted: Error {}
private struct DelayStopped: Error {}
private final class ReadyWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) { lock.lock(); count += 1; lock.unlock() }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor @Suite(.serialized)
struct EditorStartBoundaryTests {
    @Test func missingResourcesIsFinalWithoutWaiting() async {
        var attempts = 0
        var delays = 0
        await #expect(throws: RemoteFileError.self) {
            let _: String = try await RemoteEditorRuntime.retryingWorkspaceLookup(sleep: { _ in delays += 1 }) {
                attempts += 1
                throw RemoteFileError.missingResources
            }
        }
        #expect(attempts == 1)
        #expect(delays == 0)
    }

    @Test func delayFailureDoesNotAdmitAnotherLookup() async {
        var attempts = 0
        var delays: [Duration] = []
        await #expect(throws: DelayStopped.self) {
            let _: String = try await RemoteEditorRuntime.retryingWorkspaceLookup(sleep: {
                delays.append($0)
                throw DelayStopped()
            }) {
                attempts += 1
                throw LookupInterrupted()
            }
        }
        #expect(attempts == 1)
        #expect(delays == [.seconds(2)])
    }

    @Test func cancellationDuringDefaultDelayStopsRetries() async throws {
        var attempts = 0
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            try await RemoteEditorRuntime.retryingWorkspaceLookup(delays: [.seconds(30)]) { () async throws -> String in
                attempts += 1
                continuation.yield(())
                throw LookupInterrupted()
            }
        }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(attempts == 1)
        continuation.finish()
    }

    @Test func theNodeReadyPathPostsTheMatchingKeyOnTheMainThread() async throws {
        let profile = ConnectionProfile(name: "Editor readiness", host: "editor-ready.invalid")
        let writer = ReadyWriter()
        let connection = RelayNodeConnection(profile: profile, attachedFrameWriter: writer,
            attachedGeneration: 7, protocolReady: false)
        let channel = connection.add(sessionID: "editor-ready",
            onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in })
        defer { channel.close() }
        let (stream, continuation) = AsyncStream<(String, Bool)>.makeStream()
        let token = NotificationCenter.default.addObserver(forName: .relayNodeReady, object: nil, queue: nil) { note in
            guard let key = note.object as? String, key == profile.connectionKey else { return }
            continuation.yield((key, Thread.isMainThread))
        }
        defer { NotificationCenter.default.removeObserver(token); continuation.finish() }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)); continuation.finish() } catch {}
        }
        defer { timeout.cancel() }
        let status = RelayWireFrame(type: .status,
            payload: Data(#"{"state":"ready","capabilities":["node_mux_v1","wire_fragments_v1"]}"#.utf8))
        connection.receiveAttachedFrame(status, generation: 6)
        #expect(writer.writes == 0)
        connection.receiveAttachedFrame(status, generation: 7)
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next(), "The node-ready branch must post the notification")
        #expect(event.0 == profile.connectionKey)
        #expect(event.1)
        #expect(writer.writes == 1)
    }
}

@MainActor @Suite(.serialized)
struct EditorStartSurfaceTests {
    @Test func theMonacoSurfaceMarksItsPaneShown() {
        _ = NSApplication.shared
        let pane = PaneModel(profile: .sshConfigHost("editor-surface.invalid"), contentKind: .editor)
        let runtime = pane.editorRuntime
        runtime.workspaceLookupOverride = { throw RemoteFileError.invalidResponse }
        runtime.workspaceLookupSleep = { _ in }
        defer { runtime.stop() }
        pane.disconnected("Before presentation")
        #expect(pane.connectionStatusLabel == "Not started")
        let view = NSHostingView(rootView: MonacoEditorSurface(runtime: runtime,
            typography: EditorTypography(fontFamily: "Menlo", fontSize: 12)))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        #expect(pane.editorViewShown)
        #expect(pane.connectionStatusLabel == "Connection lost")
        withExtendedLifetime(view) {}
    }

    @Test func aHostedWorkspaceForwardsNodeReadyToItsDisconnectedEditor() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var started: [UUID] = []
        workspace.startEditorRuntime = { started.append($0.id) }
        workspace.newTab(profile: .sshConfigHost("editor-wiring.invalid"))
        let console = try #require(workspace.activePane)
        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        editor.disconnected("Connection interrupted")
        let view = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        started.removeAll()

        NotificationCenter.default.post(name: .relayNodeReady, object: "editor-wiring-other.invalid")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(started.isEmpty)
        NotificationCenter.default.post(name: .relayNodeReady, object: editor.profile.connectionKey)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(started == [editor.id])
        withExtendedLifetime(view) {}
    }
}
