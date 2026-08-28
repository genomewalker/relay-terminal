import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

enum TerminalPromptSelectionEdit {
    static func isEnabled(contentKind: PaneContentKind, agentKind: AgentKind) -> Bool {
        contentKind == .terminal
    }

    static func forcesLocalSelection(agentKind: AgentKind) -> Bool {
        agentKind != .shell
    }

    static func deletionSequence(for selectedText: String, backwards _: Bool) -> String? {
        let normalized = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let count = normalized.count
        guard count > 0, count <= 8_192 else { return nil }
        // Backspace is implemented consistently by shell line editors, Codex,
        // and Claude. Forward Delete (CSI 3~) is ignored by some agent TUIs.
        // Relay therefore moves the remote caret to the logical end of the
        // selected range and always erases backwards, including real newlines.
        return String(repeating: "\u{007F}", count: count)
    }

    static func selectionIsNearCursor(
        startY: CGFloat,
        endY: CGFloat,
        cursorY: CGFloat,
        viewportHeight: CGFloat,
        agentPrompt: Bool
    ) -> Bool {
        guard startY.isFinite, endY.isFinite, cursorY.isFinite,
              viewportHeight.isFinite, viewportHeight > 0,
              cursorY >= 0, cursorY <= viewportHeight
        else { return false }

        // Agent TUIs place their composer wherever their layout requires;
        // Codex commonly anchors it near the top of a tall pane. Validate the
        // selection against Ghostty's live IME/cursor rectangle instead of a
        // guessed bottom strip. The wider agent range supports wrapped prompt
        // blocks while keeping selections far from the active cursor inert.
        let radius = agentPrompt
            ? min(320, max(96, viewportHeight * 0.42))
            : min(96, max(48, viewportHeight * 0.2))
        return abs(startY - cursorY) <= radius && abs(endY - cursorY) <= radius
    }

    static func cursorMovementOffset(
        cursor: CGPoint,
        target: CGPoint,
        cellSize: CGSize,
        viewportWidth: CGFloat
    ) -> Int? {
        guard cursor.x.isFinite, cursor.y.isFinite,
              target.x.isFinite, target.y.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              viewportWidth.isFinite,
              cellSize.width > 0, cellSize.height > 0, viewportWidth > 0
        else { return nil }

        let columns = max(1, Int(floor(viewportWidth / cellSize.width)))
        // AppKit's IME rectangle and Ghostty's mouse grid can differ by one
        // baseline even when both points are on the same terminal row. Treat
        // that small vertical discrepancy as the same row; otherwise a short
        // horizontal edit turns into an entire row of Left key presses.
        let verticalDelta = target.y - cursor.y
        let rowDelta = abs(verticalDelta) < cellSize.height * 1.75
            ? 0
            : Int(round(verticalDelta / cellSize.height))
        let columnDelta = Int(round((target.x - cursor.x) / cellSize.width))
        let offset = rowDelta * columns + columnDelta
        guard abs(offset) <= 8_192 else { return nil }
        return offset
    }
}

enum TerminalGeometry {
    /// SwiftUI can briefly propose invalid NSView dimensions while replacing
    /// one tab tree with another. Reject those values rather than clamping to
    /// a tiny placeholder: Ghostty propagates every accepted size to the
    /// remote PTY, where even a momentary 1x1 grid permanently reflows TUI
    /// output.
    static func accepts(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite &&
            size.width >= 2 && size.height >= 2
    }
}

enum TerminalResizePolicy {
    /// SwiftUI emits several valid-but-transitional pane sizes while moving
    /// durable terminal views between tab layouts. Only the final geometry
    /// should reach the remote PTY.
    static let debounceMilliseconds = 75
    static let revealAfterCommitMilliseconds = 50
}

@MainActor
final class TerminalRuntime: NSObject {
    private weak var pane: PaneModel?
    private let io = TerminalIOBridge()
    private let activityCoalescer = TerminalActivityCoalescer()
    private let artifactCoalescer = TerminalActivityCoalescer(delayMilliseconds: 250)
    private let artifactCoordinator = TerminalArtifactCoordinator()
    private var lastArtifact: (path: String, data: Data)?
    private var hoveredLink: String?
    private var fileTransferTask: Task<Void, Never>?
    private var started = false
    private var restoreStartedAt: UInt64?
    private var restoreReason = "launch"
    private var presentationLeases = Set<UUID>()
    private var allowsRendering = RelayApplicationActivityState.allowsContinuousUpdates

    private var session: InMemoryTerminalSession { io.session }
    private(set) lazy var view: RelayGhosttyView = makeView()

    private static let controller = TerminalController(
        configuration: RelayPreferences.shared.terminalConfiguration()
    )

    static func applyPreferences(_ preferences: RelayPreferences = .shared) {
        _ = controller.setTerminalConfiguration(preferences.terminalConfiguration())
    }

    init(pane: PaneModel) {
        self.pane = pane
        super.init()
        io.setPresentationPaused(!allowsRendering)
        pane.onAgentTurnReady = { [weak self] revision in
            self?.view.agentTurnReady(revision)
        }
        io.onReplayFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A replay commit changes a large part of Ghostty's grid in one
                // write. Reconcile the live NSView metrics and explicitly owe a
                // render before removing Relay's restore cover. Window resizes
                // and tab switches did this incidentally, which is why they
                // appeared to "fix" a garbled reconnect.
                self.view.layoutSubtreeIfNeeded()
                self.view.fitToSize()
                self.view.synchronizeAndRedraw()
                self.commitStableViewport()
                // Ghostty applies a large replay over several render passes. Keep
                // the overlay up until the viewport settles on the live screen.
                for delay in [0, 32, 96] {
                    if delay > 0 {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    _ = self.view.performBindingAction("scroll_to_bottom")
                    _ = self.view.scrollToRow(UInt.max)
                }
                self.pane?.finishTerminalRestore()
                self.finishMeasuredRestore()
            }
        }
        // Selector delivery avoids moving Foundation's non-Sendable
        // `Notification` value across an async-sequence isolation boundary.
        // RelayApplicationActivityState posts this notification on the main
        // actor, where every TerminalRuntime already lives.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityChanged(_:)),
            name: .relayApplicationActivityChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationActivityChanged(_ notification: Notification) {
        guard let allowed = notification.object as? Bool else { return }
        setApplicationRenderingAllowed(allowed)
    }

