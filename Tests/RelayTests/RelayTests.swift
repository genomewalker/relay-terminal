import Foundation
import Testing
@testable import Relay

@Test("Nested splits preserve pane ordering")
func nestedSplits() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let layout = PaneLayout.pane(a)
        .splitting(a, axis: .horizontal, with: b)
        .splitting(b, axis: .vertical, with: c)

    #expect(layout.paneIDs == [a, b, c])
}

@Test("Removing a pane collapses its empty split")
func splitRemoval() {
    let a = UUID()
    let b = UUID()
    let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, with: b)

    #expect(layout.removing(a) == .pane(b))
}

@Test("Tiled panes can swap positions without changing identity")
func splitSwap() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let layout = PaneLayout.pane(a)
        .splitting(a, axis: .horizontal, with: b)
        .splitting(b, axis: .vertical, with: c)

    #expect(layout.swapping(a, c).paneIDs == [c, b, a])
}

@Test("Pane insertion preserves all four directional drop orders")
func directionalPaneInsertion() {
    let a = UUID()
    let b = UUID()
    let left = PaneLayout.pane(a).splitting(a, axis: .horizontal, with: b, newPaneFirst: true)
    let right = PaneLayout.pane(a).splitting(a, axis: .horizontal, with: b)
    let top = PaneLayout.pane(a).splitting(a, axis: .vertical, with: b, newPaneFirst: true)
    let bottom = PaneLayout.pane(a).splitting(a, axis: .vertical, with: b)

    #expect(left.paneIDs == [b, a])
    #expect(right.paneIDs == [a, b])
    #expect(top.paneIDs == [b, a])
    #expect(bottom.paneIDs == [a, b])

    guard case .split(_, let bottomAxis, .pane(let upper), .pane(let lower)) = bottom else {
        Issue.record("Bottom drop did not create a split")
        return
    }
    #expect(bottomAxis == .vertical)
    #expect(upper == a)
    #expect(lower == b)
}

@Test("Image paths are detected once in agent output")
func imagePathDetection() {
    var detector = ImagePathDetector()
    let codex = "Saved to file:///home/test/.codex/generated_images/demo/image.png\r\n"
    #expect(detector.ingest(codex) == ["/home/test/.codex/generated_images/demo/image.png"])
    #expect(detector.ingest("Displayed /home/test/.codex/generated_images/demo/image.png") == [])
    #expect(detector.ingest("not an image: /home/test/notes.txt") == [])
}

@Test("Codex viewed images are detected from relative paths")
func relativeCodexImagePathDetection() {
    var detector = ImagePathDetector()
    let output = "Viewed Image\r\n  └ .codex/generated_images/demo/image.png\r\n"
    #expect(detector.ingest(output) == [".codex/generated_images/demo/image.png"])
}

@Test("Claude extensionless scratch images are detected")
func claudeScratchImagePathDetection() {
    var detector = ImagePathDetector()
    let output = "  /tmp/claude-363159793/project/run/scratchp (3.3KB)\r\n"
    #expect(detector.ingest(output) == ["/tmp/claude-363159793/project/run/scratchp"])
}

@Test("Structured images supersede the compatibility fetch")
func structuredArtifactWins() {
    let coordinator = TerminalArtifactCoordinator()
    let path = "/home/test/.codex/generated_images/demo/image.png"
    #expect(coordinator.discover(in: "Saved to file://\(path)") == [path])
    #expect(coordinator.acceptStructured(for: path))
    #expect(!coordinator.beginFallback(for: path))
    #expect(!coordinator.acceptStructured(for: path))
}

@Test("Compatibility image fetch can complete without a structured event")
func compatibilityArtifactFallback() {
    let coordinator = TerminalArtifactCoordinator()
    let path = "/tmp/claude-123/project/scratchp"
    #expect(coordinator.discover(in: "\(path) (3KB)\n") == [path])
    #expect(coordinator.beginFallback(for: path))
    #expect(coordinator.acceptFallback(for: path))
    #expect(!coordinator.acceptStructured(for: path))
}

@Test("Kitty image transport is chunked and terminated")
func kittyImagePackets() {
    let image = Data(repeating: 0xAB, count: 5_000)
    let packets = KittyImageEncoder.packets(for: image, imageID: 42, columns: 36)
    let text = packets.compactMap { String(data: $0, encoding: .utf8) }.joined()

    #expect(packets.count > 3)
    #expect(text.contains("a=T,f=100,q=2,i=42,c=36,m=1"))
    #expect(text.contains("q=2,i=42,m=0"))
    #expect(text.hasSuffix("\r\n"))
}

