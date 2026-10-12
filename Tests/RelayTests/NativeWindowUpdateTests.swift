import AppKit
import Testing
@testable import Relay

@MainActor
@Test("Native window chrome waits until the view update has returned")
func nativeWindowChromeIsDeferred() async {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let marker = RelayStandardWindowMarker.Marker(frame: .zero)
    window.contentView?.addSubview(marker)
    #expect(window.styleMask.contains(.fullSizeContentView))
    marker.scheduleConfiguration()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!window.styleMask.contains(.fullSizeContentView))
    #expect(window.styleMask.contains(.closable))
    #expect(window.titleVisibility == .visible)
    window.contentView = nil
}

@MainActor
@Test("Terminal metadata callbacks defer published model changes")
func terminalMetadataUpdatesAreDeferred() async {
    _ = NSApplication.shared
    let profile = ConnectionProfile(name: "Metadata test", kind: .local, backend: .relay)
    let pane = PaneModel(profile: profile)
    let initialTitle = pane.title
    pane.runtime.terminalDidChangeTitle("First title")
    pane.runtime.terminalDidChangeTitle("Second title")
    #expect(pane.title == initialTitle)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(pane.title == "Second title")
}

@MainActor
@Test("Workspace window style changes wait until attachment layout returns")
func workspaceWindowChromeIsDeferred() async {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let marker = RelayWorkspaceWindowMarker.MarkerView(frame: .zero)
    window.contentView?.addSubview(marker)
    #expect(window.styleMask.contains(.fullSizeContentView))
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!window.styleMask.contains(.fullSizeContentView))
    #expect(window.identifier == .relayWorkspaceWindow)
    window.contentView = nil
}
