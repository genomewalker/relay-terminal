import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Editor starts survive a host reconnect")
struct EditorStartRetryTests {
    private struct Interrupted: Error {}
    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @Test func aWorkspaceLookupRetriesATransportErrorThenSucceeds() async throws {
        var attempts = 0
        var slept: [Duration] = []
        let path = try await RemoteEditorRuntime.retryingWorkspaceLookup(sleep: { slept.append($0) }) { () async throws -> String in
            attempts += 1
            if attempts < 3 { throw Interrupted() }
            return "/project"
        }
        #expect(path == "/project")
        #expect(attempts == 3)
        #expect(slept == RemoteEditorRuntime.workspaceLookupDelays)
    }

    @Test func aWorkspaceLookupStopsAfterThreeTries() async {
        var attempts = 0
        await #expect(throws: Interrupted.self) {
            _ = try await RemoteEditorRuntime.retryingWorkspaceLookup(sleep: { _ in }) { () async throws -> String in
                attempts += 1
                throw Interrupted()
            }
        }
        #expect(attempts == 3)
    }

    @Test func anUnavailableParentSessionFailsAtOnce() async {
        var attempts = 0
        await #expect(throws: RemoteFileError.self) {
            _ = try await RemoteEditorRuntime.retryingWorkspaceLookup(sleep: { _ in }) { () async throws -> String in
                attempts += 1
                throw RemoteFileError.unavailable("relayd: parent session is unavailable")
            }
        }
        #expect(attempts == 1)
    }

    @Test func onlyRelaydsParentRefusalsAreFinal() {
        let final = ["valid parent session required", "parent session is unavailable", "parent shell is unavailable",
                     "parent shell identity changed", "parent working directory is unavailable"]
        for message in final {
            let error: Error = RemoteFileError.unavailable("relayd: " + message)
            #expect(RemoteEditorRuntime.workspaceLookupIsFinal(error))
        }
        let invalid: Error = RemoteFileError.invalidResponse
        #expect(RemoteEditorRuntime.workspaceLookupIsFinal(invalid))
        let interrupted: Error = RemoteFileError.unavailable("Connection interrupted")
        #expect(RemoteEditorRuntime.workspaceLookupIsFinal(interrupted) == false)
        #expect(RemoteEditorRuntime.workspaceLookupIsFinal(Interrupted()) == false)
    }

    @Test func theEditorStartPathRetriesALostLookupAndConnects() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.startEditorRuntime = { _ in }
        workspace.newTab(profile: .sshConfigHost("editor-retry.invalid"))
        let console = try #require(workspace.activePane)
        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        let attempts = Attempts()
        editor.editorRuntime.workspaceLookupSleep = { _ in }
        editor.editorRuntime.workspaceLookupOverride = {
            if await attempts.next() == 1 { throw Interrupted() }
            return "/project"
        }

        editor.editorRuntime.startIfNeeded()
        for _ in 0..<500 where editor.connectionState != .connected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.connectionState == .connected)
        #expect(editor.directory == "/project")
        #expect(await attempts.count == 2)
    }

    @Test func aReadyNodeRestartsOnlyItsDisconnectedEditors() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var started: [UUID] = []
        workspace.startEditorRuntime = { started.append($0.id) }
        workspace.newTab(profile: .sshConfigHost("editor-retry.invalid"))
        let console = try #require(workspace.activePane)
        let lost = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        workspace.newTab(profile: .sshConfigHost("editor-retry-other.invalid"))
        let otherConsole = try #require(workspace.activePane)
        let otherHost = try workspace.addFloatingRPanel(consoleID: otherConsole.id, contentKind: .editor)
        started.removeAll()

        lost.disconnected("Connection interrupted")
        otherHost.disconnected("Connection interrupted")
        console.disconnected("Connection interrupted")
        workspace.restartDisconnectedEditors(connectionKey: lost.profile.connectionKey)
        #expect(started == [lost.id])

        started.removeAll()
        lost.connected()
        workspace.restartDisconnectedEditors(connectionKey: lost.profile.connectionKey)
        #expect(started.isEmpty)
    }

    @Test func anEditorThatFailedBeforeItWasDrawnSaysNotStarted() {
        let editor = PaneModel(profile: .sshConfigHost("editor-retry.invalid"), contentKind: .editor)
        editor.reconnecting()
        editor.disconnected("Connection interrupted")
        #expect(editor.connectionStatusLabel == "Not started")
        #expect(editor.connectionState.errorMessage != nil)

        editor.editorViewShown = true
        #expect(editor.connectionStatusLabel == "Connection lost")
    }
}
