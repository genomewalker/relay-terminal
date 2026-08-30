import AppKit
import Combine
import Foundation
import Testing
@testable import Relay

@Test("Energy policy buffers background terminals and occludes their surfaces")
func terminalEnergyPolicyBuffersBackgroundWork() {
    #expect(!TerminalEnergyPolicy.pausesTerminalEmulation(
        isPresented: true,
        applicationVisible: true
    ))
    #expect(TerminalEnergyPolicy.pausesTerminalEmulation(
        isPresented: true,
        applicationVisible: false
    ))
    #expect(TerminalEnergyPolicy.pausesTerminalEmulation(
        isPresented: false,
        applicationVisible: true
    ))
    #expect(TerminalEnergyPolicy.showsSurface(isPresented: true, applicationVisible: true))
    #expect(!TerminalEnergyPolicy.showsSurface(isPresented: true, applicationVisible: false))
    #expect(!TerminalEnergyPolicy.showsSurface(isPresented: false, applicationVisible: true))
}

@Test("Side panel HTTP parser waits for complete bodies and requires its token")
func sidePanelRequestParsingAndAuthentication() {
    let prefix = "POST /api/panes/00000000-0000-0000-0000-000000000001/prompt HTTP/1.1\r\n" +
        "Host: 127.0.0.1\r\nX-Relay-Token: secret\r\nContent-Length: 12\r\n\r\n"
    #expect(RelaySidePanelHTTPRequest.parse(Data((prefix + "{\"text\":\"a").utf8)) == .incomplete)
    let parsed = RelaySidePanelHTTPRequest.parse(Data((prefix + "{\"text\":\"a\"}").utf8))
    guard case .request(let request) = parsed else {
        Issue.record("Expected a complete side-panel request")
        return
    }
    #expect(request.method == "POST")
    #expect(request.isAuthorized(token: "secret"))
    #expect(!request.isAuthorized(token: "other"))
    #expect(String(decoding: request.body, as: UTF8.self) == "{\"text\":\"a\"}")
}

@Test("Side panel WebSocket requires the loopback origin and both protocols")
func sidePanelWebSocketAuthentication() {
    let request = RelaySidePanelHTTPRequest(
        method: "GET",
        path: "/api/panes/00000000-0000-0000-0000-000000000001/terminal",
        headers: [
            "upgrade": "websocket",
            "connection": "keep-alive, Upgrade",
            "origin": "http://127.0.0.1:47471",
            "sec-websocket-protocol": "relay-v1, secret",
        ],
        body: Data()
    )
    #expect(request.isAuthorizedWebSocket(token: "secret"))
    #expect(!request.isAuthorizedWebSocket(token: "other"))
    let hostileOrigin = RelaySidePanelHTTPRequest(
        method: request.method,
        path: request.path,
        headers: request.headers.merging(["origin": "https://example.com"]) { _, new in new },
        body: Data()
    )
    #expect(!hostileOrigin.isAuthorizedWebSocket(token: "secret"))
}

@Test("Side panel WebSocket framing follows RFC 6455 and rejects unsafe control frames")
func sidePanelWebSocketFraming() {
    #expect(
        RelaySidePanelWebSocket.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") ==
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    )

    let payload = Data([0x01, 0x61, 0x62, 0x63])
    let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
    var wire = Data([0x82, 0x80 | UInt8(payload.count)])
    wire.append(contentsOf: mask)
    wire.append(contentsOf: payload.enumerated().map { index, byte in
        byte ^ mask[index & 3]
    })
    guard case .frame(let frame) = RelaySidePanelWebSocket.parseClientFrame(&wire) else {
        Issue.record("Expected one complete masked binary frame")
        return
    }
    #expect(frame.final)
    #expect(frame.opcode == 0x2)
    #expect(frame.payload == payload)
    #expect(wire.isEmpty)

    // Data.removeFirst advances Data.startIndex. A second frame in the same
    // network read must therefore use indices relative to the new start.
    let secondPayload = Data([0x03])
    var firstAndSecond = Data([0x82, 0x81])
    firstAndSecond.append(contentsOf: mask)
    firstAndSecond.append(secondPayload[secondPayload.startIndex] ^ mask[0])
    firstAndSecond.append(Data([0x82, 0x81]))
    firstAndSecond.append(contentsOf: mask)
    firstAndSecond.append(secondPayload[secondPayload.startIndex] ^ mask[0])
    guard case .frame = RelaySidePanelWebSocket.parseClientFrame(&firstAndSecond),
          case .frame(let secondFrame) = RelaySidePanelWebSocket.parseClientFrame(&firstAndSecond) else {
        Issue.record("Expected consecutive frames from one network read")
        return
    }
    #expect(secondFrame.payload == secondPayload)
    #expect(firstAndSecond.isEmpty)

    var unmasked = Data([0x82, 0x01, 0x00])
    guard case .invalid = RelaySidePanelWebSocket.parseClientFrame(&unmasked) else {
        Issue.record("Client frames must be masked")
        return
    }
    var fragmentedPing = Data([0x09, 0x80, 0, 0, 0, 0])
    guard case .invalid = RelaySidePanelWebSocket.parseClientFrame(&fragmentedPing) else {
        Issue.record("Control frames must not be fragmented")
        return
    }
}

@Test("Side panel keeps pane history out of the polled workspace index")
@MainActor
func sidePanelIndexAndDetailAreSeparated() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let state = workspace.sidePanelState()
    let paneID = try #require(workspace.activePaneID)
    let detail = try #require(workspace.sidePanelDetail(for: paneID))

    #expect(state.version == 3)
    #expect(detail.id == paneID.uuidString.lowercased())
    let encodedIndex = try JSONEncoder().encode(state)
    let indexObject = try #require(
        JSONSerialization.jsonObject(with: encodedIndex) as? [String: Any]
    )
    let sessions = try #require(indexObject["sessions"] as? [[String: Any]])
    let tabs = try #require(sessions.first?["tabs"] as? [[String: Any]])
    let panes = try #require(tabs.first?["panes"] as? [[String: Any]])
    #expect(panes.first?["context"] == nil)
    #expect(panes.first?["subagents"] == nil)
    #expect(panes.first?["terminalAvailable"] as? Bool == false)
}

@Test("Side panel gives each pane one input and geometry owner")
func sidePanelInputOwnershipIsLastClaimWinsAndIdentitySafe() {
    let paneID = UUID()
    let first = UUID()
    let second = UUID()
    var ownership = RelaySidePanelInputOwnership()

    ownership.claim(socketID: first, paneID: paneID)
    #expect(ownership.owns(socketID: first, paneID: paneID))
    #expect(!ownership.owns(socketID: second, paneID: paneID))

    ownership.claim(socketID: second, paneID: paneID)
    #expect(!ownership.owns(socketID: first, paneID: paneID))
    #expect(ownership.owns(socketID: second, paneID: paneID))

    // A stale blur/close from the old client must not revoke the new owner.
    let staleRelease = ownership.release(socketID: first, paneID: paneID)
    #expect(!staleRelease)
    #expect(ownership.owns(socketID: second, paneID: paneID))
    let ownerRelease = ownership.release(socketID: second, paneID: paneID)
    #expect(ownerRelease)
    #expect(!ownership.owns(socketID: second, paneID: paneID))
}