    func startIfNeeded() {
        guard !started, let pane else { return }
        started = true
        guard pane.profile.kind == .ssh, pane.profile.backend == .relay else { return }

        let remote = RelayRemoteTransport()
        let artifactPresentation = RelayPreferences.shared.artifactPresentation
        let artifactsEnabled = RelayPreferences.shared.showArtifactPreviews && !RelayLaunchMode.isSafeMode
        io.installTransport(remote)
        beginMeasuredRestore(reason: "launch")
        io.beginReplay()
        let restoredSequence = io.restoreSnapshot(paneID: pane.id)
        if restoredSequence != nil {
            pane.showTerminalSnapshot()
        }
        let io = self.io
        let activityCoalescer = self.activityCoalescer
        let artifactCoalescer = self.artifactCoalescer
        let artifactCoordinator = self.artifactCoordinator
        let artifactProfile = pane.profile
        remote.start(
            profile: pane.profile,
            sessionID: pane.id.uuidString.lowercased(),
            parentSessionID: pane.remoteParentSessionID,
            workspaceSessionID: pane.remoteWorkspaceSessionID,
            tabID: pane.remoteTabID,
            paneTitle: pane.displayName,
            contentKind: pane.contentKind.rawValue,
            initialLastSequence: restoredSequence ?? 0,
            onOutput: { [weak self] data, sequence in
                autoreleasepool {
                    // Linkify the 4 ms display batch in TerminalIOBridge, not
                    // every small SSH frame. This keeps clickable paths while
                    // avoiding repeated UTF-8 scans during TUI repaint bursts.
                    let isLiveOutput = io.receive(data, remoteSequence: sequence)
                    // Historical replay is compacted once when caught_up arrives.
                    // Decoding and scanning every replay packet here both repeats
                    // work and can stop the shared node reader long enough for
                    // later pane handshakes to fall back to dedicated SSH streams.
                    guard isLiveOutput else { return }
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    if artifactsEnabled {
                        artifactCoalescer.ingest(text) { [weak self] batch in
                            for path in artifactCoordinator.discover(in: batch) {
                                Task { @Sendable [weak self] in
                                    // Modern workers put a structured artifact frame
                                    // directly after this output. Give it priority and
                                    // only open a separate SSH fetch for older workers.
                                    try? await Task.sleep(for: .milliseconds(150))
                                    guard artifactCoordinator.beginFallback(for: path) else { return }
                                    guard let data = try? await RemoteArtifactLoader.load(path: path, profile: artifactProfile),
                                          artifactCoordinator.acceptFallback(for: path) else { return }
                                    await MainActor.run { [weak self] in
                                        guard let self else { return }
                                        if artifactPresentation == .inline,
                                           let png = TerminalImageNormalizer.pngData(from: data) {
                                            io.receiveInlineImageOrdered(
                                                png,
                                                imageID: Self.stableImageID(for: path)
                                            )
                                            self.cacheArtifact(path: path, data: data)
                                        } else {
                                            self.presentArtifact(path: path, data: data)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    self?.activityCoalescer.ingest(text) { [weak self] batch in
                        Task { @MainActor [weak self] in self?.pane?.received(batch) }
                    }
                }
            },
            onStatus: { [weak self] status in
                if status.outputReset { io.resetRemoteSequence() }
                if status.state == "attached" || status.state == "read_only" {
                    // Current workers emit an authoritative caught_up marker
                    // after replay. Do not let the legacy timeout start feeding
                    // reconstruction packets into Ghostty before that marker.
                    io.setExplicitReplayBoundary(status.capabilities.contains("event_cursor_v1"))
                }
                RelayDiagnostics.shared.record(category: "pane", name: status.state, details: [
                    "pane_id": pane.id.uuidString.lowercased(),
                    "profile": pane.profile.name,
                    "message": status.message ?? "",
                ])
                if status.state == "attached" || status.state == "read_only" {
                    // Modern workers provide authoritative process, hook, and
                    // transcript events. Do not also parse every TUI repaint
                    // on the main actor looking for legacy text heuristics.
                    activityCoalescer.setEnabled(!status.capabilities.contains("event_cursor_v1"))
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status.state == "attached" {
                        self.pane?.beginTerminalRestore()
                        self.pane?.connected()
                    } else if status.state == "caught_up" {
                        self.io.endReplayAfterViewportSettle()
                    } else if status.state == "reconnecting" {
                        self.beginMeasuredRestore(reason: "reconnect")
                        self.io.beginReplay()
                        self.pane?.connectionInterrupted(status.message ?? "Reconnecting")
                    } else if status.state == "waiting_for_network" {
                        self.beginMeasuredRestore(reason: "network-recovery")
                        self.io.beginReplay()
                        self.pane?.waitingForNetwork(status.message ?? "VPN or network route unavailable. Retrying automatically.")
                    } else if status.state == "read_only" {
                        self.pane?.connectionInterrupted(status.message ?? "Another client controls this pane.")
                    } else if status.state == "exited" {
                        self.io.endReplay()
                        // Keep Ghostty as a renderer. Host-managed exits do not
                        // have exec lifecycle metadata, so forwarding finish()
                        // makes Ghostty present its generic "failed to launch"
                        // screen. Relay owns this lifecycle and renders a native
                        // ended-session overlay with an explicit restart action.
                        self.pane?.exited(exitCode: status.exitCode ?? 0)
                    } else if status.state == "error" {
                        self.io.endReplay()
                        let message = status.message ?? "Remote session error"
                        self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay: \(message)\u{001B}[0m\r\n".utf8))
                        self.pane?.disconnected(message)
                    } else if status.state == "input_dropped" {
                        let message = status.message ?? "Some offline input was not queued."
                        self.io.receive(Data("\r\n\u{001B}[38;2;255;184;108mRelay: \(message)\u{001B}[0m\r\n".utf8))
                    }
                }
            },
            onAgentEvent: { [weak self] data in
                Task { @MainActor [weak self] in self?.pane?.receivedAgentEvent(data) }
            },
            onArtifact: { [weak self] artifact in
                guard let self else { return }
                guard artifactsEnabled else { return }
                guard artifactCoordinator.acceptStructured(for: artifact.path) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if artifactPresentation == .inline,
                       let png = TerminalImageNormalizer.pngData(from: artifact.data) {
                        self.io.receiveInlineImageOrdered(
                            png,
                            imageID: Self.stableImageID(for: artifact.path)
                        )
                        self.cacheArtifact(path: artifact.path, data: artifact.data)
                    } else {
                        self.presentArtifact(path: artifact.path, data: artifact.data)
                    }
                }
            },
            onDisconnect: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.io.endReplay()
                    self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay connection: \(message)\u{001B}[0m\r\n".utf8))
                    self.pane?.disconnected(message)
                }
            }
        )
    }

    func stop() {
        fileTransferTask?.cancel()
        fileTransferTask = nil
        io.flushSnapshot()
        io.endReplay()
        io.removeTransport()?.detach()
        started = false
    }

    func restart() {
        io.removeTransport()?.detach()
        started = false
        pane?.reconnecting()
        startIfNeeded()
    }

    func focus() {
        _ = view.acquireProgrammaticFocus()
        view.refreshConversationSuggestion()
    }

    @discardableResult
    func jumpToPrompt(by offset: Int16) -> Bool {
        view.jumpToPrompt(by: offset)
    }

    /// SwiftUI can keep an NSView alive after switching tabs or zooming a
    /// sibling pane. Tell Ghostty about actual presentation so its display
    /// link and Metal work stop immediately while the surface is off-screen.
    func setPresented(_ presented: Bool, lease: UUID, force: Bool = false) {
        let wasPresented = !presentationLeases.isEmpty
        if presented {
            presentationLeases.insert(lease)
        } else {
            presentationLeases.remove(lease)
        }
        let isPresented = !presentationLeases.isEmpty
        if isPresented != wasPresented || force {
            view.setSurfaceVisible(isPresented && allowsRendering)
        }
    }

    private func setApplicationRenderingAllowed(_ allowed: Bool) {
        guard allowsRendering != allowed else { return }
        allowsRendering = allowed
        io.setPresentationPaused(!allowed)
        guard started else { return }
        view.setSurfaceVisible(allowed && !presentationLeases.isEmpty)
    }

    fileprivate func commitStableViewport() {
        io.flushPendingResize()
    }

    private func beginMeasuredRestore(reason: String) {
        if restoreStartedAt == nil {
            restoreStartedAt = DispatchTime.now().uptimeNanoseconds
            restoreReason = reason
        }
        pane?.beginTerminalRestore()
    }

    private func finishMeasuredRestore() {
        guard let startedAt = restoreStartedAt else { return }
        restoreStartedAt = nil
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        RelayDiagnostics.shared.record(category: "performance", name: "terminal-restore", details: [
            "pane_id": pane?.id.uuidString.lowercased() ?? "unknown",
            "reason": restoreReason,
            "milliseconds": String(format: "%.2f", Double(elapsed) / 1_000_000),
        ])
    }

    private func makeView() -> RelayGhosttyView {
        let terminal = RelayGhosttyView(frame: .zero)
        terminal.owner = self
        terminal.delegate = self
        if let pane, pane.profile.kind == .ssh, pane.profile.backend == .relay {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .inMemory(session),
                context: .window,
                resizeThrottleMilliseconds: 16
            )
        } else {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                envVars: ["RELAY_PANE_ID": pane?.id.uuidString ?? ""],
                command: directCommand(),
                waitAfterCommand: true,
                context: .window
            )
        }
        // Ghostty creates a surface as soon as a controller is installed on
        // an attached view. Set the backend first so a remote pane never
        // transiently launches and tears down the default exec surface.
        terminal.controller = Self.controller
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel("Terminal for \(pane?.profile.name ?? "session")")
        return terminal
    }

    private func directCommand() -> String? {
        guard let pane, pane.profile.kind == .ssh else { return nil }
        let profile = pane.profile
        var parts = ["/usr/bin/ssh", "-tt"]
        parts.append(contentsOf: profile.sshConnectionArguments.map(Self.shellQuote))
        if let command = profile.remoteCommand(forPane: pane.id) {
            parts.append(Self.shellQuote(command))
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func stableImageID(for path: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    fileprivate func selectPane() {
        guard let pane else { return }
        NotificationCenter.default.post(name: .relaySelectPane, object: pane.id)
    }

    fileprivate func split(_ axis: SplitAxis) {
        selectPane()
        NotificationCenter.default.post(
            name: axis == .horizontal ? .relaySplitRight : .relaySplitDown,
            object: pane?.id
        )
    }

    fileprivate func closePane() {
        selectPane()
        NotificationCenter.default.post(name: .relayClosePane, object: pane?.id)
    }

    fileprivate func openHoveredLink() -> Bool {
        guard let hoveredLink else { return false }
        return openTerminalLink(hoveredLink)
    }

    fileprivate var allowsPromptSelectionEditing: Bool {
        guard let pane else { return false }
        return TerminalPromptSelectionEdit.isEnabled(
            contentKind: pane.contentKind,
            agentKind: pane.kind
        )
    }

    fileprivate var forcesLocalPromptSelection: Bool {
        pane.map { TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: $0.kind) } ?? false
    }

    fileprivate var suggestionContext: TerminalSuggestionContext? {
        guard let pane, pane.contentKind == .terminal else { return nil }
        let host = pane.profile.kind == .local ? "This Mac" : pane.profile.host
        let activity = Array(pane.recentConversationContext.suffix(18)) +
            pane.agentActivities.suffix(5).map(\.label) + pane.subagents
            .suffix(4)
            .compactMap { $0.updates.last?.message }
        return TerminalSuggestionContext(
            paneID: pane.id,
            profile: pane.profile,
            host: host,
            directory: pane.directory ?? "",
            agentKind: pane.kind,
            conversationRevision: pane.conversationRevision,
            recentActivity: activity.map { RelayDiagnostics.redact(String($0.prefix(240))) }
        )
    }

    fileprivate func userEnteredInput() {
        pane?.userEnteredInput()
    }

    fileprivate func importLocalFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, fileTransferTask == nil,
              let pane, pane.profile.kind == .ssh, pane.profile.backend == .relay else { return false }
        let profile = pane.profile
        let paneID = pane.id.uuidString.lowercased()
        view.toolTip = "Uploading \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")…"
        fileTransferTask = Task { @MainActor [weak self] in
            do {
                let imported = try await RemoteFileTransfer.upload(
                    urls,
                    toPane: paneID,
                    profile: profile
                )
                guard let self, !Task.isCancelled else { return }
                self.fileTransferTask = nil
                if let path = imported.first?.path {
                    pane.directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
                }
                self.view.toolTip = imported.count == 1
                    ? "Uploaded \(imported[0].name)"
                    : "Uploaded \(imported.count) files"
                let paths = imported.map { Self.promptPath($0.path) }.joined(separator: " ") + " "
                self.view.sendText(paths)
                RelayDiagnostics.shared.record(category: "transfer", name: "uploaded", details: [
                    "pane_id": pane.id.uuidString.lowercased(),
                    "files": String(imported.count),
                ])
            } catch {
                guard let self else { return }
                self.fileTransferTask = nil
                self.view.toolTip = error.localizedDescription
                NSSound.beep()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not upload file"
                alert.informativeText = error.localizedDescription
                if let window = self.view.window {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
        return true
    }

    private func presentArtifact(path: String, data: Data) {
        cacheArtifact(path: path, data: data)
        pane?.receivedArtifact(path: path, data: data)
    }

    private func cacheArtifact(path: String, data: Data) {
        lastArtifact = (path, data)
    }

    private func showArtifact(path: String) {
        if let lastArtifact, lastArtifact.path == path {
            pane?.receivedArtifact(path: path, data: lastArtifact.data)
            return
        }
        guard let profile = pane?.profile else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await RemoteArtifactLoader.load(path: path, profile: profile)
                self.presentArtifact(path: path, data: data)
            } catch {
                RelayDiagnostics.shared.record(category: "artifact", name: "open_failed", details: [
                    "path": path,
                    "message": error.localizedDescription,
                ])
            }
        }
    }

    @discardableResult
    private func openTerminalLink(_ link: String) -> Bool {
        guard let target = TerminalLinkResolver.target(from: link) else { return false }
        switch target {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .image(let path):
            showArtifact(path: resolvedRemotePath(path))
        case .file(let path):
            guard let pane else { return false }
            NotificationCenter.default.post(
                name: .relayOpenRemoteFile,
                object: RemoteFileOpenRequest(
                    profile: pane.profile,
                    parentSessionID: pane.id.uuidString.lowercased(),
                    request: EditorOpenRequest(paths: [resolvedRemotePath(path)], diff: false)
                )
            )
        }
        return true
    }

    private func resolvedRemotePath(_ path: String) -> String {
        guard (path.hasPrefix("./") || path.hasPrefix("../")),
              let directory = pane?.directory, directory.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL.path
    }

    private static func promptPath(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || "'\"\\$`!()[]{};&|<>".contains($0) }) else {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class TerminalActivityCoalescer: @unchecked Sendable {
    private static let maximumCharacters = 256 << 10
    private let lock = NSLock()
    private let delayMilliseconds: Int
    private var pendingText = ""
    private var pendingBytes = 0
    private var deliveryScheduled = false
    private var enabled = true

    init(delayMilliseconds: Int = 80) {
        self.delayMilliseconds = delayMilliseconds
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled {
            pendingText.removeAll(keepingCapacity: true)
            pendingBytes = 0
        }
        lock.unlock()
    }

    func ingest(_ text: String, deliver: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        pendingText.append(text)
        pendingBytes += text.utf8.count
        if pendingBytes > Self.maximumCharacters {
            pendingText = String(
                decoding: pendingText.utf8.suffix(Self.maximumCharacters),
                as: UTF8.self
            )
            pendingBytes = pendingText.utf8.count
        }
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        let delayMilliseconds = self.delayMilliseconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(delayMilliseconds)
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let batch = self.pendingText
            self.pendingText.removeAll(keepingCapacity: true)
            self.pendingBytes = 0
            self.deliveryScheduled = false
            self.lock.unlock()
            if !batch.isEmpty { deliver(batch) }
        }
    }
}

private final class TerminalIOBridge: @unchecked Sendable {
    private var transport: RelayRemoteTransport?
    var onReplayFinished: (@Sendable () -> Void)?
    private let receiveLock = NSLock()
    private let resizeLock = NSLock()
    private let presentationLock = NSLock()
    private let displayLock = NSLock()
    private let displayQueue = DispatchQueue(label: "relay.terminal-display", qos: .userInteractive)
    private var displayBuffer = Data()
    private var displayDrainScheduled = false
    private var presentationPaused = false
    private var deferredDisplayBuffer = Data()
    private let replayLock = NSLock()
    private var replaying = false
    private var expectsExplicitReplayBoundary = false
    private var suppressingTerminalWrites = false
    private var replayBuffer = Data()
    private var replayGeneration: UInt64 = 0
    /// Non-nil while a background compaction is preparing an atomic replay
    /// commit. The generation makes a newer reconnect cancel the old commit
    /// without discarding bytes already acknowledged by the remote worker.
    private var replayCommitGeneration: UInt64?
    private var legacyReplayGeneration: UInt64 = 0
    private var legacyReplayHardDeadline = DispatchTime.distantFuture
    private var filterDeviceResponsesUntil = Date.distantPast
    private var snapshotPaneID: UUID?
    private var snapshotBuffer = Data()
    private var snapshotRemoteSequence: UInt64 = 0
    private let alternateScreenCleanup = TerminalAlternateScreenCleanupFilter()
    private var snapshotWriteWindowStartedAt: DispatchTime?
    private var snapshotScheduledDeadline: DispatchTime?
    private var usesBackgroundSnapshotCadence = false
    private var latestViewport = RelayViewport.default
    private let legacyReplayTimer: DispatchSourceTimer
    private let snapshotSaveTimer: DispatchSourceTimer
    private let resizeTimer: DispatchSourceTimer

    init() {
        legacyReplayTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        snapshotSaveTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        resizeTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        legacyReplayTimer.setEventHandler { [weak self] in
            self?.finishLegacyReplayIfIdle()
        }
        legacyReplayTimer.schedule(deadline: .distantFuture)
        legacyReplayTimer.resume()

        // One reschedulable timer is a real debounce. Enqueuing a new
        // asyncAfter closure for every PTY packet leaves thousands of dormant
        // closures behind during agent/TUI repaint storms, increasing memory
        // and waking utility workers only to discover stale generations.
        snapshotSaveTimer.setEventHandler { [weak self] in
            self?.savePendingSnapshot()
        }
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        snapshotSaveTimer.resume()

        resizeTimer.setEventHandler { [weak self] in
            self?.flushPendingResize()
        }
        resizeTimer.schedule(deadline: .distantFuture)
        resizeTimer.resume()
    }

    deinit {
        legacyReplayTimer.cancel()
        snapshotSaveTimer.cancel()
        resizeTimer.cancel()
    }

    lazy var session = InMemoryTerminalSession(
        write: { [weak self] data in self?.forwardTerminalWrite(data) },
        resize: { [weak self] viewport in
            self?.terminalDidResize(columns: viewport.columns, rows: viewport.rows)
        },
        suppressesPixelOnlyResizes: true
    )

    func installTransport(_ transport: RelayRemoteTransport) {
        resizeLock.lock()
        self.transport = transport
        let viewport = latestViewport
        resizeLock.unlock()
        transport.setInitialViewport(viewport)
    }

    func removeTransport() -> RelayRemoteTransport? {
        resizeLock.lock()
        let transport = self.transport
        self.transport = nil
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
        return transport
    }

    private var currentViewport: RelayViewport {
        resizeLock.lock()
        let viewport = latestViewport
        resizeLock.unlock()
        return viewport
    }

    private func terminalDidResize(columns: UInt16, rows: UInt16) {
        let viewport = RelayViewport(columns: columns, rows: rows)
        resizeLock.lock()
        latestViewport = viewport
        if transport != nil {
            resizeTimer.schedule(
                deadline: .now() + .milliseconds(TerminalResizePolicy.debounceMilliseconds),
                leeway: .milliseconds(20)
            )
        }
        resizeLock.unlock()
    }

    func flushPendingResize() {
        resizeLock.lock()
        let viewport = latestViewport
        let transport = self.transport
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
        transport?.sendResize(columns: viewport.columns, rows: viewport.rows)
    }

    /// Keep consuming and snapshotting the remote stream while the app is in
    /// the background, but do not spend CPU parsing and rendering every frame.
    /// On resume, one compact reconstruction replaces the accumulated redraws.
    func setPresentationPaused(_ paused: Bool) {
        presentationLock.lock()
        guard presentationPaused != paused else {
            presentationLock.unlock()
            return
        }
        presentationPaused = paused
        // Match snapshot persistence to visibility. Remote output remains
        // authoritative, and flushSnapshot() still performs a synchronous save
        // on quit. Re-arm the one existing timer rather than creating new work.
        receiveLock.lock()
        usesBackgroundSnapshotCadence = paused
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        if snapshotPaneID != nil, !snapshotBuffer.isEmpty {
            scheduleSnapshotSaveLocked()
        } else {
            snapshotSaveTimer.schedule(deadline: .distantFuture)
        }
        receiveLock.unlock()
        guard !paused, !deferredDisplayBuffer.isEmpty else {
            presentationLock.unlock()
            return
        }
        let deferred = deferredDisplayBuffer
        deferredDisplayBuffer.removeAll(keepingCapacity: true)
        receiveLock.lock()
        let snapshot = snapshotBuffer
        receiveLock.unlock()
        // The deferred stream starts at the moment the app became inactive;
        // it may contain only an incremental prompt update. Reconstruct from
        // the rolling snapshot so resetting Ghostty cannot erase the preceding
        // screen. Inline-only payloads fall back to the deferred bytes.
        let compacted = TerminalReplayCompactor.compact(snapshot.isEmpty ? deferred : snapshot)
        var reconstruction = Data("\u{001B}c".utf8)
        reconstruction.append(compacted)
        enqueueDisplayWhilePresentationLocked(reconstruction, immediate: true)
        presentationLock.unlock()
    }

    /// Returns true for live output and false for buffered reconstruction data.
    @discardableResult
    func receive(_ data: Data, remoteSequence: UInt64 = 0) -> Bool {
        let displayData = alternateScreenCleanup.transform(data)
        guard !displayData.isEmpty else { return true }
        replayLock.lock()
        if replaying {
            replayBuffer.append(displayData)
            if replayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                replayBuffer = TerminalSnapshotStore.bounded(replayBuffer)
            }
            replayLock.unlock()
            receiveLock.lock()
            snapshotRemoteSequence = max(snapshotRemoteSequence, remoteSequence)
            receiveLock.unlock()
            scheduleLegacyReplayEnd()
            return false
        }
        replayLock.unlock()
        receiveLock.lock()
        appendSnapshotLocked(displayData, remoteSequence: remoteSequence)
        receiveLock.unlock()
        enqueueDisplay(displayData)
        return true
    }

    func restoreSnapshot(paneID: UUID) -> UInt64? {
        receiveLock.lock()
        snapshotPaneID = paneID
        receiveLock.unlock()
        guard let cached = TerminalSnapshotStore.shared.loadSnapshot(
            paneID: paneID, viewport: currentViewport
        ), !cached.payload.isEmpty else {
            return nil
        }
        receiveLock.lock()
        snapshotBuffer = cached.payload
        snapshotRemoteSequence = cached.remoteSequence
        receiveLock.unlock()
        alternateScreenCleanup.observe(cached.payload)
        enqueueDisplay(cached.payload, immediate: true)
        RelayDiagnostics.shared.record(category: "snapshot", name: "restored", details: [
            "pane_id": paneID.uuidString.lowercased(),
            "bytes": String(cached.payload.count),
            "remote_sequence": String(cached.remoteSequence),
        ])
        return cached.remoteSequence
    }

    func resetRemoteSequence() {
        receiveLock.lock()
        snapshotRemoteSequence = 0
        receiveLock.unlock()
    }

    func flushSnapshot() {
        receiveLock.lock()
        let paneID = snapshotPaneID
        let snapshot = snapshotBuffer
        let remoteSequence = snapshotRemoteSequence
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        receiveLock.unlock()
        if let paneID, !snapshot.isEmpty {
            TerminalSnapshotStore.shared.saveSynchronously(
                snapshot, paneID: paneID, viewport: currentViewport,
                remoteSequence: remoteSequence
            )
        }
    }

    func beginReplay() {
        replayLock.lock()
        if !replaying { replayBuffer.removeAll(keepingCapacity: true) }
        replaying = true
        replayCommitGeneration = nil
        suppressingTerminalWrites = true
        filterDeviceResponsesUntil = Date().addingTimeInterval(5)
        // Pre-caught_up workers can redraw continuously (Codex and Claude do),
        // so an idle-only boundary would leave the opaque restore layer up
        // forever. Bound that compatibility path while newer workers still end
        // reconstruction immediately with their explicit caught_up status.
        let explicitBoundary = expectsExplicitReplayBoundary
        legacyReplayHardDeadline = explicitBoundary
            ? .now() + .seconds(30)
            : .now() + .milliseconds(750)
        replayGeneration &+= 1
        let explicitDeadline = legacyReplayHardDeadline
        replayLock.unlock()
        if explicitBoundary {
            legacyReplayTimer.schedule(deadline: explicitDeadline, leeway: .seconds(1))
        } else {
            scheduleLegacyReplayEnd()
        }
    }

    func setExplicitReplayBoundary(_ enabled: Bool) {
        replayLock.lock()
        expectsExplicitReplayBoundary = enabled
        if enabled {
            // SSH setup may finish while the short compatibility timeout is
            // already compacting. The authoritative worker boundary wins:
            // cancel that provisional commit but retain its buffer so the
            // ordered caught_up commit contains every acknowledged byte.
            if replayCommitGeneration != nil {
                replayGeneration &+= 1
                replayCommitGeneration = nil
            }
            // `attached` is ordered before replay frames, but SSH setup can
            // outlast the legacy 750 ms timer armed at launch. Re-enter replay
            // here when that timer already fired so no frame can escape into
            // Ghostty's per-write queue. A long failsafe prevents a broken
            // worker from holding the restore layer forever.
            if !replaying {
                replayBuffer.removeAll(keepingCapacity: true)
                replaying = true
                suppressingTerminalWrites = true
                filterDeviceResponsesUntil = Date().addingTimeInterval(5)
                replayGeneration &+= 1
            }
            legacyReplayHardDeadline = .now() + .seconds(30)
            legacyReplayTimer.schedule(deadline: legacyReplayHardDeadline, leeway: .seconds(1))
        } else if replaying {
            // A downgraded worker has no caught_up marker. Restore the bounded
            // compatibility path instead of leaving its replay open forever.
            legacyReplayHardDeadline = .now() + .milliseconds(750)
            replayGeneration &+= 1
            legacyReplayGeneration = replayGeneration
            legacyReplayTimer.schedule(deadline: legacyReplayHardDeadline)
        }
        replayLock.unlock()
    }

    func endReplay() {
        replayLock.lock()
        guard replaying, replayCommitGeneration == nil else {
            replayLock.unlock()
            return
        }
        replayGeneration &+= 1
        let generation = replayGeneration
        replayCommitGeneration = generation
        let buffered = replayBuffer
        let bufferedCount = buffered.count
        legacyReplayHardDeadline = .distantFuture
        legacyReplayTimer.schedule(deadline: .distantFuture)
        replayLock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            self.receiveLock.lock()
            let cached = self.snapshotBuffer
            self.receiveLock.unlock()
            let replacement = TerminalReplayCommit.prepare(
                cached: cached,
                incoming: buffered
            )

            // Keep the replay gate closed while the expensive compaction runs.
            // Fresh PTY bytes accumulate after `buffered`; enqueue the reset,
            // reconstruction, and that live tail as one ordered display commit
            // before reopening the live path. Previously `replaying` became
            // false above, allowing the tail to overtake the reconstruction.
            self.replayLock.lock()
            guard self.replaying,
                  self.replayGeneration == generation,
                  self.replayCommitGeneration == generation else {
                self.replayLock.unlock()
                return
            }
            let liveTail: Data
            if self.replayBuffer.count > bufferedCount {
                liveTail = Data(self.replayBuffer.dropFirst(bufferedCount))
            } else {
                liveTail = Data()
            }
            let commit = TerminalReplayCommit.appendingLiveTail(liveTail, to: replacement)
            if !commit.isEmpty {
                self.receiveLock.lock()
                self.snapshotBuffer = TerminalSnapshotStore.bounded(commit)
                self.scheduleSnapshotSaveLocked()
                self.receiveLock.unlock()
                // receive() cannot pass replayLock until this has entered the
                // display queue, so later live frames cannot overtake it.
                self.enqueueDisplay(commit, immediate: true)
            }
            self.replayBuffer.removeAll(keepingCapacity: true)
            self.replaying = false
            self.replayCommitGeneration = nil
            self.replayLock.unlock()

            // Device-query replies are produced asynchronously by the renderer.
            // Keep them local for a couple of frames after reconstruction.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(150)
            ) { [weak self] in
                guard let self else { return }
                // Cross both serial queues before asking the surface to redraw:
                // first move every Relay display byte into the in-memory
                // backend, then wait until Ghostty has parsed that batch. A
                // timer alone can expose an IOSurface whose grid has only seen
                // the live cursor updates at the end of the replay.
                self.displayQueue.async { [weak self] in
                    guard let self else { return }
                    self.drainDisplay()
                    self.session.waitForPendingOutput()
                    self.replayLock.lock()
                    let finished = !self.replaying && self.replayGeneration == generation
                    if finished { self.suppressingTerminalWrites = false }
                    self.replayLock.unlock()
                    if finished { self.onReplayFinished?() }
                }
            }
        }
    }

    /// The worker emits `caught_up` before it consumes the viewport frame that
    /// follows the attach acknowledgement. Keep reconstruction buffered long
    /// enough to include the resulting SIGWINCH redraw, then reveal one
    /// correctly-sized screen rather than historical cursor-addressed output.
    func endReplayAfterViewportSettle() {
        replayLock.lock()
        let generation = replayGeneration
        replayLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(120)
        ) { [weak self] in
            guard let self else { return }
            self.replayLock.lock()
            let isCurrent = self.replaying && self.replayGeneration == generation
            self.replayLock.unlock()
            if isCurrent { self.endReplay() }
        }
    }

