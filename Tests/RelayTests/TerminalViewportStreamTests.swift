import Foundation
import Testing
@testable import Relay

@Test("Predicted geometry cannot impersonate an engine-confirmed resize")
func viewportWaitsForEngineConfirmation() {
    let bridge = TerminalIOBridge()
    bridge.terminalDidResize(columns: 80, rows: 24)
    bridge.beginViewportTransition()
    _ = bridge.flushPendingResize(viewport: RelayViewport(columns: 140, rows: 40), forceRepaint: true)
    #expect(bridge.currentViewport == RelayViewport(columns: 80, rows: 24))
    bridge.terminalDidResize(columns: 100, rows: 30)
    #expect(bridge.currentViewport == RelayViewport(columns: 100, rows: 30))
    bridge.terminalDidResize(columns: 140, rows: 40)
    #expect(bridge.currentViewport == RelayViewport(columns: 140, rows: 40))
}

@Test("A live output burst beyond the snapshot cap remains byte exact")
func liveOutputIsNeverSnapshotCompacted() async {
    let bridge = TerminalIOBridge()
    let captured = CapturedViewportOutput()
    let mirror = bridge.beginSidePanelMirror(deliver: { captured.append($0) }, viewportChanged: { _ in }, ready: { _, _ in })
    let bytes = Data(("saved shell\u{001B}[?1049h" + String(repeating: "x", count: TerminalSnapshotStore.maximumBytes * 2 + 1024) + "\u{001B}[?1049l").utf8)
    bridge.setPresentationPaused(true)
    _ = bridge.receive(bytes)
    await withCheckedContinuation { continuation in
        _ = bridge.beginSidePanelMirror(deliver: { _ in }, viewportChanged: { _ in }) { _, _ in
            continuation.resume()
        }
    }
    #expect(captured.data == bytes)
    bridge.setPresentationPaused(false)
    bridge.endSidePanelMirror(mirror)
}

private final class CapturedViewportOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}

@Test("A fresh agent renderer keeps history before a partial repaint")
func unrenderedAgentCheckpointReplaysItsScreenBase() async {
    let bridge = TerminalIOBridge()
    let captured = CapturedViewportOutput()
    let mirror: UUID = await withCheckedContinuation { continuation in
        let id = bridge.beginSidePanelMirror(deliver: { captured.append($0) },
            viewportChanged: { _ in }, ready: { _, _ in })
        _ = bridge.beginSidePanelMirror(deliver: { _ in }, viewportChanged: { _ in }) { _, _ in
            continuation.resume(returning: id)
        }
    }
    bridge.setExplicitReplayBoundary(true)
    bridge.beginReplay()
    // A viewport-mismatched cache supplies a cursor, but no screen. The
    // worker's partial repaint does not include the earlier transcript rows.
    let cursor = TerminalSnapshotDisplayPolicy.initialReplaySequence(
        remoteSequence: 42, rendered: false)
    let history = Data("retained transcript one\r\nretained transcript two\r\n".utf8)
    let repaint = Data("\u{001B}[10;1Hcomposer\u{001B}[20;1Hstatus".utf8)
    if cursor == 0 { _ = bridge.receive(history, remoteSequence: 42) }
    _ = bridge.receive(repaint, remoteSequence: 43)
    await withCheckedContinuation { continuation in
        bridge.onReplayFinished = { _ in continuation.resume() }
        bridge.endReplay()
    }
    bridge.onReplayFinished = nil
    bridge.endSidePanelMirror(mirror)
    #expect(captured.data.range(of: history) != nil)
    #expect(captured.data.range(of: repaint) != nil)
}

private func outputAcrossViewportBarrier(before: Data, after: Data) async -> Data {
    let bridge = TerminalIOBridge()
    let captured = CapturedViewportOutput()
    let mirrorID: UUID = await withCheckedContinuation { continuation in
        let id = bridge.beginSidePanelMirror(
            deliver: { captured.append($0) }, viewportChanged: { _ in }, ready: { _, _ in }
        )
        // Registration and completion barriers share the ordered display queue.
        _ = bridge.beginSidePanelMirror(deliver: { _ in }, viewportChanged: { _ in }) { _, _ in
            continuation.resume(returning: id)
        }
    }
    bridge.beginViewportTransition()
    #expect(bridge.receive(before, remoteSequence: 1))
    bridge.armViewportFrameBarrier(rows: 24)
    #expect(bridge.receive(after, remoteSequence: 2))
    await withCheckedContinuation { continuation in
        bridge.finishViewportTransition(rows: 24) { continuation.resume() }
    }
    bridge.endSidePanelMirror(mirrorID)
    return captured.data
}