@MainActor
@Test("A tab tracks tiled and floating panes together")
func tabIncludesFloatingPanes() {
    let tiled = UUID()
    let floating = UUID()
    let tab = TabModel(
        name: "HPC",
        firstPane: tiled,
        floatingPanes: [.initial(paneID: floating, index: 0)]
    )

    #expect(tab.allPaneIDs == [tiled, floating])
}

@MainActor
@Test("Remote editors open floating and inherit the active pane session")
func remoteEditorPane() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let profile = ConnectionProfile.sshConfigHost("editor-test-host")
    workspace.newTab(profile: profile)
    let terminalID = workspace.activePaneID

    workspace.openEditorForActive()

    let editor = workspace.activePane
    #expect(editor?.contentKind == .editor)
    #expect(editor?.remoteParentSessionID == terminalID?.uuidString.lowercased())
    #expect(workspace.selectedTab?.layout.paneIDs == [terminalID].compactMap { $0 })
    #expect(workspace.selectedTab?.floatingPanes.map(\.paneID) == [editor?.id].compactMap { $0 })
    workspace.shutdown()
}

@MainActor
@Test("rcode file requests create a floating editor")
func remoteFileRequestOpensFloatingEditor() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let profile = ConnectionProfile.sshConfigHost("rcode-test-host")
    workspace.newTab(profile: profile)
    let terminalID = workspace.activePaneID!

    workspace.openRemoteFile(RemoteFileOpenRequest(
        profile: profile,
        parentSessionID: terminalID.uuidString.lowercased(),
        request: EditorOpenRequest(paths: ["/work/example.swift"], diff: false)
    ))

    #expect(workspace.selectedTab?.layout.paneIDs == [terminalID])
    #expect(workspace.selectedTab?.floatingPanes.count == 1)
    #expect(workspace.activePane?.contentKind == .editor)
    #expect(workspace.activePane?.editorRequest?.paths == ["/work/example.swift"])
    workspace.shutdown()
}

@Test("Quick editor typography follows terminal settings safely")
func editorTypography() {
    let configured = EditorTypography(fontFamily: "  Berkeley Mono  ", fontSize: 18.5)
    #expect(configured.fontFamily == "Berkeley Mono")
    #expect(configured.fontSize == 18.5)
    #expect(configured.javascriptArgument?.contains("Berkeley Mono") == true)

    #expect(EditorTypography(fontFamily: "  ", fontSize: 4).fontFamily == "Menlo")
    #expect(EditorTypography(fontFamily: "Menlo", fontSize: 40).fontSize == 32)
}

@MainActor
@Test("A session owns multiple tabs with separate pane workers")
func multipleTabsPerSession() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    workspace.newTab(profile: .sshConfigHost("tabs-test-host"))
    let firstTab = workspace.selectedTab
    let firstPaneID = workspace.activePaneID

    workspace.newTabInActiveSession()
    let secondTabID = workspace.selectedTabID

    #expect(workspace.selectedTab?.sessionID == firstTab?.sessionID)
    #expect(workspace.tabs.filter { $0.sessionID == firstTab?.sessionID }.count == 2)
    #expect(workspace.activePane?.remoteParentSessionID == firstPaneID?.uuidString.lowercased())
    workspace.selectTab(firstTab!.id)
    #expect(workspace.selectedTabID == firstTab?.id)
    #expect(workspace.activePaneID == firstPaneID)
    workspace.selectTab(UUID())
    #expect(workspace.selectedTabID == firstTab?.id)
    workspace.selectTab(secondTabID!)
    workspace.shutdown()
}

