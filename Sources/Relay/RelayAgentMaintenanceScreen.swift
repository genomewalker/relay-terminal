import AppKit
import Darwin
import GhosttyTerminal

/// The offscreen host for a maintenance rendering. It is never shown: it
/// cannot become key or main, every request to order it onto the screen is
/// turned into an order-out, and it is fully transparent, click-through and
/// left out of the Windows menu and window cycling.
final class RelayAgentMaintenanceScreenWindow: NSWindow {
    /// Far from any display. Rendering needs no screen.
    static let origin = NSPoint(x: -64_000, y: -64_000)

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        alphaValue = 0
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle]
        level = .normal
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        super.order(.out, relativeTo: 0)
    }
    override func orderFront(_ sender: Any?) { orderOut(sender) }
    override func orderFrontRegardless() { orderOut(nil) }
    override func makeKeyAndOrderFront(_ sender: Any?) { orderOut(sender) }
    override func makeKey() {}
    override func makeMain() {}
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(Self.origin) }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: Self.origin, size: frameRect.size), display: false)
    }
}

/// A native, read-only rendering of a complete ordered host snapshot. It owns
/// neither the live pane's view nor its transport. Terminal replies and resize
/// callbacks deliberately have no route to a PTY.
@MainActor enum RelayAgentMaintenanceScreen {
    @TaskLocal static var observeWindow: (@MainActor (NSWindow) -> Void)?
    @TaskLocal static var observeReplay: (@MainActor (Int) -> Void)?

    /// One bounded working renderer, keyed to the worker incarnation. Reads
    /// and key taps reuse parsed state; ordered output adds only its suffix.
    /// Unrelated workers, changed grids, non-prefix snapshots or idle expiry
    /// discard it. Nothing here owns a live pane or its transport.
    @MainActor private final class Renderer {
        let id = UUID()
        let identity: UUID?
        let session: InMemoryTerminalSession
        let controller: TerminalController
        let view: AppTerminalView
        let window: RelayAgentMaintenanceScreenWindow
        let viewport: RelayViewport
        let pasteboardID: ObjectIdentifier?
        var data = Data()

