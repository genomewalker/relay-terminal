import AppKit
import SwiftUI

/// One presentation owner per R editor; detaching never creates another R device.
@MainActor
final class RPlotWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var detached = false
    var dockVisible = false
    private var window: NSWindow?
    private weak var connection: RHttpgdConnection?

    func show(connection: RHttpgdConnection, title: String) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        self.connection = connection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Plots — " + title
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        RelayToolSurface.configure(window)
        window.contentView = NSHostingView(rootView: VStack(alignment: .trailing, spacing: RelayTheme.spacing(8)) {
            RelayIconAction("Dock plots back", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in self?.close() }
            RHttpgdPlotView(connection: connection)
        }.padding(RelayTheme.spacing(12)).relaySurface().environment(\.relayNativeToolSurface, true))
        self.window = window
        detached = true
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        detached = false
        if !dockVisible { connection?.disconnect() }
        connection = nil
    }
}