@Test("Remote catalog groups durable workspaces and leaves old panes recoverable")
func remoteCatalogGrouping() throws {
    let data = Data(#"{"schema":1,"revision":7,"node_id":"node","node_name":"dandy-07","panes":[{"pane_id":"11111111-1111-1111-1111-111111111111","workspace_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","tab_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","content_kind":"terminal","state":"running","last_sequence":9,"recoverable":true,"unfiled":false},{"pane_id":"22222222-2222-2222-2222-222222222222","content_kind":"terminal","state":"running","last_sequence":3,"recoverable":true,"unfiled":true}]}"#.utf8)
    let snapshot = try JSONDecoder().decode(RemoteCatalogSnapshot.self, from: data)

    #expect(snapshot.sessions.count == 2)
    #expect(snapshot.sessions.contains { $0.workspaceID == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" && $0.tabCount == 1 })
    #expect(snapshot.sessions.contains { $0.isUnfiled && $0.recoverable })
}

@MainActor
@Test("Attaching a remote catalog session preserves remote pane and hierarchy IDs")
func attachRemoteCatalogSession() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let sessionID = UUID()
    let tabID = UUID()
    let paneID = UUID()
    let remote = RemoteSessionRecord(
        id: "workspace:\(sessionID.uuidString.lowercased())",
        workspaceID: sessionID.uuidString.lowercased(),
        panes: [RemoteCatalogPane(
            paneID: paneID.uuidString.lowercased(),
            workspaceID: sessionID.uuidString.lowercased(),
            tabID: tabID.uuidString.lowercased(),
            parentPaneID: nil,
            title: "Training",
            contentKind: "terminal",
            command: nil,
            directory: "/work",
            state: "running",
            workerPID: 42,
            shellPID: 43,
            lastSequence: 8,
            recoverable: true,
            unfiled: false
        )],
        workspaceSnapshot: nil
    )

    workspace.attachRemoteSession(profile: .sshConfigHost("dandy-07"), remote: remote)

    #expect(workspace.selectedTabID == tabID)
    #expect(workspace.selectedTab?.sessionID == sessionID)
    #expect(workspace.activePaneID == paneID)
    #expect(workspace.activePane?.remoteWorkspaceSessionID == sessionID.uuidString.lowercased())
    #expect(workspace.activePane?.remoteTabID == tabID.uuidString.lowercased())
    workspace.shutdown()
}

@MainActor
@Test("Remote workspace restore preserves tabs, split ratios, and floating editors")
func attachRemoteWorkspaceLayout() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let sessionID = UUID()
    let tabID = UUID()
    let terminalID = UUID()
    let editorID = UUID()
    let splitID = UUID()
    let profile = ConnectionProfile.sshConfigHost("dandy-07")
    let layout = PaneLayout.pane(terminalID)
    let floating = FloatingPanePlacement(
        paneID: editorID, originX: 90, originY: 70, width: 640, height: 440
    )
    let snapshot = WorkspaceSnapshot(
        tabs: [TabSnapshot(
            id: tabID,
            sessionID: sessionID,
            name: "Analysis",
            layout: layout,
            floatingPanes: [floating],
            splitRatios: [splitID: 0.61]
        )],
        panes: [
            PaneSnapshot(
                id: terminalID,
                profile: profile,
                contentKind: .terminal,
                remoteParentSessionID: nil,
                editorRequest: nil,
                customName: "Codex"
            ),
            PaneSnapshot(
                id: editorID,
                profile: profile,
                contentKind: .editor,
                remoteParentSessionID: terminalID.uuidString.lowercased(),
                editorRequest: EditorOpenRequest(paths: ["/work/model.rs"], diff: false),
                customName: "model.rs"
            ),
        ],
        sessionNames: [sessionID: "Training"],
        selectedTabID: tabID,
        activePaneID: editorID
    )
    let remote = RemoteSessionRecord(
        id: "workspace:\(sessionID.uuidString.lowercased())",
        workspaceID: sessionID.uuidString.lowercased(),
        panes: [RemoteCatalogPane(
            paneID: terminalID.uuidString.lowercased(),
            workspaceID: sessionID.uuidString.lowercased(),
            tabID: tabID.uuidString.lowercased(),
            parentPaneID: nil,
            title: "Codex",
            contentKind: "terminal",
            command: "codex",
            directory: "/work",
            state: "running",
            workerPID: 42,
            shellPID: 43,
            lastSequence: 8,
            recoverable: true,
            unfiled: false
        )],
        workspaceSnapshot: snapshot
    )

    workspace.attachRemoteSession(profile: profile, remote: remote)

    #expect(workspace.selectedTab?.name == "Analysis")
    #expect(workspace.selectedTab?.floatingPanes == [floating])
    #expect(workspace.activePaneID == editorID)
    #expect(workspace.activePane?.contentKind == .editor)
    #expect(workspace.activePane?.profile == profile)
    workspace.shutdown()
}

