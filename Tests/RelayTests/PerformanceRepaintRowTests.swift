import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

/// 0.5.58: the Performance panel shows the focused pane's repaint counters.
@MainActor
@Suite(.serialized)
struct PerformanceRepaintRowTests {
    @Test("Reading the repaint row never builds a terminal view for an unshown pane")
    func unshownPaneHasNoSummary() {
        let pane = PaneModel(profile: .sshConfigHost("repaint-row.invalid"))
        #expect(pane.runtime.repaintSummary == nil)
        #expect(pane.runtime.viewIsMadeForTesting == false)
        #expect(RelayPerformancePanel.repaintRowValue(nil) == "no terminal view focused")
    }

    @Test("A shown pane reports its repaint contract counters")
    func shownPaneReportsCounters() throws {
        _ = NSApplication.shared
        let pane = PaneModel(profile: .sshConfigHost("repaint-row.invalid"))
        let view = pane.runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }

        let summary = try #require(pane.runtime.repaintSummary)
        #expect(summary == view.repaintStatistics.summary)
        #expect(summary.contains("requested["))
        // Joining a window is a full-repaint transition.
        #expect(summary.contains("attach=1"))
        #expect(RelayPerformancePanel.repaintRowValue(summary) == summary)
    }
}
