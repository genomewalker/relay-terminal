import Testing
@testable import Relay

@Test("A small echo after a quiet period is drawn without waiting for a batch")
func displayBatchDrawsInteractiveEchoImmediately() {
    let quiet = Double(TerminalDisplayBatchPolicy.liveMilliseconds)
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: 1, millisecondsSinceLastDrain: nil) == 0)
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: 1, millisecondsSinceLastDrain: quiet) == 0)
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: TerminalDisplayBatchPolicy.interactiveBytes,
        millisecondsSinceLastDrain: 500) == 0)
}

@Test("Sustained or large output keeps the display batch")
func displayBatchKeepsBurstsBatched() {
    let live = TerminalDisplayBatchPolicy.liveMilliseconds
    // Packets arriving within a frame of the previous drain are a stream.
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: 64, millisecondsSinceLastDrain: Double(live) - 1) == live)
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: 64, millisecondsSinceLastDrain: 0) == live)
    // A large first packet is the start of a burst, not an echo.
    #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: false, pendingBytes: TerminalDisplayBatchPolicy.interactiveBytes + 1,
        millisecondsSinceLastDrain: nil) == live)
}

@Test("Explicit immediate drains are unchanged")
func displayBatchImmediateStaysImmediate() {
    for elapsed in [nil, 0, 1_000] as [Double?] {
        #expect(TerminalDisplayBatchPolicy.drainDelayMilliseconds(
            immediate: true, pendingBytes: 1 << 20, millisecondsSinceLastDrain: elapsed) == 0)
    }
    #expect(TerminalDisplayBatchPolicy.interactiveBytes > 0)
    #expect(TerminalDisplayBatchPolicy.interactiveBytes <= 4096)
}
