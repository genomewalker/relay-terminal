//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit
import MSDisplayLink
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via scheduled wakeups.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    /// The callback bridge of the current surface generation. Each surface
    /// gets its own: a retired surface whose release is deferred keeps its
    /// bridge (and that bridge's `rawSurface`) until it is freed, so its late
    /// callbacks never route through, or drop the retention of, a replacement.
    private(set) var bridge = TerminalCallbackBridge()

    #if canImport(AppKit) && !canImport(UIKit)
        /// The pasteboard every generation's bridge uses; nil means the general one.
        var pasteboard: NSPasteboard? {
            didSet { bridge.pasteboard = pasteboard }
        }
    #endif

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    /// Called after every display-link render (`tick`).
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?
    var onContentUpdate: (() -> Void)?
    /// True while the view has IME marked text. A full rebuild waits for it:
    /// the rebuild lever is an empty preedit, which would cancel composition.
    var isComposing: () -> Bool = { false }
    /// Tests observe applied full rebuilds here instead of on a surface.
    var fullRebuildOverride: ((TerminalRepaintReason) -> Void)?
    private(set) var repaintStatistics = TerminalRepaintStatistics()
    /// A full rebuild that could not run yet, redeemed by the next frame.
    private var fullRepaintOwed: TerminalRepaintReason?
    private var trailingRepaint: Task<Void, Never>?
    private var settleRepaint: Task<Void, Never>?
    private var lastDamageUptime: TimeInterval?
    private var damageSinceUptime: TimeInterval?
    private var inspectionWidthPixels: UInt32?
    private var inspectionSuppressesRendering = false

    private var lastMetrics: TerminalViewportMetrics?
    private var isDisplayVisible = true
    /// The last visibility the SwiftUI host declared through
    /// `TerminalViewState.isSurfaceVisible`. The representable forwards only
    /// changes to this value, so an imperative `setSurfaceVisible` call made
    /// between SwiftUI updates is not silently reverted by every refresh
    /// re-stamping the declarative default.
    var hostDeclaredDisplayVisible: Bool?
    private var isApplicationActive = true
    private var pendingImmediateTick = true
    private var lastTickTimestamp: TimeInterval = 0
    private var isSurfaceFocused = false

    /// Held only while frames are owed. The engine's wakeups arrive at PTY
    /// speed, not display speed; rendering straight from them draws far more
    /// often than the screen can show and starves input handling under heavy
    /// output. The link paces draws to vsync (60 fps cap) instead, and is
    /// released after a stretch of idle frames so a quiet terminal costs no
    /// per-frame wakeups at all. All instances share one platform link.
    private var displayLinkRegistration: UUID?
    private var idleFrameCount = 0
    private var isRenderingFrame = false
    private var deferredAnimationTick: Task<Void, Never>?
    private var animationBurstFramesRemaining = 0
    private static let idleFramesBeforeRelease = 30

    init() {
        connect(bridge)
    }

    /// Points a bridge's view-facing callbacks at this coordinator.
    private func connect(_ bridge: TerminalCallbackBridge) {
        bridge.delegate = delegate
        #if canImport(AppKit) && !canImport(UIKit)
            bridge.pasteboard = pasteboard
        #endif
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
        bridge.onRenderRequest = { [weak self] in
            self?.onContentUpdate?()
            self?.requestImmediateTick()
        }
    }

    func requestImmediateTick() {
        // Ghostty asks for another render from inside controller.tick() while
        // cursor/blink animation remains armed. Treat that as a low-frequency
        // animation deadline, not fresh PTY damage; otherwise a quiet terminal
        // pins the shared display link at 60 fps forever. Output, input, resize,
        // and focus requests arrive outside the frame and still render at the
        // next vsync.
        if isRenderingFrame {
            if animationBurstFramesRemaining > 0 {
                animationBurstFramesRemaining -= 1
                pendingImmediateTick = true
                ensureDisplayLink()
                return
            }
            repaintStatistics.deferredAsAnimation += 1
            scheduleDeferredAnimationTick()
            return
        }
        armFrameBurst()
        noteDamage()
    }

    /// Fresh PTY damage, input, focus, resize and full repaints receive a
    /// short full-rate burst for smooth interactive animation. A
    /// self-sustaining cursor request cannot keep extending the burst by
    /// itself.
    private func armFrameBurst() {
        deferredAnimationTick?.cancel()
        deferredAnimationTick = nil
        animationBurstFramesRemaining = 8
        pendingImmediateTick = true
        ensureDisplayLink()
    }

    // MARK: - Full Repaint

    /// Repaints the whole viewport: every row is rebuilt from the terminal,
    /// exactly as a resize would, and a frame is armed. Output keeps
    /// repainting only the rows it damaged; this is for the transitions
    /// (size, scale, scroll, replay, visibility) after which a stale row
    /// would otherwise survive until the next resize.
    ///
    /// Never downgraded to the 250 ms animation tick, and applied after any
    /// occlusion change the caller made, so the renderer is visible when it
    /// rebuilds.
    func requestFullRepaint(_ reason: TerminalRepaintReason) {
        repaintStatistics.requested[reason, default: 0] += 1
        TerminalDebugLog.log(.render, "full repaint requested reason=\(reason.rawValue)")
        applyOrOweFullRepaint(reason, counting: true)
        if TerminalRepaintPolicy.needsTrailingRepaint(reason) {
            scheduleTrailingRepaint(reason)
        }
        if canRenderFrame { armFrameBurst() }
    }

    private var canApplyFullRepaint: Bool {
        canRenderFrame && (surface != nil || fullRebuildOverride != nil)
    }

    private func applyOrOweFullRepaint(_ reason: TerminalRepaintReason, counting: Bool) {
        let composing = isComposing()
        let action = TerminalRepaintPolicy.action(
            canRender: canApplyFullRepaint,
            composing: composing,
            now: Self.monotonicTimestamp(),
            lastApplied: repaintStatistics.lastAppliedUptime
        )
        switch action {
        case .apply:
            applyFullRepaint(reason)
        case .owe, .coalesce:
            if counting {
                if composing { repaintStatistics.skippedWhileComposing += 1 } else { repaintStatistics.owed += 1 }
            }
            fullRepaintOwed = fullRepaintOwed ?? reason
        }
    }

    private func applyFullRepaint(_ reason: TerminalRepaintReason) {
        fullRepaintOwed = nil
        repaintStatistics.applied += 1
        repaintStatistics.lastReason = reason
        repaintStatistics.lastAppliedUptime = Self.monotonicTimestamp()
        TerminalDebugLog.log(.render, "full repaint applied reason=\(reason.rawValue)")
        if let fullRebuildOverride {
            fullRebuildOverride(reason)
        } else {
            surface?.markFullyDirty()
        }
    }

    /// The resize throttle can deliver the final size after the first
    /// rebuild; repaint once more after it has landed.
    private func scheduleTrailingRepaint(_ reason: TerminalRepaintReason) {
        trailingRepaint?.cancel()
        trailingRepaint = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TerminalRepaintPolicy.trailingDelay))
            guard !Task.isCancelled, let self else { return }
            self.trailingRepaint = nil
            self.applyOrOweFullRepaint(reason, counting: false)
            if self.canRenderFrame { self.armFrameBurst() }
        }
    }

    /// Self-heal: once output has been quiet for `settleDelay`, or every
    /// `maximumIntervalUnderDamage` under continuous output, rebuild the
    /// whole viewport once. A row whose damage was never reported is then
    /// stale for at most that long instead of until the next resize.
    private func noteDamage() {
        guard canRenderFrame else { return }
        let now = Self.monotonicTimestamp()
        if TerminalRepaintPolicy.isEcho(now: now, lastApplied: repaintStatistics.lastAppliedUptime) { return }
        lastDamageUptime = now
        let since = damageSinceUptime ?? now
        damageSinceUptime = since
        if TerminalRepaintPolicy.settleIsOverdue(
            now: now, lastApplied: repaintStatistics.lastAppliedUptime, damageSince: since
        ) {
            damageSinceUptime = nil
            requestFullRepaint(.settle)
            return
        }
        guard settleRepaint == nil else { return }
        settleRepaint = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                let quiet = Self.monotonicTimestamp() - (self.lastDamageUptime ?? 0)
                let remaining = TerminalRepaintPolicy.settleDelay - quiet
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard let self, !Task.isCancelled else { return }
            self.settleRepaint = nil
            self.damageSinceUptime = nil
            self.requestFullRepaint(.settle)
        }
    }

    private func cancelRepaintTasks() {
        trailingRepaint?.cancel()
        trailingRepaint = nil
        settleRepaint?.cancel()
        settleRepaint = nil
        fullRepaintOwed = nil
        lastDamageUptime = nil
        damageSinceUptime = nil
    }

    func startDisplayLink() {
        ensureDisplayLink()
    }

    func stopDisplayLink() {
        deferredAnimationTick?.cancel()
        deferredAnimationTick = nil
        releaseDisplayLink()
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        // A pane that is merely hidden reports a zero size. Tearing the surface
        // down here and then bailing out at the size guard below would destroy
        // ghostty's grid and scrollback for a condition that is temporary: when
        // the pane comes back there is nothing left to show, and only the app
        // redrawing can refill it. Keep the surface — the caller re-runs this
        // once the view has a usable size again.
        //
        // This is the same intent as the reattach guard in viewDidMoveToWindow
        // ("rebuilding on every reattach discards Ghostty's scrollback/state"),
        // which cannot help while the teardown happens before the checks.
        if surface != nil, previousController == nil, !hasValidViewSize {
            // The rebuild is owed, not cancelled. Configuration options are
            // consumed only by createSurface, and no caller re-runs this once
            // the view regains a size (fitToSize, viewDidMoveToWindow and the
            // UIKit twin all take the surface != nil branch and merely sync
            // metrics). Dropping the request outright would leave a hidden
            // pane running its old configuration indefinitely.
            pendingRebuild = true
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface kept: view size temporarily invalid \(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )

            return
        }
        pendingRebuild = false

        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        bridge.rawSurface = rawSurface
        let newSurface = TerminalSurface(rawSurface)
        surface = newSurface
        newSurface.setOcclusion(effectiveSurfaceVisible)
        // The controller always drains Ghostty's protocol mailbox on wakeup.
        // This policy gates presentation work only: hidden and background
        // terminals must keep parsing output without requesting display frames.
        controller.shouldProcessWakeup = { [weak self] in
            guard let self else { return false }
            return isApplicationActive && isAttached()
        }
        controller.onWakeup = { [weak self] in
            self?.requestImmediateTick()
        }
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        synchronizeMetrics()
        requestImmediateTick()
    }

    // MARK: - Metrics

    // Ghostty's IO thread coalesces resize messages with a hardcoded 25ms
    // trailing-only window (Thread.zig). For an alt-screen TUI that fully
    // repaints on every winsize (Claude Code), a live divider drag posts new
    // sizes faster than that window resolves — the grid reflow runs
    // permanently behind the layer bounds and the renderer composites the
    // stale grid into the new frame: the mid-drag collapse. Bounding the
    // stream (leading edge for responsiveness, trailing edge so the final
    // size always lands) hands the engine a signal it can settle on.
    //
    // The right window is CONTENT-dependent, so it is a per-surface value
    // the host sets (`TerminalSurfaceOptions.resizeThrottleMilliseconds`, or
    // the platform setter for a live change): a primary-screen transcript
    // that never re-emits its scrollback (codex-style) renders best fully
    // unthrottled — large throttled jumps read as blinking — while the
    // alt-screen full-repaint agents need ~96ms. 0 disables. The env var
    // GHOSTTY_SURFACE_RESIZE_THROTTLE_MS, when set, overrides every surface
    // for whole-process A/B runs.
    private static let resizeThrottleOverride: TimeInterval? = {
        guard
            let raw = ProcessInfo.processInfo
                .environment["GHOSTTY_SURFACE_RESIZE_THROTTLE_MS"],
            let ms = Double(raw), ms >= 0
        else { return nil }
        return ms / 1000
    }()

    /// Set directly by a platform view; otherwise sourced from
    /// `configuration.resizeThrottleMilliseconds`. Kept as an override so the
    /// AppKit setter can adjust a live surface without rebuilding it.
    var resizeThrottleInterval: TimeInterval?

    private var effectiveResizeThrottle: TimeInterval {
        if let override = Self.resizeThrottleOverride { return override }
        if let interval = resizeThrottleInterval { return interval }
        return max(0, configuration.resizeThrottleMilliseconds) / 1000
    }

    private var resizeThrottleArmed = false
    private var resizeThrottleTrailing = false
    /// Invalidates in-flight throttle timers across a teardown. A timer
    /// armed for the old surface must not size — or re-arm against — the
    /// surface that replaced it.
    private var resizeThrottleGeneration = 0
    /// Host-managed remote surfaces can commit geometry atomically: keep the
    /// current grid live while the remote PTY paints the destination grid,
    /// then resume metrics immediately before feeding that complete frame.
    private var resizeSynchronizationSuspended = false
    private var resizeSynchronizationPending = false
    /// A rebuild deferred by the zero-size guard above, replayed by
    /// `synchronizeMetrics` as soon as the view has a usable size again.
    private var pendingRebuild = false

    func synchronizeMetrics() {
        guard !resizeSynchronizationSuspended else {
            resizeSynchronizationPending = true
            return
        }
        resizeSynchronizationPending = false
        // Redeem a rebuild the zero-size guard deferred. Every caller that
        // could restore a usable size lands here, so this is the one place
        // that reliably observes the transition.
        if pendingRebuild, hasValidViewSize {
            pendingRebuild = false
            rebuildIfReady()
            return
        }

        guard effectiveResizeThrottle > 0 else {
            performMetricsSync()
            return
        }

        guard !resizeThrottleArmed else {
            // Newest wins: the trailing fire re-reads the live view size,
            // so nothing needs to be captured here.
            resizeThrottleTrailing = true
            return
        }

        performMetricsSync()
        armResizeThrottle()
    }

    /// Repaint a wider logical grid without changing the host view or drawing
    /// the temporary frame. Bound physical width to avoid oversized textures.
    func beginViewportInspection(columns: Int) -> Bool {
        guard inspectionWidthPixels == nil, !inspectionSuppressesRendering,
              !resizeSynchronizationSuspended, let metrics = surface?.size(),
              metrics.cellWidthPixels > 0, columns > Int(metrics.columns),
              columns <= 4_098 else { return false }
        let padding = max(0, Int(metrics.widthPixels) - Int(metrics.columns) * Int(metrics.cellWidthPixels))
        let pixels = columns * Int(metrics.cellWidthPixels) + padding
        guard pixels <= 8_192 else { return false }
        inspectionSuppressesRendering = true
        inspectionWidthPixels = UInt32(pixels)
        surface?.setOcclusion(false)
        stopDisplayLink()
        performMetricsSync()
        return true
    }

    private(set) var capturedPasteRequestState = "idle"
    func pasteCapturedText(_ text: String) -> Bool {
        guard let surface else { capturedPasteRequestState = "unavailable_surface"; return false }
        guard let id = bridge.capturedClipboardRead.begin(text) else { capturedPasteRequestState = "capture_busy"; return false }
        let handled = surface.performBindingAction("paste_from_clipboard")
        let consumed = bridge.capturedClipboardRead.finish(id)
        capturedPasteRequestState = !handled ? "binding_not_handled" : !consumed ? "capture_not_consumed" : "consumed"
        return handled && consumed
    }

    /// Restore the view-sized grid while withholding presentation until the
    /// host has observed the provider's restored-width repaint.
    func restoreViewportAfterInspection() {
        guard inspectionSuppressesRendering else { return }
        inspectionWidthPixels = nil
        performMetricsSync()
    }

    func finishViewportInspection() {
        guard inspectionSuppressesRendering else { return }
        inspectionWidthPixels = nil
        performMetricsSync()
        inspectionSuppressesRendering = false
        surface?.setOcclusion(effectiveSurfaceVisible)
        requestFullRepaint(.inspection)
    }

    func setResizeSynchronizationSuspended(_ suspended: Bool) {
        guard resizeSynchronizationSuspended != suspended else { return }
        resizeSynchronizationSuspended = suspended
        if suspended {
            // Retire a throttle timer armed for the outgoing grid. It must not
            // wake in the middle of the host's atomic geometry transaction.
            resizeThrottleGeneration &+= 1
            resizeThrottleArmed = false
            resizeThrottleTrailing = false
            return
        }
        guard resizeSynchronizationPending else { return }
        resizeSynchronizationPending = false
        synchronizeMetrics()
    }

    private func armResizeThrottle() {
        resizeThrottleArmed = true
        let generation = resizeThrottleGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + effectiveResizeThrottle
        ) { [weak self] in
            guard let self else { return }
            // A teardown bumped the generation: this timer belongs to a
            // surface that no longer exists. Returning without touching
            // `resizeThrottleArmed` leaves the current surface's own state
            // alone.
            guard generation == resizeThrottleGeneration else { return }
            resizeThrottleArmed = false
            guard resizeThrottleTrailing else { return }
            resizeThrottleTrailing = false
            guard surface != nil else { return }
            performMetricsSync()
            armResizeThrottle()
        }
    }

    private func performMetricsSync() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return
        }

        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let pixelWidth = inspectionWidthPixels ?? UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
        )

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(width: pixelWidth, height: pixelHeight)

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)"
            )
            onMetricsUpdate?()
            return
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        // Deliberately no host resize dispatch here. This runs on the AppKit
        // thread right after setSize(), i.e. before the engine's IO thread has
        // run the resize operation at all — the host would learn the new size
        // from a thread that has not yet reflowed anything.
        //
        // Worse, it poisons the correctly-phased notification: the IO thread's
        // `receiveResizeCallback` (invoked from HostManaged.resize, immediately
        // before `terminal.resize`, both serial within one IO-thread resize
        // operation) then arrives carrying a size the session already recorded,
        // and is discarded as unchanged. A relative-cursor TUI therefore
        // repainted against a winsize that led the grid, and its clamped CUD
        // merged the footer.
        //
        // Leaving `receiveResizeCallback` as the sole PTY-resize source matches
        // stock Ghostty, where pty.setSize runs only inside Termio.resize.
        // Local UI metrics still flow via the delegate below and
        // onMetricsUpdate.
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows)
            )
        }
        onMetricsUpdate?()
    }

    func fitToSize() {
        if surface == nil {
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
        if surface != nil {
            requestImmediateTick()
        }
    }

    func synchronizeAndRenderImmediately() {
        synchronizeMetrics()
        if inspectionSuppressesRendering {
            // Drain parser and protocol callbacks without drawing the
            // temporary grid into the host's unchanged view.
            controller?.tick()
            return
        }
        // Explicit host reconciliation may need a fresh native frame after
        // resize or restoration. Request it once here, rather than on every
        // display tick (which feeds the renderer's callback back into itself).
        surface?.refresh()
        // Replay and presentation rebuild every row, not only the dirty ones.
        requestFullRepaint(.replay)
        renderImmediately()
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(effectiveSurfaceVisible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            // Ghostty keeps updating frame data while occluded but skips
            // drawing; a revealed pane gets every row rebuilt and drawn.
            requestFullRepaint(.visibility)
        } else {
            stopDisplayLink()
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else {
            // Same state, but not necessarily the same surface: one built
            // between two syncs still wears the occlusion stamped at its
            // birth. Re-stamp — a surface born occluded that never hears
            // otherwise skips every draw and shows as a blank pane.
            surface?.setOcclusion(effectiveSurfaceVisible)
            if active {
                renderImmediately()
            } else {
                stopDisplayLink()
            }
            return
        }

        isApplicationActive = active
        surface?.setOcclusion(effectiveSurfaceVisible)

        if active {
            synchronizeMetrics()
            requestFullRepaint(.visibility)
            renderImmediately()
        } else {
            stopDisplayLink()
        }
    }

    // MARK: - Frame Rendering

    func tick(context: DisplayLinkCallbackContext) {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        guard shouldRenderFrame(at: context.timestamp) else {
            idleFrameCount += 1
            if idleFrameCount >= Self.idleFramesBeforeRelease {
                releaseDisplayLink()
            }
            return
        }
        idleFrameCount = 0
        pendingImmediateTick = false
        lastTickTimestamp = context.timestamp
        TerminalDebugLog.log(.render, "tick")
        // Redeem a full repaint that was coalesced, or owed while the pane
        // could not draw or an IME composition was open.
        if let owed = fullRepaintOwed {
            applyOrOweFullRepaint(owed, counting: false)
        }
        isRenderingFrame = true
        controller?.tick()
        // Output, input and native animation already schedule frame updates.
        // refresh() queues another renderer update and its async render action
        // arrives after this tick, appearing to be fresh damage indefinitely.
        surface?.draw()
        onPostRender?()
        isRenderingFrame = false
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        isSurfaceFocused = focused
        requestImmediateTick()
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    #if DEBUG
        // Test access to the host-managed resize state. Read-only apart from
        // `pendingRebuild`, which tests set to drive the redemption path
        // without needing a real ghostty surface.
        var testHooks_pendingRebuild: Bool {
            get { pendingRebuild }
            set { pendingRebuild = newValue }
        }

        var testHooks_throttleArmed: Bool { resizeThrottleArmed }
        var testHooks_throttleTrailing: Bool { resizeThrottleTrailing }
        var testHooks_throttleGeneration: Int { resizeThrottleGeneration }
        var testHooks_resizeSynchronizationSuspended: Bool { resizeSynchronizationSuspended }
        var testHooks_resizeSynchronizationPending: Bool { resizeSynchronizationPending }
    #endif

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    #if DEBUG
        var testHooks_fullRepaintOwed: TerminalRepaintReason? { fullRepaintOwed }
        var testHooks_settleScheduled: Bool { settleRepaint != nil }
        func testHooks_noteDamage() { noteDamage() }
    #endif

    /// Tests only: the bridge a surface generation was created with.
    var bridgeForTesting: TerminalCallbackBridge { bridge }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller, replacingBridge: false)
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?,
                                 replacingBridge: Bool = true) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        releaseDisplayLink()
        cancelRepaintTasks()
        let retiredSurface = surface
        let retiredBridge = bridge
        // In-memory output may still be inside a Ghostty call on this surface,
        // blocked on the app mailbox that only this (main) thread drains, so
        // teardown must not wait for it. The session frees the surface (and
        // only then drops its callback bridge) after that call returns.
        var releaseDeferredToSession = false
        if let session = configuration.inMemorySession {
            session.clearSurface(ifMatches: surface?.rawValue)
            if let retiredSurface, let raw = retiredSurface.rawValue {
                releaseDeferredToSession = true
                let releasingController = controller
                let release = TerminalSurfaceRelease { @MainActor in
                    retiredSurface.setFocus(false)
                    // Until here the retired bridge still names its own
                    // surface, so a late clipboard completion reaches that
                    // surface, which is alive, and never a replacement.
                    retiredBridge.rawSurface = nil
                    retiredSurface.free()
                    releasingController?.remove(retiredBridge)
                }
                session.retireSurface(raw) { release.run() }
            }
        }
        controller?.onWakeup = nil
        controller?.shouldProcessWakeup = nil
        if !releaseDeferredToSession {
            retiredBridge.rawSurface = nil
        }
        let hadSurface = surface != nil
        if !releaseDeferredToSession {
            surface?.setFocus(false)
            surface?.free()
        }
        surface = nil
        inspectionWidthPixels = nil
        inspectionSuppressesRendering = false
        lastMetrics = nil
        // Retire any armed timer with the surface it was armed for, and
        // clear the gate so the replacement surface sizes immediately
        // instead of being suppressed by the old surface's armed flag.
        resizeThrottleGeneration &+= 1
        resizeThrottleArmed = false
        resizeThrottleTrailing = false
        resizeSynchronizationSuspended = false
        resizeSynchronizationPending = false
        pendingImmediateTick = true
        lastTickTimestamp = 0
        if !releaseDeferredToSession {
            controller?.remove(retiredBridge)
        }
        if hadSurface, replacingBridge {
            // The retired generation no longer reaches the view; the next
            // surface gets a bridge of its own.
            retiredBridge.delegate = nil
            retiredBridge.onCellSizeChange = nil
            retiredBridge.onRenderRequest = nil
            bridge = TerminalCallbackBridge()
            connect(bridge)
        }
        if hadSurface {
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        requestImmediateTick()
        onCellSizeDidChange?()
    }

    private func shouldRenderFrame(at timestamp: TimeInterval) -> Bool {
        guard canRenderFrame else { return false }
        return TerminalRenderCadencePolicy.shouldRender(
            pendingDamage: pendingImmediateTick,
            lastTimestamp: lastTickTimestamp,
            timestamp: timestamp,
            focused: isSurfaceFocused
        )
    }

    private func ensureDisplayLink() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        idleFrameCount = 0
        guard displayLinkRegistration == nil else { return }
        displayLinkRegistration = TerminalDisplayLinkHub.shared.register(self)
        TerminalDebugLog.log(.lifecycle, "display link acquired")
    }

    private func releaseDisplayLink() {
        guard let registration = displayLinkRegistration else { return }
        displayLinkRegistration = nil
        TerminalDisplayLinkHub.shared.unregister(registration)
        idleFrameCount = 0
        TerminalDebugLog.log(.lifecycle, "display link released")
    }

    private func scheduleDeferredAnimationTick() {
        guard deferredAnimationTick == nil, canRenderFrame else { return }
        deferredAnimationTick = Task { @MainActor [weak self] in
            // Cursor blinking and shader animation do not need display-rate
            // polling. Real terminal damage cancels this sleep and wakes the
            // next vsync immediately through requestImmediateTick().
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.deferredAnimationTick = nil
            self.pendingImmediateTick = true
            self.ensureDisplayLink()
        }
        releaseDisplayLink()
    }

    private static func monotonicTimestamp() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var effectiveSurfaceVisible: Bool {
        isDisplayVisible && isApplicationActive
    }

    private var canRenderFrame: Bool {
        !inspectionSuppressesRendering && effectiveSurfaceVisible && isAttached()
    }

    private var hasValidViewSize: Bool {
        let size = viewSize()
        return size.width > 0 && size.height > 0
    }

    private func renderImmediately() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }

        pendingImmediateTick = true
        let timestamp = Self.monotonicTimestamp()
        tick(
            context: .init(
                duration: 0,
                timestamp: timestamp,
                targetTimestamp: timestamp
            )
        )
        ensureDisplayLink()
    }
}

