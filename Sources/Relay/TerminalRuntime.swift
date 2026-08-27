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

    static func deletionSequence(for selectedText: String, backwards: Bool) -> String? {
        // Newlines may represent either a real multi-line command or selected
        // output. Until Relay has cell-level prompt ranges, do not guess.
        guard !selectedText.isEmpty,
              !selectedText.contains("\n"),
              !selectedText.contains("\r") else { return nil }
        let count = selectedText.count
        guard count > 0 else { return nil }
        let key = backwards ? "\u{007F}" : "\u{001B}[3~"
        return String(repeating: key, count: count)
    }
}

@MainActor
final class TerminalRuntime: NSObject {
    private weak var pane: PaneModel?
    private let io = TerminalIOBridge()
    private let activityCoalescer = TerminalActivityCoalescer()
    private let artifactCoordinator = TerminalArtifactCoordinator()
    private var lastArtifact: (path: String, data: Data)?
    private var hoveredLink: String?
    private var fileTransferTask: Task<Void, Never>?
    private var started = false
    private var presentationLeases = Set<UUID>()

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
        io.onReplayFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
            }
        }
    }

    func startIfNeeded() {
        guard !started, let pane else { return }
        started = true
        guard pane.profile.kind == .ssh, pane.profile.backend == .relay else { return }

        let remote = RelayRemoteTransport()
        let artifactPresentation = RelayPreferences.shared.artifactPresentation
        let artifactsEnabled = RelayPreferences.shared.showArtifactPreviews && !RelayLaunchMode.isSafeMode
        io.transport = remote
        pane.beginTerminalRestore()
        io.beginReplay()
        if io.restoreSnapshot(paneID: pane.id) {
            pane.showTerminalSnapshot()
        }
        let io = self.io
        let activityCoalescer = self.activityCoalescer
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
            onOutput: { [weak self] data in
                autoreleasepool {
                    let displayData = ArtifactHyperlinkEncoder.encode(data)
                    let isLiveOutput = io.receive(displayData)
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    if artifactsEnabled {
                        for path in artifactCoordinator.discover(in: text) {
                            Task { @Sendable [weak self] in
                                // Modern workers put a structured artifact frame
                                // directly after this output. Give it priority and
                                // only open a separate SSH fetch for older workers.
                                try? await Task.sleep(for: .milliseconds(150))
                                guard artifactCoordinator.beginFallback(for: path) else { return }
                                guard let data = try? await RemoteArtifactLoader.load(path: path, profile: artifactProfile),
                                      artifactCoordinator.acceptFallback(for: path) else { return }
                                if artifactPresentation == .inline {
                                    io.receiveInlineImageOrdered(
                                        data,
                                        imageID: Self.stableImageID(for: path)
                                    )
                                }
                                await MainActor.run { [weak self] in
                                    self?.presentArtifact(path: path, data: data)
                                }
                            }
                        }
                    }
                    guard isLiveOutput else { return }
                    self?.activityCoalescer.ingest(text) { [weak self] batch in
                        Task { @MainActor [weak self] in self?.pane?.received(batch) }
                    }
                }
            },
            onStatus: { [weak self] status in
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
                        self.io.endReplay()
                    } else if status.state == "reconnecting" {
                        self.io.beginReplay()
                        self.pane?.connectionInterrupted(status.message ?? "Reconnecting")
                    } else if status.state == "waiting_for_network" {
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
                if artifactPresentation == .inline {
                    self.io.receiveInlineImageOrdered(
                        artifact.data,
                        imageID: Self.stableImageID(for: artifact.path)
                    )
                }
                Task { @MainActor [weak self] in
                    self?.presentArtifact(path: artifact.path, data: artifact.data)
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
        io.transport?.detach()
        io.transport = nil
        started = false
    }

    func restart() {
        io.transport?.detach()
        io.transport = nil
        started = false
        pane?.reconnecting()
        startIfNeeded()
    }

    func focus() {
        _ = view.acquireProgrammaticFocus()
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
            view.setSurfaceVisible(isPresented)
        }
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
        lastArtifact = (path, data)
        pane?.receivedArtifact(path: path, data: data)
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
    private let lock = NSLock()
    private var pendingText = ""
    private var deliveryScheduled = false
    private var enabled = true

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled {
            pendingText.removeAll(keepingCapacity: true)
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
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let batch = self.pendingText
            self.pendingText.removeAll(keepingCapacity: true)
            self.deliveryScheduled = false
            self.lock.unlock()
            if !batch.isEmpty { deliver(batch) }
        }
    }
}