    private func appendSnapshotLocked(_ data: Data, remoteSequence: UInt64) {
        guard snapshotPaneID != nil else { return }
        snapshotBuffer.append(data)
        snapshotRemoteSequence = max(snapshotRemoteSequence, remoteSequence)
        // Avoid scanning a multi-megabyte ANSI stream for every small PTY
        // write. Compact only when the rolling buffer crosses a generous
        // bound; the debounced disk writer performs the normal compaction.
        if snapshotBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
            snapshotBuffer = TerminalSnapshotStore.bounded(snapshotBuffer)
        }
        scheduleSnapshotSaveLocked()
    }

    private func scheduleSnapshotSaveLocked() {
        guard snapshotPaneID != nil else { return }
        let now = DispatchTime.now()
        if snapshotWriteWindowStartedAt == nil {
            snapshotWriteWindowStartedAt = now
        }
        let debounceMilliseconds = usesBackgroundSnapshotCadence
            ? TerminalSnapshotWritePolicy.backgroundDebounceMilliseconds
            : TerminalSnapshotWritePolicy.debounceMilliseconds
        let maximumIntervalMilliseconds = usesBackgroundSnapshotCadence
            ? TerminalSnapshotWritePolicy.backgroundMaximumIntervalMilliseconds
            : TerminalSnapshotWritePolicy.maximumIntervalMilliseconds
        let debounceDeadline = now + .milliseconds(
            debounceMilliseconds
        )
        let maximumDeadline = snapshotWriteWindowStartedAt! + .milliseconds(
            maximumIntervalMilliseconds
        )
        let deadline = min(debounceDeadline, maximumDeadline)
        // Reprogramming a DispatchSourceTimer for every PTY packet becomes a
        // kernel-event hot loop for htop and agent TUIs. Move the deadline at
        // most four times per second; the normal debounce remains accurate to
        // 250 ms and the hard five-second persistence bound is unchanged.
        let minimumMove = UInt64(250_000_000)
        if let scheduled = snapshotScheduledDeadline,
           deadline.uptimeNanoseconds <= scheduled.uptimeNanoseconds &+ minimumMove {
            return
        }
        snapshotScheduledDeadline = deadline
        snapshotSaveTimer.schedule(
            deadline: deadline,
            leeway: .milliseconds(TerminalSnapshotWritePolicy.leewayMilliseconds)
        )
    }

    private func savePendingSnapshot() {
        receiveLock.lock()
        guard let paneID = snapshotPaneID, !snapshotBuffer.isEmpty else {
            receiveLock.unlock()
            return
        }
        let snapshot = snapshotBuffer
        let remoteSequence = snapshotRemoteSequence
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        receiveLock.unlock()

        TerminalSnapshotStore.shared.save(
            snapshot, paneID: paneID, viewport: currentViewport,
            remoteSequence: remoteSequence
        )
    }

    private func forwardTerminalWrite(_ data: Data) {
        replayLock.lock()
        let shouldSuppress = suppressingTerminalWrites
        let filterStartupResponse = Date() < filterDeviceResponsesUntil
        replayLock.unlock()
        guard !shouldSuppress else { return }
        guard !filterStartupResponse || !TerminalDeviceResponseFilter.matches(data) else { return }
        resizeLock.lock()
        let transport = self.transport
        resizeLock.unlock()
        transport?.sendInput(data)
    }

    // Workers released before the caught_up marker remain attachable. One
    // reschedulable timer handles their idle boundary without enqueuing a timer
    // for every replay frame.
    private func scheduleLegacyReplayEnd() {
        replayLock.lock()
        guard replaying, !expectsExplicitReplayBoundary else {
            replayLock.unlock()
            return
        }
        replayGeneration &+= 1
        legacyReplayGeneration = replayGeneration
        legacyReplayTimer.schedule(deadline: min(.now() + .seconds(1), legacyReplayHardDeadline))
        replayLock.unlock()
    }

    private func finishLegacyReplayIfIdle() {
        replayLock.lock()
        let hardDeadlineReached = DispatchTime.now() >= legacyReplayHardDeadline
        let shouldFinish = replaying && (replayGeneration == legacyReplayGeneration || hardDeadlineReached)
        replayLock.unlock()
        if shouldFinish { endReplay() }
    }

    func receiveInlineImageOrdered(_ data: Data, imageID: UInt32) {
        var encoded = Data()
        for packet in KittyImageEncoder.packets(for: data, imageID: imageID) {
            encoded.append(packet)
        }
        replayLock.lock()
        if replaying {
            replayBuffer.append(encoded)
            replayLock.unlock()
            return
        }
        replayLock.unlock()
        enqueueDisplay(encoded)
    }

    /// Collapse a burst of PTY frames into one Ghostty write. The dependency's
    /// in-memory surface queues one GCD closure per call, so forwarding every
    /// 4–8 KiB SSH packet can retain gigabytes during a repaint storm. One
    /// scheduled drain preserves byte order and interactive latency while a
    /// high-water compaction makes overload memory-bounded.
    private func enqueueDisplay(_ data: Data, immediate: Bool = false) {
        guard !data.isEmpty else { return }
        presentationLock.lock()
        if presentationPaused {
            deferredDisplayBuffer.append(data)
            if deferredDisplayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                deferredDisplayBuffer = TerminalSnapshotStore.bounded(deferredDisplayBuffer)
            }
            presentationLock.unlock()
            return
        }
        enqueueDisplayWhilePresentationLocked(data, immediate: immediate)
        presentationLock.unlock()
    }

    /// Caller owns presentationLock so resume reconstruction is ordered before
    /// the first newly arriving live frame.
    private func enqueueDisplayWhilePresentationLocked(_ data: Data, immediate: Bool) {
        displayLock.lock()
        displayBuffer.append(data)
        if displayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
            displayBuffer = TerminalSnapshotStore.bounded(displayBuffer)
            RelayDiagnostics.shared.record(category: "terminal", name: "display-overload-compacted", details: [
                "bytes": String(displayBuffer.count),
            ])
        }
        guard !displayDrainScheduled else {
            displayLock.unlock()
            return
        }
        displayDrainScheduled = true
        displayLock.unlock()
        let delay: DispatchTimeInterval = immediate ? .nanoseconds(0) : .milliseconds(4)
        displayQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.drainDisplay()
        }
    }

    private func drainDisplay() {
        presentationLock.lock()
        displayLock.lock()
        let batch = displayBuffer
        displayBuffer = Data()
        displayDrainScheduled = false
        displayLock.unlock()
        if presentationPaused {
            deferredDisplayBuffer.append(batch)
            if deferredDisplayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                deferredDisplayBuffer = TerminalSnapshotStore.bounded(deferredDisplayBuffer)
            }
            presentationLock.unlock()
            return
        }
        presentationLock.unlock()
        guard !batch.isEmpty else { return }
        autoreleasepool {
            let encoded = ArtifactHyperlinkEncoder.encode(batch)
            session.receive(encoded)
            RelayPerformance.shared.recordTerminalBatch(
                bytes: encoded.count,
                pendingBytes: session.pendingOutputByteCount
            )
        }
    }
}