        init(viewport: RelayViewport, identity: UUID?, pasteboard: NSPasteboard?) {
            self.viewport = viewport; self.identity = identity
            pasteboardID = pasteboard.map(ObjectIdentifier.init)
            session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let configuration = TerminalConfiguration(startingFrom: RelayPreferences.shared.terminalConfiguration()) { builder in
                builder.withWindowPaddingX(0); builder.withWindowPaddingY(0)
                builder.withCustom("clipboard-read", "deny"); builder.withCustom("clipboard-write", "deny")
                builder.withCustom("desktop-notifications", "false"); builder.withCustom("bell-features", "")
            }
            controller = TerminalController(configuration: configuration)
            view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 440))
            view.pasteboard = pasteboard
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
            view.controller = controller
            window = RelayAgentMaintenanceScreenWindow(size: view.frame.size)
            window.contentView = view
        }

        func start(_ bytes: Data) async -> Bool {
            observeWindow?(window)
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.fitToSize()
            guard let metrics = view.currentGridMetrics(), metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return false }
            let scale = window.backingScaleFactor
            let size = NSSize(width: CGFloat(viewport.columns) * CGFloat(metrics.cellWidthPixels) / scale,
                height: CGFloat(viewport.rows) * CGFloat(metrics.cellHeightPixels) / scale)
            window.setContentSize(size); view.setFrameSize(size); view.fitToSize()
            await Task.yield()
            window.layoutIfNeeded(); view.fitToSize()
            guard exactGrid else { return false }
            observeWindow?(window)
            return await append(bytes)
        }

        var exactGrid: Bool {
            guard let metrics = view.currentGridMetrics() else { return false }
            return metrics.columns == viewport.columns && metrics.rows == viewport.rows
        }

        func append(_ bytes: Data) async -> Bool {
            if !bytes.isEmpty {
                observeReplay?(bytes.count)
                session.receive(bytes)
                let currentSession = session
                await Task.detached { currentSession.waitForPendingOutput() }.value
                data.append(bytes)
            }
            observeWindow?(window)
            return !Task.isCancelled && exactGrid
        }

        func close() { observeWindow?(window); window.contentView = nil; window.orderOut(nil); window.close() }
    }

    private static var editingRenderer: Renderer?
    private static var editingExpiry: Task<Void, Never>?
    private static var editingBusy = false
    private static var editingWaiters: [CheckedContinuation<Void, Never>] = []

    private static func acquireEditing() async -> Bool {
        if !editingBusy { editingBusy = true; return true }
        guard editingWaiters.count < 16 else { return false }
        await withCheckedContinuation { editingWaiters.append($0) }
        return true
    }
    private static func releaseEditing() {
        if editingWaiters.isEmpty { editingBusy = false }
        else { editingWaiters.removeFirst().resume() }
    }
    private static func discardEditing() {
        editingExpiry?.cancel(); editingExpiry = nil
        editingRenderer?.close(); editingRenderer = nil
    }
    private static func hasPrefix(_ data: Data, _ prefix: Data) -> Bool {
        guard data.count >= prefix.count else { return false }
        if prefix.isEmpty { return true }
        // Data's generic Sequence.starts(with:) iterates every byte in Swift.
        // Compare the immutable contiguous snapshots directly instead.
        return prefix.withUnsafeBytes { first in
            data.withUnsafeBytes { second in memcmp(first.baseAddress!, second.baseAddress!, first.count) == 0 }
        }
    }
    private static func valid(_ data: Data, _ viewport: RelayViewport) -> Bool {
        !data.isEmpty && data.count <= 16 << 20 && viewport.columns > 0 && viewport.rows > 0 &&
            viewport.columns <= 1000 && viewport.rows <= 1000
    }

    private static func makeRenderer(_ data: Data, viewport: RelayViewport, identity: UUID?, pasteboard: NSPasteboard?) async -> Renderer? {
        let renderer = Renderer(viewport: viewport, identity: identity, pasteboard: pasteboard)
        guard await renderer.start(data) else { renderer.close(); return nil }
        return renderer
    }

    private static func withEditingRenderer<Result>(_ data: Data, viewport: RelayViewport, identity: UUID?,
        pasteboard: NSPasteboard? = nil, operation: @MainActor (Renderer) -> Result?) async -> Result? {
        guard valid(data, viewport), await acquireEditing() else { return nil }
        defer { releaseEditing() }
        guard !Task.isCancelled else { return nil }
        editingExpiry?.cancel(); editingExpiry = nil
        let renderer: Renderer
        if let cached = editingRenderer, cached.identity == identity,
           cached.pasteboardID == pasteboard.map(ObjectIdentifier.init),
           cached.viewport.columns == viewport.columns, cached.viewport.rows == viewport.rows,
           hasPrefix(data, cached.data) {
            guard await cached.append(Data(data.dropFirst(cached.data.count))) else { discardEditing(); return nil }
            renderer = cached
        } else {
            discardEditing()
            guard let fresh = await makeRenderer(data, viewport: viewport, identity: identity, pasteboard: pasteboard) else { return nil }
            editingRenderer = fresh; renderer = fresh
        }
        observeWindow?(renderer.window)
        let result = operation(renderer)
        observeWindow?(renderer.window)
        guard let result else { discardEditing(); return nil }
        scheduleEditingExpiry(renderer.id)
        return result
    }

    private static func scheduleEditingExpiry(_ id: UUID) {
        // Detached expiry does not retain a request's TaskLocal observers.
        editingExpiry = Task.detached { await expireEditing(id) }
    }
    private static func expireEditing(_ id: UUID) async {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard editingRenderer?.id == id, !editingBusy else { return }
        discardEditing()
    }

    static func read(_ data: Data, viewport: RelayViewport, pasteboard: NSPasteboard? = nil) async -> String? {
        guard valid(data, viewport), let renderer = await makeRenderer(data, viewport: viewport, identity: nil, pasteboard: pasteboard) else { return nil }
        defer { renderer.close() }
        return renderer.session.readActiveScreenVT()
    }

    static func editingScreen(_ data: Data, viewport: RelayViewport, identity: UUID? = nil) async -> String? {
        await withEditingRenderer(data, viewport: viewport, identity: identity) { $0.session.readViewportText() }
    }

    static func editingInput(_ data: Data, viewport: RelayViewport, request: RelayTerminalEditRequest,
        identity: UUID? = nil, pasteboard: NSPasteboard? = nil) async -> Data? {
        guard request.isValid else { return nil }
        return await withEditingRenderer(data, viewport: viewport, identity: identity, pasteboard: pasteboard) { renderer in
            let view = renderer.view
            guard let packet = view.collectNativeInput({
                if request.action == "insert_text", let text = request.text { view.sendText(text); return }
                guard let key = request.key.flatMap(RelayTerminalEditKey.init(rawValue:)) else { return }
                let native = key.native, modifiers = request.nativeModifiers
                let characters = modifiers.contains(.shift) ? native.characters.uppercased() : native.characters
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: renderer.window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: native.characters, isARepeat: false, keyCode: native.code),
                      let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: renderer.window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: native.characters, isARepeat: false, keyCode: native.code) else { return }
                view.keyDown(with: event); view.keyUp(with: up)
            }), !packet.isEmpty else { return nil }
            return packet
        }
    }
}