@Test("Remote status decodes event-driven terminal client counts")
func remoteStatusClientCount() throws {
    let payload = Data(#"{"state":"clients","client_count":3}"#.utf8)
    let status = try JSONDecoder().decode(StatusWirePayload.self, from: payload)
    #expect(status.state == "clients")
    #expect(status.clientCount == 3)
}

@Test("Performance counters expose cumulative terminal traffic")
func cumulativePerformanceCounters() {
    let before = RelayPerformance.shared.snapshot()
    RelayPerformance.shared.recordTerminalInput(bytes: 7)
    RelayPerformance.shared.recordTerminalBatch(bytes: 11, pendingBytes: 13)
    let after = RelayPerformance.shared.snapshot()
    #expect(after.terminalInputBytes >= before.terminalInputBytes + 7)
    #expect(after.terminalOutputBytes >= before.terminalOutputBytes + 11)
    #expect(after.terminalBatches >= before.terminalBatches + 1)
    #expect(after.maximumPendingBytes >= 13)
}

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

@Test("ANSI-colored image paths remain detectable across packets")
func coloredImagePathDetection() {
    var detector = ImagePathDetector()
    #expect(detector.ingest("Saved: \u{001B}[38;2;80;") == [])
    #expect(detector.ingest("180;220m/tmp/result.png\u{001B}[0m\r\n") == ["/tmp/result.png"])
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

@MainActor
@Test("Dismissed images stay closed until their content changes")
func dismissedArtifactsDoNotReappear() {
    let paneID = UUID()
    ArtifactDismissalStore.clear(paneID: paneID)
    defer { ArtifactDismissalStore.clear(paneID: paneID) }
    let pane = PaneModel(id: paneID, profile: .local)
    let path = "/tmp/relay-dismissed-preview.png"
    let first = Data("first image".utf8)
    let replacement = Data("replacement image".utf8)

    pane.receivedArtifact(path: path, data: first)
    #expect(pane.artifacts.count == 1)
    pane.dismissArtifact(pane.artifacts[0].id)
    pane.receivedArtifact(path: path, data: first)
    #expect(pane.artifacts.isEmpty)

    pane.receivedArtifact(path: path, data: replacement)
    #expect(pane.artifacts.count == 1)
}

@MainActor
@Test("Claude SVG artifacts are detected and normalized for terminal rendering")
func svgArtifactsRenderInline() {
    let path = "/tmp/claude-123/session/scratchpad/diagram.svg"
    var detector = ImagePathDetector()
    #expect(detector.ingest("Generated: \(path)\n") == [path])
    #expect(TerminalLinkResolver.target(from: path) == .image(path))

    let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16"><rect width="24" height="16" fill="#2fc6a0"/></svg>"##.utf8)
    let png = TerminalImageNormalizer.pngData(from: svg)
    if ProcessInfo.processInfo.environment["RELAY_HEADLESS_TESTING"] == "1" {
        #expect(png == nil)
    } else {
        #expect(png?.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == true)
    }
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

@Test("Hyperlink decoration never mutates Kitty image payloads")
func hyperlinkEncoderPreservesKittyImages() {
    let payload = Data("\u{001B}_Ga=T,f=100;YWJjL2RlZi5wbmc=\u{001B}\\".utf8)
    #expect(ArtifactHyperlinkEncoder.encode(payload) == payload)
}

@Test("Hyperlink decoration preserves shell integration control strings")
func hyperlinkEncoderPreservesShellIntegrationControls() {
    let osc7 = "\u{001B}]7;file://host/maps/project\u{0007}"
    let prompt = "\u{001B}]133;P;k=i\u{0007}[user] $ \u{001B}]133;B\u{0007}"
    let visible = "open /maps/project/main.rs\r\n"
    let encoded = ArtifactHyperlinkEncoder.encode(Data((osc7 + prompt + visible).utf8))
    let output = String(decoding: encoded, as: UTF8.self)

    #expect(output.hasPrefix(osc7 + prompt))
    #expect(output.contains("\u{001B}]8;;file:///__relay_remote_file__/"))
    #expect(!output.prefix((osc7 + prompt).count).contains("\u{001B}]8;"))
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

@MainActor
@Test("Tabs can be dragged in both directions and across the pinned boundary")
func tabReordering() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    workspace.newTab(profile: .sshConfigHost("tab-reorder-host"))
    let first = workspace.selectedTab!
    workspace.newTabInActiveSession()
    let second = workspace.selectedTab!
    workspace.newTabInActiveSession()
    let third = workspace.selectedTab!

    workspace.moveTab(third.id, relativeTo: first.id, placement: .before)
    #expect(workspace.orderedTabs(in: first.sessionID).map(\.id) == [third.id, first.id, second.id])

    workspace.moveTab(third.id, relativeTo: second.id, placement: .after)
    #expect(workspace.orderedTabs(in: first.sessionID).map(\.id) == [first.id, second.id, third.id])

    workspace.toggleTabPin(first.id)
    workspace.moveTab(third.id, relativeTo: first.id, placement: .before)
    #expect(workspace.isTabPinned(third.id))
    #expect(workspace.orderedTabs(in: first.sessionID).map(\.id) == [third.id, first.id, second.id])

    workspace.moveTab(first.id, relativeTo: second.id, placement: .after)
    #expect(!workspace.isTabPinned(first.id))
    #expect(workspace.orderedTabs(in: first.sessionID).map(\.id) == [third.id, second.id, first.id])
    workspace.shutdown()
}

@Test("Remote catalog groups durable workspaces and leaves old panes recoverable")
func remoteCatalogGrouping() throws {
    let data = Data(#"{"schema":1,"revision":7,"node_id":"node","node_name":"hpc-login","panes":[{"pane_id":"11111111-1111-1111-1111-111111111111","workspace_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","tab_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","content_kind":"terminal","state":"running","last_sequence":9,"recoverable":true,"unfiled":false},{"pane_id":"22222222-2222-2222-2222-222222222222","content_kind":"terminal","state":"running","last_sequence":3,"recoverable":true,"unfiled":true}]}"#.utf8)
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

    workspace.attachRemoteSession(profile: .sshConfigHost("hpc-login"), remote: remote)

    #expect(workspace.selectedTabID == tabID)
    #expect(workspace.selectedTab?.sessionID == sessionID)
    #expect(workspace.activePaneID == paneID)
    #expect(workspace.activePane?.remoteWorkspaceSessionID == sessionID.uuidString.lowercased())
    #expect(workspace.activePane?.remoteTabID == tabID.uuidString.lowercased())
    #expect(workspace.activePane?.directory == "/work")
    workspace.shutdown()
}

@MainActor
@Test("A missing pane can be recovered individually into its open remote tab")
func attachIndividualRemotePane() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let sessionID = UUID()
    let tabID = UUID()
    let existingPaneID = UUID()
    let missingPaneID = UUID()
    let profile = ConnectionProfile.sshConfigHost("hpc-login")

    func catalogPane(_ paneID: UUID, title: String) -> RemoteCatalogPane {
        RemoteCatalogPane(
            paneID: paneID.uuidString.lowercased(),
            workspaceID: sessionID.uuidString.lowercased(),
            tabID: tabID.uuidString.lowercased(),
            parentPaneID: nil,
            title: title,
            contentKind: "terminal",
            command: title.lowercased(),
            directory: "/work",
            state: "running",
            workerPID: 42,
            shellPID: 43,
            lastSequence: 8,
            recoverable: true,
            unfiled: false
        )
    }

    workspace.attachRemoteSession(
        profile: profile,
        remote: RemoteSessionRecord(
            id: "workspace:\(sessionID.uuidString.lowercased())",
            workspaceID: sessionID.uuidString.lowercased(),
            panes: [catalogPane(existingPaneID, title: "Shell")],
            workspaceSnapshot: nil
        )
    )
    workspace.attachRemotePane(
        profile: profile,
        remotePane: catalogPane(missingPaneID, title: "Codex"),
        workspaceID: sessionID.uuidString.lowercased(),
        sessionLabel: "Training"
    )

    #expect(workspace.panes[missingPaneID] != nil)
    #expect(workspace.selectedTabID == tabID)
    #expect(workspace.selectedTab?.floatingPanes.contains { $0.paneID == missingPaneID } == true)
    #expect(workspace.activePaneID == missingPaneID)
    workspace.shutdown()
}

@MainActor
@Test("A closed remote pane can be reopened without creating a new remote session")
func reopenClosedRemotePane() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    workspace.newTab(profile: .sshConfigHost("hpc-login"))
    let tabID = workspace.selectedTabID!
    let paneID = workspace.activePaneID!

    workspace.splitActive(axis: .horizontal)
    let siblingID = workspace.activePaneID!
    workspace.selectPane(paneID)
    workspace.closeActivePane()

    #expect(workspace.panes[paneID] == nil)
    #expect(workspace.canReopenClosedPane)
    #expect(workspace.selectedTab?.layout.paneIDs == [siblingID])

    workspace.reopenLastClosedPane()

    #expect(workspace.selectedTabID == tabID)
    #expect(workspace.activePaneID == paneID)
    #expect(workspace.selectedTab?.layout.paneIDs.contains(paneID) == true)
    #expect(workspace.selectedTab?.layout.paneIDs.contains(siblingID) == true)
    #expect(!workspace.canReopenClosedPane)
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
    let profile = ConnectionProfile.sshConfigHost("hpc-login")
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
                customName: "Codex",
                directory: "/stale"
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
    #expect(workspace.panes[terminalID]?.directory == "/work")
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
@Test("Duplicate tab names include project context")
func duplicateTabNamesAreDisambiguated() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let first = workspace.selectedTab!
    first.name = "compute-07"
    workspace.panes[first.allPaneIDs[0]]?.directory = "/work/alpha"
    workspace.newTabInActiveSession()
    let second = workspace.selectedTab!
    second.name = "compute-07"
    workspace.panes[second.allPaneIDs[0]]?.directory = "/work/beta"

    #expect(workspace.tabDisplayName(first, fallback: "Main") == "compute-07 · alpha")
    #expect(workspace.tabDisplayName(second, fallback: "Tab 2") == "compute-07 · beta")
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

@MainActor
@Test("Only explicit chrome can move the workspace window")
func workspaceBackgroundDoesNotStealContentDrags() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let marker = RelayWorkspaceWindowMarker.MarkerView(frame: .zero)
    window.contentView = marker
    marker.configureWindow()
    #expect(!window.isMovableByWindowBackground)
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

@Test("Node pane frame dispatch preserves order without blocking sibling panes")
func nodePaneFrameDispatchIsOrderedAndIndependent() {
    let blockedStarted = DispatchSemaphore(value: 0)
    let releaseBlocked = DispatchSemaphore(value: 0)
    let siblingFinished = DispatchSemaphore(value: 0)
    let orderedFinished = DispatchSemaphore(value: 0)
    let values = RelayNodeFrameRecorder()

    let blocked = RelayNodeFrameDispatcher(label: "relay.tests.node.blocked") { _ in
        blockedStarted.signal()
        releaseBlocked.wait()
    }
    let sibling = RelayNodeFrameDispatcher(label: "relay.tests.node.sibling") { frame in
        values.append(Int(frame.payload.first ?? 0))
        if frame.payload.first == 100 { siblingFinished.signal() }
    }
    let ordered = RelayNodeFrameDispatcher(label: "relay.tests.node.ordered") { frame in
        values.append(Int(frame.payload.first ?? 0))
        if frame.payload.first == 10 { orderedFinished.signal() }
    }

    blocked.enqueue(RelayWireFrame(type: .output, payload: Data([1])))
    #expect(blockedStarted.wait(timeout: .now() + 1) == .success)

    sibling.enqueue(RelayWireFrame(type: .output, payload: Data([100])))
    #expect(siblingFinished.wait(timeout: .now() + 1) == .success)

    for value in 2...10 {
        ordered.enqueue(RelayWireFrame(type: .output, payload: Data([UInt8(value)])))
    }
    #expect(orderedFinished.wait(timeout: .now() + 1) == .success)
    releaseBlocked.signal()
    blocked.close()
    sibling.close()
    ordered.close()

    #expect(values.snapshot == [100] + Array(2...10))
}

private final class RelayNodeFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
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

@Test("Relay pane handshakes never advertise an invalid viewport")
func relayViewportIsClamped() {
    #expect(RelayViewport(columns: 0, rows: -8) == RelayViewport(columns: 1, rows: 1))
    #expect(RelayViewport(columns: 180, rows: 52) == RelayViewport(columns: 180, rows: 52))
    #expect(RelayViewport(columns: Int.max, rows: Int.max).columns == UInt16.max)
}

@Test("Viewport-aware workers avoid a redundant redraw after attach")
func viewportAttachCapabilityControlsCompatibilityResize() {
    #expect(RelayTransportCapabilityPolicy.needsPostAttachResize([]))
    #expect(RelayTransportCapabilityPolicy.needsPostAttachResize(["input_ack_v1"]))
    #expect(!RelayTransportCapabilityPolicy.needsPostAttachResize(["viewport_attach_v1"]))
    #expect(RelayTransportCapabilityPolicy.supportsViewportCommit(["viewport_commit_v1"]))
    #expect(RelayTransportCapabilityPolicy.supportsViewportCommit(["viewport_commit_v2"]))
    #expect(!RelayTransportCapabilityPolicy.supportsExactViewportCommit(["viewport_commit_v1"]))
    #expect(RelayTransportCapabilityPolicy.supportsExactViewportCommit(["viewport_commit_v2"]))
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

    let prompt = "\u{001B}]133;P;k=i\u{0007}[user host]$ \u{001B}]133;B\u{0007}pending"
    let promptStorm = Data(("old scrollback" + prompt + prompt + prompt + "latest").utf8)
    let compactedStorm = String(decoding: TerminalReplayCompactor.compact(promptStorm), as: UTF8.self)
    #expect(compactedStorm.hasPrefix("\u{001B}c\u{001B}]133;P;k=i"))
    #expect(compactedStorm.hasSuffix("pendinglatest"))
    #expect(!compactedStorm.contains("old scrollback"))
}

@Test("Terminal replay keeps the latest complete synchronized TUI frame")
func compactSynchronizedTerminalFrames() {
    let first = "\u{001B}[?2026h\u{001B}[10;1Hfirst frame" +
        String(repeating: "a", count: 600) + "\u{001B}[?2026l"
    let latest = "\u{001B}[?2026h\u{001B}[10;1Hlatest frame" +
        String(repeating: "b", count: 600) + "\u{001B}[?2026l"
    let incomplete = "\u{001B}[?2026h\u{001B}[11;1Hlive tail"
    let history = Data(("old redraws" + first + latest + incomplete).utf8)

    let compacted = String(decoding: TerminalReplayCompactor.compact(history), as: UTF8.self)

    #expect(compacted.hasPrefix("\u{001B}c\u{001B}[?2026h"))
    #expect(compacted.contains("latest frame"))
    #expect(compacted.hasSuffix("live tail"))
    #expect(!compacted.contains("old redraws"))
    #expect(!compacted.contains("first frame"))
}

@Test("Terminal replay retains a complete base before synchronized cursor deltas")
func compactSynchronizedTerminalDeltas() {
    let base = "\u{001B}[?2026h\u{001B}[Hfull frame" +
        String(repeating: "x", count: 600) + "\u{001B}[?2026l"
    let spinner = "\u{001B}[?2026h\u{001B}[30;3HWorking\u{001B}[?2026l"
    let history = Data(("old redraws" + base + spinner + spinner).utf8)

    let compacted = String(decoding: TerminalReplayCompactor.compact(history), as: UTF8.self)

    #expect(compacted.contains("full frame"))
    #expect(compacted.components(separatedBy: "Working").count == 3)
    #expect(!compacted.contains("old redraws"))
}

@Test("Synchronized frames inside the alternate screen retain their owner")
func compactAlternateScreenSynchronizedFrames() {
    let history = Data(
        ("shell prompt\u{001B}[?1049h" +
            "\u{001B}[?2026h\u{001B}[Hhtop frame\u{001B}[?2026l").utf8
    )

    let compacted = String(decoding: TerminalReplayCompactor.compact(history), as: UTF8.self)

    #expect(compacted.contains("shell prompt"))
    #expect(compacted.contains("\u{001B}[?1049h"))
    #expect(compacted.hasSuffix("\u{001B}[?2026l"))
}

@Test("Terminal replay compaction preserves active TUI input modes")
func compactTerminalReplayPreservesInputModes() {
    let activeModes = "\u{001B}[?1h\u{001B}[?1000h\u{001B}[?1002h" +
        "\u{001B}[?1004h\u{001B}[?1006h\u{001B}[?1007h\u{001B}[?2004h"
    let history = Data((activeModes + "old frame\u{001B}[2J\u{001B}[Hcurrent frame").utf8)
    let compacted = String(decoding: TerminalReplayCompactor.compact(history), as: UTF8.self)

    #expect(compacted == "\u{001B}c" + activeModes + "\u{001B}[2J\u{001B}[Hcurrent frame")

    let disabledBeforeBoundary = Data(
        ("\u{001B}[?1000h\u{001B}[?1000lold frame\u{001B}[2Jcurrent frame").utf8
    )
    let disabledReplay = String(
        decoding: TerminalReplayCompactor.compact(disabledBeforeBoundary),
        as: UTF8.self
    )
    #expect(!disabledReplay.contains("\u{001B}[?1000h"))
}

@Test("Terminal replay compaction preserves the negotiated keyboard protocol")
func compactTerminalReplayPreservesKeyboardProtocol() {
    let history = Data(
        ("\u{001B}[>1uold frame\u{001B}[2J\u{001B}[Hcurrent composer").utf8
    )
    let compacted = String(decoding: TerminalReplayCompactor.compact(history), as: UTF8.self)
    #expect(compacted == "\u{001B}c\u{001B}[=1u\u{001B}[2J\u{001B}[Hcurrent composer")

    let nested = Data(
        ("\u{001B}[>1u\u{001B}[>3u\u{001B}[<uold\u{001B}[2Jcurrent").utf8
    )
    let nestedReplay = String(decoding: TerminalReplayCompactor.compact(nested), as: UTF8.self)
    #expect(nestedReplay == "\u{001B}c\u{001B}[=1u\u{001B}[2Jcurrent")

    let popped = Data(
        ("\u{001B}[>1u\u{001B}[<uold\u{001B}[2Jcurrent").utf8
    )
    let poppedReplay = String(decoding: TerminalReplayCompactor.compact(popped), as: UTF8.self)
    #expect(!poppedReplay.contains("\u{001B}[=1u"))
}

@Test("Live output cannot overtake a prepared reconnect screen")
func orderedTerminalReplayCommit() {
    let cached = Data("cached prompt".utf8)
    let replay = Data("\u{001B}[2J\u{001B}[Hreplayed screen".utf8)
    let liveTail = Data("\u{001B}[4;1Hfresh agent output".utf8)

    let replacement = TerminalReplayCommit.prepare(cached: cached, incoming: replay)
    let commit = TerminalReplayCommit.appendingLiveTail(liveTail, to: replacement)
    let rendered = String(decoding: commit, as: UTF8.self)

    #expect(rendered.contains("replayed screen"))
    #expect(rendered.hasSuffix("\u{001B}[4;1Hfresh agent output"))
    #expect(rendered.range(of: "replayed screen")!.lowerBound < rendered.range(of: "fresh agent output")!.lowerBound)
}

@Test("Terminal replay preserves alternate-screen ownership")
func compactTerminalReplayPreservesAlternateScreenLifecycle() {
    let completed = Data(
        "shell\u{001B}[2Jprompt\u{001B}[?1049h\u{001B}[2Jhtop\u{001B}[?1049lafter".utf8
    )
    let completedReplay = String(decoding: TerminalReplayCompactor.compact(completed), as: UTF8.self)
    #expect(completedReplay.contains("prompt"))
    #expect(completedReplay.contains("\u{001B}[?1049h"))
    #expect(completedReplay.contains("\u{001B}[?1049lafter"))

    let legacyTruncated = Data("\u{001B}[2Jhtop\u{001B}[?1049lclean prompt".utf8)
    let compatibilityReplay = String(
        decoding: TerminalReplayCompactor.compact(legacyTruncated), as: UTF8.self
    )
    #expect(!compatibilityReplay.contains("htop"))
    #expect(compatibilityReplay.hasSuffix("clean prompt"))

    let cachedOwner = Data(
        "shell\u{001B}[2Jprompt\u{001B}[?1049h\u{001B}[2Jhtop first frame".utf8
    )
    let oldWorkerReplay = Data("\u{001B}c\u{001B}[2Jhtop current frame".utf8)
    let merged = TerminalReplayCompactor.preservingAlternateScreenOwner(
        cached: cachedOwner,
        incoming: oldWorkerReplay
    )
    let activeReplay = String(decoding: TerminalReplayCompactor.compact(merged), as: UTF8.self)
    #expect(activeReplay.contains("prompt"))
    #expect(activeReplay.contains("\u{001B}[?1049h"))
    #expect(activeReplay.hasSuffix("htop current frame"))
    let afterAlternateEntry = activeReplay.components(separatedBy: "\u{001B}[?1049h").last ?? ""
    #expect(!afterAlternateEntry.contains("\u{001B}c"))
}

@Test("Leaving a dynamic alternate-screen app clears the restored viewport")
func alternateScreenExitClearsRestoredViewport() {
    let filter = TerminalAlternateScreenCleanupFilter()
    let entry = Data("\u{001B}[?1049h\u{001B}[2Jwatch frame".utf8)
    let exitAndPrompt = Data("\u{001B}[?1049lrelay$ ".utf8)

    #expect(filter.transform(entry) == entry)
    #expect(
        filter.transform(exitAndPrompt)
            == Data("\u{001B}[?1049l\u{001B}[0m\u{001B}[?25h\u{001B}[0 q\u{001B}[2J\u{001B}[Hrelay$ ".utf8)
    )
}

@Test("Alternate-screen cleanup survives packet boundaries and snapshot restore")
func alternateScreenCleanupHandlesSplitPacketsAndRestore() {
    let filter = TerminalAlternateScreenCleanupFilter()
    filter.observe(Data("shell\u{001B}[?1049hactive watch".utf8))

    #expect(filter.transform(Data("\u{001B}[?10".utf8)).isEmpty)
    #expect(
        filter.transform(Data("49lprompt".utf8))
            == Data("\u{001B}[?1049l\u{001B}[0m\u{001B}[?25h\u{001B}[0 q\u{001B}[2J\u{001B}[Hprompt".utf8)
    )

    let orphan = TerminalAlternateScreenCleanupFilter()
    #expect(
        orphan.transform(Data("\u{001B}[?1049lunchanged".utf8))
            == Data("\u{001B}[?1049lunchanged".utf8)
    )
}