/// Full-screen programs correctly leave Ghostty's alternate screen, but that
/// operation restores the previous primary viewport byte-for-byte. For a remote
/// work pane this can look like the stopped `watch`/`htop` frame survived as
/// dirty background. Insert a viewport clear after a matched alternate-screen
/// exit, before the following shell prompt. The parser retains only a possible
/// control-sequence prefix, so SSH packet boundaries are transparent.
final class TerminalAlternateScreenCleanupFilter: @unchecked Sendable {
    private static let entries = [
        Array("\u{001B}[?1049h".utf8),
        Array("\u{001B}[?1047h".utf8),
        Array("\u{001B}[?47h".utf8),
    ]
    private static let exits = [
        Array("\u{001B}[?1049l".utf8),
        Array("\u{001B}[?1047l".utf8),
        Array("\u{001B}[?47l".utf8),
    ]
    private static let modeMarker = Data([0x1B, 0x5B, 0x3F]) // ESC [ ?
    private static let cleanup = Data("\u{001B}[2J\u{001B}[H".utf8)

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var inAlternateScreen = false

    func transform(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        lock.lock()
        if pending.isEmpty,
           data.range(of: Self.modeMarker) == nil,
           !Self.endsWithCandidatePrefix(data) {
            lock.unlock()
            return data
        }
        defer { lock.unlock() }
        var output = Data()
        output.reserveCapacity(data.count + Self.cleanup.count)
        for byte in data {
            if pending.isEmpty, byte != 0x1B {
                output.append(byte)
                continue
            }
            pending.append(byte)
            drainPending(into: &output)
        }
        return output
    }

