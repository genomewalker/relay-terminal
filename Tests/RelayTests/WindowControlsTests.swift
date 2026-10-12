import AppKit
import Testing
@testable import Relay

@Test("Workspace uses visible native window controls with bounded hit regions")
@MainActor
func workspaceNativeWindowControls() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let marker = RelayWorkspaceWindowMarker.MarkerView(frame: .zero)
    window.contentView?.addSubview(marker)
    marker.configureWindow()
    #expect(window.identifier == .relayWorkspaceWindow)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = window.standardWindowButton(kind)
        #expect(button != nil)
        #expect(button?.isHidden == false)
        #expect((button?.frame.width ?? 0) > 0)
        #expect((button?.frame.width ?? 900) < 40)
        #expect((button?.frame.height ?? 600) < 40)
    }
}