@Test("Remote semantic prompt tracking survives SSH packet boundaries")
func semanticPromptTrackingHandlesSplitPackets() {
    let tracker = TerminalSemanticPromptStateTracker()

    #expect(tracker.observe(Data("output\u{001B}]133;".utf8)) == nil)
    #expect(tracker.observe(Data("B\u{0007}".utf8)) == true)
    #expect(tracker.observe(Data("prompt text".utf8)) == nil)
    #expect(tracker.observe(Data("\u{001B}]133;C\u{001B}\\".utf8)) == false)
}

@Test("Unrelated terminal OSC data cannot enable prompt editing")
func semanticPromptTrackingIgnoresUnrelatedOSC() {
    let tracker = TerminalSemanticPromptStateTracker()
    #expect(tracker.observe(Data("\u{001B}]0;133;B fake title\u{0007}".utf8)) == nil)
    #expect(tracker.observe(Data("\u{001B}]133;P;k=i\u{0007}".utf8)) == nil)
    #expect(tracker.observe(Data("\u{001B}]133;B\u{0007}".utf8)) == true)
    #expect(tracker.observe(Data("\u{001B}]133;B\u{0007}".utf8)) == nil)
}

@Test("Primary-screen reconnect deltas extend the cached TUI screen")
func reconnectDeltaPreservesPrimaryScreenBase() {
    let cached = Data("\u{001B}cfull Codex conversation\u{001B}[36;3Hworking".utf8)
    let spinnerDelta = Data("\u{001B}[36;3H57".utf8)
    let merged = TerminalReplayCompactor.preservingAlternateScreenOwner(
        cached: cached,
        incoming: spinnerDelta
    )
    let rendered = String(decoding: merged, as: UTF8.self)

    #expect(rendered.contains("full Codex conversation"))
    #expect(rendered.hasSuffix("\u{001B}[36;3H57"))
}