    func observe(_ data: Data) {
        _ = transform(data)
    }

    private func drainPending(into output: inout Data) {
        while !pending.isEmpty {
            guard pending[0] == 0x1B else {
                output.append(pending.removeFirst())
                continue
            }
            if let sequence = Self.entries.first(where: { pending == $0 }) {
                output.append(contentsOf: sequence)
                pending.removeAll(keepingCapacity: true)
                inAlternateScreen = true
                return
            }
            if let sequence = Self.exits.first(where: { pending == $0 }) {
                output.append(contentsOf: sequence)
                pending.removeAll(keepingCapacity: true)
                if inAlternateScreen {
                    inAlternateScreen = false
                    output.append(Self.cleanup)
                }
                return
            }
            if Self.isCandidatePrefix(pending) { return }
            output.append(pending.removeFirst())
        }
    }

    private static func isCandidatePrefix(_ bytes: [UInt8]) -> Bool {
        (entries + exits).contains { sequence in
            bytes.count < sequence.count && sequence.prefix(bytes.count).elementsEqual(bytes)
        }
    }

    private static func endsWithCandidatePrefix(_ data: Data) -> Bool {
        guard let last = data.last else { return false }
        if last == 0x1B { return true }
        guard last == 0x5B, data.count >= 2 else { return false }
        return data[data.index(data.endIndex, offsetBy: -2)] == 0x1B
    }
}

/// Builds the screen replacement separately from the replay gate so expensive
/// ANSI compaction never blocks the shared node reader. The caller appends any
/// bytes that arrived during preparation while still holding that gate.
enum TerminalReplayCommit {
    private static let reset = Data("\u{001B}c".utf8)

    static func prepare(cached: Data, incoming: Data) -> Data {
        let replayHistory = TerminalReplayCompactor.preservingAlternateScreenOwner(
            cached: cached,
            incoming: incoming
        )
        let reconstruction = TerminalReplayCompactor.compact(replayHistory)
        guard !reconstruction.isEmpty else { return Data() }
        var replacement = reset
        replacement.append(reconstruction)
        return replacement
    }

    static func appendingLiveTail(_ liveTail: Data, to replacement: Data) -> Data {
        guard !liveTail.isEmpty else { return replacement }
        var commit = replacement
        commit.append(liveTail)
        return commit
    }
}

enum TerminalReplayCompactor {
    private static let reset = Data("\u{001B}c".utf8)
    private static let alternateScreenEntries = [
        Array("\u{001B}[?1049h".utf8),
        Array("\u{001B}[?1047h".utf8),
        Array("\u{001B}[?47h".utf8),
    ]
    private static let alternateScreenExits = [
        Array("\u{001B}[?1049l".utf8),
        Array("\u{001B}[?1047l".utf8),
        Array("\u{001B}[?47l".utf8),
    ]

    /// A fresh local surface needs the current screen, not every cursor-addressed
    /// redraw ever emitted by a TUI. Reconstruct from its latest full clear.
    static func compact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let latest = scan(data).replayStart
        guard let latest, latest > data.startIndex else { return data }
        var result = reset
        result.append(contentsOf: data[latest...])
        return result
    }

    /// A resume cursor normally returns only bytes missed since the local
    /// snapshot. Primary-screen TUIs such as Codex often emit nothing more
    /// than a spinner/cursor delta, so that delta must extend the cached base;
    /// treating it as a complete screen produces an otherwise blank pane.
    /// A replay containing its own reset/clear is self-contained. The special
    /// alternate-screen branch below also preserves the cached owner when an
    /// older worker synthesizes a reset before an incremental TUI repaint.
    static func preservingAlternateScreenOwner(cached: Data, incoming: Data) -> Data {
        guard !cached.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return cached }
        let incomingScan = scan(incoming)
        if incomingScan.replayStart == nil {
            var continuation = cached
            continuation.append(incoming)
            return continuation
        }
        guard scan(cached).endsInAlternateScreen,
              !incomingScan.containsAlternateScreenEntry else { return incoming }
        var continuation = incoming
        // Compatibility workers synthesize RIS before a replay that begins at
        // an alternate-screen clear. The cached stream already established
        // the correct terminal mode, so applying that RIS here would exit the
        // alternate screen and erase its saved primary shell.
        while continuation.starts(with: reset) {
            continuation.removeFirst(reset.count)
        }
        var merged = cached
        merged.append(continuation)
        return merged
    }

    /// A full-screen program saves the primary shell screen before switching
    /// to its alternate screen. A clear emitted inside that alternate screen
    /// is not a valid replay boundary: dropping the preceding mode switch
    /// makes `htop`/`less` content become the shell background after exit.
    ///
    /// An unmatched exit is produced by older relayd workers that already
    /// truncated replay inside an alternate screen. In that compatibility
    /// case, discard the orphaned TUI prefix and reconstruct from the bytes
    /// after the exit rather than painting them onto the primary screen.
    private struct ScanResult {
        let replayStart: Int?
        let endsInAlternateScreen: Bool
        let containsAlternateScreenEntry: Bool
    }

    /// Scan the contiguous Data storage once. Terminal streams are overwhelmingly
    /// printable bytes, so ignore them with one comparison and inspect control
    /// sequences only at ESC. This replaces an Array copy plus six collection
    /// comparisons at every byte of every periodic snapshot.
    private static func scan(_ data: Data) -> ScanResult {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var index = 0
            var inAlternateScreen = false
            var sawAlternateScreenEntry = false
            var latestPrimaryClear: Int?
            var unmatchedExitEnd: Int?

            while index < bytes.count {
                guard bytes[index] == 0x1B else {
                    index += 1
                    continue
                }
                if let count = matchingLength(alternateScreenEntries, in: bytes, at: index) {
                    inAlternateScreen = true
                    sawAlternateScreenEntry = true
                    index += count
                    continue
                }
                if let count = matchingLength(alternateScreenExits, in: bytes, at: index) {
                    if inAlternateScreen {
                        inAlternateScreen = false
                    } else {
                        unmatchedExitEnd = index + count
                        latestPrimaryClear = nil
                    }
                    index += count
                    continue
                }
                if !inAlternateScreen, let count = clearSequenceLength(in: bytes, at: index) {
                    latestPrimaryClear = index
                    index += count
                    continue
                }
                index += 1
            }
            return ScanResult(
                replayStart: latestPrimaryClear ?? unmatchedExitEnd,
                endsInAlternateScreen: inAlternateScreen,
                containsAlternateScreenEntry: sawAlternateScreenEntry
            )
        }
    }

    private static func clearSequenceLength(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> Int? {
        if index + 2 <= bytes.count, bytes[index + 1] == 0x63 { return 2 } // ESC c
        guard index + 4 <= bytes.count,
              bytes[index + 1] == 0x5B,
              (bytes[index + 2] == 0x32 || bytes[index + 2] == 0x33),
              bytes[index + 3] == 0x4A else { return nil } // ESC [ 2J / 3J
        return 4
    }

    private static func matchingLength(
        _ sequences: [[UInt8]],
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> Int? {
        for sequence in sequences where index + sequence.count <= bytes.count {
            var offset = 0
            while offset < sequence.count, bytes[index + offset] == sequence[offset] {
                offset += 1
            }
            if offset == sequence.count { return sequence.count }
        }
        return nil
    }
}

enum TerminalDeviceResponseFilter {
    /// Ghostty and the shell share one in-memory write callback. During surface
    /// startup, drop only complete terminal capability replies; ordinary input
    /// (including arrows, mouse reports, function keys, and paste) does not
    /// match this grammar.
    static func matches(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count else { return false }
            switch bytes[index + 1] {
            case 0x5B: // CSI
                let parameterStart = index + 2
                var final = parameterStart
                while final < bytes.count && !(0x40...0x7E).contains(bytes[final]) {
                    final += 1
                }
                guard final < bytes.count else { return false }
                let parameters = bytes[parameterStart..<final]
                switch bytes[final] {
                case 0x63, 0x52: // device attributes or cursor position
                    break
                case 0x75: // kitty keyboard capability reply, always private
                    guard parameters.contains(0x3F) || parameters.contains(0x3E) else { return false }
                default:
                    return false
                }
                index = final + 1
            case 0x5D, 0x50: // OSC or DCS, terminated by BEL or ST
                var end = index + 2
                var found = false
                while end < bytes.count {
                    if bytes[end] == 0x07 {
                        end += 1
                        found = true
                        break
                    }
                    if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C {
                        end += 2
                        found = true
                        break
                    }
                    end += 1
                }
                guard found else { return false }
                index = end
            default:
                return false
            }
        }
        return true
    }
}

