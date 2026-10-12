import AppKit
import Testing
@testable import Relay

@Test("Local helper starts at home without inherited prompt commands")
func localHelperEnvironment() {
    let process = Process()
    LocalRelayProcess.configure(process)
    #expect(process.currentDirectoryURL == FileManager.default.homeDirectoryForCurrentUser)
    #expect(process.environment?["PROMPT_COMMAND"] == nil)
    #expect(process.environment?["SHELL"]?.hasPrefix("/") == true)
}

@MainActor
@Test("Unfocused terminals decline editor keyboard equivalents")
func unfocusedTerminalDeclinesEditorKeys() {
    _ = NSApplication.shared
    let terminal = RelayGhosttyView(frame: .zero)
    for (key, code) in [("v", UInt16(9)), ("a", UInt16(0)), ("z", UInt16(6))] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code)!
        #expect(!terminal.performKeyEquivalent(with: event))
    }
}

@MainActor
@Test("R results visibility belongs to the persistent pane runtime")
func rResultsVisibilitySurvivesViewRecreation() {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    pane.editorRuntime.showsRResults = true
    let recreatedViewRuntime = pane.editorRuntime
    #expect(recreatedViewRuntime.showsRResults)
    recreatedViewRuntime.showsRResults = false
    #expect(!pane.editorRuntime.showsRResults)
}

@MainActor
@Test("Programmatic editor focus does not recursively select its pane")
func editorFocusDoesNotReselect() {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    let selected = LockedFlag()
    let token = NotificationCenter.default.addObserver(forName: .relaySelectPane, object: nil, queue: nil) { _ in
        selected.set()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    pane.editorRuntime.focus()
    #expect(!selected.value)
    pane.editorRuntime.selectForInteraction()
    #expect(selected.value)
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); defer { lock.unlock() }; storage = true }
}

@MainActor
@Test("Historical editor requests do not reopen closed editors")
func editorRequestExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(PaneModel.isFreshEditorRequest(["relay_recorded_at": formatter.string(from: now)], now: now))
    #expect(!PaneModel.isFreshEditorRequest(["relay_recorded_at": formatter.string(from: now.addingTimeInterval(-60))], now: now))
    #expect(!PaneModel.isFreshEditorRequest([:], now: now))
}

@Test("Agent observers never request the publisher role")
func agentObserverHandshake() {
    let hello = RelayAgentObserverHello.payload(sessionID: "test-session", lastEventSequence: 42)
    #expect(hello["observe_events"] as? Bool == true)
    #expect(hello["event_only"] == nil)
    #expect(hello["session_id"] as? String == "test-session")
    #expect(hello["last_event_seq"] as? UInt64 == 42)
}

@MainActor
@Test("Outgoing editor presentation cannot detach the new presentation")
func editorPresentationHandoff() {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    let web = pane.editorRuntime.webView
    let floating = RelayEditorHostView(editor: web)
    floating.frame = NSRect(x: 0, y: 0, width: 620, height: 410)
    floating.attachEditor()
    #expect(web.superview === floating)
    let maximized = RelayEditorHostView(editor: web)
    maximized.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    maximized.attachEditor()
    floating.detachEditor()
    floating.layout()
    #expect(web.superview === maximized)
    #expect(web.frame.size == maximized.bounds.size)
    maximized.detachEditor()
    #expect(web.superview == nil)
}

@MainActor
@Test("WebKit descendants retain editor command ownership")
func editorResponderOwnership() {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    let runtime = pane.editorRuntime
    let child = NSView()
    runtime.webView.addSubview(child)
    #expect(RemoteEditorRuntime.owner(of: child) === runtime)
    #expect(RemoteEditorRuntime.owner(of: NSTextView()) == nil)
    #expect(RemoteEditorRuntime.owner(of: nil) == nil)
}

@MainActor
@Test("Remote file opens use their originating tab and terminal")
func remoteEditorOriginRouting() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let profile = ConnectionProfile.sshConfigHost("editor-test")
    workspace.newTab(profile: profile)
    let origin = workspace.activePaneID!
    let originTab = workspace.selectedTabID
    workspace.newTab(profile: profile)
    let otherTab = workspace.selectedTabID
    workspace.openRemoteFile(RemoteFileOpenRequest(
        profile: profile, parentSessionID: origin.uuidString.lowercased(),
        request: EditorOpenRequest(paths: ["/tmp/example.txt"], diff: false)
    ))
    #expect(workspace.selectedTabID == originTab)
    #expect(workspace.selectedTabID != otherTab)
    #expect(workspace.activePane?.contentKind == .editor)
    #expect(workspace.activePane?.remoteParentSessionID == origin.uuidString.lowercased())
    #expect(workspace.selectedTab?.floatingPanes.count == 1)
}
