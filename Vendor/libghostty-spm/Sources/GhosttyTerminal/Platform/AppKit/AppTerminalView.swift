//
//  AppTerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    open class AppTerminalView: NSView {
        let core = TerminalSurfaceCoordinator()
        var metalLayer: CAMetalLayer?
        var inputHandler: TerminalKeyEventHandler?

        // Grouped view state, one struct per concern — same convention as
        // the UIKit twin: each state type is defined in the extension file
        // that owns the behavior (+Input, +Lifecycle); the storage lives
        // here because extensions cannot add stored properties.
        var keyEcho: KeyEchoState = .init()
        var pointer: PointerSelectionState = .init()
        var focusBridge: FocusBridgeState = .init()

        open weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        open var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        open var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        /// The pasteboard this surface copies to and pastes from; nil means
        /// the general pasteboard. Tests use a private named pasteboard.
        open var pasteboard: NSPasteboard? {
            get { core.pasteboard }
            set { core.pasteboard = newValue }
        }

        open func setSurfaceVisible(_ visible: Bool) {
            core.setDisplayVisible(visible)
        }

        /// Adjusts this surface's resize coalescing window without rebuilding
        /// it. Overrides `TerminalSurfaceOptions.resizeThrottleMilliseconds`,
        /// which is the declarative home for the same policy and the one every
        /// platform can reach; pass `nil` to fall back to it.
        open func setResizeThrottle(milliseconds: Double?) {
            core.resizeThrottleInterval = milliseconds.map { max(0, $0) / 1000 }
        }

        /// Temporarily defer view-size driven grid changes. Remote hosts use
        /// this to keep the outgoing terminal frame visible until a complete
        /// destination-sized PTY repaint is ready for an atomic swap.
        open func setResizeSynchronizationSuspended(_ suspended: Bool) {
            core.setResizeSynchronizationSuspended(suspended)
        }

        /// Reconcile the host view's current pixel/grid metrics and render one
        /// frame synchronously. Host-managed backends use this after an atomic
        /// reconnect replay, once their ordered input queue is drained, so the
        /// newly reconstructed grid is visible before a restore cover drops.
        open func synchronizeAndRedraw() {
            core.synchronizeAndRenderImmediately()
        }

        var surface: TerminalSurface? {
            core.surface
        }

        /// Observe native terminal damage, including output parsed while the
        /// temporary inspection viewport is withheld from presentation.
        public var onTerminalContentUpdate: (() -> Void)? {
            get { core.onContentUpdate }
            set { core.onContentUpdate = newValue }
        }

        @discardableResult
        public func beginViewportInspection(columns: Int) -> Bool {
            core.beginViewportInspection(columns: columns)
        }

        public func restoreViewportAfterInspection() {
            core.restoreViewportAfterInspection()
        }

        public func finishViewportInspection() {
            core.finishViewportInspection()
        }

        /// Query the renderer's current cell geometry without changing its size.
        open func currentGridMetrics() -> TerminalGridMetrics? {
            surface?.size()
        }

        /// Return the visible terminal grid without focusing or scrolling the view.
        open func readViewportText() -> String? {
            surface?.readViewportText()
        }

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            wantsLayer = true

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metal.isOpaque = false
            metal.backgroundColor = NSColor.clear.cgColor
            layer = metal
            metalLayer = metal
            layer?.backgroundColor = NSColor.clear.cgColor

            inputHandler = TerminalKeyEventHandler(view: self)
            setupTrackingArea()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(
                    self?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
                )
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
            core.onPostRender = { [weak self] in
                self?.enforceMetalLayerScale()
            }
            core.isComposing = { [weak self] in
                self?.hasMarkedText() ?? false
            }
        }

        open func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            guard surface?.hasSelection() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(selectionPointDescription(point))"
                )
                return nil
            }

            if let rect = pointer.lastSelectionRect {
                guard rect.insetBy(dx: -4, dy: -4).contains(point) else {
                    TerminalDebugLog.log(
                        .input,
                        "selection menu miss point=\(selectionPointDescription(point)) outside pointer selection"
                    )
                    return nil
                }

                TerminalDebugLog.log(
                    .input,
                    "selection menu hit point=\(selectionPointDescription(point)) inside pointer selection"
                )
                return point
            }

            guard surface?.selectionContainsQuicklookWord() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(selectionPointDescription(point)) outside quicklook word"
                )
                return nil
            }

            TerminalDebugLog.log(
                .input,
                "selection menu hit point=\(selectionPointDescription(point))"
            )
            return point
        }

        open func selectionContextMenu() -> NSMenu {
            let menu = NSMenu()
            let copyItem = NSMenuItem(
                title: "Copy",
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            menu.addItem(copyItem)
            return menu
        }

        @discardableResult
        open func copySelectedTextToPasteboard() -> Bool {
            guard surface?.hasSelection() == true else {
                return false
            }
            guard surface?.performBindingAction("copy_to_clipboard") == true else {
                return false
            }
            TerminalDebugLog.log(
                .input,
                "selection copied to clipboard"
            )
            return true
        }

        private func selectionPointDescription(_ point: CGPoint) -> String {
            "\(String(format: "%.2f", point.x))x\(String(format: "%.2f", point.y))"
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
