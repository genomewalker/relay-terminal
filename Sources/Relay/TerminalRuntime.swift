import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import SwiftUI

enum RelayClipboardAction: String, Sendable {
    case copy
    case paste
    case selectAll
}

@MainActor
final class RelayClipboardRequest {
    let action: RelayClipboardAction
    var handled = false

    init(_ action: RelayClipboardAction) {
        self.action = action
    }
}

enum TerminalPromptSelectionEdit {
    static func isEnabled(contentKind: PaneContentKind, agentKind: AgentKind) -> Bool {
        contentKind == .terminal
    }

    static func forcesLocalSelection(agentKind: AgentKind) -> Bool {
        agentKind != .shell
    }

    /// Full-screen terminal programs own their pointer protocol, so Relay
    /// must not synthesize line-editor movement while a shell is in the
    /// alternate screen. Codex and Claude are different: their composer is
    /// itself an alternate-screen TUI, and Relay deliberately handles prompt
    /// selection locally for those agents.
    static func allowsCursorPlacement(
        geometryIsStable: Bool,
        alternateScreenIsActive: Bool,
        agentPrompt _: Bool
    ) -> Bool {
        // Alternate-screen TUIs own their mouse and composer cursor. Ghostty's
        // IME rectangle is the terminal grid cursor, which can differ from a
        // Codex/Claude prompt; synthesizing arrows from it corrupts input.
        geometryIsStable && !alternateScreenIsActive
    }

    static func deletionSequence(for selectedText: String, backwards _: Bool) -> String? {
        let normalized = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let count = normalized.count
        guard count > 0, count <= 4_096 else { return nil }
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
        cursorOrigin: CGPoint,
        target: CGPoint,
        cellSize: CGSize,
        columns: Int
    ) -> Int? {
        guard cursorOrigin.x.isFinite, cursorOrigin.y.isFinite,
              target.x.isFinite, target.y.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0, columns > 0
        else { return nil }

        // Ghostty reports the cursor cell's top-left origin. A click belongs
        // to the cell containing it, so floor is correct in both directions:
        // a click anywhere in the immediately preceding cell moves left once,
        // while a click inside the cursor's current cell does not move.
        let rowDelta = Int(floor((target.y - cursorOrigin.y) / cellSize.height))
        let columnDelta = Int(floor((target.x - cursorOrigin.x) / cellSize.width))
        let offset = rowDelta * columns + columnDelta
        guard abs(offset) <= 4_096 else { return nil }
        return offset
    }

    /// Agent state switches back to `active` as soon as the user types a
    /// response. That describes the conversation, not whether its composer is
    /// editable. Local input is stronger evidence than that eager phase
    /// update. Shell prompts are governed by OSC 133 instead.
    static func promptEditingIsActive(
        agentPrompt: Bool,
        hasLocalInput: Bool,
        agentPhaseAllowsEditing: Bool,
        semanticShellPromptActive: Bool
    ) -> Bool {
        if agentPrompt {
            return agentPhaseAllowsEditing || hasLocalInput
        }
        return semanticShellPromptActive
    }

    /// Prefer the exact logical mirror when Relay saw the whole prompt. After
    /// an SSH reconnect the visible line may predate this app process, so a
    /// bounded visual delta is the only honest fallback. Readline and agent
    /// composers clamp arrows at their own input boundaries.
    static func resolvedMovementOffset(
        visualOffset: Int,
        mirroredOffset: Int?,
        mirrorIsReliable: Bool,
        allowsRemoteVisualFallback: Bool
    ) -> Int? {
        if let mirroredOffset { return mirroredOffset }
        guard !mirrorIsReliable,
              allowsRemoteVisualFallback,
              abs(visualOffset) <= 1_024
        else { return nil }
        return visualOffset
    }
}

enum TerminalViewportRepaintPolicy {
    private struct Evidence {
        var addressedRows: [UInt16] = []
        var hasExplicitClear = false
        var hasSemanticPromptProperty = false
        var hasSemanticPromptEnd = false
        var hasEraseLine = false
        var printableBytes = 0
    }

    /// A resize repaint from a primary-screen TUI is cursor-addressed and
    /// replaces the viewport. OSC 133 is semantic metadata, not proof of a
    /// complete visual prompt repaint, so it must not clear the screen by
    /// itself. Ordinary shell/build/tail output retains scrollback.
    static func needsClearBarrier(_ data: Data, rows: UInt16) -> Bool {
        guard !data.isEmpty else { return false }
        guard data.count >= 96 else { return false }
        let evidence = repaintEvidence(in: data, rows: rows)
        return !evidence.hasExplicitClear && replacementIsSubstantial(evidence, rows: rows)
    }

    /// A resize transaction may be published as soon as the application has
    /// produced a complete replacement frame. This keeps the previous
    /// IOSurface visible across an early clear from a slow TUI such as Codex,
    /// while Claude, htop, and synchronized renderers swap immediately when
    /// their destination-sized frame completes.
    static func hasCompleteReplacement(_ data: Data, rows: UInt16) -> Bool {
        guard data.count >= 96 else { return false }
        if TerminalReplayCompactor.hasCompletedSynchronizedFrame(data) { return true }
        let evidence = repaintEvidence(in: data, rows: rows)
        if replacementIsSubstantial(evidence, rows: rows) { return true }
        let printableFloor = max(512, Int(rows) * 4)
        return evidence.hasExplicitClear && evidence.printableBytes >= printableFloor
    }

    private static func replacementIsSubstantial(_ evidence: Evidence, rows: UInt16) -> Bool {
        let required = rows > 0 && rows < 5 ? 2 : 3
        let semanticPromptRepaint = evidence.hasSemanticPromptProperty &&
            evidence.hasSemanticPromptEnd && evidence.hasEraseLine && evidence.printableBytes >= 4
        return evidence.addressedRows.count >= required || semanticPromptRepaint
    }

    private static func repaintEvidence(in data: Data, rows _: UInt16) -> Evidence {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var evidence = Evidence()
            evidence.addressedRows.reserveCapacity(4)
            var index = 0
            while index + 1 < bytes.count {
                guard bytes[index] == 0x1B else {
                    if bytes[index] >= 0x20, bytes[index] != 0x7F {
                        evidence.printableBytes += 1
                    }
                    index += 1
                    continue
                }
                if bytes[index + 1] == 0x63 { // RIS: ESC c
                    evidence.hasExplicitClear = true
                    index += 2
                    continue
                }
                if bytes[index + 1] == 0x5D, index + 6 < bytes.count,
                   bytes[index + 2] == 0x31,
                   bytes[index + 3] == 0x33,
                   bytes[index + 4] == 0x33,
                   bytes[index + 5] == 0x3B {
                    if bytes[index + 6] == 0x50 { evidence.hasSemanticPromptProperty = true }
                    if bytes[index + 6] == 0x42 { evidence.hasSemanticPromptEnd = true }
                    index += 7
                    continue
                }
                guard bytes[index + 1] == 0x5B else {
                    index += 2
                    continue
                }
                var cursor = index + 2
                var firstParameter = 0
                var hasFirstParameter = false
                while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) {
                    hasFirstParameter = true
                    firstParameter = min(
                        Int(UInt16.max),
                        firstParameter * 10 + Int(bytes[cursor] - 0x30)
                    )
                    cursor += 1
                }
                if hasFirstParameter, cursor < bytes.count,
                   (firstParameter == 2 || firstParameter == 3),
                   bytes[cursor] == 0x4A { // CSI 2J / CSI 3J
                    evidence.hasExplicitClear = true
                    index = cursor + 1
                    continue
                }
                if cursor < bytes.count, bytes[cursor] == 0x4B { // CSI K / 0K / 2K
                    evidence.hasEraseLine = true
                    index = cursor + 1
                    continue
                }
                guard hasFirstParameter else {
                    index += 2
                    continue
                }
                if cursor < bytes.count, bytes[cursor] == 0x3B {
                    cursor += 1
                    while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) {
                        cursor += 1
                    }
                }
                // Only CUP/HVP terminators address a row. A semicolon in SGR
                // (for example CSI 38;5;...m) is merely another color parameter.
                if cursor < bytes.count,
                   bytes[cursor] == 0x48 || bytes[cursor] == 0x66 {
                    let row = UInt16(firstParameter)
                    if !evidence.addressedRows.contains(row) {
                        evidence.addressedRows.append(row)
                    }
                }
                index = max(index + 1, cursor + 1)
            }
            return evidence
        }
    }
}

enum TerminalViewportGeometry {
    /// Predict Ghostty's final grid without mutating the live surface. Relay
    /// can then resize the remote PTY while Ghostty continues presenting the
    /// outgoing grid, and swap only after the replacement frame is complete.
    static func predictedViewport(
        bounds: CGSize,
        backingScaleFactor: CGFloat,
        cellWidthPixels: CGFloat,
        cellHeightPixels: CGFloat
    ) -> RelayViewport? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              backingScaleFactor.isFinite, backingScaleFactor > 0,
              cellWidthPixels.isFinite, cellWidthPixels > 0,
              cellHeightPixels.isFinite, cellHeightPixels > 0
        else { return nil }
        let columns = Int(floor(bounds.width * backingScaleFactor / cellWidthPixels))
        let rows = Int(floor(bounds.height * backingScaleFactor / cellHeightPixels))
        guard columns > 0, rows > 0 else { return nil }
        return RelayViewport(
            columns: UInt16(clamping: columns),
            rows: UInt16(clamping: rows)
        )
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

enum TerminalBufferRetentionPolicy {
    static let retainedCapacityLimit = 512 << 10

    static func clear(_ data: inout Data) {
        if data.count > retainedCapacityLimit {
            data = Data()
        } else {
            data.removeAll(keepingCapacity: true)
        }
    }
}

enum TerminalEnergyPolicy {
    /// Presentation and catch-up are deliberately separate. Background panes
    /// buffer the ordered PTY delta without waking Ghostty or Metal. Returning
    /// applies that delta to the retained grid; a full snapshot reconstruction
    /// is reserved for the rare case where the bounded delta overflows.
    static func pausesTerminalEmulation(
        isPresented: Bool,
        applicationVisible: Bool
    ) -> Bool {
        !isPresented || !applicationVisible
    }

    static func showsSurface(isPresented: Bool, applicationVisible: Bool) -> Bool {
        isPresented && applicationVisible
    }
}

enum TerminalSnapshotCompactionPolicy {
    /// Keep live appends O(1). Once a snapshot reaches its 2 MiB storage
    /// boundary, compacting every following SSH packet repeatedly rescans the
    /// entire buffer. A bounded high-water window amortizes that scan while
    /// synchronous and scheduled persistence still enforce the disk limit.
    static let highWaterBytes = TerminalSnapshotStore.maximumBytes * 2

    static func shouldCompact(byteCount: Int) -> Bool {
        byteCount > highWaterBytes
    }
}

enum TerminalResizePolicy {
    /// SwiftUI emits several valid-but-transitional pane sizes while moving
    /// durable terminal views between tab layouts. Only the final geometry
    /// should reach the remote PTY.
    static let debounceMilliseconds = 75
    static let revealAfterCommitMilliseconds = 50
}

enum TerminalViewportOwnershipPolicy {
    /// The native surface only needs to take the PTY back when another client
    /// committed a different grid (or no grid has been committed yet).
    static func needsNativeReclaim(
        native: RelayViewport,
        committed: RelayViewport?
    ) -> Bool {
        native != committed
    }
}

/// Live PTY packets can arrive much faster than a display can present them.
/// One frame-sized batch keeps parsing, link detection, and renderer wakeups
/// proportional to visible frames instead of SSH packet count. Explicit replay
/// and resize barriers continue to bypass this delay.
enum TerminalDisplayBatchPolicy {
    static let liveMilliseconds = 16
}

enum TerminalViewportPosition {
    static func isAtBottom(_ scrollbar: TerminalScrollbar) -> Bool {
        scrollbar.len >= scrollbar.total ||
            scrollbar.offset >= scrollbar.total - scrollbar.len
    }
}

struct TerminalStableViewportCommit {
    let explicit: Bool
    let remoteGeneration: UInt64?
    let presentationEpoch: UInt64
}

struct TerminalPresentationAttachmentState {
    private(set) var generation: UInt64 = 0
    private(set) var currentLease: UUID?
    private(set) var isPresented = false

    mutating func begin(lease: UUID) -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        currentLease = lease
        isPresented = false
        return generation
    }

    mutating func setPresented(_ presented: Bool, lease: UUID, generation: UInt64) -> Bool {
        guard self.generation == generation, currentLease == lease else { return false }
        isPresented = presented
        return true
    }

    mutating func end(lease: UUID, generation: UInt64) -> Bool {
        guard self.generation == generation, currentLease == lease else { return false }
        currentLease = nil
        isPresented = false
        return true
    }
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
    private var presentationAttachment = TerminalPresentationAttachmentState()
    private var allowsRendering = RelayApplicationActivityState.allowsContinuousUpdates
    private var legacyActivityHeuristicsEnabled = true
    private var workerProvidesTerminalModeState = false
    private var terminalWorkerCapabilitiesKnown = false
    private var terminalReplayCaughtUp = false
    private var legacyTerminalModeCompatibilityApplied = false
    private var explicitGeometryTransitionPending = false
    private var revealLatestAfterGeometryTransition = true
    private var viewportIsAtBottom = true
    private var presentationRecoveryTask: Task<Void, Never>?
    private var focusRecoveryTask: Task<Void, Never>?
    private var interactionPresentationTask: Task<Void, Never>?
    private var viewportCommitFallbackTask: Task<Void, Never>?
    private var pendingViewportCommitGeneration: UInt64?
    private var pendingViewportCommitEpoch: UInt64?
    private var viewportPresentationEpoch: UInt64 = 0
    private var pendingExplicitViewportTarget: RelayViewport?
    private var latestSurfaceViewport: RelayViewport?
    private var latestSurfaceGridMetrics: TerminalGridMetrics?
    private var pendingFocusOnPresentation = false
    private var keyboardFocusEligible = false
    private var inputDiagnosticCount = 0