@Test("Authoritative reconnect repaint replaces stale primary-screen cells")
func reconnectRepaintBarrierReplacesPrimaryScreenBase() {
    let cached = Data("\u{001B}cstale Claude status\u{001B}[36;3H99".utf8)
    let repaint = Data("\u{001B}[2J\u{001B}[Hcurrent Claude conversation\u{001B}[36;3Hworking".utf8)
    let merged = TerminalReplayCompactor.preservingAlternateScreenOwner(
        cached: cached,
        incoming: repaint
    )
    let rendered = String(decoding: TerminalReplayCompactor.compact(merged), as: UTF8.self)

    #expect(!rendered.contains("stale Claude status"))
    #expect(rendered.contains("current Claude conversation"))
    #expect(rendered.hasSuffix("\u{001B}[36;3Hworking"))
}

@Test("Terminal snapshots stay bounded and self-resetting")
func terminalSnapshotBound() {
    var oversized = Data("old-prefix".utf8)
    oversized.append(Data(repeating: 0x78, count: TerminalSnapshotStore.maximumBytes * 2))
    let bounded = TerminalSnapshotStore.bounded(oversized)
    #expect(bounded.count <= TerminalSnapshotStore.maximumBytes)
    #expect(bounded.starts(with: Data("\u{001B}c".utf8)))
}

@Test("Live snapshot compaction uses a bounded high-water window")
func liveSnapshotCompactionUsesHighWaterWindow() {
    #expect(!TerminalSnapshotCompactionPolicy.shouldCompact(
        byteCount: TerminalSnapshotStore.maximumBytes
    ))
    #expect(!TerminalSnapshotCompactionPolicy.shouldCompact(
        byteCount: TerminalSnapshotCompactionPolicy.highWaterBytes
    ))
    #expect(TerminalSnapshotCompactionPolicy.shouldCompact(
        byteCount: TerminalSnapshotCompactionPolicy.highWaterBytes + 1
    ))
}

@Test("Already-bounded terminal snapshots avoid replay compaction")
func terminalSnapshotSmallPassThrough() {
    let payload = Data("prompt\u{001B}[31m ready".utf8)
    #expect(TerminalSnapshotStore.bounded(payload) == payload)
}

@Test("Persisted agent trees keep a useful bounded tail")
func persistedAgentStateBound() {
    let updates = (0..<12).map { index in
        SubagentUpdate(
            id: UUID(), message: String(repeating: "x", count: 3_000) + "-\(index)",
            occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
    let subagents = (0..<120).map { index in
        SubagentActivity(
            id: "worker-\(index)", label: "Worker \(index)",
            startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            provider: .codex, phase: index >= 115 ? .active : .quiet,
            updates: updates
        )
    }
    let state = PersistedAgentPaneState(
        cursor: 42, kind: .codex, phase: .active,
        summary: String(repeating: "s", count: 2_000),
        subagents: subagents, activities: [], resourceUsage: nil,
        progressPercent: nil, pendingApprovals: 0
    ).boundedForStorage()

    #expect(state.subagents.count == 100)
    #expect(state.subagents.filter { $0.phase == .active }.count == 5)
    #expect(state.subagents.allSatisfy { $0.updates.count <= 10 })
    #expect(state.subagents.flatMap(\.updates).allSatisfy { $0.message.count <= 2_048 })
    #expect(state.summary.count == 1_024)
}

@Test("relayd status distinguishes missing, healthy, and outdated hosts")
func relaydStatusParsing() throws {
    let missing = try RelaydStatusParser.parse(
        Data("RELAYD_MISSING\tx86_64\n".utf8), expectedVersion: "0.5.0"
    )
    #expect(missing.state == .missing)
    #expect(missing.architecture == "x86_64")

    let catalog = #"{"schema":1,"revision":3,"panes":[{"pane_id":"pane-1","content_kind":"terminal","state":"running","last_sequence":7,"recoverable":true,"unfiled":true}],"workspace_states":{}}"#
    let fakeToken = "sk-" + String(repeating: "a", count: 24)
    let response = """
    RELAYD_STATUS\tx86_64\trelayd 0.5.0\t4321\t1
    RELAYD_CATALOG_BEGIN
    \(catalog)
    RELAYD_CATALOG_END
    RELAYD_LOG_BEGIN
    supervisor ready token=\(fakeToken)
    RELAYD_LOG_END
    """
    let healthy = try RelaydStatusParser.parse(Data(response.utf8), expectedVersion: "0.5.0")
    #expect(healthy.state == .ready)
    #expect(healthy.supervisorPID == 4321)
    #expect(healthy.sessionCount == 1)
    #expect(healthy.runningPaneCount == 1)
    #expect(healthy.recoverablePaneCount == 1)
    #expect(healthy.logLines.first?.contains("<redacted>") == true)

    let outdated = try RelaydStatusParser.parse(Data(response.utf8), expectedVersion: "0.6.0")
    #expect(outdated.state == .outdated)
    #expect(outdated.message?.contains("0.6.0") == true)

    let newer = try RelaydStatusParser.parse(Data(response.utf8), expectedVersion: "0.4.9")
    #expect(newer.state == .ready)
    #expect(newer.message?.contains("will not downgrade") == true)
}

@Test("relayd status ignores SSH banners and detects a stale live supervisor")
func relaydStatusIgnoresBanners() throws {
    let nonce = "relay-status-42-100"
    let response = """
    Welcome to the shared cluster
    Maintenance banner: RELAYD_STATUS is a reserved Relay marker
    RELAYD_STATUS\t\(nonce)\taarch64\trelayd 0.5.2\t0.5.1\t1\t998\t2
    RELAYD_CATALOG_BEGIN\t\(nonce)
    {"schema":1,"revision":0,"panes":[],"workspace_states":{}}
    RELAYD_CATALOG_END\t\(nonce)
    RELAYD_LOG_BEGIN\t\(nonce)
    old supervisor still answering
    RELAYD_LOG_END\t\(nonce)
    """
    let report = try RelaydStatusParser.parse(Data(response.utf8), expectedVersion: "0.5.2")
    #expect(report.state == .outdated)
    #expect(report.architecture == "aarch64")
    #expect(report.version == "0.5.2")
    #expect(report.liveVersion == "0.5.1")
    #expect(report.protocolVersion == 1)
    #expect(report.supervisorPID == 998)
    #expect(report.message?.contains("running supervisor") == true)
}

@Test("relayd catalog failure remains repairable even at the current version")
func relaydCatalogFailureIsRepairable() throws {
    let nonce = "relay-status-8-200"
    let response = """
    RELAYD_STATUS\t\(nonce)\tx86_64\trelayd 0.5.2\t0.5.2\t2\t100\t2\t0
    RELAYD_CATALOG_BEGIN\t\(nonce)
    {"schema":1,"revision":0,"panes":[],"workspace_states":{}}
    RELAYD_CATALOG_END\t\(nonce)
    RELAYD_LOG_BEGIN\t\(nonce)
    RELAYD_LOG_END\t\(nonce)
    """
    let report = try RelaydStatusParser.parse(Data(response.utf8), expectedVersion: "0.5.2")
    #expect(report.state == .outdated)
    #expect(report.message?.contains("repair") == true)
}

@Test("Terminal snapshots use a battery-friendly write debounce")
func terminalSnapshotWritePolicy() {
    #expect(TerminalSnapshotWritePolicy.debounceMilliseconds >= 1_000)
    #expect(TerminalSnapshotWritePolicy.leewayMilliseconds >= 250)
    #expect(TerminalSnapshotWritePolicy.maximumIntervalMilliseconds >= 3_000)
    #expect(TerminalSnapshotWritePolicy.maximumIntervalMilliseconds <= 10_000)
    #expect(TerminalSnapshotWritePolicy.backgroundDebounceMilliseconds >= 15_000)
    #expect(
        TerminalSnapshotWritePolicy.backgroundMaximumIntervalMilliseconds
            >= TerminalSnapshotWritePolicy.backgroundDebounceMilliseconds
    )
}

@Test("Live terminal output is batched at display cadence")
func liveTerminalOutputBatchPolicy() {
    #expect(TerminalDisplayBatchPolicy.liveMilliseconds >= 8)
    #expect(TerminalDisplayBatchPolicy.liveMilliseconds <= 17)
}

@Test("Quit-time terminal snapshots are immediately durable")
func terminalSnapshotSynchronousSave() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-snapshot-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TerminalSnapshotStore(directory: directory)
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    let payload = Data("shell\u{001B}[?1049h\u{001B}[2Jhtop".utf8)

    store.saveSynchronously(
        payload, paneID: paneID, viewport: viewport, remoteSequence: 417
    )

    #expect(store.load(paneID: paneID, viewport: viewport) != nil)
    #expect(store.loadSnapshot(paneID: paneID, viewport: viewport)?.remoteSequence == 417)
}