/// One process-wide display subscription for every terminal surface. The
/// underlying macOS clock may run at 120 Hz and MSDisplayLink otherwise fans
/// each tick through a separate Combine pipeline per pane. A single weak
/// registry pays that bridge cost once, caps terminal work at 60 Hz, and then
/// calls only surfaces that currently owe frames.
@MainActor
private final class TerminalDisplayLinkHub: DisplayLinkDelegate {
    static let shared = TerminalDisplayLinkHub()

    private final class WeakCoordinator {
        weak var value: TerminalSurfaceCoordinator?
        init(_ value: TerminalSurfaceCoordinator) { self.value = value }
    }

    private var registrations: [UUID: WeakCoordinator] = [:]
    private var displayLink: DisplayLink?
    private var lastDispatchTimestamp: TimeInterval = 0

    func register(_ coordinator: TerminalSurfaceCoordinator) -> UUID {
        let id = UUID()
        registrations[id] = WeakCoordinator(coordinator)
        if displayLink == nil {
            let link = DisplayLink(preferredFrameRateRange: .init(
                minimum: 30, maximum: 60, preferred: 60
            ))
            link.delegatingObject(self)
            displayLink = link
        }
        return id
    }

    func unregister(_ id: UUID) {
        registrations[id] = nil
        retireClockIfEmpty()
    }