private final class TerminalIOBridge: @unchecked Sendable {
    var transport: RelayRemoteTransport?
    var onReplayFinished: (@Sendable () -> Void)?
    private let receiveLock = NSLock()
    private let displayLock = NSLock()
    private let displayQueue = DispatchQueue(label: "relay.terminal-display", qos: .userInteractive)
    private var displayBuffer = Data()
    private var displayDrainScheduled = false
    private let replayLock = NSLock()
    private var replaying = false
    private var expectsExplicitReplayBoundary = false
    private var suppressingTerminalWrites = false
    private var replayBuffer = Data()
    private var replayGeneration: UInt64 = 0
    private var legacyReplayGeneration: UInt64 = 0
    private var legacyReplayHardDeadline = DispatchTime.distantFuture
    private var filterDeviceResponsesUntil = Date.distantPast
    private var snapshotPaneID: UUID?
    private var snapshotBuffer = Data()
    private var snapshotGeneration: UInt64 = 0
    private let legacyReplayTimer: DispatchSourceTimer
    private let snapshotSaveTimer: DispatchSourceTimer

    init() {
        legacyReplayTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        snapshotSaveTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
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
    }

    deinit {
        legacyReplayTimer.cancel()
        snapshotSaveTimer.cancel()
    }

    lazy var session = InMemoryTerminalSession(
        write: { [weak self] data in self?.forwardTerminalWrite(data) },
        resize: { [weak self] viewport in
            self?.transport?.sendResize(
                columns: UInt16(viewport.columns),
                rows: UInt16(viewport.rows)
            )
        },
        suppressesPixelOnlyResizes: true
    )

    /// Returns true for live output and false for buffered reconstruction data.
    @discardableResult
    func receive(_ data: Data) -> Bool {
        replayLock.lock()
        if replaying {
            replayBuffer.append(data)
            if replayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                replayBuffer = TerminalSnapshotStore.bounded(replayBuffer)
            }
            replayLock.unlock()
            scheduleLegacyReplayEnd()
            return false
        }
        replayLock.unlock()
        enqueueDisplay(data)
        receiveLock.lock()
        appendSnapshotLocked(data)
        receiveLock.unlock()
        return true
    }

    func restoreSnapshot(paneID: UUID) -> Bool {
        snapshotPaneID = paneID
        guard let cached = TerminalSnapshotStore.shared.load(paneID: paneID), !cached.isEmpty else {
            return false
        }
        receiveLock.lock()
        snapshotBuffer = cached
        receiveLock.unlock()
        enqueueDisplay(cached, immediate: true)
        RelayDiagnostics.shared.record(category: "snapshot", name: "restored", details: [
            "pane_id": paneID.uuidString.lowercased(),
            "bytes": String(cached.count),
        ])
        return true
    }

    func flushSnapshot() {
        receiveLock.lock()
        let paneID = snapshotPaneID
        let snapshot = snapshotBuffer
        receiveLock.unlock()
        if let paneID, !snapshot.isEmpty { TerminalSnapshotStore.shared.save(snapshot, paneID: paneID) }
    }

    func beginReplay() {
        replayLock.lock()
        if !replaying { replayBuffer.removeAll(keepingCapacity: true) }
        replaying = true
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
        guard replaying else {
            replayLock.unlock()
            return
        }
        replaying = false
        replayGeneration &+= 1
        let generation = replayGeneration
        let buffered = replayBuffer
        replayBuffer.removeAll(keepingCapacity: true)
        legacyReplayHardDeadline = .distantFuture
        legacyReplayTimer.schedule(deadline: .distantFuture)
        replayLock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let reconstruction = TerminalReplayCompactor.compact(buffered)
            if !reconstruction.isEmpty {
                var replacement = Data("\u{001B}c".utf8)
                replacement.append(reconstruction)
                self.enqueueDisplay(replacement, immediate: true)
                self.receiveLock.lock()
                self.snapshotBuffer = TerminalSnapshotStore.bounded(replacement)
                self.scheduleSnapshotSaveLocked()
                self.receiveLock.unlock()
            }

            // Device-query replies are produced asynchronously by the renderer.
            // Keep them local for a couple of frames after reconstruction.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(150)
            ) { [weak self] in
                guard let self else { return }
                self.replayLock.lock()
                let finished = !self.replaying && self.replayGeneration == generation
                if finished { self.suppressingTerminalWrites = false }
                self.replayLock.unlock()
                if finished { self.onReplayFinished?() }
            }
        }
    }

    private func appendSnapshotLocked(_ data: Data) {
        guard snapshotPaneID != nil else { return }
        snapshotBuffer.append(data)
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
        snapshotGeneration &+= 1
        snapshotSaveTimer.schedule(
            deadline: .now() + .milliseconds(500),
            leeway: .milliseconds(150)
        )
    }

    private func savePendingSnapshot() {
        receiveLock.lock()
        guard let paneID = snapshotPaneID, !snapshotBuffer.isEmpty else {
            receiveLock.unlock()
            return
        }
        let generation = snapshotGeneration
        let snapshot = snapshotBuffer
        receiveLock.unlock()

        TerminalSnapshotStore.shared.save(snapshot, paneID: paneID)

        // If output arrived while the snapshot was compacted or queued for
        // disk, the producer already re-armed the timer. Do not overwrite its
        // deadline with a stale save.
        receiveLock.lock()
        let unchanged = snapshotGeneration == generation
        if unchanged {
            snapshotSaveTimer.schedule(deadline: .distantFuture)
        }
        receiveLock.unlock()
    }

    private func forwardTerminalWrite(_ data: Data) {
        replayLock.lock()
        let shouldSuppress = suppressingTerminalWrites
        let filterStartupResponse = Date() < filterDeviceResponsesUntil
        replayLock.unlock()
        guard !shouldSuppress else { return }
        guard !filterStartupResponse || !TerminalDeviceResponseFilter.matches(data) else { return }
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
        displayLock.lock()
        let batch = displayBuffer
        displayBuffer = Data()
        displayDrainScheduled = false
        displayLock.unlock()
        guard !batch.isEmpty else { return }
        autoreleasepool { session.receive(batch) }
    }
}