@MainActor
@Test("Sessions, tabs, and panes can be renamed independently")
func workspaceRenaming() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    workspace.newTab(profile: .sshConfigHost("rename-test-host"))
    let sessionID = workspace.selectedTab!.sessionID
    let tabID = workspace.selectedTab!.id
    let paneID = workspace.activePaneID!

    workspace.beginRenameSession(sessionID, fallback: "Session")
    workspace.renameDraft = "Research"
    workspace.commitRename()
    workspace.beginRenameTab(tabID)
    workspace.renameDraft = "Training"
    workspace.commitRename()
    workspace.beginRenamePane(paneID)
    workspace.renameDraft = "Codex run"
    workspace.commitRename()

    #expect(workspace.sessionDisplayName(sessionID, fallback: "Session") == "Research")
    #expect(workspace.tabs.first(where: { $0.id == tabID })?.name == "Training")
    #expect(workspace.panes[paneID]?.displayName == "Codex run")
    workspace.shutdown()
}

@MainActor
@Test("Full screen hides and restores the session navigator")
func fullScreenChrome() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    workspace.sidebarVisible = true

    workspace.setFullScreen(true)
    #expect(workspace.isFullScreen)
    #expect(!workspace.sidebarVisible)

    workspace.setFullScreen(false)
    #expect(!workspace.isFullScreen)
    #expect(workspace.sidebarVisible)
}

@Test("Agent detector recognizes Claude and approval prompts")
func claudeAttentionSignal() {
    var detector = AgentSignalDetector()
    detector.ingest("Claude Code\nThis action requires approval. Do you want to proceed? (y/n)")

    #expect(detector.kind == .claude)
    #expect(detector.phase == .needsInput)

    detector.acknowledgeInput()
    #expect(detector.phase == .active)
}

@Test("Agent detector recognizes Codex")
func codexSignal() {
    var detector = AgentSignalDetector()
    detector.ingest("OpenAI Codex CLI\nWorking on your repository")

    #expect(detector.kind == .codex)
    #expect(detector.phase == .active)
}

@Test("SSH config discovery keeps aliases and rejects patterns")
func sshConfigAliases() {
    let config = """
    Host hpc-login gpu-02 *.cluster !blocked
      HostName dandy.example.edu
    Host "quoted-host" # comment
    Match host anything
      User ignored
    """

    #expect(SSHConfigDiscovery.literalHosts(in: config) == ["hpc-login", "gpu-02", "quoted-host"])
}

@Test("SSH config aliases defer connection options to OpenSSH")
func sshConfigConnectionArguments() {
    let profile = ConnectionProfile.sshConfigHost("hpc-login")
    #expect(profile.sshConnectionArguments == ["hpc-login"])
    #expect(profile.backend == .relay)
}

@Test("SSH diagnostics distinguish VPN outages from permanent failures")
func sshFailureDiagnosis() {
    let noRoute = SSHConnectionFailure.diagnose("ssh: connect to host hpc port 22: No route to host", terminationStatus: 255)
    #expect(noRoute.kind == .networkRoute)
    #expect(noRoute.shouldRetry)

    let timeout = SSHConnectionFailure.diagnose("ssh: connect to host hpc port 22: Operation timed out", terminationStatus: 255)
    #expect(timeout.kind == .networkRoute)
    #expect(timeout.userMessage == "VPN or network route unavailable.")

    let permission = SSHConnectionFailure.diagnose("user@hpc: Permission denied (publickey).", terminationStatus: 255)
    #expect(permission.kind == .authentication)
    #expect(!permission.shouldRetry)

    let missingRelay = SSHConnectionFailure.diagnose("bash: /home/user/.local/bin/relayd: No such file or directory", terminationStatus: 127)
    #expect(missingRelay.kind == .remoteConfiguration)
    #expect(!missingRelay.shouldRetry)

    let oldRelay = SSHConnectionFailure.diagnose("relayd: unknown command: node", terminationStatus: 1)
    #expect(oldRelay.kind == .remoteConfiguration)

    let reset = SSHConnectionFailure.diagnose("Connection reset by peer", terminationStatus: 255)
    #expect(reset.kind == .interrupted)
    #expect(reset.shouldRetry)

    let staleNode = SSHConnectionFailure.diagnoseNodeTransport(
        "",
        terminationStatus: 0,
        reachedProtocolReady: false
    )
    #expect(staleNode.kind == .remoteConfiguration)
    #expect(!staleNode.shouldRetry)

    let closedReadyNode = SSHConnectionFailure.diagnoseNodeTransport(
        "",
        terminationStatus: 0,
        reachedProtocolReady: true
    )
    #expect(closedReadyNode.kind == .interrupted)
    #expect(closedReadyNode.shouldRetry)
}

