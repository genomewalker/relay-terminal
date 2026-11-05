import AppKit
import GhosttyTerminal
import Testing
@testable import Relay

private final class MaintenanceInputCount: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func write(_ data: Data) { lock.lock(); bytes += data.count; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

@MainActor
@Test("Native styled prompt reads preserve viewport, clipboard and PTY input", .timeLimit(.minutes(5)))
func maintenanceNativePromptIsReadOnly() async throws {
    _ = NSApplication.shared
    let input = MaintenanceInputCount()
    let session = InMemoryTerminalSession(write: { input.write($0) }, resize: { _ in })
    let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
    // A private pasteboard: other tests and processes change the general one.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("relay.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 440))
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
    view.pasteboard = pasteboard
    view.controller = controller
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    // Settle the initial AppKit layout before taking the immutable baseline.
    // A deferred first resize otherwise changes the viewport during the read.
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.fitToSize()
    await Task.yield()
    view.fitToSize()
    defer { window.contentView = nil }
    // Keep clipboard IPC outside the compared terminal snapshots.
    let clipboardBefore = pasteboard.changeCount
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.fitToSize()
    let frame = "\u{1b}[2J\u{1b}[999;1H" +
        "› \u{1b}[90mAsk Codex to do anything\u{1b}[0m\r\n\r\n" +
        "GPT-Rosalind Research xhigh · Context 33% left · /owned/test\r\n? for shortcuts"
    // The I/O thread applies a resize asynchronously (Ghostty coalesces it).
    // Feed the frame only once the native grid has the surface's size, so no
    // late resize reflows the viewport between the compared reads.
    let metrics = try #require(view.currentGridMetrics())
    var resizes = session.nativeResizeEvents().makeAsyncIterator()
    while let applied = await resizes.next(),
          applied.columns != metrics.columns || applied.rows != metrics.rows {}
    session.receive(frame)
    await Task.detached { session.waitForPendingOutput() }.value
    let textBefore = try #require(session.readViewportText())
    let inputBefore = input.count
    let snapshot = try #require(session.readActiveScreenVT())
    #expect(snapshot.contains("Ask Codex to do anything"))
    #expect(snapshot.contains("\u{1b}["))
    #expect(RelayAgentMaintenancePrompt.isEmpty(snapshot, provider: "codex"), "Owned native export: \(String(reflecting: snapshot.prefix(1800)))")
    #expect(session.readViewportText() == textBefore)
    #expect(pasteboard.changeCount == clipboardBefore)
    #expect(input.count == inputBefore)
}

@MainActor
@Test("Hidden-pane inspection uses its exact grid and preserves the user's UI and clipboard")
func maintenanceHiddenNativeSnapshotIsReadOnly() async throws {
    _ = NSApplication.shared
    let keyWindow = NSApp.keyWindow
    // A private pasteboard: other tests and processes change the general one.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("relay.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboardBefore = pasteboard.changeCount
    let viewport = RelayViewport(columns: 120, rows: 90)
    let frame = "\u{1b}[2J\u{1b}[Howned transcript\r\n❯ \u{1b}[2mCheck this change\u{1b}[22m\r\n" +
        "────────────────\r\n⏵⏵ bypass permissions on · update installed\r\n" +
        "\u{1b}]52;c;cmVsYXktaW5zcGVjdG9yLW11c3Qtbm90LWNvcHk=\u{7}"
    let screen = try #require(await RelayAgentMaintenanceScreen.read(Data(frame.utf8), viewport: viewport,
        pasteboard: pasteboard))
    #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"))
    #expect(NSApp.keyWindow === keyWindow)
    #expect(pasteboard.changeCount == clipboardBefore)
    let draft = frame.replacingOccurrences(of: "\u{1b}[2mCheck this change\u{1b}[22m", with: "a real unsent draft")
    let withDraft = try #require(await RelayAgentMaintenanceScreen.read(Data(draft.utf8), viewport: viewport,
        pasteboard: pasteboard))
    #expect(!RelayAgentMaintenancePrompt.isEmpty(withDraft, provider: "claude"))
    #expect(NSApp.keyWindow === keyWindow)
    #expect(pasteboard.changeCount == clipboardBefore)
}

/// The pre-change rendering, in an ordinary borderless window at (0, 0), as
/// the reference for an exact screen.
@MainActor
private func referenceMaintenanceScreen(_ data: Data, viewport: RelayViewport) async -> String? {
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let configuration = TerminalConfiguration(startingFrom: RelayPreferences.shared.terminalConfiguration()) { builder in
        builder.withWindowPaddingX(0)
        builder.withWindowPaddingY(0)
    }
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 440))
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
    view.controller = TerminalController(configuration: configuration)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.contentView = nil; window.close() }
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.fitToSize()
    guard let metrics = view.currentGridMetrics(), metrics.cellWidthPixels > 0 else { return nil }
    let scale = window.backingScaleFactor
    let size = NSSize(width: CGFloat(viewport.columns) * CGFloat(metrics.cellWidthPixels) / scale,
                      height: CGFloat(viewport.rows) * CGFloat(metrics.cellHeightPixels) / scale)
    window.setContentSize(size)
    view.setFrameSize(size)
    view.fitToSize()
    await Task.yield()
    window.layoutIfNeeded()
    view.fitToSize()
    guard let exact = view.currentGridMetrics(), exact.columns == viewport.columns, exact.rows == viewport.rows else { return nil }
    session.receive(data)
    await Task.detached { session.waitForPendingOutput() }.value
    return session.readActiveScreenVT()
}

@MainActor
@Test("The maintenance rendering window is never shown, keyed or opaque, and reads the exact screen")
func maintenanceRenderingWindowIsNeverVisible() async throws {
    _ = NSApplication.shared
    let keyWindow = NSApp.keyWindow
    var observations = 0
    let observe: @MainActor (NSWindow) -> Void = { window in
        observations += 1
        // Whatever else asks, the window stays off screen.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.orderFront(nil)
        window.order(.above, relativeTo: 0)
        window.makeKey()
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow && !window.isMainWindow)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(window.alphaValue == 0)
        #expect(!window.occlusionState.contains(.visible))
        #expect(window.ignoresMouseEvents && !window.hasShadow && window.isExcludedFromWindowsMenu)
        #expect(window.collectionBehavior.contains(.transient) && window.collectionBehavior.contains(.ignoresCycle))
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }
    let viewport = RelayViewport(columns: 100, rows: 30)
    let frame = "\u{1b}[2J\u{1b}[Hprevious output\r\n\r\n› \u{1b}[2mAsk Codex to do anything\u{1b}[22m\r\n\r\n" +
        "  GPT-Rosalind Research high · Context 53% left · /maps/projects/caeg\r\n" +
        "  ? for shortcuts                                    ⚠ 3 warnings · f2 to view"
    let screen = try #require(await RelayAgentMaintenanceScreen.$observeWindow.withValue(observe) {
        await RelayAgentMaintenanceScreen.read(Data(frame.utf8), viewport: viewport)
    })
    #expect(observations >= 3)
    let reference = try #require(await referenceMaintenanceScreen(Data(frame.utf8), viewport: viewport))
    #expect(screen == reference)
    #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
    #expect(NSApp.keyWindow === keyWindow)
}