@Test("Terminal screen caches require an exact viewport match")
func terminalSnapshotViewportRecord() {
    let viewport = RelayViewport(columns: 91, rows: 27)
    let payload = Data("current screen".utf8)
    let record = TerminalSnapshotRecordCodec.encode(
        payload, viewport: viewport, remoteSequence: 99
    )

    #expect(TerminalSnapshotRecordCodec.decode(record, expectedViewport: viewport) == payload)
    #expect(TerminalSnapshotRecordCodec.decodeSnapshot(
        record, expectedViewport: viewport
    )?.remoteSequence == 99)
    #expect(TerminalSnapshotRecordCodec.decode(
        record, expectedViewport: RelayViewport(columns: 92, rows: 27)
    ) == nil)
    #expect(TerminalSnapshotRecordCodec.decode(payload, expectedViewport: viewport) == nil)
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

@Test("Replay filters device replies without making the terminal read-only")
func replayKeepsUserInputWritable() {
    #expect(TerminalWriteForwardingPolicy.shouldForward(
        Data("hello".utf8), filteringDeviceResponses: true
    ))
    #expect(TerminalWriteForwardingPolicy.shouldForward(
        Data("\u{001B}[A".utf8), filteringDeviceResponses: true
    ))
    #expect(TerminalWriteForwardingPolicy.shouldForward(
        Data("\u{001B}[<0;12;4M".utf8), filteringDeviceResponses: true
    ))
    #expect(!TerminalWriteForwardingPolicy.shouldForward(
        Data("\u{001B}[?62;22;52c".utf8), filteringDeviceResponses: true
    ))
    #expect(TerminalWriteForwardingPolicy.shouldForward(
        Data("\u{001B}[?62;22;52c".utf8), filteringDeviceResponses: false
    ))
    #expect(!TerminalWriteForwardingPolicy.shouldForward(
        Data(), filteringDeviceResponses: false
    ))
}

@Test("Packaged Ghostty resources resolve below the app resource directory")
func packagedGhosttyResourcePathIsDeterministic() {
    let resources = URL(fileURLWithPath: "/Applications/Relay.app/Contents/Resources")
    #expect(
        RelayBundledGhosttyResources.directory(in: resources).path
            == "/Applications/Relay.app/Contents/Resources/"
                + "GhosttyKit_GhosttyTerminal.bundle/Ghostty"
    )
}

@Test("Packaged Ghostty resources configure the runtime environment")
func packagedGhosttyResourcesConfigureEnvironment() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let ghostty = RelayBundledGhosttyResources.directory(in: root)
    try fileManager.createDirectory(at: ghostty, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
        unsetenv("GHOSTTY_RESOURCES_DIR")
    }

    #expect(RelayBundledGhosttyResources.configure(
        applicationResourcesURL: root,
        fileManager: fileManager
    ))
    #expect(String(cString: getenv("GHOSTTY_RESOURCES_DIR")) == ghostty.path)
}

@Test("Diagnostics redact credentials before they are retained or exported")
func diagnosticRedaction() throws {
    #expect(RelayDiagnostics.redact("Bearer abc.def.secret") == "Bearer <redacted>")
    #expect(RelayDiagnostics.redact("github_pat", key: "access_token") == "<redacted>")
    #expect(RelayDiagnostics.redact("https://person:password@example.test/path") == "https://<redacted>@example.test/path")

    let diagnostics = RelayDiagnostics()
    diagnostics.record(category: "test", name: "redaction", details: [
        "authorization": "Bearer must-not-survive",
        "message": "request used \("ghp_" + String(repeating: "a", count: 24))",
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
    #expect(!exported.contains("ghp_" + String(repeating: "a", count: 24)))
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
    let path = "/home/test/.codex/generated_images/demo image.png"
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

@Test("Prompt selection deletion supports agent prompt blocks")
func promptSelectionDeletionSequence() {
    for kind in AgentKind.allCases {
        #expect(TerminalPromptSelectionEdit.isEnabled(contentKind: .terminal, agentKind: kind))
    }
    #expect(!TerminalPromptSelectionEdit.isEnabled(contentKind: .editor, agentKind: .codex))
    #expect(!TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: .shell))
    #expect(TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: .codex))
    #expect(TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: .claude))
    #expect(TerminalPromptSelectionEdit.allowsCursorPlacement(
        geometryIsStable: true,
        alternateScreenIsActive: false,
        agentPrompt: false
    ))
    #expect(!TerminalPromptSelectionEdit.allowsCursorPlacement(
        geometryIsStable: true,
        alternateScreenIsActive: true,
        agentPrompt: false
    ))
    #expect(!TerminalPromptSelectionEdit.allowsCursorPlacement(
        geometryIsStable: true,
        alternateScreenIsActive: true,
        agentPrompt: true
    ))
    #expect(!TerminalPromptSelectionEdit.allowsCursorPlacement(
        geometryIsStable: false,
        alternateScreenIsActive: false,
        agentPrompt: true
    ))
    #expect(TerminalPromptSelectionEdit.deletionSequence(for: "three words", backwards: true)
        == String(repeating: "\u{007F}", count: 11))
    #expect(TerminalPromptSelectionEdit.deletionSequence(for: "abc", backwards: false)
        == String(repeating: "\u{007F}", count: 3))
    #expect(TerminalPromptSelectionEdit.deletionSequence(for: "output\nnext", backwards: false)
        == String(repeating: "\u{007F}", count: 11))
    #expect(TerminalPromptSelectionEdit.deletionSequence(
        for: String(repeating: "x", count: 8_193),
        backwards: true
    ) == nil)

    // Codex may anchor the composer near the top of a tall terminal. Its
    // prompt remains editable because validation follows the live cursor.
    #expect(TerminalPromptSelectionEdit.selectionIsNearCursor(
        startY: 120,
        endY: 146,
        cursorY: 146,
        viewportHeight: 720,
        agentPrompt: true
    ))
    #expect(!TerminalPromptSelectionEdit.selectionIsNearCursor(
        startY: 600,
        endY: 620,
        cursorY: 146,
        viewportHeight: 720,
        agentPrompt: true
    ))
    #expect(TerminalPromptSelectionEdit.cursorMovementOffset(
        cursorOrigin: CGPoint(x: 390, y: 150),
        target: CGPoint(x: 294, y: 150),
        cellSize: CGSize(width: 6, height: 14),
        columns: 150
    ) == -16)
    #expect(TerminalPromptSelectionEdit.cursorMovementOffset(
        cursorOrigin: CGPoint(x: 294, y: 150),
        target: CGPoint(x: 390, y: 150),
        cellSize: CGSize(width: 6, height: 14),
        columns: 150
    ) == 16)
    #expect(TerminalPromptSelectionEdit.cursorMovementOffset(
        cursorOrigin: CGPoint(x: 390, y: 150),
        target: CGPoint(x: 294, y: 170),
        cellSize: CGSize(width: 6, height: 14),
        columns: 150
    ) == 134)
    #expect(TerminalPromptSelectionEdit.cursorMovementOffset(
        cursorOrigin: CGPoint(x: 390, y: 150),
        target: CGPoint(x: 395.9, y: 163.9),
        cellSize: CGSize(width: 6, height: 14),
        columns: 150
    ) == 0)
}

@Test("Remote prompt editing survives agent phase changes and restored lines")
func remotePromptEditingPolicy() {
    // Typing into an agent prompt immediately changes its conversation phase
    // to active. That must not make the composer mouse-inert mid-turn.
    #expect(TerminalPromptSelectionEdit.promptEditingIsActive(
        agentPrompt: true,
        hasLocalInput: true,
        agentPhaseAllowsEditing: false,
        semanticShellPromptActive: false
    ))
    #expect(!TerminalPromptSelectionEdit.promptEditingIsActive(
        agentPrompt: true,
        hasLocalInput: false,
        agentPhaseAllowsEditing: false,
        semanticShellPromptActive: false
    ))

    // A restored SSH line has no trustworthy local text mirror. Its semantic
    // prompt marker still permits one bounded visual arrow packet.
    #expect(TerminalPromptSelectionEdit.promptEditingIsActive(
        agentPrompt: false,
        hasLocalInput: false,
        agentPhaseAllowsEditing: false,
        semanticShellPromptActive: true
    ))
    #expect(TerminalPromptSelectionEdit.resolvedMovementOffset(
        visualOffset: -37,
        mirroredOffset: nil,
        mirrorIsReliable: false,
        allowsRemoteVisualFallback: true
    ) == -37)
    #expect(TerminalPromptSelectionEdit.resolvedMovementOffset(
        visualOffset: -37,
        mirroredOffset: -4,
        mirrorIsReliable: true,
        allowsRemoteVisualFallback: true
    ) == -4)
    #expect(TerminalPromptSelectionEdit.resolvedMovementOffset(
        visualOffset: -37,
        mirroredOffset: nil,
        mirrorIsReliable: true,
        allowsRemoteVisualFallback: true
    ) == nil)
    #expect(TerminalPromptSelectionEdit.resolvedMovementOffset(
        visualOffset: 2_000,
        mirroredOffset: nil,
        mirrorIsReliable: false,
        allowsRemoteVisualFallback: true
    ) == nil)
}