@Test("Terminal input identity is durable and separate from workspace ownership")
func terminalInputIdentityIsDurable() {
    #expect(RelayInputClientIdentity.id == RelayInputClientIdentity.id)
    #expect(RelayInputClientIdentity.id != RelayClientIdentity.id)
}

@Test("Input sequence reservations never overlap across launches")
func terminalInputSequenceReservations() {
    let suite = "relay-input-sequence-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = RelayInputSequenceAllocator(defaults: defaults, key: "sequence", blockSize: 4)
    let firstValue = first.next()
    let second = RelayInputSequenceAllocator(defaults: defaults, key: "sequence", blockSize: 4)
    let secondValue = second.next()
    #expect(firstValue == 1)
    #expect(secondValue == 5)
}

@Test("Node heartbeat watchdog distinguishes delayed from stalled replies")
func nodeHeartbeatWatchdog() {
    let timeout = RelayHeartbeatPolicy.timeoutNanoseconds
    #expect(RelayHeartbeatPolicy.intervalSeconds == 2)
    #expect(timeout == 6_000_000_000)
    let now = timeout + 100
    let pending: [UInt64: UInt64] = [
        1: 99,
        2: 100,
        3: 101,
        4: now,
    ]
    #expect(Set(RelayHeartbeatPolicy.expired(pending, now: now)) == Set([1, 2]))
    #expect(RelayHeartbeatPolicy.expired([1: 0], now: timeout - 1).isEmpty)
}

@Test("A stalled pane handshake retries forever with bounded backoff")
func paneAttachRetryPolicy() {
    #expect(RelayPaneAttachPolicy.handshakeTimeoutMilliseconds == 1_500)
    #expect(RelayPaneAttachPolicy.retryDelayMilliseconds(attempt: 1, waitingForInputLease: false) == 250)
    #expect(RelayPaneAttachPolicy.retryDelayMilliseconds(attempt: 20, waitingForInputLease: false) == 4_000)
    #expect(RelayPaneAttachPolicy.retryDelayMilliseconds(attempt: 1, waitingForInputLease: true) == 5_500)
    #expect(RelayPaneAttachPolicy.retryDelayMilliseconds(attempt: 20, waitingForInputLease: true) == 15_000)
    #expect(RelayPaneAttachPolicy.shouldUseDedicatedTransport(attempt: 1))
}

@Test("Default keybindings are unique and close pane owns Command-W")
func defaultKeyBindings() {
    let bindings = RelayCommand.allCases.map(\.defaultBinding)
    #expect(Set(bindings).count == bindings.count)
    #expect(RelayCommand.closePane.defaultBinding == RelayKeyBinding("w", command: true))
    #expect(RelayCommand.closePane.defaultBinding.displayName == "⌘W")
}

@Test("Quit requires two deliberate presses inside the confirmation window")
func guardedQuitShortcut() {
    let start: UInt64 = 10_000_000_000
    #expect(RelayQuitConfirmationPolicy.action(armedAt: nil, now: start) == .arm)
    #expect(RelayQuitConfirmationPolicy.action(armedAt: start, now: start + 1_999_999_999) == .quit)
    #expect(RelayQuitConfirmationPolicy.action(armedAt: start, now: start + 2_000_000_001) == .arm)
    #expect(RelayQuitConfirmationPolicy.action(armedAt: start + 1, now: start) == .arm)
}

