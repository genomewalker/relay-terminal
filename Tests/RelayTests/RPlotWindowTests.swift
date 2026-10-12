import AppKit
import Testing
@testable import Relay

@MainActor
@Test("Plot window is resizable, reusable and docks without replacing connection")
func plotWindowLifecycle() {
    _ = NSApplication.shared
    let plots = RHttpgdConnection()
    let controller = RPlotWindow()
    controller.dockVisible = true
    let title = "test-" + UUID().uuidString
    controller.show(connection: plots, title: title)
    #expect(controller.detached)
    let windows = NSApp.windows.filter { $0.title == "Plots — " + title }
    #expect(windows.count == 1)
    #expect(windows.first?.styleMask.contains(.resizable) == true)
    #expect(windows.first?.styleMask.contains(.miniaturizable) == true)
    controller.show(connection: plots, title: title)
    #expect(NSApp.windows.filter { $0.title == "Plots — " + title }.count == 1)
    controller.close()
    #expect(!controller.detached)
}