@Test("Viewport repaint barriers distinguish replacement output from ordinary output")
func viewportRepaintBarrierPolicy() {
    #expect(!TerminalViewportRepaintPolicy.needsClearBarrier(
        Data("\u{001B}]133;A\u{0007}$ prompt".utf8), rows: 40
    ))
    #expect(TerminalViewportRepaintPolicy.needsClearBarrier(
        Data(("\u{001B}[1;1Hfirst" + String(repeating: "x", count: 80) +
            "\u{001B}[2;1Hsecond\u{001B}[3;1Hthird").utf8), rows: 40
    ))
    #expect(!TerminalViewportRepaintPolicy.needsClearBarrier(
        Data("ordinary build output\r\nnext line\r\n".utf8), rows: 40
    ))
    #expect(!TerminalViewportRepaintPolicy.needsClearBarrier(
        Data("\r\u{001B}[2K[user@host project]$ pending input".utf8), rows: 40
    ))
    let coloredOutput = String(repeating: "\u{001B}[38;5;42mgreen\u{001B}[0m ", count: 12)
    #expect(!TerminalViewportRepaintPolicy.needsClearBarrier(
        Data(coloredOutput.utf8), rows: 40
    ))
    let semanticPromptRepaint = "\r\u{001B}[K\u{001B}]133;P;k=i\u{0007}" +
        String(repeating: "[user@host project] ", count: 5) +
        "$ \u{001B}]133;B\u{0007}pending command"
    #expect(TerminalViewportRepaintPolicy.needsClearBarrier(
        Data(semanticPromptRepaint.utf8), rows: 40
    ))
    #expect(!TerminalViewportRepaintPolicy.needsClearBarrier(
        Data("\u{001B}[2J\u{001B}[Halready clears".utf8), rows: 40
    ))

    let synchronizedFrame = "\u{001B}[?2026h\u{001B}[H" +
        String(repeating: "frame", count: 120) + "\u{001B}[?2026l"
    #expect(TerminalViewportRepaintPolicy.hasCompleteReplacement(
        Data(synchronizedFrame.utf8), rows: 40
    ))
    #expect(!TerminalViewportRepaintPolicy.hasCompleteReplacement(
        Data("\u{001B}[2J\u{001B}[H".utf8), rows: 40
    ))
    #expect(TerminalViewportRepaintPolicy.hasCompleteReplacement(
        Data(("\u{001B}[2J\u{001B}[H" + String(repeating: "content", count: 100)).utf8),
        rows: 40
    ))
    #expect(!TerminalViewportRepaintPolicy.hasCompleteReplacement(
        Data("ordinary build output\r\nnext line\r\n".utf8), rows: 40
    ))
}

@Test("Terminal links route web, image, and source paths natively")
func terminalLinkRouting() {
    let source = "/maps/project/Sources/main.swift"
    let sourceLink = TerminalLinkResolver.link(forRemotePath: source)
    #expect(TerminalLinkResolver.target(from: sourceLink) == .file(source))

    let image = "/tmp/claude-1234/result.png"
    let imageLink = TerminalLinkResolver.link(forRemotePath: image)
    #expect(TerminalLinkResolver.target(from: imageLink) == .image(image))

    let web = URL(string: "https://example.com/docs?q=relay")!
    #expect(TerminalLinkResolver.target(from: web.absoluteString) == .web(web))
}

@Test("Terminal path classification is lexical and handles HPC paths")
func terminalPathClassificationIsLexical() {
    #expect(TerminalPathSyntax.lastComponent("/maps/projects/team/main.swift") == "main.swift")
    #expect(TerminalPathSyntax.lastComponent("/maps/projects/team/") == "team")
    #expect(TerminalPathSyntax.pathExtension("/maps/projects/team/archive.TAR.GZ") == "gz")
    #expect(TerminalPathSyntax.pathExtension("/maps/projects/team/.env") == "")
    #expect(TerminalPathSyntax.parentDirectory("/maps/projects/team/main.swift") == "/maps/projects/team")
    #expect(TerminalPathSyntax.parentDirectory("/main.swift") == "/")
    #expect(
        TerminalPathSyntax.resolving("../shared/./main.rs", against: "/maps/projects/team")
            == "/maps/projects/shared/main.rs"
    )
    #expect(TerminalLinkResolver.isImagePath("/maps/projects/team/figure.PNG"))
}

@Test("Code paths and URLs become clickable without changing visible output")
func terminalHyperlinksCoverCodeAndWeb() {
    let visible = "See /maps/project/main.rs:42 and https://example.com/docs/guide.md\n"
    let encoded = ArtifactHyperlinkEncoder.encode(Data(visible.utf8))
    let output = String(decoding: encoded, as: UTF8.self)
    #expect(output.contains("file:///__relay_remote_file__/"))
    #expect(output.components(separatedBy: "file:///__relay_remote_file__/").count == 2)
    #expect(output.contains("\u{001B}]8;;https://example.com/docs/guide.md"))
    let stripped = output.replacingOccurrences(
        of: "\\u001B\\]8;;[^\\u001B]*\\u001B\\\\|\\u001B\\]8;;\\u001B\\\\",
        with: "",
        options: .regularExpression
    )
    #expect(stripped == visible)
}

@Test("Agent focus keeps urgent work visible and bounds background history")
func agentAttentionPolicyBoundsHistory() {
    let now = Date()
    var agents = (0..<20).map { index in
        SubagentActivity(
            id: "done-\(index)", label: "worker_\(index)",
            startedAt: now.addingTimeInterval(Double(-index)), phase: .quiet
        )
    }
    agents.append(SubagentActivity(id: "active", label: "active_worker", startedAt: now, phase: .active))
    agents.append(SubagentActivity(id: "urgent", label: "approval", startedAt: now, phase: .needsInput))

    let snapshot = AgentAttentionPolicy.select(
        agents, limit: 5, preferredCompletedIDs: ["done-12", "done-9"]
    )

    #expect(snapshot.visibleIDs.first == "urgent")
    #expect(snapshot.visibleIDs.contains("active"))
    #expect(snapshot.visibleIDs.contains("done-12"))
    #expect(snapshot.visibleIDs.count == 5)
    #expect(snapshot.hiddenCount == 17)
    #expect(snapshot.attentionCount == 1)
}

@Test("Restored agent lists use instant heuristics without loading a model")
func restoredAgentListsSkipAutomaticModelRanking() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let restored = SubagentActivity(
        id: "restored", label: "old review",
        startedAt: now.addingTimeInterval(-3_600), phase: .quiet,
        completedAt: now.addingTimeInterval(-600)
    )
    let live = SubagentActivity(
        id: "live", label: "fresh review",
        startedAt: now.addingTimeInterval(-30), phase: .quiet,
        completedAt: now.addingTimeInterval(-2)
    )

    #expect(!AgentAttentionPolicy.hasRecentCompletedActivity([restored], now: now))
    #expect(AgentAttentionPolicy.hasRecentCompletedActivity([restored, live], now: now))
}

@Test("Agent labels hide transport-oriented identifiers")
func agentLabelsAreHumanReadable() {
    #expect(AgentLabelFormatter.humanize("external_peer") == "External session")
    #expect(AgentLabelFormatter.humanize("/root/logic_retest") == "Logic retest")
    #expect(AgentLabelFormatter.humanize("") == "Agent")
    #expect(AgentLabelFormatter.activity("Peer message · external_peer") == "Peer message · external session")
}
@Test("Pane drop geometry previews directional and swap targets")
func paneDropGeometryTargets() {
    let size = CGSize(width: 100, height: 100)
    #expect(PaneDropGeometry.placement(at: CGPoint(x: 10, y: 50), in: size) == .leading)
    #expect(PaneDropGeometry.placement(at: CGPoint(x: 90, y: 50), in: size) == .trailing)
    #expect(PaneDropGeometry.placement(at: CGPoint(x: 50, y: 10), in: size) == .top)
    #expect(PaneDropGeometry.placement(at: CGPoint(x: 50, y: 90), in: size) == .bottom)
    #expect(PaneDropGeometry.placement(at: CGPoint(x: 50, y: 50), in: size) == .center)
}

@Test("Terminal geometry rejects invalid transitional view sizes")
func terminalGeometryRejectsInvalidTransitionalViewSizes() {
    #expect(!TerminalGeometry.accepts(NSSize(width: -40, height: -2)))
    #expect(!TerminalGeometry.accepts(NSSize(width: CGFloat.nan, height: CGFloat.infinity)))
    #expect(!TerminalGeometry.accepts(NSSize(width: 1, height: 1)))
    #expect(TerminalGeometry.accepts(NSSize(width: 640, height: 360)))
}

@Test("Remote viewport prediction preserves the live surface until commit")
func remoteViewportPredictionUsesBackingPixels() {
    let viewport = TerminalViewportGeometry.predictedViewport(
        bounds: CGSize(width: 610, height: 400),
        backingScaleFactor: 2,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    )
    #expect(viewport == RelayViewport(columns: 122, rows: 40))
    #expect(TerminalViewportGeometry.predictedViewport(
        bounds: .zero,
        backingScaleFactor: 2,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    ) == nil)
}

@Test("Split geometry never forwards invalid transition sizes to AppKit")
func splitGeometrySanitizesInvalidTransitionSizes() {
    let negative = RelaySplitGeometry(
        proposedSize: CGSize(width: -640, height: -360),
        axis: .horizontal,
        ratio: 0.5
    )
    #expect(negative.size == .zero)
    #expect(negative.divider == 0)
    #expect(negative.firstLength == 0)
    #expect(negative.secondLength == 0)

    let invalidRatio = RelaySplitGeometry(
        proposedSize: CGSize(width: 1_000, height: 600),
        axis: .horizontal,
        ratio: .nan
    )
    #expect(invalidRatio.ratio == 0.5)
    #expect(invalidRatio.firstLength >= 0)
    #expect(invalidRatio.secondLength >= 0)
    #expect(invalidRatio.firstLength + invalidRatio.secondLength == invalidRatio.available)
}

@Test("Remote resize waits for committed pane geometry")
func terminalResizePolicyWaitsForStableGeometry() {
    #expect(TerminalResizePolicy.debounceMilliseconds >= 50)
    #expect(TerminalResizePolicy.revealAfterCommitMilliseconds >= 32)
    #expect(TerminalResizePolicy.revealAfterCommitMilliseconds < 100)
}

@Test("Native terminal reclaims geometry after browser ownership")
func nativeTerminalReclaimsGeometryAfterBrowserOwnership() {
    let native = RelayViewport(columns: 82, rows: 28)
    let browser = RelayViewport(columns: 127, rows: 57)

    #expect(TerminalViewportOwnershipPolicy.needsNativeReclaim(
        native: native,
        committed: browser
    ))
    #expect(TerminalViewportOwnershipPolicy.needsNativeReclaim(
        native: native,
        committed: nil
    ))
    #expect(!TerminalViewportOwnershipPolicy.needsNativeReclaim(
        native: native,
        committed: native
    ))
}