@Test("Custom keybindings persist and conflicts are rejected")
func customKeyBindings() {
    let suite = "relay-keybindings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let custom = RelayKeyBinding("x", command: true, option: true)
    RelayKeyBindingStorage.save([RelayCommand.closePane.rawValue: custom], to: defaults)
    let loaded = RelayKeyBindingStorage.load(from: defaults)

    #expect(RelayKeyBindingStorage.binding(for: .closePane, overrides: loaded) == custom)
    #expect(RelayKeyBindingStorage.conflict(
        for: RelayCommand.splitRight.defaultBinding,
        command: .closePane,
        overrides: loaded
    ) == .splitRight)

    let movedClose = [RelayCommand.closePane.rawValue: RelayKeyBinding("x", command: true, shift: true)]
    #expect(RelayKeyBindingStorage.conflict(
        for: RelayCommand.closePane.defaultBinding,
        command: .splitRight,
        overrides: movedClose
    ) == .closePane)
}

@Test("Pane connection state exposes non-blocking recovery labels")
func paneConnectionRecoveryState() {
    let vpn = PaneConnectionState.waitingForNetwork("retrying")
    #expect(vpn.label == "VPN required")
    #expect(vpn.isWaitingForNetwork)
    #expect(vpn.recoveryMessage == "retrying")

    let reconnecting = PaneConnectionState.reconnecting("reattaching")
    #expect(reconnecting.label == "Reconnecting")
    #expect(!reconnecting.isWaitingForNetwork)
    #expect(reconnecting.recoveryMessage == "reattaching")
}

@Test("Host search tolerates omitted characters")
func fuzzyHostSearch() {
    #expect(HostSearch.score(query: "hpc", candidate: "hpc-login SSH config") != nil)
    #expect(HostSearch.score(query: "gpu7", candidate: "gpu-login-07") != nil)
    #expect(HostSearch.score(query: "ocean", candidate: "hpc-login SSH config") == nil)
}

@MainActor
@Test("Structured Codex events override terminal heuristics")
func structuredCodexEvent() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    let event = """
    {"agent":"codex","event":{"hook_event_name":"SessionStart","source":"process-tree"}}
    """
    pane.receivedAgentEvent(Data(event.utf8))
    #expect(pane.kind == .codex)
    #expect(pane.phase == .active)

    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"PreToolUse","tool_name":"exec_command"}}"#.utf8))
    #expect(pane.activitySummary == "Using exec_command")
    #expect(pane.agentActivities.last?.label == "Using exec_command")

    pane.received("random full-screen cursor text that belongs only in the terminal")
    #expect(pane.activitySummary == "Using exec_command")
}

@MainActor
@Test("Agent events from terminal and observer channels are deduplicated")
func duplicateAgentChannels() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","relay_event_seq":1,"event":{"hook_event_name":"PreToolUse","tool_name":"exec_command"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","relay_event_seq":88,"relay_recorded_at":"2026-08-25T18:00:00Z","event":{"hook_event_name":"PreToolUse","tool_name":"exec_command"}}"#.utf8))

    #expect(pane.agentActivities.count == 1)
}

@MainActor
@Test("Raw agent terminal output never becomes sidebar activity text")
func rawOutputIsNotSidebarActivity() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.received("OpenAI Codex CLI\nrandom status line from the alternate screen")

    #expect(pane.kind == .codex)
    #expect(pane.activitySummary == "Working")
    #expect(pane.agentActivities.isEmpty)
}

@MainActor
@Test("Structured subagent events retain identity and lifecycle")
func structuredSubagentLifecycle() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"research-1","agent_type":"Explore"}}"#.utf8))
    #expect(pane.activeSubagents == 1)
    #expect(pane.subagents.first?.id == "research-1")
    #expect(pane.subagents.first?.label == "Explore")

    pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"research-1"}}"#.utf8))
    #expect(pane.activeSubagents == 0)
    #expect(pane.subagents.first?.phase == .quiet)
    #expect(pane.subagents.first?.label == "Explore")

}

@MainActor
@Test("Agent thread storage handles one hundred children without truncation")
func oneHundredSubagents() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    for index in 0..<100 {
        pane.receivedAgentEvent(Data("""
        {"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"worker-\(index)","agent_type":"Worker \(index)"}}
        """.utf8))
    }

    #expect(pane.subagents.count == 100)
    #expect(pane.activeSubagents == 100)

    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SubagentStop","agent_id":"worker-42","agent_type":"Worker 42","message":"Validated the result."}}"#.utf8))
    let completed = pane.subagents.first { $0.id == "worker-42" }
    #expect(completed?.phase == .quiet)
    #expect(completed?.updates.last?.message == "Validated the result.")
    #expect(pane.subagents.count == 100)
    #expect(pane.activeSubagents == 99)
}