extension TerminalRuntime:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, pane?.title != normalized else { return }
        pane?.title = normalized
    }

    func terminalDidClose(processAlive: Bool) {
        pane?.exited()
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        if focused { selectPane() }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard pane?.directory != path else { return }
        pane?.directory = path
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        pane?.recordCommandCompletion(exitCode: exitCode, durationNanos: durationNanos)
        view.shellCommandFinished()
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        switch state {
        case .remove:
            pane?.recordTerminalProgress(state: nil, percent: nil)
        case .set:
            pane?.recordTerminalProgress(state: "running", percent: percent)
        case .error:
            pane?.recordTerminalProgress(state: "error", percent: percent)
        case .indeterminate:
            pane?.recordTerminalProgress(state: "indeterminate", percent: nil)
        case .pause:
            pane?.recordTerminalProgress(state: "paused", percent: percent)
        }
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        _ = openTerminalLink(url)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredLink = url
    }
}

@MainActor
final class RelayGhosttyView: TerminalView {
    private struct PromptSelection {
        let characterCount: Int
        let movementOffset: Int
    }

    weak var owner: TerminalRuntime?
    private var suppressNextMouseUp = false
    private var selectionStart: CGPoint?
    private var selectionStartInWindow: CGPoint?
    private var promptSelection: PromptSelection?
    private var keyboardSelectionOffset: Int?
    private var keyboardSelectionIsVisual = false
    private var forcingLocalPromptSelection = false
    private var geometryRevealTask: Task<Void, Never>?
    private var promptBuffer = TerminalPromptBuffer()
    private var suggestionTask: Task<Void, Never>?
    private var currentSuggestion: TerminalSuggestion?
    private var pendingAgentTurnRevision: UInt64 = 0
    private var attemptedAgentTurnRevision: UInt64 = 0
    private let suggestionLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        configureSuggestionLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard TerminalGeometry.accepts(newSize) else { return }
        let previousSize = frame.size
        super.setFrameSize(newSize)
        layoutSuggestionLayer()
        guard window != nil,
              newSize.width > 1,
              newSize.height > 1,
              abs(previousSize.width - newSize.width) >= 0.5 ||
                  abs(previousSize.height - newSize.height) >= 0.5 else { return }
        settleGeometryBeforeReveal()
    }

    /// SwiftUI reparents durable terminal views when panes move, tabs change,
    /// or a tiled pane becomes floating. Ghostty can otherwise publish a frame
    /// for every transitional grid size, which looks like scrambled text. Keep
    /// those frames hidden and reveal only the final, correctly fitted grid.
    private func settleGeometryBeforeReveal() {
        geometryRevealTask?.cancel()
        alphaValue = 0
        geometryRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(32))
            } catch {
                return
            }
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.fitToSize()
            self.owner?.commitStableViewport()
            do {
                try await Task.sleep(
                    for: .milliseconds(TerminalResizePolicy.revealAfterCommitMilliseconds)
                )
            } catch {
                return
            }
            guard !Task.isCancelled, self.window != nil else { return }
            self.alphaValue = 1
            self.geometryRevealTask = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.selectPane()
        dismissSuggestion()
        if !promptBuffer.text.isEmpty { promptBuffer.invalidate() }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           owner?.openHoveredLink() == true {
            suppressNextMouseUp = true
            return
        }
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        let point = terminalPoint(for: event)
        let agentPrompt = owner?.forcesLocalPromptSelection == true
        let canBeginPromptSelection = owner?.allowsPromptSelectionEditing == true &&
            (agentPrompt || pointIsNearActivePrompt(point))
        selectionStart = canBeginPromptSelection ? point : nil
        selectionStartInWindow = selectionStart == nil ? nil : event.locationInWindow
        forcingLocalPromptSelection = selectionStart != nil && agentPrompt
        super.mouseDown(with: forcingLocalPromptSelection ? localSelectionEvent(from: event) ?? event : event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: forcingLocalPromptSelection ? localSelectionEvent(from: event) ?? event : event)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
            selectionStart = nil
            selectionStartInWindow = nil
            return
        }
        let start = selectionStart
        let caretLocation = selectionStartInWindow
        let end = terminalPoint(for: event)
        let forcedLocalSelection = forcingLocalPromptSelection
        super.mouseUp(with: forcedLocalSelection ? localSelectionEvent(from: event) ?? event : event)
        selectionStart = nil
        selectionStartInWindow = nil
        forcingLocalPromptSelection = false
        if forcedLocalSelection, let start, hypot(end.x - start.x, end.y - start.y) < 2 {
            replayAgentClick(at: event.locationInWindow)
            return
        }
        guard let start, let caretLocation,
              hypot(end.x - start.x, end.y - start.y) >= 2,
              forcedLocalSelection || selectionIsNearActivePrompt(start: start, end: end),
              copySelectedTextToPasteboard(),
              let text = NSPasteboard.general.string(forType: .string),
              TerminalPromptSelectionEdit.deletionSequence(for: text, backwards: true) != nil
        else { return }
        let backwards = end.y < start.y - 4 || (abs(end.y - start.y) <= 4 && end.x < start.x)
        let deletionAnchor = backwards ? caretLocation : event.locationInWindow
        guard let movementOffset = cursorMovementOffset(to: deletionAnchor) else { return }
        promptSelection = PromptSelection(
            characterCount: text.count,
            movementOffset: movementOffset
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           acceptCurrentSuggestion() {
            return
        }
        if event.keyCode == 53, currentSuggestion != nil {
            if let suggestion = currentSuggestion {
                Task { await TerminalSuggestionService.shared.recordFeedback(for: suggestion, accepted: false) }
            }
            dismissSuggestion()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           importFiles(from: NSPasteboard.general) {
            invalidatePromptSuggestions()
            return
        }
        if handleKeyboardPromptSelection(event) {
            invalidatePromptSuggestions()
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let promptSelection {
            self.promptSelection = nil
            keyboardSelectionOffset = nil
            keyboardSelectionIsVisual = false
            sendPromptEdit(promptSelection)
            invalidatePromptSuggestions()
            return
        }
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        trackNonTextKey(event)
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String?
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String
        }
        if let text, !text.isEmpty {
            markCurrentAgentTurnHandled()
            promptBuffer.insert(text)
            owner?.userEnteredInput()
            scheduleSuggestion()
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers navigation keys to the key-equivalent chain before it
        // delivers keyDown. Intercept Shift+Arrow here as well so keyboard
        // prompt selection is reliable with hardware keyboards and synthetic
        // accessibility input alike.
        if event.type == .keyDown, handleKeyboardPromptSelection(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleKeyboardPromptSelection(_ event: NSEvent) -> Bool {
        guard owner?.forcesLocalPromptSelection == true,
              event.modifierFlags.contains(.shift),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              event.keyCode == 123 || event.keyCode == 124
        else { return false }

        let delta = event.keyCode == 123 ? -1 : 1
        let next = (keyboardSelectionOffset ?? 0) + delta
        if next == 0 {
            keyboardSelectionOffset = nil
            promptSelection = nil
            keyboardSelectionIsVisual = false
            _ = performBindingAction("clear_selection")
            return true
        }

        keyboardSelectionOffset = next
        // The logical selection is authoritative. Ghostty's cursor rectangle
        // can be temporarily unavailable while a TUI repaints, so visual
        // highlighting is best-effort but Shift-arrow deletion still works.
        keyboardSelectionIsVisual = beginKeyboardPromptSelection(delta: next)
        promptSelection = PromptSelection(
            characterCount: abs(next),
            movementOffset: next > 0 ? next : 0
        )
        return true
    }

    private func beginKeyboardPromptSelection(delta: Int) -> Bool {
        guard delta != 0, abs(delta) <= 8_192,
              let window,
              let geometry = activeCursorGeometry()
        else { return false }

        let startLocal = CGPoint(
            x: geometry.point.x,
            y: bounds.height - geometry.point.y
        )
        let endLocal = CGPoint(
            x: startLocal.x + CGFloat(delta) * geometry.cellSize.width,
            y: startLocal.y
        )
        let start = convert(startLocal, to: nil)
        let end = convert(endLocal, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: start,
            modifierFlags: .shift,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: end,
            modifierFlags: .shift,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: end,
            modifierFlags: .shift,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return false }
        super.mouseDown(with: down)
        super.mouseDragged(with: drag)
        super.mouseUp(with: up)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        localFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        importFiles(from: sender.draggingPasteboard)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Ghostty intentionally discovers hover links only with Command held.
        // Probe the same cell with Command for Relay's single-click image UX;
        // regular terminal mouse delivery above remains unchanged.
        guard !event.modifierFlags.contains(.command),
              let probe = NSEvent.mouseEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags.union(.command),
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
              ) else { return }
        super.mouseMoved(with: probe)
    }

    private func terminalPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func selectionIsNearActivePrompt(start: CGPoint, end: CGPoint) -> Bool {
        if let cursorY = activeCursorGeometry()?.point.y {
            return TerminalPromptSelectionEdit.selectionIsNearCursor(
                startY: start.y,
                endY: end.y,
                cursorY: cursorY,
                viewportHeight: bounds.height,
                agentPrompt: owner?.forcesLocalPromptSelection == true
            )
        }

        // A surface can briefly lack an IME rectangle during attachment.
        // Retain the conservative bottom-only fallback for that short window.
        let promptBand = min(96, max(48, bounds.height * 0.2))
        let top = bounds.height - promptBand
        return start.y >= top && end.y >= top
    }

    private struct CursorGeometry {
        let point: CGPoint
        let cellSize: CGSize
    }

    private func activeCursorGeometry() -> CursorGeometry? {
        guard let window else { return nil }
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: nil
        )
        guard screenRect != .zero,
              screenRect.origin.x.isFinite, screenRect.origin.y.isFinite,
              screenRect.size.width.isFinite, screenRect.size.height.isFinite
        else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        let localRect = convert(windowRect, from: nil)
        let fallback = fallbackCellSize()
        // A bar cursor can legitimately expose a zero-width IME rectangle.
        // The origin is still authoritative; use the configured monospace
        // metrics only for missing dimensions.
        let cellSize = CGSize(
            width: localRect.width >= 2 ? localRect.width : fallback.width,
            height: localRect.height >= 2 ? localRect.height : fallback.height
        )
        let cursorTop = bounds.height - localRect.maxY
        let point = CGPoint(
            x: localRect.minX + cellSize.width / 2,
            y: cursorTop + cellSize.height / 2
        )
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= bounds.width,
              point.y >= 0, point.y <= bounds.height,
              cellSize.width > 0, cellSize.height > 0
        else { return nil }
        return CursorGeometry(point: point, cellSize: cellSize)
    }

    private func fallbackCellSize() -> CGSize {
        let preferences = RelayPreferences.shared
        let size = CGFloat(min(max(preferences.fontSize, 9), 32))
        let font = NSFont(name: preferences.resolvedFontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let width = max(4, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = max(8, ceil(font.ascender - font.descender + font.leading))
        return CGSize(width: width, height: height)
    }

    private func configureSuggestionLayer() {
        suggestionLabel.isEditable = false
        suggestionLabel.isSelectable = false
        suggestionLabel.isBezeled = false
        suggestionLabel.drawsBackground = false
        suggestionLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 0.56)
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.maximumNumberOfLines = 1
        suggestionLabel.isHidden = true
        suggestionLabel.setAccessibilityElement(false)
        addSubview(suggestionLabel, positioned: .above, relativeTo: nil)
    }

    private func layoutSuggestionLayer() {
        guard let suggestion = currentSuggestion,
              let geometry = activeCursorGeometry(),
              bounds.width > 0, bounds.height > 0 else {
            suggestionLabel.isHidden = true
            return
        }
        let preferences = RelayPreferences.shared
        let size = CGFloat(min(max(preferences.fontSize, 9), 32))
        let font = NSFont(name: preferences.resolvedFontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let maximumWidth = max(0, bounds.width - geometry.point.x - 8)
        guard maximumWidth >= geometry.cellSize.width else {
            suggestionLabel.isHidden = true
            return
        }
        let naturalWidth = ceil((suggestion.suffix as NSString).size(withAttributes: [.font: font]).width) + 4
        let width = min(maximumWidth, max(geometry.cellSize.width, naturalWidth))
        let localY = bounds.height - geometry.point.y - geometry.cellSize.height / 2
        suggestionLabel.font = font
        suggestionLabel.stringValue = suggestion.suffix
        suggestionLabel.frame = CGRect(
            x: geometry.point.x - geometry.cellSize.width / 2,
            y: localY,
            width: width,
            height: max(geometry.cellSize.height, ceil(font.ascender - font.descender + font.leading))
        )
        suggestionLabel.isHidden = false
    }

    private func scheduleSuggestion() {
        dismissSuggestion()
        let preferences = RelayPreferences.shared
        guard preferences.intelligenceEnabled, preferences.predictiveSuggestions,
              !RelayLaunchMode.isSafeMode,
              promptBuffer.isReliable, promptBuffer.isAtEnd,
              TerminalSuggestionPolicy.isEligible(promptBuffer.text),
              let context = owner?.suggestionContext,
              window?.firstResponder === self else { return }
        let prefix = promptBuffer.text
        suggestionTask = Task { @MainActor [weak self] in
            if let local = await TerminalSuggestionService.shared.historySuggestion(
                prefix: prefix, context: context
            ) {
                guard let self, self.suggestionRequestIsCurrent(prefix: prefix, context: context) else { return }
                self.presentSuggestion(local)
                return
            }
            guard RelayPreferences.shared.experimentalGenerativeSuggestions,
                  let generated = await TerminalSuggestionService.shared.onDeviceSuggestion(
                    prefix: prefix, context: context
                  ),
                  let self, self.suggestionRequestIsCurrent(prefix: prefix, context: context)
            else { return }
            self.presentSuggestion(generated)
        }
    }

    func agentTurnReady(_ revision: UInt64) {
        pendingAgentTurnRevision = max(pendingAgentTurnRevision, revision)
        scheduleNextAgentTurnSuggestionIfPossible()
    }

    func refreshConversationSuggestion() {
        guard let revision = owner?.suggestionContext?.conversationRevision else { return }
        pendingAgentTurnRevision = max(pendingAgentTurnRevision, revision)
        scheduleNextAgentTurnSuggestionIfPossible()
    }

    private func scheduleNextAgentTurnSuggestionIfPossible() {
        let preferences = RelayPreferences.shared
        guard preferences.intelligenceEnabled, preferences.predictiveSuggestions,
              preferences.experimentalGenerativeSuggestions,
              !RelayLaunchMode.isSafeMode,
              pendingAgentTurnRevision > attemptedAgentTurnRevision,
              let context = owner?.suggestionContext,
              context.agentKind != .shell,
              context.conversationRevision == pendingAgentTurnRevision,
              window?.firstResponder === self else { return }

        // A structured turn boundary is authoritative: the previous submitted
        // line is over and the agent has rendered a fresh empty prompt.
        guard promptBuffer.text.isEmpty else {
            attemptedAgentTurnRevision = pendingAgentTurnRevision
            return
        }
        promptBuffer.clear()
        dismissSuggestion()
        let revision = pendingAgentTurnRevision
        attemptedAgentTurnRevision = revision
        suggestionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(260))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let generated = await TerminalSuggestionService.shared.nextAgentTurnSuggestion(context: context)
            guard let self, !Task.isCancelled,
                  self.agentTurnRequestIsCurrent(revision: revision, paneID: context.paneID),
                  let generated else { return }
            self.presentSuggestion(generated)
        }
    }

    func shellCommandFinished() {
        let preferences = RelayPreferences.shared
        guard preferences.intelligenceEnabled, preferences.predictiveSuggestions,
              preferences.experimentalGenerativeSuggestions,
              !RelayLaunchMode.isSafeMode else { return }
        dismissSuggestion()
        suggestionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self, self.promptBuffer.isReliable, self.promptBuffer.text.isEmpty,
                  self.window?.firstResponder === self,
                  let context = self.owner?.suggestionContext,
                  context.agentKind == .shell,
                  let suggestion = await TerminalSuggestionService.shared.workspaceActionSuggestion(
                    context: context
                  ),
                  self.promptBuffer.isReliable, self.promptBuffer.text.isEmpty,
                  self.owner?.suggestionContext == context,
                  self.window?.firstResponder === self
            else { return }
            self.presentSuggestion(suggestion)
        }
    }

    private func agentTurnRequestIsCurrent(revision: UInt64, paneID: UUID) -> Bool {
        guard let context = owner?.suggestionContext else { return false }
        return context.paneID == paneID && context.agentKind != .shell &&
            context.conversationRevision == revision && promptBuffer.isReliable &&
            promptBuffer.text.isEmpty && window?.firstResponder === self
    }

    private func markCurrentAgentTurnHandled() {
        guard let context = owner?.suggestionContext, context.agentKind != .shell else { return }
        attemptedAgentTurnRevision = max(attemptedAgentTurnRevision, context.conversationRevision)
    }

    private func suggestionRequestIsCurrent(
        prefix: String,
        context: TerminalSuggestionContext
    ) -> Bool {
        promptBuffer.isReliable && promptBuffer.isAtEnd && promptBuffer.text == prefix &&
            owner?.suggestionContext == context && window?.firstResponder === self
    }

    private func presentSuggestion(_ suggestion: TerminalSuggestion) {
        guard !suggestion.suffix.isEmpty else { return }
        currentSuggestion = suggestion
        setAccessibilityHelp("Suggestion: \(suggestion.suffix). Press Tab to accept.")
        layoutSuggestionLayer()
    }

    private func dismissSuggestion() {
        suggestionTask?.cancel()
        suggestionTask = nil
        currentSuggestion = nil
        suggestionLabel.isHidden = true
        setAccessibilityHelp(nil)
    }

    @discardableResult
    private func acceptCurrentSuggestion() -> Bool {
        guard let suggestion = currentSuggestion,
              promptBuffer.isReliable, promptBuffer.isAtEnd else { return false }
        dismissSuggestion()
        promptBuffer.insert(suggestion.suffix)
        owner?.userEnteredInput()
        sendText(suggestion.suffix)
        RelayDiagnostics.shared.record(category: "intelligence", name: "suggestion-accepted", details: [
            "source": suggestion.source.rawValue,
            "characters": String(suggestion.suffix.count),
        ])
        Task { await TerminalSuggestionService.shared.recordFeedback(for: suggestion, accepted: true) }
        return true
    }

    private func invalidatePromptSuggestions() {
        dismissSuggestion()
        promptBuffer.invalidate()
    }

    private func trackNonTextKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 36 || event.keyCode == 76 {
            let submitted = promptBuffer.submit()
            dismissSuggestion()
            if let submitted, let context = owner?.suggestionContext {
                Task { await TerminalSuggestionService.shared.record(submitted, context: context) }
            }
            return
        }
        if event.keyCode == 48 {
            invalidatePromptSuggestions()
            return
        }
        if command && key == "v" {
            if let pasted = NSPasteboard.general.string(forType: .string) {
                promptBuffer.insert(pasted)
                scheduleSuggestion()
            } else {
                invalidatePromptSuggestions()
            }
            return
        }
        if control {
            switch key {
            case "a": promptBuffer.moveToStart()
            case "e": promptBuffer.moveToEnd()
            case "u": promptBuffer.deleteToStart()
            case "k": promptBuffer.deleteToEnd()
            case "w": promptBuffer.deletePreviousWord()
            case "c": promptBuffer.clear()
            case "l": break
            default: promptBuffer.invalidate()
            }
            dismissSuggestion()
            if promptBuffer.isAtEnd { scheduleSuggestion() }
            return
        }
        switch event.keyCode {
        case 51:
            if command { promptBuffer.deleteToStart() }
            else if option { promptBuffer.deletePreviousWord() }
            else { promptBuffer.backspace() }
        case 117: promptBuffer.deleteForward()
        case 123: promptBuffer.move(by: -1)
        case 124: promptBuffer.move(by: 1)
        case 115: promptBuffer.moveToStart()
        case 119: promptBuffer.moveToEnd()
        case 125, 126: promptBuffer.invalidate()
        default:
            if command || option { dismissSuggestion(); return }
            return
        }
        dismissSuggestion()
        if promptBuffer.isAtEnd { scheduleSuggestion() }
    }

    private func cursorMovementOffset(to locationInWindow: CGPoint) -> Int? {
        guard let geometry = activeCursorGeometry() else { return nil }
        let local = convert(locationInWindow, from: nil)
        let target = CGPoint(x: local.x, y: bounds.height - local.y)
        return TerminalPromptSelectionEdit.cursorMovementOffset(
            cursor: geometry.point,
            target: target,
            cellSize: geometry.cellSize,
            viewportWidth: bounds.width
        )
    }

    private func sendPromptEdit(_ selection: PromptSelection) {
        guard selection.characterCount > 0, selection.characterCount <= 8_192,
              abs(selection.movementOffset) <= 8_192 else { return }
        let movementKey: UInt16 = selection.movementOffset < 0 ? 123 : 124
        for _ in 0..<abs(selection.movementOffset) {
            sendSyntheticKey(keyCode: movementKey)
        }
        for _ in 0..<selection.characterCount {
            sendSyntheticKey(keyCode: 51)
        }
    }

    private func sendSyntheticKey(keyCode: UInt16) {
        guard let window else { return }
        let characters: String
        switch keyCode {
        case 123: characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: characters = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: characters = "\u{007F}"
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        super.keyDown(with: event)
    }

    private func pointIsNearActivePrompt(_ point: CGPoint) -> Bool {
        selectionIsNearActivePrompt(start: point, end: point)
    }

    private func localSelectionEvent(from event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.union(.shift),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        )
    }

    private func replayAgentClick(at locationInWindow: CGPoint) {
        guard let window else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return }
        super.mouseDown(with: down)
        super.mouseUp(with: up)
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.selectPane()
        NSMenu.popUpContextMenu(relayContextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        relayContextMenu()
    }

    private func relayContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.addItem(item("Copy", action: #selector(copyRelay), key: "c", enabled: true))
        menu.addItem(item(
            "Paste",
            action: #selector(pasteRelay),
            key: "v",
            enabled: NSPasteboard.general.string(forType: .string) != nil
                || !localFileURLs(from: NSPasteboard.general).isEmpty
        ))
        menu.addItem(item("Select All", action: #selector(selectAllRelay), key: "a", enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Previous Prompt", action: #selector(previousPrompt), enabled: true))
        menu.addItem(item("Next Prompt", action: #selector(nextPrompt), enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", action: #selector(splitRight), key: "d", enabled: true))
        menu.addItem(item("Split Down", action: #selector(splitDown), key: "D", enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", action: #selector(clearScrollback), enabled: true))
        menu.addItem(item(
            owner?.paneIsRemote == true ? "Detach Pane" : "Close Pane",
            action: #selector(closeRelayPane),
            key: "w",
            enabled: true
        ))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func copyRelay() { _ = copySelectedTextToPasteboard() }
    @objc private func pasteRelay() {
        if !importFiles(from: NSPasteboard.general) {
            _ = performBindingAction("paste_from_clipboard")
        }
    }
    @objc private func selectAllRelay() { _ = performBindingAction("select_all") }
    @objc private func clearScrollback() { _ = performBindingAction("clear_scrollback") }
    @objc private func previousPrompt() { _ = owner?.jumpToPrompt(by: -1) }
    @objc private func nextPrompt() { _ = owner?.jumpToPrompt(by: 1) }
    @objc private func splitRight() { owner?.split(.horizontal) }
    @objc private func splitDown() { owner?.split(.vertical) }
    @objc private func closeRelayPane() { owner?.closePane() }

    private func importFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls = localFileURLs(from: pasteboard)
        return !urls.isEmpty && owner?.importLocalFiles(urls) == true
    }

    private func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return objects.compactMap { $0 as URL }
    }
}

private extension TerminalRuntime {
    var paneIsRemote: Bool {
        pane?.profile.kind == .ssh && pane?.profile.backend == .relay
    }
}

extension Notification.Name {
    static let relaySelectPane = Notification.Name("relay.select-pane")
    static let relaySplitRight = Notification.Name("relay.split-right")
    static let relaySplitDown = Notification.Name("relay.split-down")
    static let relayClosePane = Notification.Name("relay.close-pane")
    static let relayOpenRemoteFile = Notification.Name("relay.open-remote-file")
}

@MainActor
struct TerminalSurface: NSViewRepresentable, Equatable {
    let pane: PaneModel
    nonisolated let identity: UUID

    init(pane: PaneModel) {
        self.pane = pane
        self.identity = pane.id
    }

    nonisolated static func == (lhs: TerminalSurface, rhs: TerminalSurface) -> Bool {
        lhs.identity == rhs.identity
    }

    final class Coordinator {
        let presentationLease = UUID()
        var presentationTask: Task<Void, Never>?
        var isPresented = false
        var candidateSize: CGSize?
        var stableSizeSamples = 0

        deinit { presentationTask?.cancel() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RelayGhosttyView {
        let view = pane.runtime.view
        // Preserve Ghostty's last settled IOSurface while SwiftUI gives the
        // reattached view its transitional sizes. Rendering those intermediate
        // grids is the source of the garbled flash when switching tabs.
        view.alphaValue = 0
        view.setSurfaceVisible(false)
        presentAfterLayout(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: RelayGhosttyView, context: Context) {
        presentAfterLayout(nsView, coordinator: context.coordinator)
        // AppTerminalView already synchronizes its grid from setFrameSize and
        // layout. Calling fitToSize for every unrelated SwiftUI model update
        // forces an immediate Metal frame even when geometry did not change.
    }

    static func dismantleNSView(_ nsView: RelayGhosttyView, coordinator: Coordinator) {
        coordinator.presentationTask?.cancel()
        coordinator.presentationTask = nil
        coordinator.isPresented = false
        coordinator.candidateSize = nil
        coordinator.stableSizeSamples = 0
        // The same durable terminal view can be reattached by another tab or
        // zoom layout. Keep its previous IOSurface hidden until that layout is
        // stable instead of briefly stretching the old cell grid.
        nsView.alphaValue = 0
        nsView.owner?.setPresented(false, lease: coordinator.presentationLease)
    }

    private func presentAfterLayout(_ view: RelayGhosttyView, coordinator: Coordinator) {
        guard !coordinator.isPresented, coordinator.presentationTask == nil else { return }
        coordinator.presentationTask = Task { @MainActor [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            for delay in [0, 8, 16, 24, 32, 48, 64] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else { return }
                view.superview?.layoutSubtreeIfNeeded()
                guard view.window != nil,
                      view.bounds.width > 1,
                      view.bounds.height > 1 else { continue }

                let size = view.bounds.size
                if let candidate = coordinator.candidateSize,
                   abs(candidate.width - size.width) < 0.5,
                   abs(candidate.height - size.height) < 0.5 {
                    coordinator.stableSizeSamples += 1
                } else {
                    coordinator.candidateSize = size
                    coordinator.stableSizeSamples = 1
                }

                // Require the same geometry in two distinct layout samples.
                // A merely non-zero size is commonly the outgoing tab's frame.
                guard coordinator.stableSizeSamples >= 2 else { continue }

                view.fitToSize()
                pane.runtime.commitStableViewport()
                // Snapshot and remote replay bytes must not reach Ghostty
                // until its final pane grid exists. Feeding them after merely
                // one run-loop yield makes multi-pane launches interpret a
                // TUI redraw at the outgoing/full-window width; later resize
                // cannot reconstruct cursor-addressed output and leaves the
                // familiar vertical/garbled columns.
                pane.runtime.startIfNeeded()
                pane.runtime.setPresented(
                    true,
                    lease: coordinator.presentationLease,
                    force: true
                )

                // Give Ghostty one display interval to publish the correctly
                // sized IOSurface, then reveal it as one visual transaction.
                try? await Task.sleep(
                    for: .milliseconds(TerminalResizePolicy.revealAfterCommitMilliseconds)
                )
                guard !Task.isCancelled, view.window != nil else { return }
                view.alphaValue = 1
                coordinator.isPresented = true
                coordinator.presentationTask = nil
                return
            }
            // Extremely busy layout passes may not settle within the normal
            // window. Retry instead of exposing a known-wrong terminal grid.
            coordinator.presentationTask = nil
            if view.window != nil {
                presentAfterLayout(view, coordinator: coordinator)
            }
        }
    }
}
