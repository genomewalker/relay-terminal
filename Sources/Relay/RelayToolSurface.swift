import SwiftUI
import AppKit

private struct RelayNativeToolSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var relayNativeToolSurface: Bool {
        get { self[RelayNativeToolSurfaceKey.self] }
        set { self[RelayNativeToolSurfaceKey.self] = newValue }
    }
}

enum RelayToolSurface {
    @MainActor static func configure(_ window: NSWindow) {
        var style = window.styleMask
        style.formUnion([.titled, .closable, .miniaturizable, .resizable])
        style.remove(.fullSizeContentView)
        if window.styleMask != style { window.styleMask = style }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
        if window.level != .normal { window.level = .normal }
        RelayTheme.configureAppearance(window)
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        if window.isReleasedWhenClosed { window.isReleasedWhenClosed = false }
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
        if window.hidesOnDeactivate { window.hidesOnDeactivate = false }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let control = window.standardWindowButton(button), control.isHidden { control.isHidden = false }
        }
    }
}

struct RelayStandardWindowMarker: NSViewRepresentable {
    final class Marker: NSView {
        private var configurationScheduled = false
        private weak var configuredWindow: NSWindow?

        func scheduleConfiguration() {
            guard window != nil, configuredWindow !== window, !configurationScheduled else { return }
            configurationScheduled = true
            // Changing styleMask re-enters AppKit layout. Never do this from
            // SwiftUI's updateNSView or the view attachment/layout callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                guard let window = self.window, self.configuredWindow !== window else { return }
                RelayToolSurface.configure(window)
                self.configuredWindow = window
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }
    }
    func makeNSView(context: Context) -> NSView { Marker(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Marker)?.scheduleConfiguration()
    }
}