@MainActor
@Test("Peer messages preserve direction and attach to the related thread")
func peerMessageDirection() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"/root/worker","agent_type":"worker"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"PeerMessage","from_peer_id":"/root","to_peer_id":"/root/worker","message":"Check the edge case."}}"#.utf8))
    #expect(pane.subagents.first?.updates.last?.message.contains("Received from root") == true)
    #expect(pane.subagents.first?.updates.last?.message.contains("Check the edge case.") == true)
}

@MainActor
@Test("Child-to-child peer messages are visible in both agent threads")
func peerMessageBetweenChildren() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"PeerMessage","from_peer_id":"/root/one","to_peer_id":"/root/two","message":"Cross-check this."}}"#.utf8))
    #expect(pane.subagents.count == 2)
    #expect(pane.subagents.first { $0.id == "/root/one" }?.updates.last?.message.contains("Sent to two") == true)
    #expect(pane.subagents.first { $0.id == "/root/two" }?.updates.last?.message.contains("Received from one") == true)
}

@MainActor
@Test("Agent state snapshots remove stale threads before restoring active children")
func agentStateSnapshot() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"stale","agent_type":"stale"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"relay","relay_event_seq":20,"event":{"type":"RelayStateSnapshot","events":[{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"active","agent_type":"active"}}]}}"#.utf8))
    #expect(pane.subagents.count == 1)
    #expect(pane.subagents.first?.id == "active")
    #expect(pane.activeSubagents == 1)
}

@MainActor
@Test("Ending an agent restores the shell and records the lifecycle transition")
func structuredAgentSessionEnd() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"PreToolUse","tool_name":"exec_command"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"worker-1","agent_type":"Explore"}}"#.utf8))

    #expect(pane.kind == .codex)
    #expect(!pane.agentActivities.isEmpty)
    #expect(pane.activeSubagents == 1)

    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SessionEnd","source":"process-tree"}}"#.utf8))

    #expect(pane.kind == .shell)
    #expect(pane.phase == .quiet)
    #expect(pane.agentActivities.last?.label == "Codex session ended")
    #expect(pane.activeSubagents == 0)
    #expect(pane.subagents.isEmpty)

    pane.received("historical replay from OpenAI Codex CLI")
    #expect(pane.kind == .shell)
}