@Test("Reconnect keeps the live parser and alternate-screen shell restoration")
func reconnectRetainsLiveGridUntilHistoryReset() async {
    let bridge = TerminalIOBridge()
    let captured = CapturedViewportOutput()
    let mirror = bridge.beginSidePanelMirror(deliver: { captured.append($0) }, viewportChanged: { _ in }, ready: { _, _ in })
    func replay(_ bytes: Data, reset: Bool = false) async {
        bridge.beginReplay()
        bridge.setExplicitReplayBoundary(true)
        if reset { bridge.resetRemoteSequence() }
        _ = bridge.receive(bytes, remoteSequence: 1)
        await withCheckedContinuation { continuation in
            bridge.onReplayFinished = { _ in continuation.resume() }
            bridge.endReplay()
        }
        bridge.onReplayFinished = nil
    }
    await replay(Data("shell prompt\u{001B}[?1049h\u{001B}[2Jagent screen".utf8))
    let before = captured.data.count
    let exit = Data("\u{001B}[?1049l\r\nrestored shell$ ".utf8)
    await replay(exit)
    #expect(Data(captured.data.dropFirst(before)) == exit)
    let resumed = captured.data.count
    let incremental = Data("\u{001B}[3;2Hupdate".utf8)
    await replay(incremental)
    #expect(Data(captured.data.dropFirst(resumed)) == incremental)
    let resetStart = captured.data.count
    await replay(Data("\u{001B}cnew remote history".utf8), reset: true)
    #expect(Data(captured.data.dropFirst(resetStart)).starts(with: Data("\u{001B}c".utf8)))
    bridge.endSidePanelMirror(mirror)
}

@Test("Split control strings and paths are never rewritten in the live stream")
func viewportSplitControlStringsStayOpaque() async {
    let first = Data("\u{001B}]7;file://dandy-07".utf8)
    let second = Data("/tmp/figure.png\u{0007}\r\n/tmp/result.csv\r\n".utf8)
    #expect(await outputAcrossViewportBarrier(before: first, after: second) == first + second)
}

@Test("Native resume never replays hidden output to an already-live mirror")
func viewportResumeDoesNotDuplicateMirrorOutput() async {
    let bridge = TerminalIOBridge()
    let captured = CapturedViewportOutput()
    let mirror = bridge.beginSidePanelMirror(deliver: { captured.append($0) }, viewportChanged: { _ in }, ready: { _, _ in })
    // A mirror-ready callback is an ordered queue barrier that drains pending output.
    func flush() async {
        await withCheckedContinuation { continuation in
            _ = bridge.beginSidePanelMirror(deliver: { _ in }, viewportChanged: { _ in }) { _, _ in
                continuation.resume()
            }
        }
    }
    await flush()
    bridge.setPresentationPaused(true)
    #expect(bridge.receive(Data("hidden-output".utf8)))
    await flush()
    bridge.setPresentationPaused(false)
    #expect(bridge.receive(Data("live-output".utf8)))
    await flush()
    #expect(captured.data == Data("hidden-outputlive-output".utf8))
    bridge.endSidePanelMirror(mirror)
}

@Test("Resize frame barriers preserve shell output and split escape sequences")
func viewportBarrierPreservesOrderedOutput() async {
    let before = Data("shell prompt before resize \u{001B}[3".utf8)
    let after = Data("1mred\u{001B}[0m after resize".utf8)
    #expect(await outputAcrossViewportBarrier(before: before, after: after) == before + after)
}

@Test("A primary-screen prompt redraw must not erase the transcript")
func viewportPromptRepaintPreservesTranscript() async {
    let repaint = Data(("\r\u{001B}[K\u{001B}]133;P;k=i\u{0007}" +
        String(repeating: "[user@host project] ", count: 5) +
        "$ \u{001B}]133;B\u{0007}pending command").utf8)
    #expect(await outputAcrossViewportBarrier(before: Data(), after: repaint) == repaint)
}

@Test("Alternate-screen resize preserves partial updates and cursor addressing")
func viewportAlternateScreenPreservesPartialRepaint() async {
    let before = Data("\u{001B}[?1049h\u{001B}[4;9Hretained content".utf8)
    let after = Data("\u{001B}[12;2Hstatus\u{001B}[?25h".utf8)
    #expect(await outputAcrossViewportBarrier(before: before, after: after) == before + after)
}