    private func dispatch(_ context: DisplayLinkCallbackContext) {
        guard TerminalRenderCadencePolicy.shouldDispatchSharedClock(
            lastTimestamp: lastDispatchTimestamp,
            timestamp: context.timestamp
        ) else { return }
        lastDispatchTimestamp = context.timestamp

        var targets: [TerminalSurfaceCoordinator] = []
        var stale: [UUID] = []
        targets.reserveCapacity(registrations.count)
        for (id, box) in registrations {
            if let value = box.value {
                targets.append(value)
            } else {
                stale.append(id)
            }
        }
        for id in stale { registrations[id] = nil }
        for target in targets {
            target.tick(context: context)
        }
        retireClockIfEmpty()
    }

    private func retireClockIfEmpty() {
        guard registrations.isEmpty else { return }
        displayLink = nil
        lastDispatchTimestamp = 0
    }

    nonisolated func synchronization(context: DisplayLinkCallbackContext) {
        MainActor.assumeIsolated {
            dispatch(context)
        }
    }
}

/// A shared display link can fire at 120 Hz on ProMotion displays. Rendering
/// every damaged surface on every callback wastes more CPU/GPU as the pane
/// count grows, even though terminal output does not benefit from that rate.
/// Keep the focused pane at a crisp 60 fps and visible background panes at 30
/// fps. Input focuses its pane before the next frame, so this never delays
/// interactive echo; watch panes still update smoothly at half the cost.
enum TerminalRenderCadencePolicy {
    static let focusedFramesPerSecond = 60.0
    static let backgroundFramesPerSecond = 30.0