enum TerminalReplayCompactor {
    private static let reset = Data("\u{001B}c".utf8)
    private static let clearSequences = [
        Data("\u{001B}[2J".utf8),
        Data("\u{001B}[3J".utf8),
        reset,
    ]

    /// A fresh local surface needs the current screen, not every cursor-addressed
    /// redraw ever emitted by a TUI. Reconstruct from its latest full clear.
    static func compact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var latest: Data.Index?
        for sequence in clearSequences {
            if let range = data.range(of: sequence, options: .backwards),
               latest == nil || range.lowerBound > latest! {
                latest = range.lowerBound
            }
        }
        guard let latest, latest > data.startIndex else { return data }
        var result = reset
        result.append(contentsOf: data[latest...])
        return result
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
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pane?.title = title
    }

    func terminalDidClose(processAlive: Bool) {
        pane?.exited()
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        if focused { selectPane() }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        pane?.directory = path
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        pane?.recordCommandCompletion(exitCode: exitCode, durationNanos: durationNanos)
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
        let text: String
        let backwards: Bool
        let caretLocationInWindow: CGPoint
    }

    weak var owner: TerminalRuntime?
    private var suppressNextMouseUp = false
    private var selectionStart: CGPoint?
    private var selectionStartInWindow: CGPoint?
    private var promptSelection: PromptSelection?
    private var forcingLocalPromptSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        owner?.selectPane()
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           owner?.openHoveredLink() == true {
            suppressNextMouseUp = true
            return
        }
        promptSelection = nil
        let point = terminalPoint(for: event)
        selectionStart = owner?.allowsPromptSelectionEditing == true && pointIsNearActivePrompt(point)
            ? point : nil
        selectionStartInWindow = selectionStart == nil ? nil : event.locationInWindow
        forcingLocalPromptSelection = selectionStart != nil && owner?.forcesLocalPromptSelection == true
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
              selectionIsNearActivePrompt(start: start, end: end),
              copySelectedTextToPasteboard(),
              let text = NSPasteboard.general.string(forType: .string),
              TerminalPromptSelectionEdit.deletionSequence(for: text, backwards: false) != nil
        else { return }
        let backwards = end.y < start.y - 4 || (abs(end.y - start.y) <= 4 && end.x < start.x)
        promptSelection = PromptSelection(
            text: text,
            backwards: backwards,
            caretLocationInWindow: caretLocation
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           importFiles(from: NSPasteboard.general) {
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let promptSelection,
           let sequence = TerminalPromptSelectionEdit.deletionSequence(
                for: promptSelection.text,
                backwards: promptSelection.backwards
           ) {
            self.promptSelection = nil
            movePromptCursor(to: promptSelection.caretLocationInWindow)
            sendText(sequence)
            return
        }
        promptSelection = nil
        super.keyDown(with: event)
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
        // Shell prompts normally occupy the final few rows. This conservative
        // boundary prevents a selection in scrollback/output from becoming an
        // edit operation while still covering wrapped command lines.
        let promptBand = min(96, max(48, bounds.height * 0.2))
        let top = bounds.height - promptBand
        return start.y >= top && end.y >= top
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

    private func movePromptCursor(to locationInWindow: CGPoint) {
        guard let window else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: .option,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: .option,
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
        Task { @MainActor in
            await Task.yield()
            pane.runtime.startIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: RelayGhosttyView, context: Context) {
        presentAfterLayout(nsView, coordinator: context.coordinator)
        Task { @MainActor in
            await Task.yield()
            pane.runtime.startIfNeeded()
        }
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
                pane.runtime.setPresented(
                    true,
                    lease: coordinator.presentationLease,
                    force: true
                )

                // Give Ghostty one display interval to publish the correctly
                // sized IOSurface, then reveal it as one visual transaction.
                try? await Task.sleep(for: .milliseconds(16))
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