@MainActor
@Test("Ending one of two provider roots keeps the other agent thread active")
func multipleAgentRootLifecycle() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SessionStart","root_id":"codex:1"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SessionStart","root_id":"codex:2"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"worker-1","agent_type":"Explore"}}"#.utf8))
    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SessionEnd","root_id":"codex:1"}}"#.utf8))
    #expect(pane.kind == .codex)
    #expect(pane.activeSubagents == 1)

    pane.receivedAgentEvent(Data(#"{"agent":"codex","event":{"hook_event_name":"SessionEnd","root_id":"codex:2"}}"#.utf8))
    #expect(pane.kind == .shell)
    #expect(pane.activeSubagents == 0)
}

@Test("Terminal replay starts at the latest complete screen redraw")
func compactTerminalReplay() {
    let history = Data("old cursor-addressed text\u{001B}[2J\u{001B}[Hcurrent screen".utf8)
    let compacted = TerminalReplayCompactor.compact(history)

    #expect(compacted == Data("\u{001B}c\u{001B}[2J\u{001B}[Hcurrent screen".utf8))
    #expect(TerminalReplayCompactor.compact(Data("plain shell output".utf8)) == Data("plain shell output".utf8))
}

@Test("Terminal snapshots stay bounded and self-resetting")
func terminalSnapshotBound() {
    var oversized = Data("old-prefix".utf8)
    oversized.append(Data(repeating: 0x78, count: TerminalSnapshotStore.maximumBytes * 2))
    let bounded = TerminalSnapshotStore.bounded(oversized)
    #expect(bounded.count <= TerminalSnapshotStore.maximumBytes)
    #expect(bounded.starts(with: Data("\u{001B}c".utf8)))
}

@Test("Persisted agent state retains its resume cursor and thread summaries")
func persistedAgentStateRoundTrip() throws {
    let state = PersistedAgentPaneState(
        cursor: 417,
        kind: .codex,
        phase: .active,
        summary: "Running tests",
        subagents: [SubagentActivity(id: "child", label: "review", startedAt: Date(timeIntervalSince1970: 10))],
        activities: [],
        resourceUsage: AgentResourceUsage(inputTokens: 12, cachedInputTokens: 3, outputTokens: 7),
        progressPercent: 60,
        pendingApprovals: 1
    )
    let restored = try JSONDecoder().decode(PersistedAgentPaneState.self, from: JSONEncoder().encode(state))
    #expect(restored.cursor == 417)
    #expect(restored.subagents.first?.id == "child")
    #expect(restored.resourceUsage?.outputTokens == 7)
}

@Test("Startup terminal replies cannot become remote shell input")
func filterStartupDeviceResponses() {
    #expect(TerminalDeviceResponseFilter.matches(Data("\u{001B}[?62;22;52c".utf8)))
    #expect(TerminalDeviceResponseFilter.matches(Data("\u{001B}[12;40R".utf8)))
    #expect(TerminalDeviceResponseFilter.matches(Data("\u{001B}]10;rgb:d0d0/d0d0/d0d0\u{001B}\\".utf8)))
    #expect(TerminalDeviceResponseFilter.matches(Data("\u{001B}[?7u".utf8)))

    #expect(!TerminalDeviceResponseFilter.matches(Data("hello".utf8)))
    #expect(!TerminalDeviceResponseFilter.matches(Data("\u{001B}[A".utf8)))
    #expect(!TerminalDeviceResponseFilter.matches(Data("\u{001B}[<0;12;4M".utf8)))
    #expect(!TerminalDeviceResponseFilter.matches(Data("\u{001B}[97;5u".utf8)))
}

@Test("Diagnostics redact credentials before they are retained or exported")
func diagnosticRedaction() throws {
    #expect(RelayDiagnostics.redact("Bearer abc.def.secret") == "Bearer <redacted>")
    #expect(RelayDiagnostics.redact("github_pat", key: "access_token") == "<redacted>")
    #expect(RelayDiagnostics.redact("https://person:password@example.test/path") == "https://<redacted>@example.test/path")

    let diagnostics = RelayDiagnostics()
    diagnostics.record(category: "test", name: "redaction", details: [
        "authorization": "Bearer must-not-survive",
        "message": "request used ghp_abcdefghijklmnopqrstuvwxyz123456",
    ])
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.events.last?.details["authorization"] == "<redacted>")
    #expect(snapshot.events.last?.details["message"] == "request used <redacted>")

    let exportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: exportURL) }
    try diagnostics.export(to: exportURL)
    let exported = try String(contentsOf: exportURL, encoding: .utf8)
    #expect(!exported.contains("must-not-survive"))
    #expect(!exported.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
    #expect(exported.contains("<redacted>"))
}

@MainActor
@Test("Terminal semantic callbacks retain command and progress state")
func terminalSemanticState() {
    let pane = PaneModel(profile: .local)
    pane.recordCommandCompletion(exitCode: 17, durationNanos: 2_500_000)
    pane.recordTerminalProgress(state: "running", percent: 42)
    #expect(pane.lastCommandExitCode == 17)
    #expect(pane.lastCommandDurationNanos == 2_500_000)
    #expect(pane.terminalProgressState == "running")
    #expect(pane.terminalProgressPercent == 42)
}

@Test("Artifact links round-trip remote image paths")
func artifactLinksRoundTripRemotePaths() {
    let path = "/home/kbd606/.codex/generated_images/demo image.png"
    let link = ArtifactLinkResolver.link(for: path)
    #expect(link.hasPrefix("file:///__relay_artifact__/"))
    #expect(ArtifactLinkResolver.path(from: link) == path)
    #expect(ArtifactLinkResolver.path(from: "file:///tmp/demo.png") == "/tmp/demo.png")
    #expect(ArtifactLinkResolver.path(from: "https://example.com/demo.png") == nil)
}

@Test("Artifact hyperlinks preserve visible terminal text")
func artifactHyperlinksPreserveVisiblePath() {
    let path = "/tmp/F2D-desktop-evidence-spine.png"
    let encoded = ArtifactHyperlinkEncoder.encode(Data("saved: \(path)\r\n".utf8))
    let output = String(decoding: encoded, as: UTF8.self)
    #expect(output.contains("\u{001B}]8;;file:///__relay_artifact__/"))
    #expect(output.contains(path))
}