@Test("Terminal bottom detection is overflow safe")
func terminalBottomDetectionIsOverflowSafe() {
    #expect(TerminalViewportPosition.isAtBottom(.init(total: 100, offset: 76, len: 24)))
    #expect(!TerminalViewportPosition.isAtBottom(.init(total: 100, offset: 75, len: 24)))
    #expect(TerminalViewportPosition.isAtBottom(.init(total: 20, offset: .max, len: 5)))
}

@Test("Stale SwiftUI teardown cannot hide a newer terminal attachment")
func staleTerminalPresentationAttachmentIsIgnored() {
    var state = TerminalPresentationAttachmentState()
    let outgoingLease = UUID()
    let incomingLease = UUID()
    let outgoingGeneration = state.begin(lease: outgoingLease)
    let outgoingPresented = state.setPresented(
        true, lease: outgoingLease, generation: outgoingGeneration
    )
    #expect(outgoingPresented)

    let incomingGeneration = state.begin(lease: incomingLease)
    let staleEndAccepted = state.end(
        lease: outgoingLease, generation: outgoingGeneration
    )
    #expect(!staleEndAccepted)
    #expect(state.currentLease == incomingLease)
    let incomingPresented = state.setPresented(
        true, lease: incomingLease, generation: incomingGeneration
    )
    #expect(incomingPresented)
    #expect(state.isPresented)
}

@Test("Viewport transactions retain generation and final geometry")
func viewportTransactionsRetainGenerationAndGeometry() {
    let payload = RelayWireFrame.viewportCommitPayload(
        generation: 42,
        columns: 160,
        rows: 48
    )
    #expect(payload.count == 12)
    #expect(payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } == 42)
    #expect(payload.dropFirst(8).prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) } == 160)
    #expect(payload.suffix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) } == 48)

    var acknowledgement = Data()
    var generation = UInt64(42).bigEndian
    var sequence = UInt64(9_001).bigEndian
    withUnsafeBytes(of: &generation) { acknowledgement.append(contentsOf: $0) }
    withUnsafeBytes(of: &sequence) { acknowledgement.append(contentsOf: $0) }
    let parsed = RelayWireFrame.parseViewportAck(acknowledgement)
    #expect(parsed?.generation == 42)
    #expect(parsed?.repaintSequence == 9_001)
}

@MainActor
@Test("Missing terminal fonts use a metrically valid installed fallback")
func missingTerminalFontsUseInstalledFallback() {
    let preferences = RelayPreferences.shared
    let original = preferences.fontFamily
    defer { preferences.fontFamily = original }
    preferences.fontFamily = "Relay Definitely Missing Font"
    #expect(preferences.resolvedFontFamily == "Menlo")
    #expect(preferences.isUsingFontFallback)
}

@MainActor
@Test("Agent intelligence inbox deduplicates replay and tracks unread state")
func agentIntelligenceInboxDeduplicatesReplay() {
    let store = AgentIntelligenceStore(persistenceEnabled: false)
    let paneID = UUID()
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    let event = AgentInboxEvent(
        paneID: paneID,
        host: "compute-07",
        provider: .codex,
        agentID: "/root/review",
        kind: .completion,
        title: "Review finished",
        detail: "Validated the reconnect path.",
        occurredAt: time,
        sourceID: "relay-seq:42"
    )

    let firstID = store.record(event)
    let replayID = store.record(AgentInboxEvent(
        paneID: paneID,
        host: "compute-07",
        provider: .codex,
        agentID: "/root/review",
        kind: .completion,
        title: "Review finished",
        detail: "Validated the reconnect path.",
        occurredAt: time.addingTimeInterval(20),
        sourceID: "relay-seq:42"
    ))
    #expect(firstID == replayID)
    #expect(store.items.count == 1)
    #expect(store.unreadCount == 1)

    store.markRead(firstID)
    #expect(store.unreadCount == 0)
    #expect(store.items.first?.isRead == true)
}

@MainActor
@Test("Agent intelligence preserves cross-session peer direction")
func agentIntelligencePreservesPeerDirection() {
    let store = AgentIntelligenceStore(persistenceEnabled: false)
    store.record(AgentInboxEvent(
        paneID: UUID(),
        host: "compute-07",
        provider: .claude,
        agentID: "/root/worker",
        kind: .peer,
        title: "Logic → shell",
        detail: "Please validate the generated manifest.",
        occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
        fromPeerID: "/root/logic",
        toPeerID: "/root/shell"
    ))

    #expect(store.coordinationCount == 1)
    #expect(store.items.first?.fromPeerID == "/root/logic")
    #expect(store.items.first?.toPeerID == "/root/shell")
    #expect(AgentInboxSearch.rank(store.items, query: "manifest", scope: .coordination).count == 1)
    #expect(AgentInboxSearch.rank(store.items, query: "manifest", scope: .completed).isEmpty)
}

@MainActor
@Test("Agent activity search ranks action and metadata matches")
func agentActivitySearchRanksUsefulMatches() {
    let store = AgentIntelligenceStore(persistenceEnabled: false)
    let paneID = UUID()
    store.record(AgentInboxEvent(
        paneID: paneID, host: "gpu-node", provider: .codex,
        kind: .failure, title: "Rust build failed",
        detail: "The linker could not find libssl.",
        occurredAt: Date(timeIntervalSince1970: 1_800_000_002)
    ))
    store.record(AgentInboxEvent(
        paneID: paneID, host: "login-node", provider: .claude,
        kind: .completion, title: "Documentation updated",
        detail: "README examples now use the new command.",
        occurredAt: Date(timeIntervalSince1970: 1_800_000_003)
    ))

    let results = AgentInboxSearch.rank(store.items, query: "rust linker", scope: .all)
    #expect(results.first?.title == "Rust build failed")
    #expect(AgentInboxSearch.rank(store.items, query: "login-node", scope: .all).first?.host == "login-node")
    #expect(AgentInboxSearch.rank(store.items, query: "rust", scope: .needsYou).count == 1)
}

@MainActor
@Test("Agent intelligence history remains bounded under heavy agent usage")
func agentIntelligenceHistoryIsBounded() {
    let store = AgentIntelligenceStore(persistenceEnabled: false)
    let paneID = UUID()
    for index in 0..<1_200 {
        store.record(AgentInboxEvent(
            paneID: paneID,
            host: "compute-07",
            provider: index.isMultiple(of: 2) ? .codex : .claude,
            agentID: "worker-\(index)",
            kind: .completion,
            title: "Worker \(index) finished",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        ))
    }

    #expect(store.items.count == 1_000)
    #expect(store.items.first?.agentID == "worker-1199")
}

@MainActor
@Test("Agent intelligence batches replay publication into one UI refresh")
func agentIntelligenceBatchesReplayPublication() async {
    let store = AgentIntelligenceStore(persistenceEnabled: false)
    let paneID = UUID()
    var publicationCount = 0
    let observation = store.objectWillChange.sink { publicationCount += 1 }

    for index in 0..<400 {
        store.record(AgentInboxEvent(
            paneID: paneID,
            host: "compute-07",
            provider: .codex,
            kind: .peer,
            title: "Replay event \(index)",
            sourceID: "relay-seq:\(index)"
        ))
    }

    #expect(publicationCount == 0)
    let deadline = ContinuousClock.now + .seconds(2)
    while publicationCount == 0, ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(publicationCount == 1)
    withExtendedLifetime(observation) {}
}

@Test("Restored agent history never starts automatic model summaries")
func restoredAgentHistorySkipsModelSummaries() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let restored = AgentInboxItem(
        id: "restored", paneID: UUID(), host: "compute-07", provider: .codex,
        agentID: "/root/review", kind: .completion, title: "Review finished",
        detail: String(repeating: "A substantive restored result. ", count: 5),
        occurredAt: now.addingTimeInterval(-600), isRead: false,
        summarySource: .exact, fromPeerID: nil, toPeerID: nil
    )
    let live = AgentInboxItem(
        id: "live", paneID: UUID(), host: "compute-07", provider: .claude,
        agentID: "/root/test", kind: .completion, title: "Tests finished",
        detail: String(repeating: "A substantive live result. ", count: 5),
        occurredAt: now.addingTimeInterval(-2), isRead: false,
        summarySource: .exact, fromPeerID: nil, toPeerID: nil
    )

    #expect(!AgentSummaryPolicy.shouldSummarize(restored, now: now))
    #expect(AgentSummaryPolicy.shouldSummarize(live, now: now))
}

@Test("On-device model scheduler rate limits automatic bursts")
func onDeviceModelSchedulerRateLimitsBursts() async {
    let scheduler = OnDeviceIntelligenceScheduler()
    let first = await scheduler.perform(
        priority: .background, minimumInterval: 60, operation: { 1 }
    )
    let burst = await scheduler.perform(
        priority: .background, minimumInterval: 60, operation: { 2 }
    )
    let interactive = await scheduler.perform(
        priority: .interactive, minimumInterval: 0, operation: { 3 }
    )

    #expect(first == 1)
    #expect(burst == nil)
    #expect(interactive == 3)
    #expect(OnDeviceIntelligenceScheduler.backgroundIntervalFloor == 20)
    #expect(OnDeviceIntelligenceScheduler.interactiveIntervalFloor >= 0.75)
}

@MainActor
@Test("Every terminal palette keeps selected text readable")
func terminalSelectionColorsAreExplicit() {
    let preferences = RelayPreferences.shared
    let original = preferences.palette
    defer { preferences.palette = original }

    for palette in RelayTerminalPalette.allCases {
        preferences.palette = palette
        let rendered = preferences.terminalConfiguration().rendered
        #expect(rendered.contains("selection-background = \(palette.selectionBackground)"))
        #expect(rendered.contains("selection-foreground = FFFFFF"))
        let expectedSize = String(
            format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
            min(max(preferences.fontSize, 9), 32)
        )
        #expect(rendered.contains("font-size = \(expectedSize)"))
        #expect(rendered.contains("minimum-contrast = 2.2"))
        #expect(rendered.contains("selection-clear-on-copy = false"))
        #expect(rendered.contains("shell-integration = "))
        #expect(rendered.contains("cursor-click-to-move = false"))
        #expect(!rendered.contains("13,5"))
        #expect(palette.selectionBackground != palette.background)
    }
}

