import Foundation
import Testing
@testable import Relay

@Test("Scrollback erasure and cursor-home never discard unchanged screen cells")
func replayRetainsBaseForHomeAndScrollbackErase() {
    for control in ["\u{001B}[H", "\u{001B}[1;1H", "\u{001B}[3J"] {
        let base = "unchanged transcript and composer\r\n"
        let delta = "\u{001B}[?2026h" + control + String(repeating: "x", count: 700) + "\u{001B}[?2026l"
        let input = Data((base + delta).utf8)
        #expect(TerminalReplayCompactor.compact(input) == input)
        #expect(!TerminalReplayCompactor.hasCompletedSynchronizedFrame(input))
    }
}

@Test("Reconnect gate buffers bytes immediately without a main-thread callback")
func reconnectGateBuffersImmediately() {
    let bridge = TerminalIOBridge()
    bridge.beginReplay()
    bridge.setExplicitReplayBoundary(true)
    #expect(bridge.receive(Data("\u{001B}[2J\u{001B}[HClaude repaint".utf8), remoteSequence: 1) == false)
    #expect(bridge.receive(Data("\u{001B}[5;1HCodex tail".utf8), remoteSequence: 2) == false)
}