    static func shouldDispatchSharedClock(
        lastTimestamp: TimeInterval,
        timestamp: TimeInterval
    ) -> Bool {
        guard lastTimestamp > 0 else { return true }
        let minimumInterval = (1.0 / focusedFramesPerSecond) * 0.90
        return timestamp - lastTimestamp >= minimumInterval
    }

    static func shouldRender(
        pendingDamage: Bool,
        lastTimestamp: TimeInterval,
        timestamp: TimeInterval,
        focused: Bool
    ) -> Bool {
        guard pendingDamage else { return lastTimestamp == 0 }
        guard lastTimestamp > 0 else { return true }
        let framesPerSecond = focused
            ? focusedFramesPerSecond
            : backgroundFramesPerSecond
        // A small tolerance avoids accidentally halving 60 Hz output because
        // display timestamps normally land a fraction below the ideal period.
        let minimumInterval = (1.0 / framesPerSecond) * 0.90
        return timestamp - lastTimestamp >= minimumInterval
    }
}

extension TerminalSurfaceCoordinator: DisplayLinkDelegate {
    // The shared CADisplayLink dispatches synchronously on the main run
    // loop; the protocol just cannot say so.
    nonisolated func synchronization(context: DisplayLinkCallbackContext) {
        MainActor.assumeIsolated {
            tick(context: context)
        }
    }
}

/// The main-actor release of a retired surface, handed to the in-memory
/// session, which runs it from whichever thread finished the surface's last
/// operation (or inline when the surface was idle). It always runs on the
/// main actor and at most once.
final class TerminalSurfaceRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@MainActor () -> Void)?

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    func run() {
        lock.lock()
        let body = self.body
        self.body = nil
        lock.unlock()
        guard let body else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