    private var session: InMemoryTerminalSession { io.session }
    private(set) lazy var view: RelayGhosttyView = makeView()

    private static let controller = TerminalController(
        configuration: RelayPreferences.shared.terminalConfiguration()
    )

    static func applyPreferences(_ preferences: RelayPreferences = .shared) {
        _ = controller.setTerminalConfiguration(preferences.terminalConfiguration())
    }

    init(pane: PaneModel) {
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            TerminalDebugLog.enable([.lifecycle, .metrics])
        }
        self.pane = pane
        super.init()
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
        io.onPresentationResumed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishPresentationResume()
            }
        }
        io.onViewportCommitted = { [weak self] generation in
            Task { @MainActor [weak self] in
                self?.viewportDidCommit(generation)
            }
        }
        io.onViewportFrameReady = { [weak self] in
            Task { @MainActor [weak self] in
                self?.viewportFrameDidBecomeReady()
            }
        }
        io.onSemanticPromptStateChanged = { [weak self] active in
            Task { @MainActor [weak self] in
                self?.view.setShellPromptActive(active)
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
        presentationRecoveryTask?.cancel()
        focusRecoveryTask?.cancel()
        interactionPresentationTask?.cancel()
        viewportCommitFallbackTask?.cancel()
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
            // A snapshot may contain a partially composed command entered
            // before this Relay process existed. The rendered state is valid;
            // the local prompt mirror is not.
            view.remoteTerminalStateWasRestored()
            pane.showTerminalSnapshot()
        }
        let io = self.io
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
                        Task { @MainActor [weak self] in
                            guard let self, let pane = self.pane else { return }
                            pane.received(batch)
                            self.agentKindDidChange(pane.kind)
                        }
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let clientCount = status.clientCount {
                        self.pane?.recordRemoteClientCount(clientCount)
                    }
                    if status.state == "attached" || status.state == "read_only" {
                        // Modern workers provide authoritative process, hook,
                        // and transcript events. Legacy text parsing also
                        // sleeps whenever Relay is not interactive.
                        self.legacyActivityHeuristicsEnabled =
                            !status.capabilities.contains("event_cursor_v1")
                        self.workerProvidesTerminalModeState = status.capabilities.contains(
                            LegacyTerminalModeCompatibility.durableCapability
                        )
                        self.terminalWorkerCapabilitiesKnown = true
                        self.terminalReplayCaughtUp = false
                        self.legacyTerminalModeCompatibilityApplied = false
                        self.updateBackgroundTextWork()
                    }
                    if status.state == "attached" {
                        self.pane?.beginTerminalRestore()
                        self.pane?.connected()
                    } else if status.state == "caught_up" {
                        self.terminalReplayCaughtUp = true
                        self.applyLegacyTerminalModeCompatibilityIfNeeded()
                        self.io.endReplayAfterViewportSettle()
                    } else if status.state == "reconnecting" {
                        self.terminalReplayCaughtUp = false
                        self.terminalWorkerCapabilitiesKnown = false
                        self.view.remoteTerminalStateWasRestored()
                        self.beginMeasuredRestore(reason: "reconnect")
                        self.io.beginReplay()
                        self.pane?.connectionInterrupted(status.message ?? "Reconnecting")
                    } else if status.state == "waiting_for_network" {
                        self.terminalReplayCaughtUp = false
                        self.terminalWorkerCapabilitiesKnown = false
                        self.view.remoteTerminalStateWasRestored()
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
                Task { @MainActor [weak self] in
                    guard let self, let pane = self.pane else { return }
                    pane.receivedAgentEvent(data)
                    self.agentKindDidChange(pane.kind)
                }
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

    /// Agent lifecycle events and terminal replay are independent ordered
    /// streams. Either may identify readiness first, so compatibility is
    /// committed only after both have arrived instead of relying on startup
    /// timing.
    func agentKindDidChange(_ kind: AgentKind) {
        applyLegacyTerminalModeCompatibilityIfNeeded(agentKind: kind)
    }

    private func applyLegacyTerminalModeCompatibilityIfNeeded(agentKind: AgentKind? = nil) {
        guard terminalWorkerCapabilitiesKnown,
              terminalReplayCaughtUp,
              !legacyTerminalModeCompatibilityApplied,
              let agentKind = agentKind ?? pane?.kind,
              let prelude = LegacyTerminalModeCompatibility.prelude(
                  agentKind: agentKind,
                  capabilities: workerProvidesTerminalModeState
                      ? [LegacyTerminalModeCompatibility.durableCapability]
                      : []
              ) else { return }
        legacyTerminalModeCompatibilityApplied = true
        _ = io.receive(prelude, remoteSequence: 0)
    }

    func stop() {
        fileTransferTask?.cancel()
        fileTransferTask = nil
        io.finishViewportTransition(rows: latestSurfaceViewport?.rows ?? 0)
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
        guard keyboardFocusEligible else { return }
        pendingFocusOnPresentation = true
        // A mounted terminal should take keyboard ownership synchronously.
        // Waiting only for the recovery task leaves a visible interval where
        // AppKit can keep the previously selected pane as first responder,
        // especially while several surfaces are restoring at once. Keep the
        // delayed claims as a SwiftUI reparenting fallback, but do not make
        // normal input wait for them.
        _ = claimKeyboardFocus()
        scheduleFocusRecovery()
    }

    func setKeyboardFocusEligible(_ eligible: Bool) {
        guard keyboardFocusEligible != eligible else { return }
        keyboardFocusEligible = eligible
        guard !eligible else { return }
        pendingFocusOnPresentation = false
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
    }

    private func claimKeyboardFocus() -> Bool {
        if view.acquireProgrammaticFocus() { return true }
        return view.window?.makeFirstResponder(view) ?? false
    }

    private func scheduleFocusRecovery() {
        focusRecoveryTask?.cancel()
        guard pendingFocusOnPresentation, keyboardFocusEligible else { return }
        focusRecoveryTask = Task { @MainActor [weak self] in
            // SwiftUI can reset first responder at the end of the same update
            // that mounts an NSViewRepresentable. Claim it after that update,
            // with bounded retries for a busy multi-pane restore.
            for delay in [24, 64, 128] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self,
                      self.pendingFocusOnPresentation,
                      self.keyboardFocusEligible,
                      self.presentationAttachment.isPresented,
                      self.view.window != nil else { continue }
                if self.claimKeyboardFocus() {
                    self.pendingFocusOnPresentation = false
                    self.focusRecoveryTask = nil
                    return
                }
            }
            self?.focusRecoveryTask = nil
        }
    }

    @discardableResult
    func jumpToPrompt(by offset: Int16) -> Bool {
        view.jumpToPrompt(by: offset)
    }

    /// A durable Ghostty NSView is reparented when SwiftUI changes tabs, zoom,
    /// or floating layout. Representable teardown and creation can overlap, so
    /// an unordered lease set lets a stale coordinator hide the newly attached
    /// view. Only the newest attachment generation may present or dismantle it.
    func beginPresentationAttachment(lease: UUID) -> UInt64 {
        presentationAttachment.begin(lease: lease)
    }

    func setPresented(
        _ presented: Bool,
        lease: UUID,
        generation: UInt64,
        force: Bool = false
    ) {
        let changed = presentationAttachment.isPresented != presented
        guard presentationAttachment.setPresented(
            presented, lease: lease, generation: generation
        ) else { return }
        if !TerminalEnergyPolicy.pausesTerminalEmulation(
            isPresented: presented,
            applicationVisible: allowsRendering
        ) {
            io.setPresentationPaused(false, reconstruct: false)
        } else {
            io.setPresentationPaused(true)
        }
        if changed || force {
            // Occluding the surface releases Ghostty's shared display-link.
            // The ordered PTY stream continues into the bounded delta buffer.
            let visible = TerminalEnergyPolicy.showsSurface(
                isPresented: presented,
                applicationVisible: allowsRendering
            )
            view.setSurfaceVisible(visible)
            // Visibility must precede the redraw. Ghostty does not publish a
            // new IOSurface for an invisible idle terminal, so redrawing first
            // left restored panes transparent until an unrelated resize.
            if visible {
                view.synchronizeAndRedraw()
                // The retained IOSurface is valid immediately. A later stable
                // geometry sample replaces it atomically, but the user should
                // never wait on a black cover just to revisit a tab.
                if pendingViewportCommitEpoch == nil && presentationRecoveryTask == nil {
                    view.alphaValue = 1
                }
                if pendingFocusOnPresentation { scheduleFocusRecovery() }
            }
        }
    }

    func endPresentationAttachment(lease: UUID, generation: UInt64) {
        guard presentationAttachment.end(lease: lease, generation: generation) else { return }
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
        // Preserve the retained terminal grid while detached. AppKit removes
        // the view from a window; subsequent PTY bytes accumulate as an
        // ordered delta without mutating that grid's input state.
        finishHiddenGeometryTransitionIfNeeded()
        // A detached tab does not need Ghostty to parse and render every
        // remote repaint. Continue consuming the transport into the bounded
        // snapshot and delta, then catch the retained grid up once when this
        // pane is shown again. This removes renderer bursts that could delay
        // keyboard echo in the active pane.
        io.setPresentationPaused(true)
    }

    /// SwiftUI can remove a pane while AppKit's final resize settle is still
    /// pending. A hidden pane has no surface to reveal, but its ordered PTY
    /// stream must leave the viewport transaction and continue accumulating in
    /// the paused snapshot path for its next attachment.
    private func finishHiddenGeometryTransitionIfNeeded() {
        guard explicitGeometryTransitionPending ||
                pendingViewportCommitEpoch != nil ||
                viewportCommitFallbackTask != nil ||
                presentationRecoveryTask != nil
        else { return }

        viewportPresentationEpoch &+= 1
        if viewportPresentationEpoch == 0 { viewportPresentationEpoch = 1 }
        explicitGeometryTransitionPending = false
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        pendingExplicitViewportTarget = nil
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = nil
        view.setResizeThrottle(milliseconds: nil)
        view.setResizeSynchronizationSuspended(false)
        io.finishViewportTransition(rows: latestSurfaceViewport?.rows ?? 0)
    }

    private func setApplicationRenderingAllowed(_ allowed: Bool) {
        guard allowsRendering != allowed else { return }
        allowsRendering = allowed
        updateBackgroundTextWork()
        guard started else { return }
        let isPresented = presentationAttachment.isPresented
        // Backgrounding suppresses Ghostty parsing, optional intelligence/link
        // scanning, and Metal presentation. The ordered PTY delta remains
        // bounded and foregrounding applies only that delta, avoiding the old
        // reset plus multi-megabyte replay for every visible pane.
        io.setPresentationPaused(
            TerminalEnergyPolicy.pausesTerminalEmulation(
                isPresented: isPresented,
                applicationVisible: allowed
            ),
            reconstruct: false
        )
        let surfaceVisible = TerminalEnergyPolicy.showsSurface(
            isPresented: isPresented,
            applicationVisible: allowed
        )
        view.setSurfaceVisible(surfaceVisible)
        guard surfaceVisible, view.window != nil else { return }
        view.layoutSubtreeIfNeeded()
        prepareFinalSurfaceMeasurement()
        fitForStableViewportCommit()
        view.synchronizeAndRedraw()
        view.alphaValue = 1
    }

    /// Input delivery is stronger evidence of interactivity than a possibly
    /// stale occlusion notification during full-screen and Space transitions.
    /// Wake the ordered display path before forwarding the input so its remote
    /// echo can be rendered. Synthetic/background input receives only a short
    /// lease; genuine app interaction updates the shared visibility state and
    /// remains awake until the normal resign/occlusion notification.
    fileprivate func prepareForUserInteraction() {
        interactionPresentationTask?.cancel()
        interactionPresentationTask = nil
        let windowIsInteractive = NSApp.isActive &&
            view.window?.isVisible == true &&
            view.window?.isMiniaturized == false
        if windowIsInteractive {
            RelayApplicationActivityState.setApplicationVisible(true)
            setApplicationRenderingAllowed(true)
            return
        }

        setApplicationRenderingAllowed(true)
        interactionPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self else { return }
            if !RelayApplicationActivityState.allowsContinuousUpdates {
                self.setApplicationRenderingAllowed(false)
            }
            self.interactionPresentationTask = nil
        }
    }

    private func updateBackgroundTextWork() {
        artifactCoalescer.setEnabled(allowsRendering)
        activityCoalescer.setEnabled(allowsRendering && legacyActivityHeuristicsEnabled)
    }

    func beginExplicitGeometryTransition() {
        viewportPresentationEpoch &+= 1
        if viewportPresentationEpoch == 0 { viewportPresentationEpoch = 1 }
        explicitGeometryTransitionPending = true
        if pane?.profile.kind == .ssh, pane?.profile.backend == .relay {
            view.setResizeSynchronizationSuspended(true)
        }
        // Reflow changes the number of wrapped rows in a primary-screen agent
        // transcript. Preserving its raw scrollbar offset can land on an empty
        // region and make the composer appear to have vanished after zoom or
        // restore. Agent panes therefore return to their live composer; an
        // ordinary shell keeps the user's deliberate scrollback position.
        revealLatestAfterGeometryTransition = viewportIsAtBottom || pane?.kind != .shell
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        pendingExplicitViewportTarget = nil
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = nil
        // Keep PTY output out of Ghostty while AppKit is changing the cell
        // grid. The remote viewport commit below is the presentation barrier:
        // once its SIGWINCH repaint has reached Relay, the complete replacement
        // is delivered to Ghostty as one ordered batch. Feeding live TUI deltas
        // into intermediate grids is what left Codex, Claude, and htop with
        // stale columns after zoom, tab, and divider transitions.
        if pane?.profile.kind == .ssh, pane?.profile.backend == .relay {
            io.beginViewportTransition(
                // Alternate-screen applications repaint their whole screen on
                // SIGWINCH. Primary-screen agents may emit only a prompt/status
                // delta, so clearing them unconditionally erases transcript
                // cells that the repaint never replaces.
                authoritativePrimaryScreen: io.isAlternateScreenActive
            )
        }
        // Coalesce AppKit's animation frames locally. The settling callback
        // switches to synchronous measurement only for the final fit, avoiding
        // a Ghostty resize/render for every full-screen or divider frame.
        view.setResizeThrottle(milliseconds: 16)
    }

    fileprivate func prepareFinalSurfaceMeasurement() {
        guard explicitGeometryTransitionPending else { return }
        view.setResizeThrottle(milliseconds: 0)
        guard pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              let metrics = latestSurfaceGridMetrics,
              let scale = view.window?.backingScaleFactor
        else { return }
        pendingExplicitViewportTarget = TerminalViewportGeometry.predictedViewport(
            bounds: view.bounds.size,
            backingScaleFactor: scale,
            cellWidthPixels: CGFloat(metrics.cellWidthPixels),
            cellHeightPixels: CGFloat(metrics.cellHeightPixels)
        )
    }

    /// Local and direct-exec terminals fit immediately. A remote pane with a
    /// measured explicit target deliberately retains its old Ghostty grid
    /// until the destination-sized PTY frame has completed.
    fileprivate func fitForStableViewportCommit() {
        if explicitGeometryTransitionPending,
           pane?.profile.kind == .ssh,
           pane?.profile.backend == .relay,
           pendingExplicitViewportTarget != nil {
            return
        }
        view.setResizeSynchronizationSuspended(false)
        view.fitToSize()
    }

    /// NSView frame changes are the authoritative signal that a presented
    /// remote terminal is moving to a different grid. Treat the whole resize
    /// as one viewport transaction even when it originated in macOS full
    /// screen or SwiftUI layout rather than Relay's pane controls.
    fileprivate func beginSurfaceGeometryTransition() {
        guard started,
              pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              presentationAttachment.isPresented
        else { return }
        beginExplicitGeometryTransition()
    }

    @discardableResult
    fileprivate func commitStableViewport() -> TerminalStableViewportCommit {
        let explicit = explicitGeometryTransitionPending
        explicitGeometryTransitionPending = false
        if explicit {
            pendingViewportCommitEpoch = viewportPresentationEpoch
        }
        // InMemoryTerminalSession reports the new grid synchronously during
        // fitToSize(). The public surface delegate follows asynchronously and
        // may still describe the outgoing layout here; never overwrite the
        // backend's fresh viewport with that stale delegate value.
        let committedViewport = explicit ? pendingExplicitViewportTarget : nil
        let generation = io.flushPendingResize(
            viewport: committedViewport,
            forceRepaint: explicit,
            compatibilityRepaintPulse: explicit &&
                (pane?.kind != .shell || io.isAlternateScreenActive)
        )
        if explicit, pane?.profile.kind == .ssh, pane?.profile.backend == .relay {
            // Arm only after the resize is on the transport. This atomically
            // discards periodic frames emitted for the outgoing grid; the
            // next accepted replacement must follow the committed SIGWINCH.
            io.armViewportFrameBarrier(
                rows: committedViewport?.rows ?? latestSurfaceViewport?.rows ?? 0
            )
        }
        if explicit, pane?.profile.kind == .ssh, pane?.profile.backend == .relay {
            // Return subsequent live frame changes to the surface policy once
            // the one-shot destination measurement has been committed.
            view.setResizeThrottle(milliseconds: nil)
        }
        if explicit {
            pendingViewportCommitGeneration = generation
            if let generation {
                scheduleViewportCommitFallback(
                    generation,
                    epoch: viewportPresentationEpoch
                )
            } else {
                // Legacy workers cannot acknowledge a repaint. Keep their
                // compatibility path bounded without making the normal v2
                // path wait on a timer.
                scheduleUnacknowledgedViewportSettle(epoch: viewportPresentationEpoch)
            }
        }
        return TerminalStableViewportCommit(
            explicit: explicit,
            remoteGeneration: generation,
            presentationEpoch: viewportPresentationEpoch
        )
    }

    @discardableResult
    fileprivate func finishStableGeometryTransition(
        _ commit: TerminalStableViewportCommit
    ) -> Bool {
        if commit.explicit,
           pane?.profile.kind == .ssh,
           pane?.profile.backend == .relay {
            // The outgoing IOSurface stays visible while the remote repaint is
            // in flight. The ordered output path publishes the replacement
            // only after it observes a complete destination-sized frame, so
            // this path has no black cover and no partial redraw.
            return false
        }
        view.synchronizeAndRedraw()
        return true
    }

    private func finishPresentationResume() {
        guard allowsRendering,
              presentationAttachment.isPresented,
              view.window != nil else { return }
        view.layoutSubtreeIfNeeded()
        prepareFinalSurfaceMeasurement()
        fitForStableViewportCommit()
        let commit = commitStableViewport()
        if finishStableGeometryTransition(commit) {
            view.setSurfaceVisible(true)
            view.synchronizeAndRedraw()
            view.alphaValue = 1
        }
    }

    private func viewportDidCommit(_ generation: UInt64) {
        guard generation == pendingViewportCommitGeneration,
              let epoch = pendingViewportCommitEpoch,
              epoch == viewportPresentationEpoch else { return }
        // The ACK confirms PTY geometry, not that the application has painted
        // the destination grid. Keep the previous IOSurface published until
        // the ordered output path observes a complete replacement frame.
        pendingViewportCommitGeneration = nil
    }

    private func viewportFrameDidBecomeReady() {
        guard let epoch = pendingViewportCommitEpoch,
              epoch == viewportPresentationEpoch else { return }
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        finishViewportPresentation(
            revealLatest: revealLatestAfterGeometryTransition,
            epoch: epoch
        )
    }

    private func scheduleViewportCommitFallback(_ generation: UInt64, epoch: UInt64) {
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = Task { @MainActor [weak self] in
            // A supported worker normally acknowledges in tens of milliseconds.
            // This is an error-path guard for a lost ACK, not the synchronization
            // mechanism, so keep the covered previous frame for a full slow-link
            // window instead of revealing an intermediate grid on a VPN.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  self.pendingViewportCommitEpoch == epoch,
                  self.viewportPresentationEpoch == epoch else { return }
            self.pendingViewportCommitGeneration = nil
            self.pendingViewportCommitEpoch = nil
            self.viewportCommitFallbackTask = nil
            RelayDiagnostics.shared.record(
                category: "performance",
                name: "viewport-commit-fallback",
                details: [
                    "pane_id": self.pane?.id.uuidString.lowercased() ?? "unknown",
                    "generation": String(generation),
                ]
            )
            self.finishViewportPresentation(
                revealLatest: self.revealLatestAfterGeometryTransition,
                epoch: epoch
            )
        }
    }

    /// Older workers acknowledge ordinary resize implicitly through their PTY
    /// stream. Hold the local atomic transaction for one bounded repaint
    /// window; a new geometry change cancels this task and starts a newer one.
    private func scheduleUnacknowledgedViewportSettle(epoch: UInt64) {
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let waitsForApplicationFrame = self.pane?.kind != .shell ||
                self.io.isAlternateScreenActive
            try? await Task.sleep(
                for: .milliseconds(waitsForApplicationFrame ? 5_000 : 250)
            )
            guard !Task.isCancelled,
                  self.viewportPresentationEpoch == epoch else { return }
            self.pendingViewportCommitEpoch = nil
            self.viewportCommitFallbackTask = nil
            self.finishViewportPresentation(
                revealLatest: self.revealLatestAfterGeometryTransition,
                epoch: epoch
            )
        }
    }

    private func finishViewportPresentation(revealLatest: Bool, epoch: UInt64) {
        guard epoch == viewportPresentationEpoch else { return }
        let rows = pendingExplicitViewportTarget?.rows ?? latestSurfaceViewport?.rows ?? 0
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Mutate Ghostty's grid only when its matching remote repaint is
            // ready to be delivered in the same ordered presentation turn.
            self.view.layoutSubtreeIfNeeded()
            self.view.setResizeSynchronizationSuspended(false)
            self.view.fitToSize()
            await withCheckedContinuation { continuation in
                self.io.finishViewportTransition(rows: rows) {
                    continuation.resume()
                }
            }
            guard !Task.isCancelled,
                  self.viewportPresentationEpoch == epoch else { return }
            guard self.view.window != nil else {
                self.presentationRecoveryTask = nil
                return
            }
            self.view.setSurfaceVisible(self.presentationAttachment.isPresented)
            self.recoverPresentation(revealLatest: revealLatest, epoch: epoch)
        }
    }

    private func recoverPresentation(revealLatest: Bool, epoch: UInt64) {
        guard viewportPresentationEpoch == epoch else { return }
        presentationRecoveryTask = nil
        guard view.window != nil else { return }
        pendingExplicitViewportTarget = nil
        // TerminalIOBridge has crossed both ordered display queues and waited
        // for Ghostty to parse the complete replacement. One render is enough;
        // retry loops made every resize feel sluggish and could race a newer
        // geometry generation.
        view.layoutSubtreeIfNeeded()
        view.synchronizeAndRedraw()
        if revealLatest {
            _ = view.performBindingAction("scroll_to_bottom")
            _ = view.scrollToRow(UInt.max)
        }
        view.alphaValue = 1
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
            var environment = RelayTerminfo.sessionEnvironment
            environment["RELAY_PANE_ID"] = pane?.id.uuidString ?? ""
            environment["COLORTERM"] = "truecolor"
            environment["TERM_PROGRAM"] = "relay"
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                envVars: environment,
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

    fileprivate func terminalGridGeometry(
        backingScaleFactor: CGFloat
    ) -> (cellSize: CGSize, columns: Int)? {
        guard let metrics = latestSurfaceGridMetrics,
              backingScaleFactor.isFinite, backingScaleFactor > 0,
              metrics.columns > 0,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0
        else { return nil }
        let cellSize = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / backingScaleFactor,
            height: CGFloat(metrics.cellHeightPixels) / backingScaleFactor
        )
        guard cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0
        else { return nil }
        return (cellSize, Int(metrics.columns))
    }

    fileprivate var promptCursorPlacementAllowed: Bool {
        TerminalPromptSelectionEdit.allowsCursorPlacement(
            geometryIsStable: viewportIsAtBottom &&
                !explicitGeometryTransitionPending &&
                pendingViewportCommitEpoch == nil &&
                presentationRecoveryTask == nil,
            alternateScreenIsActive: io.isAlternateScreenActive,
            agentPrompt: forcesLocalPromptSelection
        )
    }

    fileprivate var agentPromptEditingAllowed: Bool {
        guard let pane, pane.kind != .shell else { return false }
        return pane.phase == .quiet || pane.phase == .needsInput
    }

    fileprivate var allowsRemotePromptVisualFallback: Bool {
        pane?.profile.kind == .ssh && pane?.profile.backend == .relay
    }

    fileprivate var bracketedPasteIsActive: Bool {
        io.isBracketedPasteActive
    }

    fileprivate func beginPromptControlTranslationCapture() -> Bool {
        guard pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay else { return false }
        return io.beginPromptControlCapture()
    }

    fileprivate func sendPromptRawInput(_ data: Data) -> Bool {
        guard pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              !data.isEmpty else { return false }
        io.sendPromptControlInput(data)
        return true
    }

    /// Sends a complete prompt from Relay's authenticated local companion.
    /// Newlines are preserved as line breaks but the final carriage return is
    /// the only submit action, matching a paste followed by Return.
    @discardableResult
    func sendSidePanelPrompt(_ text: String) -> Bool {
        guard pane?.contentKind == .terminal,
              !text.isEmpty, text.utf8.count <= 16 << 10 else { return false }
        let prompt = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let payload = TerminalPastePayload.directPayload(
            for: prompt, bracketed: io.isBracketedPasteActive
        ) else { return false }
        if pane?.profile.kind == .ssh, pane?.profile.backend == .relay {
            io.sendUserInput(Data((payload + "\r").utf8))
            pane?.userEnteredInput()
            return true
        }
        view.sendText(payload + "\r")
        pane?.userEnteredInput()
        return true
    }

    func beginSidePanelTerminalMirror(
        deliver: @escaping @Sendable (Data) -> Void,
        viewportChanged: @escaping @Sendable (RelayViewport) -> Void,
        ready: @escaping @Sendable (Data, RelayViewport) -> Void
    ) -> UUID? {
        guard pane?.contentKind == .terminal,
              pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay else { return nil }
        startIfNeeded()
        return io.beginSidePanelMirror(
            deliver: deliver,
            viewportChanged: viewportChanged,
            ready: ready
        )
    }

    func endSidePanelTerminalMirror(_ id: UUID) {
        io.endSidePanelMirror(id)
    }

    @discardableResult
    func sendSidePanelTerminalInput(_ data: Data) -> Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              !data.isEmpty, data.count <= 64 << 10 else { return false }
        io.sendUserInput(data)
        pane?.userEnteredInput()
        return true
    }

    @discardableResult
    func resizeForSidePanel(columns: UInt16, rows: UInt16) -> Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              columns >= 20, rows >= 5 else { return false }
        _ = io.flushPendingResize(
            viewport: RelayViewport(columns: columns, rows: rows),
            forceRepaint: true
        )
        return true
    }

    /// Restores the PTY geometry owned by the native Ghostty surface after an
    /// external browser viewer relinquishes input. The view may not emit a
    /// resize callback because its own frame never changed while backgrounded,
    /// so explicitly compare and commit its last measured grid.
    func reclaimNativeViewportOwnership() {
        guard started,
              pane?.profile.kind == .ssh,
              pane?.profile.backend == .relay,
              presentationAttachment.isPresented,
              view.window != nil else { return }
        view.layoutSubtreeIfNeeded()
        view.fitToSize()
        guard let viewport = latestSurfaceViewport else { return }
        if io.reclaimNativeViewport(
            viewport,
            compatibilityRepaintPulse: pane?.kind != .shell
        ) {
            view.synchronizeAndRedraw()
        }
    }

    fileprivate func recordInputDiagnostic(
        _ name: String,
        details: [String: String] = [:]
    ) {
        guard let pane else { return }
        guard inputDiagnosticCount < 8 else { return }
        inputDiagnosticCount += 1
        var metadata = details
        metadata["pane_id"] = pane.id.uuidString.lowercased()
        metadata["kind"] = pane.kind.rawValue
        metadata["remote"] = String(
            pane.profile.kind == .ssh && pane.profile.backend == .relay
        )
        RelayDiagnostics.shared.record(
            category: "terminal-input",
            name: name,
            details: metadata
        )
    }

    @discardableResult
    fileprivate func endPromptControlTranslationCapture() -> Bool {
        io.endPromptControlCapture()
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

    fileprivate func terminatePane() {
        selectPane()
        NotificationCenter.default.post(name: .relayTerminatePane, object: pane?.id)
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

    fileprivate var promptEditingViewportIsLive: Bool { viewportIsAtBottom }

    fileprivate func userEnteredInput() {
        pane?.userEnteredInput()
    }

    @discardableResult
    func handleApplicationClipboardAction(_ action: RelayClipboardAction) -> Bool {
        guard pane?.contentKind == .terminal else { return false }
        prepareForUserInteraction()
        _ = view.acquireProgrammaticFocus()
        return view.handleApplicationClipboardAction(action)
    }

    @discardableResult
    func handleApplicationUndoAction(redo: Bool) -> Bool {
        guard pane?.contentKind == .terminal else { return false }
        prepareForUserInteraction()
        _ = view.acquireProgrammaticFocus()
        return view.performPromptHistoryAction(redo: redo)
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
                    pane.directory = TerminalPathSyntax.parentDirectory(path)
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
        return TerminalPathSyntax.resolving(path, against: directory)
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
    var onPresentationResumed: (@Sendable () -> Void)?
    var onViewportCommitted: (@Sendable (UInt64) -> Void)?
    var onViewportFrameReady: (@Sendable () -> Void)?
    var onSemanticPromptStateChanged: (@Sendable (Bool) -> Void)?
    private let receiveLock = NSLock()
    private let resizeLock = NSLock()
    private let promptControlLock = NSLock()
    private let presentationLock = NSLock()
    private let displayLock = NSLock()
    private let displayQueue = DispatchQueue(label: "relay.terminal-display", qos: .userInteractive)
    private var displayBuffer = Data()
    private var displayDrainScheduled = false
    /// Live browser companions observe the exact byte stream delivered to
    /// Ghostty. This dictionary is confined to displayQueue so a viewer cannot
    /// contend with terminal input or the PTY reader.
    private struct SidePanelMirrorObserver: Sendable {
        let deliver: @Sendable (Data) -> Void
        let viewportChanged: @Sendable (RelayViewport) -> Void
    }
    private var sidePanelMirrorObservers: [UUID: SidePanelMirrorObserver] = [:]
    private var presentationPaused = false
    private var deferredDisplayBuffer = Data()
    private var deferredDisplayRequiresReconstruction = false
    /// Resize output is withheld until the matching viewport acknowledgement.
    /// Ghostty then sees one replacement repaint instead of intermediate grids
    /// painted over the previous viewport.
    private var viewportTransitionActive = false
    private var viewportTransitionBuffer = Data()
    private var viewportTransitionRemoteSequence: UInt64 = 0
    private var viewportTransitionRequiresClear = false
    private var viewportTransitionFrameRows: UInt16?
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
    private let bracketedPasteTracker = TerminalBracketedPasteStateTracker()
    private let semanticPromptTracker = TerminalSemanticPromptStateTracker()
    private var snapshotWriteWindowStartedAt: DispatchTime?
    private var snapshotScheduledDeadline: DispatchTime?
    private var usesBackgroundSnapshotCadence = false
    private var latestViewport = RelayViewport.default
    private var lastSentViewport: RelayViewport?
    private var resizeTransitionActive = false
    /// Native Ghostty key translation is synchronous. During a prompt-edit
    /// gesture, collect only writes produced on the initiating thread so a
    /// mode-correct sequence (Kitty keyboard, application cursor keys, etc.)
    /// crosses SSH as one packet without swallowing unrelated terminal
    /// replies from another queue.
    private var promptControlCaptureThread: UInt32?
    private var promptControlCaptureBuffer = Data()
    /// Input diagnostics are deliberately bounded and record counts/state only.
    /// They make a dead keyboard diagnosable without retaining terminal text.
    private var inputDiagnosticCount = 0
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
        lastSentViewport = nil
        resizeLock.unlock()
        transport.setInitialViewport(viewport)
        transport.setViewportCommitHandler { [weak self] generation in
            self?.onViewportCommitted?(generation)
        }
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

    func beginSidePanelMirror(
        deliver: @escaping @Sendable (Data) -> Void,
        viewportChanged: @escaping @Sendable (RelayViewport) -> Void,
        ready: @escaping @Sendable (Data, RelayViewport) -> Void
    ) -> UUID {
        let id = UUID()
        displayQueue.async { [weak self] in
            guard let self else { return }
            // Cross the pending display boundary first. The snapshot then
            // precedes every byte observed by the newly registered mirror.
            self.drainDisplay()
            self.receiveLock.lock()
            let snapshot = self.snapshotBuffer
            self.receiveLock.unlock()
            let viewport = self.currentViewport
            self.sidePanelMirrorObservers[id] = SidePanelMirrorObserver(
                deliver: deliver,
                viewportChanged: viewportChanged
            )
            ready(snapshot, viewport)
        }
        return id
    }

    func endSidePanelMirror(_ id: UUID) {
        displayQueue.async { [weak self] in
            self?.sidePanelMirrorObservers.removeValue(forKey: id)
        }
    }

    var isAlternateScreenActive: Bool {
        alternateScreenCleanup.isActive
    }

    var isBracketedPasteActive: Bool {
        bracketedPasteTracker.isActive
    }

    private func terminalDidResize(columns: UInt16, rows: UInt16) {
        let viewport = RelayViewport(columns: columns, rows: rows)
        resizeLock.lock()
        latestViewport = viewport
        if transport != nil, !resizeTransitionActive, viewport != lastSentViewport {
            resizeTimer.schedule(
                deadline: .now() + .milliseconds(TerminalResizePolicy.debounceMilliseconds),
                leeway: .milliseconds(20)
            )
        }
        resizeLock.unlock()
        notifySidePanelViewport(viewport)
    }

    @discardableResult
    func flushPendingResize(
        viewport committedViewport: RelayViewport? = nil,
        forceRepaint: Bool = false,
        compatibilityRepaintPulse: Bool = false
    ) -> UInt64? {
        resizeLock.lock()
        if let committedViewport { latestViewport = committedViewport }
        let viewport = latestViewport
        let transport = self.transport
        let viewportChanged = viewport != lastSentViewport
        resizeTransitionActive = false
        resizeTimer.schedule(deadline: .distantFuture)
        guard forceRepaint || viewportChanged else {
            resizeLock.unlock()
            return nil
        }
        lastSentViewport = viewport
        resizeLock.unlock()
        if committedViewport != nil { notifySidePanelViewport(viewport) }
        // Explicit stable geometry uses the acknowledged commit path whenever
        // the negotiated worker/supervisor promises exactly-one SIGWINCH. The
        // transport falls back to the ordinary resize frame for changed grids
        // on v1 peers, which could otherwise signal the TUI twice.
        return transport?.sendResize(
            columns: viewport.columns,
            rows: viewport.rows,
            forceRepaint: forceRepaint,
            viewportChanged: viewportChanged,
            compatibilityRepaintPulse: compatibilityRepaintPulse
        )
    }

    /// Returns true only when another client changed the committed PTY grid.
    /// Avoid a repaint on ordinary app activation when Relay already owns the
    /// correct dimensions.
    @discardableResult
    func reclaimNativeViewport(
        _ viewport: RelayViewport,
        compatibilityRepaintPulse: Bool
    ) -> Bool {
        resizeLock.lock()
        let needsReclaim = TerminalViewportOwnershipPolicy.needsNativeReclaim(
            native: viewport,
            committed: lastSentViewport
        )
        resizeLock.unlock()
        guard needsReclaim else { return false }
        _ = flushPendingResize(
            viewport: viewport,
            forceRepaint: true,
            compatibilityRepaintPulse: compatibilityRepaintPulse
        )
        return true
    }

    private func notifySidePanelViewport(_ viewport: RelayViewport) {
        displayQueue.async { [weak self] in
            guard let self else { return }
            for observer in self.sidePanelMirrorObservers.values {
                observer.viewportChanged(viewport)
            }
        }
    }

    /// Keep consuming and snapshotting the remote stream while the app is in
    /// the background, but do not spend CPU parsing and rendering every frame.
    /// On resume, one compact reconstruction replaces the accumulated redraws.
    func reconstructPresentation() {
        // Reuse the same ordered, bounded reconstruction barrier as an
        // inactive-window resume without changing transport ownership.
        setPresentationPaused(true)
        setPresentationPaused(false, reconstruct: true)
    }

    func beginViewportTransition(authoritativePrimaryScreen: Bool = false) {
        resizeLock.lock()
        resizeTransitionActive = true
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
        presentationLock.lock()
        viewportTransitionActive = true
        viewportTransitionRequiresClear =
            viewportTransitionRequiresClear || authoritativePrimaryScreen
        viewportTransitionFrameRows = nil
        presentationLock.unlock()
    }

    /// Discard output produced for an intermediate AppKit grid and begin
    /// looking for the first complete frame generated after the committed
    /// SIGWINCH. The callback is one-shot for this transition.
    func armViewportFrameBarrier(rows: UInt16) {
        presentationLock.lock()
        guard viewportTransitionActive else {
            presentationLock.unlock()
            return
        }
        TerminalBufferRetentionPolicy.clear(&viewportTransitionBuffer)
        viewportTransitionRemoteSequence = 0
        viewportTransitionFrameRows = rows
        presentationLock.unlock()
    }

    func finishViewportTransition(
        rows: UInt16,
        completion: (@Sendable () -> Void)? = nil
    ) {
        resizeLock.lock()
        resizeTransitionActive = false
        resizeLock.unlock()
        presentationLock.lock()
        guard viewportTransitionActive else {
            presentationLock.unlock()
            completion?()
            return
        }
        viewportTransitionActive = false
        var replacement = viewportTransitionBuffer
        let remoteSequence = viewportTransitionRemoteSequence
        let requiresClear = viewportTransitionRequiresClear
        TerminalBufferRetentionPolicy.clear(&viewportTransitionBuffer)
        viewportTransitionRemoteSequence = 0
        viewportTransitionRequiresClear = false
        viewportTransitionFrameRows = nil

        guard !replacement.isEmpty else {
            presentationLock.unlock()
            completion?()
            return
        }
        if requiresClear || TerminalViewportRepaintPolicy.needsClearBarrier(replacement, rows: rows) {
            var cleared = Data("\u{001B}[2J\u{001B}[H".utf8)
            cleared.append(replacement)
            replacement = cleared
        }

        receiveLock.lock()
        appendSnapshotLocked(replacement, remoteSequence: remoteSequence)
        receiveLock.unlock()
        // The native surface may be paused while a browser companion is live.
        // Keep one ordered display path; drainDisplay decides independently
        // whether to feed Ghostty, the side-panel observers, or both.
        enqueueDisplayWhilePresentationLocked(replacement, immediate: true)
        presentationLock.unlock()
        guard let completion else { return }
        // Drain explicitly so completion cannot overtake the zero-delay
        // display work item. Waiting for the in-memory backend is the parser
        // barrier that makes the following AppKit redraw deterministic.
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.drainDisplay()
            self.session.waitForPendingOutput()
            completion()
        }
    }

    func setPresentationPaused(_ paused: Bool, reconstruct: Bool = true) {
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
        guard !paused else {
            // Do not steal a scheduled batch from displayQueue. It still has
            // to reach an attached browser companion. drainDisplay will retain
            // the same bytes for native catch-up without parsing them in
            // Ghostty while this pane is hidden.
            presentationLock.unlock()
            return
        }
        let deferred = deferredDisplayBuffer
        TerminalBufferRetentionPolicy.clear(&deferredDisplayBuffer)
        let requiresReconstruction = reconstruct || deferredDisplayRequiresReconstruction
        deferredDisplayRequiresReconstruction = false
        receiveLock.lock()
        let snapshot = snapshotBuffer
        receiveLock.unlock()
        let reconstructionSource = requiresReconstruction
            ? (snapshot.isEmpty ? deferred : snapshot)
            : deferred
        if !reconstructionSource.isEmpty {
            // The retained Ghostty grid normally needs only the ordered bytes
            // missed while paused. If that delta overflowed its safety bound
            // (or a caller explicitly requests recovery), rebuild from the
            // authoritative snapshot instead.
            if requiresReconstruction {
                // Compaction can scan up to the bounded snapshot limit. Queue
                // it ahead of subsequent display drains, but never do that work
                // on MainActor or while holding presentationLock.
                displayQueue.async { [weak self] in
                    guard let self else { return }
                    let compacted = TerminalReplayCompactor.compact(reconstructionSource)
                    var reconstruction = Data("\u{001B}c".utf8)
                    reconstruction.append(compacted)
                    self.presentationLock.lock()
                    if self.presentationPaused {
                        self.deferredDisplayBuffer.append(reconstruction)
                        if self.deferredDisplayBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                            self.deferredDisplayBuffer = TerminalSnapshotStore.bounded(
                                self.deferredDisplayBuffer
                            )
                        }
                        self.presentationLock.unlock()
                    } else {
                        self.presentationLock.unlock()
                        // Reconstruction is native presentation state. Browser
                        // companions already consumed the live stream and must
                        // not receive a duplicate snapshot on every tab switch.
                        self.deliverDisplayBatch(
                            reconstruction,
                            toNative: true,
                            toMirrors: false
                        )
                    }
                }
            } else {
                enqueueDisplayWhilePresentationLocked(reconstructionSource, immediate: true)
            }
        }
        presentationLock.unlock()
        // Cross both ordered queues before telling AppKit that the surface is
        // safe to reveal. This is the same barrier used for reconnect replay.
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.drainDisplay()
            self.session.waitForPendingOutput()
            self.onPresentationResumed?()
        }
    }

    /// Returns true for live output and false for buffered reconstruction data.
    @discardableResult
    func receive(_ data: Data, remoteSequence: UInt64 = 0) -> Bool {
        bracketedPasteTracker.observe(data)
        if let active = semanticPromptTracker.observe(data) {
            onSemanticPromptStateChanged?(active)
        }
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
        presentationLock.lock()
        if viewportTransitionActive {
            viewportTransitionBuffer.append(displayData)
            viewportTransitionRemoteSequence = max(
                viewportTransitionRemoteSequence, remoteSequence
            )
            if viewportTransitionBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                viewportTransitionBuffer = TerminalSnapshotStore.bounded(viewportTransitionBuffer)
            }
            var frameReady = false
            if let rows = viewportTransitionFrameRows {
                frameReady = TerminalViewportRepaintPolicy.hasCompleteReplacement(
                    viewportTransitionBuffer,
                    rows: rows
                )
            }
            let frameReadyCallback = frameReady ? onViewportFrameReady : nil
            if frameReady { viewportTransitionFrameRows = nil }
            presentationLock.unlock()
            frameReadyCallback?()
            return true
        }
        presentationLock.unlock()
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
            if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
                let viewport = currentViewport
                FileHandle.standardError.write(Data(
                    "[RelayTerminal] pane=\(paneID.uuidString.lowercased()) snapshot=miss viewport=\(viewport.columns)x\(viewport.rows)\n".utf8
                ))
            }
            return nil
        }
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            let viewport = currentViewport
            FileHandle.standardError.write(Data(
                "[RelayTerminal] pane=\(paneID.uuidString.lowercased()) snapshot=hit bytes=\(cached.payload.count) viewport=\(viewport.columns)x\(viewport.rows)\n".utf8
            ))
        }
        receiveLock.lock()
        snapshotBuffer = cached.payload
        snapshotRemoteSequence = cached.remoteSequence
        receiveLock.unlock()
        alternateScreenCleanup.observe(cached.payload)
        bracketedPasteTracker.observe(cached.payload)
        if let active = semanticPromptTracker.observe(cached.payload) {
            onSemanticPromptStateChanged?(active)
        }
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
        if !replaying { TerminalBufferRetentionPolicy.clear(&replayBuffer) }
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
                TerminalBufferRetentionPolicy.clear(&replayBuffer)
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
            TerminalBufferRetentionPolicy.clear(&self.replayBuffer)
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
        // Compact at a bounded high-water mark, not after every packet beyond
        // the persisted 2 MiB limit. The store applies the exact disk bound.
        if TerminalSnapshotCompactionPolicy.shouldCompact(byteCount: snapshotBuffer.count) {
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

    func sendUserInput(_ data: Data) {
        guard !data.isEmpty else { return }
        RelayPerformance.shared.recordTerminalInput(bytes: data.count)
        resizeLock.lock()
        let transport = self.transport
        resizeLock.unlock()
        recordInputDiagnostic("bridge-send", details: [
            "bytes": String(data.count),
            "transport": String(transport != nil),
        ])
        transport?.sendInput(data)
    }

    func sendPromptControlInput(_ data: Data) {
        guard !data.isEmpty else { return }
        if capturePromptControlWrite(data) { return }
        sendUserInput(data)
    }

    func beginPromptControlCapture() -> Bool {
        resizeLock.lock()
        let hasRemoteTransport = transport != nil
        resizeLock.unlock()
        guard hasRemoteTransport else { return false }

        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == nil else {
            promptControlLock.unlock()
            return false
        }
        promptControlCaptureThread = thread
        promptControlCaptureBuffer.removeAll(keepingCapacity: true)
        promptControlLock.unlock()
        return true
    }

    @discardableResult
    func endPromptControlCapture() -> Bool {
        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == thread else {
            promptControlLock.unlock()
            return false
        }
        let translated = promptControlCaptureBuffer
        promptControlCaptureBuffer.removeAll(keepingCapacity: true)
        promptControlCaptureThread = nil
        promptControlLock.unlock()
        guard !translated.isEmpty else { return false }
        sendUserInput(translated)
        return true
    }

    private func capturePromptControlWrite(_ data: Data) -> Bool {
        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == thread else {
            promptControlLock.unlock()
            return false
        }
        if promptControlCaptureBuffer.count + data.count <= 64 << 10 {
            promptControlCaptureBuffer.append(data)
        }
        promptControlLock.unlock()
        return true
    }

    private func forwardTerminalWrite(_ data: Data) {
        if capturePromptControlWrite(data) {
            recordInputDiagnostic("ghostty-write-captured", details: [
                "bytes": String(data.count),
            ])
            return
        }
        replayLock.lock()
        let filterDeviceResponses = suppressingTerminalWrites || Date() < filterDeviceResponsesUntil
        replayLock.unlock()
        // Ghostty reports both real user input and renderer-generated terminal
        // replies through this callback. Replay reconstruction must filter the
        // latter, but it must never make the keyboard read-only. The transport
        // already queues input safely until the remote attach completes.
        let shouldForward = TerminalWriteForwardingPolicy.shouldForward(
            data,
            filteringDeviceResponses: filterDeviceResponses
        )
        recordInputDiagnostic("ghostty-write", details: [
            "bytes": String(data.count),
            "filtering": String(filterDeviceResponses),
            "forwarded": String(shouldForward),
        ])
        guard shouldForward else { return }
        sendUserInput(data)
    }

    private func recordInputDiagnostic(
        _ name: String,
        details: [String: String]
    ) {
        promptControlLock.lock()
        guard inputDiagnosticCount < 16 else {
            promptControlLock.unlock()
            return
        }
        inputDiagnosticCount += 1
        promptControlLock.unlock()
        receiveLock.lock()
        let paneID = snapshotPaneID?.uuidString.lowercased() ?? "unknown"
        receiveLock.unlock()
        var metadata = details
        metadata["pane_id"] = paneID
        RelayDiagnostics.shared.record(
            category: "terminal-input",
            name: name,
            details: metadata
        )
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
        // Even with native presentation paused, the display queue remains the
        // ordering boundary for a live browser companion. drainDisplay stores
        // a bounded native reconstruction copy without waking Ghostty.
        enqueueDisplayWhilePresentationLocked(data, immediate: immediate)
        presentationLock.unlock()
    }

    /// Caller owns presentationLock so resume catch-up is ordered before the
    /// first newly arriving live frame.
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
        let delay: DispatchTimeInterval = immediate
            ? .nanoseconds(0)
            : .milliseconds(TerminalDisplayBatchPolicy.liveMilliseconds)
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
                deferredDisplayRequiresReconstruction = true
            }
            presentationLock.unlock()
            guard !batch.isEmpty else { return }
            deliverDisplayBatch(batch, toNative: false, toMirrors: true)
            return
        }
        presentationLock.unlock()
        guard !batch.isEmpty else { return }
        deliverDisplayBatch(batch)
    }

    private func deliverDisplayBatch(
        _ batch: Data,
        toNative: Bool = true,
        toMirrors: Bool = true
    ) {
        autoreleasepool {
            if !toNative, (!toMirrors || sidePanelMirrorObservers.isEmpty) {
                return
            }
            let encoded = ArtifactHyperlinkEncoder.encode(batch)
            if toNative { session.receive(encoded) }
            if toMirrors {
                for observer in sidePanelMirrorObservers.values {
                    observer.deliver(encoded)
                }
            }
            RelayPerformance.shared.recordTerminalBatch(
                bytes: encoded.count,
                pendingBytes: session.pendingOutputByteCount
            )
        }
    }
}

