import Foundation
import Testing
@testable import Relay

// Without a transport, requestObservedViewportRepaint has no commit generation
// to wait for, so observation arms immediately. These tests exercise the
// display stream's frame detection and its single-shot notification.

private final class ObservedRepaintFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    func append(_ id: UUID) { lock.withLock { ids.append(id) } }
    var all: [UUID] { lock.withLock { ids } }
}

private let synchronizedBegin = "\u{001B}[?2026h"
private let synchronizedEnd = "\u{001B}[?2026l"

/// A substantial synchronized update, as Codex emits for a full redraw.
private func fullRepaintFrame(_ label: String = "transcript") -> Data {
    var body = "\u{001B}[H"
    for row in 1...6 { body += "\u{001B}[\(row);1H\(label) row \(row) with visible text" }
    return Data((synchronizedBegin + body + synchronizedEnd).utf8)
}

private func observedBridge() -> (TerminalIOBridge, ObservedRepaintFrames) {
    let bridge = TerminalIOBridge()
    let frames = ObservedRepaintFrames()
    bridge.onObservedRepaintFrame = { frames.append($0) }
    return (bridge, frames)
}

/// Waits for the ordered display drain that delivers observation callbacks.
private func drain(_ bridge: TerminalIOBridge) async {
    await withCheckedContinuation { continuation in
        _ = bridge.beginSidePanelMirror(deliver: { _ in }, viewportChanged: { _ in }) { _, _ in
            continuation.resume()
        }
    }
    try? await Task.sleep(for: .milliseconds(60))
}

private func waitForFrames(_ frames: ObservedRepaintFrames, count: Int) async {
    for _ in 0..<100 where frames.all.count < count {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Test("An observed repaint completes once its synchronized frame is parsed")
func observedRepaintCompletesOnSynchronizedFrame() async {
    let (bridge, frames) = observedBridge()
    let id = UUID()
    bridge.requestObservedViewportRepaint(id: id)
    #expect(bridge.receive(fullRepaintFrame()))
    await waitForFrames(frames, count: 1)
    #expect(frames.all == [id])
}

@Test("A synchronized frame split across chunks and inside its markers completes once")
func observedRepaintSurvivesChunkSplits() async {
    let (bridge, frames) = observedBridge()
    let id = UUID()
    bridge.requestObservedViewportRepaint(id: id)
    let frame = fullRepaintFrame()
    // Cut inside the opening marker, mid-body, and inside the closing marker.
    let cuts = [3, 5, frame.count / 2, frame.count - 4, frame.count - 2]
    var start = frame.startIndex
    for cut in cuts {
        let end = frame.startIndex + cut
        #expect(bridge.receive(frame.subdata(in: start..<end)))
        start = end
    }
    #expect(bridge.receive(frame.subdata(in: start..<frame.endIndex)))
    await waitForFrames(frames, count: 1)
    #expect(frames.all == [id])
    // Observation is single-shot: a later frame does not notify again.
    #expect(bridge.receive(fullRepaintFrame("later")))
    await drain(bridge)
    #expect(frames.all == [id])
}

@Test("Status-only deltas do not complete an observed repaint")
func observedRepaintIgnoresStatusDeltas() async {
    let (bridge, frames) = observedBridge()
    let id = UUID()
    bridge.requestObservedViewportRepaint(id: id)
    // A spinner tick: synchronized, has text, but below the frame minimum.
    let tick = Data((synchronizedBegin + "\u{001B}[24;1H⠋ Working" + synchronizedEnd).utf8)
    // Unsynchronized output, however large, is not a completed frame.
    let plain = Data(("\u{001B}[23;1H" + String(repeating: "status ", count: 40)).utf8)
    // A synchronized update made only of cursor moves has no visible text.
    let moves = Data((synchronizedBegin + String(repeating: "\u{001B}[5;5H", count: 30)
        + synchronizedEnd).utf8)
    for delta in [tick, plain, moves, tick] { #expect(bridge.receive(delta)) }
    await drain(bridge)
    #expect(frames.all.isEmpty)
    // Observation stays armed for the real repaint.
    #expect(bridge.receive(fullRepaintFrame()))
    await waitForFrames(frames, count: 1)
    #expect(frames.all == [id])
}

@Test("A cancelled observation never fires")
func observedRepaintCancellationIsFinal() async {
    let (bridge, frames) = observedBridge()
    bridge.requestObservedViewportRepaint(id: UUID())
    bridge.cancelObservedRepaint()
    #expect(bridge.receive(fullRepaintFrame()))
    await drain(bridge)
    #expect(frames.all.isEmpty)
}

@Test("Cancelling after completion but before the drain suppresses the callback")
func observedRepaintCancellationBeforeDrain() async {
    let (bridge, frames) = observedBridge()
    bridge.requestObservedViewportRepaint(id: UUID())
    // The frame completes during enqueue; the callback waits for the drain.
    #expect(bridge.receive(fullRepaintFrame()))
    bridge.cancelObservedRepaint()
    await drain(bridge)
    #expect(frames.all.isEmpty)
}

@Test("A new request replaces the previous observation")
func observedRepaintNewRequestReplacesOld() async {
    let (bridge, frames) = observedBridge()
    bridge.requestObservedViewportRepaint(id: UUID())
    let current = UUID()
    bridge.requestObservedViewportRepaint(id: current)
    #expect(bridge.receive(fullRepaintFrame()))
    await waitForFrames(frames, count: 1)
    await drain(bridge)
    #expect(frames.all == [current])
}

@Test("A frame begun before observation armed does not complete it")
func observedRepaintIgnoresFrameStartedBeforeArm() async {
    let (bridge, frames) = observedBridge()
    let frame = fullRepaintFrame()
    let split = frame.startIndex + frame.count / 2
    // The opening marker and half the body arrive before the request.
    #expect(bridge.receive(frame.subdata(in: frame.startIndex..<split)))
    let id = UUID()
    bridge.requestObservedViewportRepaint(id: id)
    #expect(bridge.receive(frame.subdata(in: split..<frame.endIndex)))
    await drain(bridge)
    #expect(frames.all.isEmpty)
    // The next whole frame after arming completes it.
    #expect(bridge.receive(fullRepaintFrame("next")))
    await waitForFrames(frames, count: 1)
    #expect(frames.all == [id])
}