@Test("Login-shell wrappers use the user's actual shell integration")
func terminalShellIntegrationUsesConfiguredShell() {
    #expect(RelayShellIntegrationPolicy.configurationValue(
        shellPath: "/opt/homebrew/bin/bash"
    ) == "bash")
    #expect(RelayShellIntegrationPolicy.configurationValue(
        shellPath: "/bin/zsh"
    ) == "zsh")
    #expect(RelayShellIntegrationPolicy.configurationValue(
        shellPath: "/opt/homebrew/bin/nu"
    ) == "nushell")
    #expect(RelayShellIntegrationPolicy.configurationValue(
        shellPath: "/usr/local/bin/custom-shell"
    ) == "detect")
}

@Test("Terminal prompt mirror handles editing without inventing state")
func terminalPromptMirrorEditing() {
    var buffer = TerminalPromptBuffer()
    buffer.insert("git statuz")
    buffer.move(by: -1)
    buffer.deleteForward()
    buffer.insert("s")
    #expect(buffer.text == "git status")
    #expect(buffer.isAtEnd)
    buffer.deletePreviousWord()
    #expect(buffer.text == "git ")
    buffer.insert("diff")
    #expect(buffer.submit() == "git diff")
    #expect(buffer.text.isEmpty)
    #expect(buffer.isReliable)

    buffer.insert("unsafe")
    buffer.invalidate()
    buffer.insert("ignored")
    #expect(buffer.text.isEmpty)
    #expect(!buffer.isReliable)
}

@Test("Prompt history coalesces typing and preserves multiline undo and redo")
func terminalPromptHistoryEditing() {
    var buffer = TerminalPromptBuffer()
    var history = TerminalPromptEditHistory()

    history.record(before: buffer.snapshot!, kind: .typing, timestamp: 1)
    buffer.insert("hello")
    history.record(before: buffer.snapshot!, kind: .typing, timestamp: 1.2)
    buffer.insert("\nworld")
    #expect(buffer.text == "hello\nworld")

    let edited = buffer.snapshot!
    let original = history.undo(current: edited)
    #expect(original?.text == "")
    buffer.restore(original!)
    let restored = history.redo(current: buffer.snapshot!)
    #expect(restored == edited)

    history.breakCoalescing()
    history.record(before: edited, kind: .deleting, timestamp: 2)
    buffer.restore(edited)
    buffer.backspace()
    #expect(history.canUndo)
}

@Test("Captured paste payload preserves bracketed mode across packets")
func capturedPastePayloadTracksBracketedMode() {
    let tracker = TerminalBracketedPasteStateTracker()
    tracker.observe(Data("prefix\u{001B}[?20".utf8))
    #expect(!tracker.isActive)
    tracker.observe(Data("04h".utf8))
    #expect(tracker.isActive)
    #expect(TerminalPastePayload.directPayload(
        for: "first\nsecond",
        bracketed: tracker.isActive
    ) == "\u{001B}[200~first\nsecond\u{001B}[201~")

    tracker.observe(Data("\u{001B}[?2004l".utf8))
    #expect(!tracker.isActive)
    #expect(TerminalPastePayload.directPayload(for: "one line", bracketed: false) == "one line")
    #expect(TerminalPastePayload.directPayload(for: "one\ntwo", bracketed: false) == nil)
}

@Test("Legacy Codex workers receive input-mode compatibility only during migration")
func legacyCodexWorkersReceiveTerminalModeCompatibility() {
    let prelude = LegacyTerminalModeCompatibility.prelude(
        agentKind: .codex,
        capabilities: []
    )
    #expect(prelude?.range(of: Data("\u{001B}[>7u".utf8)) != nil)
    #expect(prelude?.range(of: Data("\u{001B}[?2004h".utf8)) != nil)
    #expect(LegacyTerminalModeCompatibility.prelude(
        agentKind: .claude,
        capabilities: []
    ) == nil)
    #expect(LegacyTerminalModeCompatibility.prelude(
        agentKind: .codex,
        capabilities: [LegacyTerminalModeCompatibility.durableCapability]
    ) == nil)
}

@Test("Prompt cursor mapping follows logical characters across wide and wrapped text")
func terminalPromptLogicalCursorMapping() {
    var wide = TerminalPromptBuffer()
    wide.insert("ab界cd")
    #expect(wide.logicalMovementOffset(forVisualCellDelta: -2) == -2)
    #expect(wide.logicalMovementOffset(forVisualCellDelta: -5) == -5)
    #expect(wide.logicalMovementOffset(forVisualCellDelta: -6) == nil)

    var wrapped = TerminalPromptBuffer()
    wrapped.insert(String(repeating: "x", count: 160))
    #expect(wrapped.logicalMovementOffset(forVisualCellDelta: -93) == -93)
    wrapped.move(by: -40)
    #expect(wrapped.logicalMovementOffset(forVisualCellDelta: 40) == 40)
    #expect(wrapped.logicalMovementOffset(forVisualCellDelta: 500) == nil)

    wrapped.invalidate()
    #expect(wrapped.logicalMovementOffset(forVisualCellDelta: -1) == nil)

    var selection = TerminalPromptBuffer()
    selection.insert("copy this text")
    selection.move(by: -5)
    #expect(selection.selectedText(relativeToCursor: -4) == "this")
    #expect(selection.selectedText(relativeToCursor: 5) == " text")
    #expect(selection.selectedText(relativeToCursor: 0) == nil)
    selection.invalidate()
    #expect(selection.selectedText(relativeToCursor: -1) == nil)
}

@Test("Conversation context is readable, deduplicated, and bounded")
func terminalConversationContext() {
    var context = TerminalConversationContextBuffer()
    context.ingest("\u{001B}[32mAssistant:\u{001B}[0m Fixed the reconnect race.\r\n")
    context.ingest("Assistant: Fixed the reconnect race.\n")
    for index in 0..<40 { context.ingest("Result \(index) is ready.\n") }

    #expect(!context.lines.contains { $0.contains("\u{001B}") })
    #expect(context.lines.count == 28)
    #expect(context.lines.last == "Result 39 is ready.")
}

@Test("Session and tab pins persist as stable identifiers")
func workspacePinsPersist() {
    let suiteName = "relay-tests-pins-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = UUID()
    let second = UUID()
    WorkspacePinStore.save([first, second], kind: .session, defaults: defaults)
    WorkspacePinStore.save([second], kind: .tab, defaults: defaults)
    #expect(WorkspacePinStore.load(.session, defaults: defaults) == [first, second])
    #expect(WorkspacePinStore.load(.tab, defaults: defaults) == [second])
}

@Test("Subprocess capture stops output that exceeds its byte budget")
func processCaptureIsBounded() throws {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 4096 /dev/zero"]
    process.standardOutput = output
    process.standardError = errors

    var exceeded = false
    do {
        _ = try ProcessCapture.run(
            process,
            output: output,
            errors: errors,
            maximumBytesPerStream: 1_024
        )
    } catch let error as ProcessCaptureError {
        exceeded = error == .outputTooLarge(limit: 1_024)
    }
    #expect(exceeded)
}

@Test("Subprocess capture preserves ordinary output")
func processCapturePreservesOutput() throws {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf relay; printf warning >&2"]
    process.standardOutput = output
    process.standardError = errors

    let captured = try ProcessCapture.run(
        process,
        output: output,
        errors: errors,
        maximumBytesPerStream: 1_024
    )
    #expect(String(decoding: captured.standardOutput, as: UTF8.self) == "relay")
    #expect(String(decoding: captured.standardError, as: UTF8.self) == "warning")
}

@Test("Subprocess capture reports its timeout")
func processCaptureReportsTimeout() throws {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["2"]
    process.standardOutput = output
    process.standardError = errors

    var timedOut = false
    do {
        _ = try ProcessCapture.run(
            process,
            output: output,
            errors: errors,
            timeout: 0.05,
            maximumBytesPerStream: 1_024
        )
    } catch let error as ProcessCaptureError {
        if case .timedOut = error { timedOut = true }
    }
    #expect(timedOut)
}

@Test("Subprocess capture does not hang when a descendant inherits its pipes")
func processCaptureBoundsInheritedPipes() throws {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "(sleep 3) & exit 0"]
    process.standardOutput = output
    process.standardError = errors

    let started = ContinuousClock.now
    var readFailed = false
    do {
        _ = try ProcessCapture.run(
            process,
            output: output,
            errors: errors,
            timeout: 0.1,
            maximumBytesPerStream: 1_024
        )
    } catch let error as ProcessCaptureError {
        if case .readFailed = error { readFailed = true }
    }

    #expect(readFailed)
    #expect(started.duration(to: .now) < .seconds(2))
}

@Test("Floating image controls do not overlap corner resize handles")
func floatingImageControlsClearResizeHandles() {
    #expect(
        FloatingArtifactChromeMetrics.titleBarEdgeInset >=
            FloatingArtifactChromeMetrics.resizeHandleLength
    )
    #expect(
        FloatingArtifactChromeMetrics.controlLength <=
            FloatingArtifactChromeMetrics.titleBarHeight
    )
}
@Test("Relay terminfo installs idempotently and safely falls back")
func relayTerminfoInstallation() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bundled = sourceRoot
        .appendingPathComponent("Sources/Relay/Resources/Terminfo/78/xterm-relay")
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-terminfo-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let first = RelayTerminfo.install(
        homeDirectory: temporary,
        bundledEntry: bundled,
        systemDatabases: [],
        fileManager: .default
    )
    #expect(first.activeTerm == "xterm-relay")
    #expect(first.installedForCurrentUser)
    #expect(first.updatedLocations.count == 1)

    let second = RelayTerminfo.install(
        homeDirectory: temporary,
        bundledEntry: bundled,
        systemDatabases: [],
        fileManager: .default
    )
    #expect(second.activeTerm == "xterm-relay")
    #expect(second.updatedLocations.isEmpty)

    let fallback = RelayTerminfo.install(
        homeDirectory: temporary,
        bundledEntry: nil,
        systemDatabases: [],
        fileManager: .default
    )
    #expect(fallback.activeTerm == "xterm-256color")
}