/// Tracks the shell's semantic input region directly from OSC 133. Older
/// durable relayd workers may predate OSC 7 working-directory callbacks, but
/// their prompt still emits `133;B` and `133;C`. Keeping this small state
/// machine in the transport makes remote click-to-move use the same prompt
/// safety gate as a local shell without depending on packet boundaries.
final class TerminalSemanticPromptStateTracker: @unchecked Sendable {
    private enum ParserState {
        case ground
        case escape
        case osc
        case oscEscape
    }

    private let lock = NSLock()
    private var parserState = ParserState.ground
    private var payload: [UInt8] = []
    private var promptActive = false

    /// Returns the newest prompt state only when a complete semantic marker
    /// changes it. Other OSC payloads are ignored and bounded to avoid retaining
    /// terminal titles or clipboard data.
    func observe(_ data: Data) -> Bool? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var changed: Bool?
        for byte in data {
            switch parserState {
            case .ground:
                if byte == 0x1B { parserState = .escape }
            case .escape:
                if byte == 0x5D { // ESC ]
                    payload.removeAll(keepingCapacity: true)
                    parserState = .osc
                } else {
                    parserState = byte == 0x1B ? .escape : .ground
                }
            case .osc:
                if byte == 0x07 { // BEL terminator
                    changed = finishPayload() ?? changed
                    parserState = .ground
                } else if byte == 0x1B {
                    parserState = .oscEscape
                } else if payload.count < 64 {
                    payload.append(byte)
                }
            case .oscEscape:
                if byte == 0x5C { // ST: ESC \
                    changed = finishPayload() ?? changed
                    parserState = .ground
                } else {
                    if payload.count < 63 {
                        payload.append(0x1B)
                        payload.append(byte)
                    }
                    parserState = .osc
                }
            }
        }
        return changed
    }

    private func finishPayload() -> Bool? {
        defer { payload.removeAll(keepingCapacity: true) }
        guard payload.count >= 5,
              payload[0] == 0x31, payload[1] == 0x33, payload[2] == 0x33,
              payload[3] == 0x3B else { return nil }
        let active: Bool
        switch payload[4] {
        case 0x42: active = true  // OSC 133;B — command input begins
        case 0x43: active = false // OSC 133;C — command execution begins
        default: return nil
        }
        guard active != promptActive else { return nil }
        promptActive = active
        return active
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
    // Reset rendition and cursor visibility before erasing. Clearing while a
    // fullscreen program's background SGR is still active paints that color
    // across the primary screen, which looks like htop/watch survived after
    // exit even though the cells themselves were erased.
    private static let cleanup = Data(
        "\u{001B}[0m\u{001B}[?25h\u{001B}[0 q\u{001B}[2J\u{001B}[H".utf8
    )

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var inAlternateScreen = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inAlternateScreen
    }

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
    private struct PreservedPrivateMode {
        let enable: [UInt8]
        let disable: [UInt8]
    }

    /// RIS resets terminal input modes as well as the visible grid. A compacted
    /// replay that starts after the original mode negotiation must restore the
    /// modes that were active at its new boundary or the terminal consumes
    /// wheel/key input locally instead of forwarding it to the TUI.
    private static let preservedPrivateModes = [
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1h".utf8),
            disable: Array("\u{001B}[?1l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1000h".utf8),
            disable: Array("\u{001B}[?1000l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1002h".utf8),
            disable: Array("\u{001B}[?1002l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1003h".utf8),
            disable: Array("\u{001B}[?1003l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1004h".utf8),
            disable: Array("\u{001B}[?1004l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1006h".utf8),
            disable: Array("\u{001B}[?1006l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1007h".utf8),
            disable: Array("\u{001B}[?1007l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?2004h".utf8),
            disable: Array("\u{001B}[?2004l".utf8)
        ),
    ]
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
    private static let synchronizedOutputBegin = Array("\u{001B}[?2026h".utf8)
    private static let synchronizedOutputEnd = Array("\u{001B}[?2026l".utf8)
    // Codex and Claude wrap both complete redraws and tiny spinner/status
    // deltas in synchronized output. The latter are commonly 40–300 bytes and
    // cannot reconstruct the unchanged grid by themselves. A 512-byte floor
    // keeps the latest substantial completed frame as the base, followed by
    // every later incremental frame.
    private static let minimumReplayableSynchronizedFrameBytes = 512

    /// A fresh local surface needs the current screen, not every cursor-addressed
    /// redraw ever emitted by a TUI. Reconstruct from its latest full clear.
    static func compact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let scanned = scan(data)
        let latest = [
            scanned.replayStart,
            scanned.promptStormStart,
            scanned.synchronizedFrameStart,
        ]
            .compactMap { $0 }
            .max()
        guard let latest, latest > data.startIndex else { return data }
        var result = reset
        result.append(privateModePrelude(in: data, before: latest))
        result.append(contentsOf: data[latest...])
        return result
    }

    static func hasCompletedSynchronizedFrame(_ data: Data) -> Bool {
        !data.isEmpty && scan(data).synchronizedFrameStart != nil
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
        let promptStormStart: Int?
        let synchronizedFrameStart: Int?
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
            var promptRedrawCount = 0
            var promptStormStart: Int?
            var synchronizedFrameCandidate: Int?
            var latestCompletedSynchronizedFrame: Int?

            while index < bytes.count {
                guard bytes[index] == 0x1B else {
                    index += 1
                    continue
                }
                if let count = matchingLength(alternateScreenEntries, in: bytes, at: index) {
                    inAlternateScreen = true
                    sawAlternateScreenEntry = true
                    // A synchronized frame that enters the alternate screen
                    // is not independently replayable: it still depends on
                    // the preceding mode switch to preserve the primary shell.
                    synchronizedFrameCandidate = nil
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
                if !inAlternateScreen,
                   sequence(synchronizedOutputBegin, matches: bytes, at: index, before: bytes.count) {
                    // DEC synchronized output gives us an explicit atomic TUI
                    // frame boundary. Codex and Claude redraw rapidly without
                    // clearing the screen; retaining every historical frame
                    // fills the snapshot and makes restore replay thousands of
                    // obsolete cursor updates. Only a completed frame is safe
                    // as a new reconstruction base because the current frame
                    // may still be arriving on another SSH packet.
                    synchronizedFrameCandidate = index
                    index += synchronizedOutputBegin.count
                    continue
                }
                if !inAlternateScreen,
                   sequence(synchronizedOutputEnd, matches: bytes, at: index, before: bytes.count) {
                    if let candidate = synchronizedFrameCandidate,
                       index + synchronizedOutputEnd.count - candidate >=
                       minimumReplayableSynchronizedFrameBytes {
                        latestCompletedSynchronizedFrame = candidate
                    }
                    synchronizedFrameCandidate = nil
                    index += synchronizedOutputEnd.count
                    continue
                }
                if !inAlternateScreen, index + 6 < bytes.count,
                   bytes[index + 1] == 0x5D,
                   bytes[index + 2] == 0x31,
                   bytes[index + 3] == 0x33,
                   bytes[index + 4] == 0x33,
                   bytes[index + 5] == 0x3B {
                    switch bytes[index + 6] {
                    case 0x50: // OSC 133;P — prompt property/redraw
                        promptRedrawCount += 1
                        if promptRedrawCount >= 3 { promptStormStart = index }
                    case 0x43, 0x44: // command start/finished
                        promptRedrawCount = 0
                        promptStormStart = nil
                    default:
                        break
                    }
                }
                if !inAlternateScreen, let count = clearSequenceLength(in: bytes, at: index) {
                    latestPrimaryClear = index
                    promptRedrawCount = 0
                    promptStormStart = nil
                    index += count
                    continue
                }
                index += 1
            }
            return ScanResult(
                replayStart: latestPrimaryClear ?? unmatchedExitEnd,
                promptStormStart: promptStormStart,
                synchronizedFrameStart: latestCompletedSynchronizedFrame,
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

    private static func privateModePrelude(in data: Data, before boundary: Int) -> Data {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let end = min(boundary, bytes.count)
            var enabled = Array(repeating: false, count: preservedPrivateModes.count)
            // Kitty's progressive keyboard protocol is negotiated by the TUI,
            // not by the shell. RIS clears it, so replay compaction must restore
            // the effective flags just like mouse and bracketed-paste modes.
            // Keep the stack while scanning so nested push/pop sequences resolve
            // to the same active mode at the replay boundary.
            var kittyKeyboardStack = [0]
            var index = 0
            while index < end {
                guard bytes[index] == 0x1B else {
                    index += 1
                    continue
                }

                if let command = kittyKeyboardCommand(in: bytes, at: index, before: end) {
                    switch command.operation {
                    case 0x3E: // CSI > flags u — push
                        kittyKeyboardStack.append(command.value ?? 0)
                    case 0x3D: // CSI = flags u — set
                        kittyKeyboardStack[kittyKeyboardStack.count - 1] = command.value ?? 0
                    case 0x3C: // CSI < count u — pop
                        let requested = max(command.value ?? 1, 1)
                        let removable = min(requested, kittyKeyboardStack.count - 1)
                        if removable > 0 {
                            kittyKeyboardStack.removeLast(removable)
                        }
                    default:
                        break
                    }
                    index += command.length
                    continue
                }

                var matched = false
                for (modeIndex, mode) in preservedPrivateModes.enumerated() {
                    if sequence(mode.enable, matches: bytes, at: index, before: end) {
                        enabled[modeIndex] = true
                        index += mode.enable.count
                        matched = true
                        break
                    }
                    if sequence(mode.disable, matches: bytes, at: index, before: end) {
                        enabled[modeIndex] = false
                        index += mode.disable.count
                        matched = true
                        break
                    }
                }
                if !matched { index += 1 }
            }

            var prelude = Data()
            for (modeIndex, mode) in preservedPrivateModes.enumerated()
            where enabled[modeIndex] {
                prelude.append(contentsOf: mode.enable)
            }
            if let keyboardFlags = kittyKeyboardStack.last, keyboardFlags > 0 {
                prelude.append(Data("\u{001B}[=\(keyboardFlags)u".utf8))
            }
            return prelude
        }
    }

    private struct KittyKeyboardCommand {
        let operation: UInt8
        let value: Int?
        let length: Int
    }

    private static func kittyKeyboardCommand(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        before end: Int
    ) -> KittyKeyboardCommand? {
        guard index + 3 < end,
              bytes[index] == 0x1B,
              bytes[index + 1] == 0x5B else { return nil }
        let operation = bytes[index + 2]
        guard operation == 0x3E || operation == 0x3D || operation == 0x3C else { return nil }

        var cursor = index + 3
        var value: Int?
        while cursor < end, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            let digit = Int(bytes[cursor] - 0x30)
            value = min((value ?? 0) * 10 + digit, Int(UInt16.max))
            cursor += 1
        }
        guard cursor < end, bytes[cursor] == 0x75 else { return nil }
        return KittyKeyboardCommand(
            operation: operation,
            value: value,
            length: cursor - index + 1
        )
    }

    private static func sequence(
        _ sequence: [UInt8],
        matches bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        before end: Int
    ) -> Bool {
        guard index + sequence.count <= end else { return false }
        var offset = 0
        while offset < sequence.count, bytes[index + offset] == sequence[offset] {
            offset += 1
        }
        return offset == sequence.count
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

enum TerminalWriteForwardingPolicy {
    /// During replay/startup, only terminal-generated capability responses are
    /// local. User keys, paste, mouse reports, and application key sequences
    /// continue to the transport, where they may be buffered until attach.
    static func shouldForward(_ data: Data, filteringDeviceResponses: Bool) -> Bool {
        guard !data.isEmpty else { return false }
        return !filteringDeviceResponses || !TerminalDeviceResponseFilter.matches(data)
    }
}

extension TerminalRuntime:
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate,
    TerminalSurfaceScrollbarDelegate
{
    func terminalDidResize(_ size: TerminalGridMetrics) {
        latestSurfaceGridMetrics = size
        latestSurfaceViewport = RelayViewport(
            columns: size.columns,
            rows: size.rows
        )
    }

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
        view.shellPromptBecameActive()
        guard pane?.directory != path else { return }
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

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        viewportIsAtBottom = TerminalViewportPosition.isAtBottom(scrollbar)
    }
}

@MainActor
final class RelayGhosttyView: TerminalView {
    private struct PromptSelection {
        let characterCount: Int
        let movementOffset: Int
    }

    weak var owner: TerminalRuntime?
    private var pointerDownPoint: CGPoint?
    private var selectionStart: CGPoint?
    private var selectionStartInWindow: CGPoint?
    private var selectionCanEditPrompt = false
    private var promptSelection: PromptSelection?
    private var keyboardSelectionOffset: Int?
    private var keyboardSelectionIsVisual = false
    private var forcingLocalPromptSelection = false
    private var pendingLocalSelectionMouseDown: NSEvent?
    private var localSelectionDidDrag = false
    private var geometryRevealTask: Task<Void, Never>?
    private var promptBuffer = TerminalPromptBuffer()
    private var promptHistory = TerminalPromptEditHistory()
    private var semanticShellPromptActive = false
    private var hasLocalInputSincePromptBoundary = false
    var didAttachToWindow: (() -> Void)?
    private(set) var relaySurfaceIsVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    /// Relay uses a full-size content view and lets empty chrome move the
    /// window. A terminal surface is never empty chrome: every drag belongs to
    /// Ghostty for selection or mouse reporting. Without this override AppKit
    /// can promote a text-selection drag into a window drag before mouseDragged
    /// reaches the terminal.
    override var mouseDownCanMoveWindow: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setSurfaceVisible(_ visible: Bool) {
        relaySurfaceIsVisible = visible
        super.setSurfaceVisible(visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // A restored workspace with many panes/agent threads can take longer
        // than the representable's initial settling window to enter AppKit's
        // hierarchy. Drive presentation from the real attachment event so a
        // late pane cannot remain a header above an unstarted blank surface.
        didAttachToWindow?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        // SwiftUI may establish the superview before AppKit propagates the
        // containing window. Recheck on the following run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.didAttachToWindow?()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard TerminalGeometry.accepts(newSize) else { return }
        let previousSize = frame.size
        let geometryChanged = newSize.width > 1 &&
            newSize.height > 1 &&
            (abs(previousSize.width - newSize.width) >= 0.5 ||
                abs(previousSize.height - newSize.height) >= 0.5)
        // AppTerminalView fits its grid inside super.setFrameSize(). Suspend
        // that synchronization before the mutation so the outgoing terminal
        // remains presentable throughout the remote resize transaction.
        if window != nil, geometryChanged {
            owner?.beginSurfaceGeometryTransition()
        }
        super.setFrameSize(newSize)
        guard window != nil, geometryChanged else { return }
        settleGeometryBeforeReveal()
    }

    /// Coalesce transitional geometry without hiding or reconstructing the
    /// terminal. The existing surface remains usable while the final grid is
    /// measured.
    private func settleGeometryBeforeReveal() {
        geometryRevealTask?.cancel()
        geometryRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(32))
            } catch {
                return
            }
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.owner?.prepareFinalSurfaceMeasurement()
            self.owner?.fitForStableViewportCommit()
            let commit = self.owner?.commitStableViewport() ?? TerminalStableViewportCommit(
                explicit: false,
                remoteGeneration: nil,
                presentationEpoch: 0
            )
            let mayReveal = self.owner?.finishStableGeometryTransition(commit) ?? true
            guard !Task.isCancelled, self.window != nil else { return }
            _ = mayReveal
            self.alphaValue = 1
            self.geometryRevealTask = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.prepareForUserInteraction()
        // Own the keyboard before publishing the SwiftUI selection change.
        // A floating-pane reorder or tab/zoom transition can reparent this
        // durable view during that notification. The model schedules a second
        // focus claim after its update, covering both sides of the handoff.
        let focused = acquireProgrammaticFocus()
        owner?.recordInputDiagnostic("pointer-down", details: [
            "focus_claimed": String(focused),
            "surface_visible": String(relaySurfaceIsVisible),
            "window_key": String(window?.isKeyWindow == true),
        ])
        owner?.selectPane()
        owner?.focus()
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        let point = terminalPoint(for: event)
        pointerDownPoint = point
        let agentPrompt = owner?.forcesLocalPromptSelection == true
        let canBeginPromptSelection = owner?.allowsPromptSelectionEditing == true &&
            owner?.promptEditingViewportIsLive == true &&
            promptEditingIsSemanticallyActive &&
            (agentPrompt || pointIsNearActivePrompt(point))
        // Codex and Claude commonly keep terminal mouse reporting enabled.
        // Give an ordinary drag native macOS text-selection semantics across
        // the whole transcript, then replay a genuine click to the TUI when
        // the gesture never became a drag. Prompt deletion remains gated by
        // `selectionCanEditPrompt`, so selecting old output can never edit the
        // live composer.
        selectionStart = (canBeginPromptSelection || agentPrompt) ? point : nil
        selectionStartInWindow = selectionStart == nil ? nil : event.locationInWindow
        selectionCanEditPrompt = canBeginPromptSelection
        forcingLocalPromptSelection = selectionStart != nil && agentPrompt
        localSelectionDidDrag = false
        if forcingLocalPromptSelection {
            // Do not commit the terminal selection mode until AppKit proves
            // this is a drag. A focus click can otherwise be coalesced with a
            // subsequent drag as a double/triple click, expanding a precise
            // character selection to word or line boundaries. A genuine click
            // is replayed to the TUI from mouseUp instead.
            pendingLocalSelectionMouseDown = event
        } else {
            pendingLocalSelectionMouseDown = nil
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forcingLocalPromptSelection else {
            super.mouseDragged(with: event)
            return
        }
        if let pending = pendingLocalSelectionMouseDown {
            pendingLocalSelectionMouseDown = nil
            super.mouseDown(with: localSelectionEvent(from: pending, clickCount: 1) ?? pending)
        }
        localSelectionDidDrag = true
        super.mouseDragged(with: localSelectionEvent(from: event, clickCount: 1) ?? event)
    }

    override func mouseUp(with event: NSEvent) {
        let start = selectionStart
        let pointerStart = pointerDownPoint
        let caretLocation = selectionStartInWindow
        let canEditPrompt = selectionCanEditPrompt
        let end = terminalPoint(for: event)
        let forcedLocalSelection = forcingLocalPromptSelection
        let pendingLocalDown = pendingLocalSelectionMouseDown
        let completedLocalDrag = localSelectionDidDrag
        var handledLocalSelectionClick = false
        if forcedLocalSelection {
            if completedLocalDrag {
                super.mouseUp(with: localSelectionEvent(from: event, clickCount: 1) ?? event)
            } else if let pendingLocalDown,
                      pendingLocalDown.clickCount > 1 ||
                        !pendingLocalDown.modifierFlags
                            .intersection([.command, .option, .control, .shift]).isEmpty {
                // Preserve deliberate word/line selection and modified-click
                // selection. Ordinary single clicks belong to the agent TUI.
                super.mouseDown(with: localSelectionEvent(from: pendingLocalDown) ?? pendingLocalDown)
                super.mouseUp(with: localSelectionEvent(from: event) ?? event)
                handledLocalSelectionClick = true
            }
        } else {
            super.mouseUp(with: event)
        }
        selectionStart = nil
        pointerDownPoint = nil
        selectionStartInWindow = nil
        selectionCanEditPrompt = false
        forcingLocalPromptSelection = false
        pendingLocalSelectionMouseDown = nil
        localSelectionDidDrag = false
        if handledLocalSelectionClick { return }
        let clickDistance = pointerStart.map { hypot(end.x - $0.x, end.y - $0.y) }
        let unmodified = event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        if let clickDistance, clickDistance < 4, unmodified {
            // Open links only after this has proven to be a click. Opening on
            // mouse-down made paths and URLs impossible to drag-select and
            // therefore impossible to copy from Codex/Claude transcripts.
            if owner?.openHoveredLink() == true { return }
            if forcedLocalSelection {
                // Alternate-screen applications own their pointer protocol.
                replayAgentClick(at: event.locationInWindow)
                return
            }
            if placePromptCursor(at: event.locationInWindow) {
                return
            }
        }
        guard canEditPrompt, let start, let caretLocation,
              hypot(end.x - start.x, end.y - start.y) >= 2,
              selectionIsNearActivePrompt(start: start, end: end),
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
        if event.timestamp > 0 {
            RelayPerformance.shared.recordKeyDispatchLatency(
                milliseconds: max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000
                )
            )
        }
        owner?.prepareForUserInteraction()
        owner?.recordInputDiagnostic("key-down", details: [
            "first_responder": String(window?.firstResponder === self),
            "surface_visible": String(relaySurfaceIsVisible),
        ])
        if handlePromptHistoryShortcut(event) { return }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           importFiles(from: NSPasteboard.general) {
            invalidatePromptMirror()
            return
        }
        if handleKeyboardPromptSelection(event) {
            invalidatePromptMirror()
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let promptSelection {
            self.promptSelection = nil
            keyboardSelectionOffset = nil
            keyboardSelectionIsVisual = false
            sendPromptEdit(promptSelection)
            invalidatePromptMirror()
            return
        }
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        trackNonTextKey(event)
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        owner?.prepareForUserInteraction()
        let text: String?
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String
        }
        if let text, !text.isEmpty {
            owner?.recordInputDiagnostic("insert-text", details: [
                "characters": String(text.count),
            ])
            hasLocalInputSincePromptBoundary = true
            recordPromptEdit(.typing)
            promptBuffer.insert(text)
            if !promptBuffer.isReliable { promptHistory.reset() }
            owner?.userEnteredInput()
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    @discardableResult
    func handleApplicationClipboardShortcut(_ event: NSEvent) -> Bool {
        // Own the standard macOS editing shortcuts. Delegating these through
        // Ghostty's binding lookup made them dependent on the active terminal
        // mode and key-equivalent echo path, which can differ after an SSH
        // reconnect or while an agent TUI has application keyboard mode set.
        // Command always means a local clipboard operation in Relay.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                return handleApplicationClipboardAction(.copy)
            case "v":
                return handleApplicationClipboardAction(.paste)
            case "a":
                return handleApplicationClipboardAction(.selectAll)
            default:
                break
            }
        }
        return false
    }

    @discardableResult
    func handleApplicationClipboardAction(_ action: RelayClipboardAction) -> Bool {
        switch action {
        case .copy:
            return copyRelaySelectionToPasteboard()
        case .paste:
            return pasteFromClipboard()
        case .selectAll:
            return performBindingAction("select_all")
        }
    }

    @IBAction override func copy(_ sender: Any?) {
        _ = copyRelaySelectionToPasteboard()
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = performBindingAction("select_all")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePromptHistoryShortcut(event) { return true }
        if handleApplicationClipboardShortcut(event) { return true }
        // Shift-Return can be offered to AppKit's key-equivalent chain instead
        // of keyDown (notably after a terminal has been reparented, floated, or
        // restored). Replay it through the normal Ghostty keyboard translator
        // so negotiated Kitty keyboard mode still produces CSI 13;2u rather
        // than submitting the agent prompt.
        if event.type == .keyDown,
           (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            keyDown(with: event)
            return true
        }
        // AppKit offers navigation keys to the key-equivalent chain before it
        // delivers keyDown. Intercept Shift+Arrow here as well so keyboard
        // prompt selection is reliable with hardware keyboards and synthetic
        // accessibility input alike.
        if event.type == .keyDown, handleKeyboardPromptSelection(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handlePromptHistoryShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else { return false }
        return performPromptHistoryAction(redo: event.modifierFlags.contains(.shift))
    }

    @discardableResult
    func performPromptHistoryAction(redo: Bool) -> Bool {
        let hasRequestedHistory = redo ? promptHistory.canRedo : promptHistory.canUndo
        guard let current = promptBuffer.snapshot,
              promptEditingIsSemanticallyActive || hasRequestedHistory else { return false }
        let target = redo
            ? promptHistory.redo(current: current)
            : promptHistory.undo(current: current)
        guard let target else { return false }
        return restorePromptSnapshot(target, replacing: current)
    }

    private func recordPromptEdit(_ kind: TerminalPromptEditHistory.Kind) {
        guard let snapshot = promptBuffer.snapshot else {
            promptHistory.reset()
            return
        }
        promptHistory.record(before: snapshot, kind: kind)
    }

    /// Reconcile the remote editor using its negotiated keyboard mode. Moving
    /// to the end and backspacing is understood by shells, Codex, and Claude;
    /// embedded newlines are recreated with genuine Shift-Return events so an
    /// undo can never accidentally submit the prompt.
    private func restorePromptSnapshot(
        _ target: TerminalPromptBuffer.Snapshot,
        replacing current: TerminalPromptBuffer.Snapshot
    ) -> Bool {
        guard window != nil, target.characters.count <= 4_096 else {
            promptHistory.reset()
            return false
        }
        let capturesRemotePacket = owner?.beginPromptControlTranslationCapture() == true
        defer {
            if capturesRemotePacket { owner?.endPromptControlTranslationCapture() }
        }

        for _ in current.cursor..<current.characters.count {
            sendSyntheticPromptKey(124)
        }
        if !current.characters.isEmpty {
            let deletion = Data(repeating: 0x7F, count: current.characters.count)
            if owner?.sendPromptRawInput(deletion) != true {
                for _ in current.characters { sendSyntheticPromptKey(51) }
            }
        }

        var plainText = ""
        func flushPlainText() {
            guard !plainText.isEmpty else { return }
            sendPromptPlainText(plainText)
            plainText.removeAll(keepingCapacity: true)
        }
        for character in target.characters {
            if character.isNewline {
                flushPlainText()
                sendSyntheticPromptKey(36, modifiers: .shift)
            } else {
                plainText.append(character)
            }
        }
        flushPlainText()
        for _ in target.cursor..<target.characters.count {
            sendSyntheticPromptKey(123)
        }

        promptBuffer.restore(target)
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        hasLocalInputSincePromptBoundary = !target.characters.isEmpty
        owner?.userEnteredInput()
        return true
    }

    private func sendPromptPlainText(_ text: String) {
        if owner?.sendPromptRawInput(Data(text.utf8)) != true {
            // `insertText` is an NSTextInputClient callback, not a reliable
            // programmatic write path: AppKit may suppress it while an undo
            // key equivalent is still being dispatched. Ghostty's public raw
            // text path writes synchronously to the local PTY and avoids
            // recursively recording the restored text as a new edit.
            sendText(text)
        }
    }

    private func handleKeyboardPromptSelection(_ event: NSEvent) -> Bool {
        // Agent detection is asynchronous after an attach. Local input is
        // sufficient evidence that this terminal currently owns an editable
        // prompt, so Shift-arrow selection must not depend on the sidebar
        // having already relabeled the pane from Shell to Codex/Claude.
        guard owner?.allowsPromptSelectionEditing == true,
              (promptEditingIsSemanticallyActive || hasLocalInputSincePromptBoundary),
              event.modifierFlags.contains(.shift),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              event.keyCode == 123 || event.keyCode == 124
        else { return false }

        let delta = event.keyCode == 123 ? -1 : 1
        promptHistory.breakCoalescing()
        let next = (keyboardSelectionOffset ?? 0) + delta
        if next == 0 {
            keyboardSelectionOffset = nil
            promptSelection = nil
            keyboardSelectionIsVisual = false
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
        guard delta != 0, abs(delta) <= 4_096,
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
        let origin: CGPoint
        let point: CGPoint
        let cellSize: CGSize
        let columns: Int
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
        let exactGrid = owner?.terminalGridGeometry(
            backingScaleFactor: window.backingScaleFactor
        )
        let fallback = fallbackCellSize()
        // A bar cursor can legitimately expose a zero-width IME rectangle.
        // The origin is still authoritative; use the configured monospace
        // metrics only for missing dimensions.
        let cellSize = CGSize(
            width: exactGrid?.cellSize.width ?? (localRect.width >= 2 ? localRect.width : fallback.width),
            height: exactGrid?.cellSize.height ?? (localRect.height >= 2 ? localRect.height : fallback.height)
        )
        let cursorTop = bounds.height - localRect.maxY
        let origin = CGPoint(x: localRect.minX, y: cursorTop)
        let point = CGPoint(
            x: origin.x + cellSize.width / 2,
            y: origin.y + cellSize.height / 2
        )
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= bounds.width,
              point.y >= 0, point.y <= bounds.height,
              cellSize.width > 0, cellSize.height > 0
        else { return nil }
        let columns = exactGrid?.columns ?? max(1, Int(floor(bounds.width / cellSize.width)))
        return CursorGeometry(
            origin: origin,
            point: point,
            cellSize: cellSize,
            columns: columns
        )
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

    private func invalidatePromptMirror() {
        promptBuffer.invalidate()
        promptHistory.reset()
    }

    private func trackNonTextKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.shift),
               flags.intersection([.command, .control, .option]).isEmpty {
                hasLocalInputSincePromptBoundary = true
                recordPromptEdit(.typing)
                promptBuffer.insert("\n")
                if !promptBuffer.isReliable { promptHistory.reset() }
                return
            }
            setShellPromptActive(false)
            _ = promptBuffer.submit()
            promptHistory.reset()
            hasLocalInputSincePromptBoundary = false
            return
        }
        if event.keyCode == 48 {
            invalidatePromptMirror()
            return
        }
        if command && key == "v" {
            if let pasted = NSPasteboard.general.string(forType: .string) {
                hasLocalInputSincePromptBoundary = true
                recordPromptEdit(.paste)
                promptBuffer.insert(pasted)
                if !promptBuffer.isReliable { promptHistory.reset() }
            } else {
                invalidatePromptMirror()
            }
            return
        }
        if control {
            switch key {
            case "a":
                promptHistory.breakCoalescing()
                promptBuffer.moveToStart()
            case "e":
                promptHistory.breakCoalescing()
                promptBuffer.moveToEnd()
            case "u":
                if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
                promptBuffer.deleteToStart()
            case "k":
                if !promptBuffer.isAtEnd { recordPromptEdit(.deleting) }
                promptBuffer.deleteToEnd()
            case "w":
                if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
                promptBuffer.deletePreviousWord()
            case "c":
                promptBuffer.clear()
                promptHistory.reset()
            case "l": break
            default: invalidatePromptMirror()
            }
            return
        }
        switch event.keyCode {
        case 51:
            if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
            if command { promptBuffer.deleteToStart() }
            else if option { promptBuffer.deletePreviousWord() }
            else { promptBuffer.backspace() }
        case 117:
            if !promptBuffer.isAtEnd { recordPromptEdit(.deleting) }
            promptBuffer.deleteForward()
        case 123:
            promptHistory.breakCoalescing()
            promptBuffer.move(by: -1)
        case 124:
            promptHistory.breakCoalescing()
            promptBuffer.move(by: 1)
        case 115:
            promptHistory.breakCoalescing()
            promptBuffer.moveToStart()
        case 119:
            promptHistory.breakCoalescing()
            promptBuffer.moveToEnd()
        case 125, 126: invalidatePromptMirror()
        default:
            if command || option { return }
            return
        }
    }

    private func cursorMovementOffset(to locationInWindow: CGPoint) -> Int? {
        guard let geometry = activeCursorGeometry() else { return nil }
        let local = convert(locationInWindow, from: nil)
        let target = CGPoint(x: local.x, y: bounds.height - local.y)
        guard let visualOffset = TerminalPromptSelectionEdit.cursorMovementOffset(
            cursorOrigin: geometry.origin,
            target: target,
            cellSize: geometry.cellSize,
            columns: geometry.columns
        ) else { return nil }
        let promptMirrorIsReliable = promptBuffer.isReliable
        return TerminalPromptSelectionEdit.resolvedMovementOffset(
            visualOffset: visualOffset,
            mirroredOffset: promptBuffer.logicalMovementOffset(
                forVisualCellDelta: visualOffset
            ),
            mirrorIsReliable: promptMirrorIsReliable,
            allowsRemoteVisualFallback: owner?.allowsRemotePromptVisualFallback == true &&
                (semanticShellPromptActive ||
                    owner?.agentPromptEditingAllowed == true ||
                    hasLocalInputSincePromptBoundary)
        )
    }

    private func placePromptCursor(at locationInWindow: CGPoint) -> Bool {
        let point = terminalPointForWindowLocation(locationInWindow)
        guard owner?.allowsPromptSelectionEditing == true,
              owner?.promptCursorPlacementAllowed == true,
              promptEditingIsSemanticallyActive,
              pointIsNearActivePrompt(point),
              let movementOffset = cursorMovementOffset(to: locationInWindow)
        else { return false }

        window?.makeFirstResponder(self)
        guard movementOffset != 0 else { return true }
        promptHistory.breakCoalescing()
        sendPromptControl(movementOffset: movementOffset)
        promptBuffer.move(by: movementOffset)
        return true
    }

    func shellPromptBecameActive() {
        setShellPromptActive(true)
    }

    func setShellPromptActive(_ active: Bool) {
        semanticShellPromptActive = active
        if !active {
            promptSelection = nil
            keyboardSelectionOffset = nil
            keyboardSelectionIsVisual = false
        }
    }

    /// A remote snapshot/replay is visual terminal state, not proof that Relay
    /// observed the complete editable line. Keep semantic prompt state but
    /// discard the local text mirror so mouse placement cannot clamp itself to
    /// only the suffix typed after reconnect.
    func remoteTerminalStateWasRestored() {
        promptBuffer.invalidate()
        promptHistory.reset()
        hasLocalInputSincePromptBoundary = false
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
    }

    private var promptEditingIsSemanticallyActive: Bool {
        TerminalPromptSelectionEdit.promptEditingIsActive(
            agentPrompt: owner?.forcesLocalPromptSelection == true,
            hasLocalInput: hasLocalInputSincePromptBoundary,
            agentPhaseAllowsEditing: owner?.agentPromptEditingAllowed == true,
            semanticShellPromptActive: semanticShellPromptActive
        )
    }

    private func terminalPointForWindowLocation(_ locationInWindow: CGPoint) -> CGPoint {
        let local = convert(locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func sendPromptEdit(_ selection: PromptSelection) {
        guard selection.characterCount > 0, selection.characterCount <= 4_096,
              abs(selection.movementOffset) <= 4_096 else { return }
        sendPromptControl(
            movementOffset: selection.movementOffset,
            deletionCount: selection.characterCount
        )
        let relativeOffset = selection.movementOffset > 0
            ? selection.characterCount
            : -selection.characterCount
        recordPromptEdit(.deleting)
        if !promptBuffer.deleteSelection(relativeToCursor: relativeOffset) {
            invalidatePromptMirror()
        }
    }

    private func sendPromptControl(movementOffset: Int, deletionCount: Int = 0) {
        guard abs(movementOffset) <= 4_096,
              deletionCount >= 0, deletionCount <= 4_096 else { return }
        guard movementOffset != 0 || deletionCount != 0 else { return }

        // Always let Ghostty translate keys against the live terminal mode.
        // Codex and Claude can enable Kitty keyboard or application-cursor
        // modes, where hard-coded ESC [ D/C is not equivalent to an actual
        // arrow key. Remote panes capture these synchronous translated writes
        // and flush them as one SSH packet; local panes forward them directly.
        let capturesRemotePacket = owner?.beginPromptControlTranslationCapture() == true
        defer {
            if capturesRemotePacket { owner?.endPromptControlTranslationCapture() }
        }
        let movementKey: UInt16 = movementOffset < 0 ? 123 : 124
        for _ in 0..<abs(movementOffset) { sendSyntheticPromptKey(movementKey) }
        for _ in 0..<deletionCount { sendSyntheticPromptKey(51) }
    }

    private func sendSyntheticPromptKey(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let window else { return }
        let characters: String
        switch keyCode {
        case 123: characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: characters = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 36: characters = "\r"
        default: characters = "\u{007F}"
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
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

    private func localSelectionEvent(
        from event: NSEvent,
        clickCount: Int? = nil
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.union(.shift),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: clickCount ?? event.clickCount,
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
        owner?.prepareForUserInteraction()
        _ = acquireProgrammaticFocus()
        owner?.selectPane()
        owner?.focus()
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
        if owner?.paneIsRemote == true {
            menu.addItem(item(
                "Terminate Remote Pane…",
                action: #selector(terminateRelayPane),
                enabled: true
            ))
        }
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

    @objc private func copyRelay() { _ = copyRelaySelectionToPasteboard() }
    @objc private func pasteRelay() { _ = pasteFromClipboard() }
    @objc private func selectAllRelay() { _ = performBindingAction("select_all") }
    @objc private func clearScrollback() { _ = performBindingAction("clear_scrollback") }
    @objc private func previousPrompt() { _ = owner?.jumpToPrompt(by: -1) }
    @objc private func nextPrompt() { _ = owner?.jumpToPrompt(by: 1) }
    @objc private func splitRight() { owner?.split(.horizontal) }
    @objc private func splitDown() { owner?.split(.vertical) }
    @objc private func closeRelayPane() { owner?.closePane() }
    @objc private func terminateRelayPane() { owner?.terminatePane() }

    private func importFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls = localFileURLs(from: pasteboard)
        return !urls.isEmpty && owner?.importLocalFiles(urls) == true
    }

    @discardableResult
    private func pasteFromClipboard() -> Bool {
        owner?.prepareForUserInteraction()
        if importFiles(from: NSPasteboard.general) {
            invalidatePromptMirror()
            return true
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        if let payload = TerminalPastePayload.directPayload(
            for: text,
            bracketed: owner?.bracketedPasteIsActive == true
        ) {
            if owner?.sendCapturedPaste(payload) != true {
                sendText(payload)
            }
        } else {
            // Unbracketed multi-line pastes keep Ghostty's existing safety
            // confirmation. Single-line and bracketed payloads above use the
            // already-captured value and therefore cannot race a clipboard
            // manager restoring the pasteboard.
            guard performBindingAction("paste_from_clipboard") else { return false }
        }

        // Clipboard input bypasses insertText/keyDown, so keep the semantic
        // prompt mirror in sync explicitly for cursor placement.
        hasLocalInputSincePromptBoundary = true
        recordPromptEdit(.paste)
        promptBuffer.insert(text)
        if !promptBuffer.isReliable { promptHistory.reset() }
        owner?.userEnteredInput()
        return true
    }

    /// Prefer Ghostty's rendered selection, then fall back to Relay's exact
    /// prompt mirror for keyboard selections. The fallback matters for
    /// alternate-screen agent composers: they may repaint between a
    /// Shift-arrow event and Command-C, clearing the renderer selection even
    /// though the logical selection is still valid.
    @discardableResult
    private func copyRelaySelectionToPasteboard() -> Bool {
        if copySelectedTextToPasteboard(),
           let rendered = NSPasteboard.general.string(forType: .string),
           !rendered.isEmpty {
            return true
        }
        guard let offset = keyboardSelectionOffset,
              let text = promptBuffer.selectedText(relativeToCursor: offset),
              !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
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

    func sendCapturedPaste(_ payload: String) -> Bool {
        guard paneIsRemote, !payload.isEmpty else { return false }
        io.sendUserInput(Data(payload.utf8))
        return true
    }
}

extension Notification.Name {
    static let relaySelectPane = Notification.Name("relay.select-pane")
    static let relaySplitRight = Notification.Name("relay.split-right")
    static let relaySplitDown = Notification.Name("relay.split-down")
    static let relayClosePane = Notification.Name("relay.close-pane")
    static let relayTerminatePane = Notification.Name("relay.terminate-pane")
    static let relayOpenRemoteFile = Notification.Name("relay.open-remote-file")
    static let relayClipboardRequest = Notification.Name("relay.clipboard-request")
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
        var attachmentGeneration: UInt64?
        var presentationTask: Task<Void, Never>?
        var isPresented = false
        var isDismantled = false
        var candidateSize: CGSize?
        var stableSizeSamples = 0

        deinit { presentationTask?.cancel() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RelayGhosttyView {
        let view = pane.runtime.view
        let coordinator = context.coordinator
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[RelaySurface] make pane=\(pane.id.uuidString.lowercased()) view=\(ObjectIdentifier(view))\n".utf8
            ))
        }
        coordinator.isDismantled = false
        coordinator.attachmentGeneration = pane.runtime.beginPresentationAttachment(
            lease: coordinator.presentationLease
        )
        view.didAttachToWindow = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            presentAfterLayout(view, coordinator: coordinator)
        }
        // Reuse Ghostty's last settled IOSurface immediately. Stable-layout
        // measurement below will replace it at the destination grid, but a
        // normal tab switch must never insert an artificial black frame.
        view.alphaValue = 1
        view.setSurfaceVisible(true)
        view.synchronizeAndRedraw()
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
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[RelaySurface] dismantle view=\(ObjectIdentifier(nsView))\n".utf8
            ))
        }
        coordinator.isDismantled = true
        coordinator.presentationTask?.cancel()
        coordinator.presentationTask = nil
        coordinator.isPresented = false
        coordinator.candidateSize = nil
        coordinator.stableSizeSamples = 0
        // The same durable terminal view can be reattached by another tab or
        // zoom layout. Keep its previous IOSurface hidden until that layout is
        // stable instead of briefly stretching the old cell grid.
        if let generation = coordinator.attachmentGeneration {
            nsView.owner?.endPresentationAttachment(
                lease: coordinator.presentationLease,
                generation: generation
            )
        }
        coordinator.attachmentGeneration = nil
    }

    private func presentAfterLayout(_ view: RelayGhosttyView, coordinator: Coordinator) {
        guard !coordinator.isDismantled,
              !coordinator.isPresented,
              coordinator.presentationTask == nil else { return }
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

                pane.runtime.prepareFinalSurfaceMeasurement()
                pane.runtime.fitForStableViewportCommit()
                let commit = pane.runtime.commitStableViewport()
                let mayReveal = pane.runtime.finishStableGeometryTransition(commit)
                // Snapshot and remote replay bytes must not reach Ghostty
                // until its final pane grid exists. Feeding them after merely
                // one run-loop yield makes multi-pane launches interpret a
                // TUI redraw at the outgoing/full-window width; later resize
                // cannot reconstruct cursor-addressed output and leaves the
                // familiar vertical/garbled columns.
                pane.runtime.startIfNeeded()
                guard let attachmentGeneration = coordinator.attachmentGeneration else { return }
                pane.runtime.setPresented(
                    true,
                    lease: coordinator.presentationLease,
                    generation: attachmentGeneration,
                    force: true
                )

                guard !Task.isCancelled, view.window != nil else { return }
                if mayReveal { view.alphaValue = 1 }
                coordinator.isPresented = true
                coordinator.presentationTask = nil
                return
            }
            // Extremely busy restored workspaces can attach the NSView after
            // the initial settling samples have elapsed. Keep retrying only
            // while this representable is alive; dismantling cancels the
            // lifecycle so hidden tabs consume no polling work.
            coordinator.presentationTask = nil
            guard !coordinator.isDismantled else { return }
            if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
                FileHandle.standardError.write(Data(
                    "[RelaySurface] unsettled view=\(ObjectIdentifier(view)) window=\(view.window != nil) bounds=\(view.bounds.width)x\(view.bounds.height)\n".utf8
                ))
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !coordinator.isDismantled else { return }
            presentAfterLayout(view, coordinator: coordinator)
        }
    }
}
