import AppKit
import SwiftUI
import Testing
@testable import Relay

/// The running waveform moves through a Core Animation layer animation, not
/// SwiftUI frames, and only while it is in a window and allowed to move.
@MainActor @Suite(.serialized) struct RelayRunningWaveformTests {
    private func hostedView() -> (NSWindow, RelayRunningWaveformView) {
        _ = NSApplication.shared
        // Never ordered in: nothing appears on screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = RelayRunningWaveformView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func sweeping(_ view: RelayRunningWaveformView) -> Bool {
        view.layer?.sublayers?.first?.sublayers?.contains { $0.animation(forKey: RelayRunningWaveformView.animationKey) != nil } == true
    }

    @Test func sweepRunsOnlyWhileAnimatingInAWindow() {
        let (window, view) = hostedView()
        view.update(color: .systemGreen, animating: true)
        #expect(sweeping(view))
        // Updates while running keep the one animation (no restart per SwiftUI update).
        view.update(color: .systemGreen, animating: true)
        #expect(view.layer?.sublayers?.first?.sublayers?.compactMap { $0.animationKeys() }.joined().count == 1)
        view.update(color: .systemGreen, animating: false)
        #expect(!sweeping(view))
        view.update(color: .systemGreen, animating: true)
        view.removeFromSuperview()
        #expect(!sweeping(view))
        window.contentView?.addSubview(view)
        #expect(sweeping(view))
        withExtendedLifetime(window) {}
    }

    @Test func sweepFillsTheBarsInTurnThenHolds() throws {
        let sweep = RelayRunningWaveformView.sweep()
        #expect(sweep.calculationMode == .discrete)
        #expect(sweep.repeatCount == .infinity)
        let values = try #require(sweep.values as? [Double])
        #expect(values.first == 0 && values.last == 1)
        #expect(values == values.sorted())
        #expect(values.count == RelayRunningWaveformView.steps + 2)
    }

    @Test func runningMarkRendersInBothAppearances() throws {
        var rendered = 0
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let marks = HStack(spacing: 10) {
                ForEach([RelayStatusMark.Status.running, .waiting, .failed, .reconnecting, .disconnected], id: \.self) {
                    RelayStatusMark(status: $0)
                }
            }
            .padding(8)
            .environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(marks, name: "status-marks-running", width: 120, appearance: appearance)
            #expect(shot.size.width == 120)
            rendered += 1
        }
        #expect(rendered == 2)
    }
}
