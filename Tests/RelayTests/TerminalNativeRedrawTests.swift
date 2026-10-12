import AppKit
import GhosttyTerminal
import Testing
@testable import Relay

/// Exercise actual Ghostty state, not just an ANSI-string predicate.
@MainActor
@Test("Native parser preserves the shell across hidden agent exit and reconnect")
func nativeRedrawPreservesShellState() async throws {
    _ = NSApplication.shared
    let bridge = TerminalIOBridge()
    let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(bridge.session), context: .window)
    view.controller = controller
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.fitToSize()
    defer { window.contentView = nil }

    func expectText(_ text: String) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(bridge.session.readViewportText() ?? "").contains(text), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect((bridge.session.readViewportText() ?? "").contains(text))
    }
    func replay(_ data: String) async {
        bridge.beginReplay()
        bridge.setExplicitReplayBoundary(true)
        _ = bridge.receive(Data(data.utf8))
        await withCheckedContinuation { continuation in
            bridge.onReplayFinished = { _ in continuation.resume() }
            bridge.endReplay()
        }
        bridge.onReplayFinished = nil
    }
    await replay("\u{001B}[2J\u{001B}[HRELAY_SHELL_SENTINEL\r\n$ \u{001B}[?1049h\u{001B}[2J\u{001B}[HAGENT_SCREEN")
    await expectText("AGENT_SCREEN")
    view.setSurfaceVisible(false)
    bridge.setPresentationPaused(true)
    _ = bridge.receive(Data("\u{001B}[?1049l".utf8))
    await expectText("RELAY_SHELL_SENTINEL")
    bridge.setPresentationPaused(false)
    view.setSurfaceVisible(true)
    await replay("\r\nAFTER_RECONNECT")
    await expectText("AFTER_RECONNECT")
    #expect((bridge.session.readViewportText() ?? "").contains("RELAY_SHELL_SENTINEL"))
    #expect(!(bridge.session.readViewportText() ?? "").contains("AGENT_SCREEN"))

    // A later pane owns the controller's presentation callback, then leaves
    // the view tree. Its visibility must not stop the shared app mailbox.
    let otherBridge = TerminalIOBridge()
    let other = AppTerminalView(frame: view.frame)
    other.configuration = TerminalSurfaceOptions(backend: .inMemory(otherBridge.session), context: .window)
    other.controller = controller
    let otherWindow = NSWindow(contentRect: other.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    otherWindow.contentView = other
    other.fitToSize()
    try? await Task.sleep(for: .milliseconds(60))
    otherWindow.contentView = nil
    let titles = (0..<4096).map { "\u{001B}]2;redraw-fixture-\($0)\u{0007}" }.joined()
    _ = bridge.receive(Data((titles + "\r\nMAILBOX_DRAINED").utf8))
    await expectText("MAILBOX_DRAINED")
    withExtendedLifetime(other) {}
}
