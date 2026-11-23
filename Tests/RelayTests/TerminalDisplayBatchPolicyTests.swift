import Testing
@testable import Relay

private func delay(
    immediate: Bool = false, pending: Int, elapsed: Double?, frameBytes: Int = 0, drains: Int = 0
) -> Int {
    TerminalDisplayBatchPolicy.drainDelayMilliseconds(
        immediate: immediate, pendingBytes: pending, frameElapsedMilliseconds: elapsed,
        bytesDrainedThisFrame: frameBytes, drainsThisFrame: drains)
}

@Test("Live output is drawn on arrival, also within a frame of the previous drain")
func displayBatchDrawsLiveOutputOnArrival() {
    // An echo, a cursor-position reply or a remote agent's redraw after a
    // scroll step used to wait 16 ms when it came within a frame of an
    // earlier drain (the Mac shell's 24-36 ms round-trip tail and the remote
    // panes' 16.5 ms draw delay on 2026-11-23).
    #expect(delay(pending: 1, elapsed: nil) == 0)
    #expect(delay(pending: 6, elapsed: 0, frameBytes: 64, drains: 1) == 0)
    #expect(delay(pending: 64, elapsed: 5, frameBytes: 4096, drains: 3) == 0)
    // A large redraw of a whole agent screen is not a flood.
    #expect(delay(pending: 60 * 1024, elapsed: 2, frameBytes: 60 * 1024, drains: 1) == 0)
}

@Test("A flood within one frame waits for the rest of that frame")
func displayBatchHoldsOnlyFloods() {
    let live = TerminalDisplayBatchPolicy.liveMilliseconds
    let bytes = TerminalDisplayBatchPolicy.floodBytesPerFrame
    let drains = TerminalDisplayBatchPolicy.floodDrainsPerFrame
    // Too many bytes in this frame.
    #expect(delay(pending: 1, elapsed: 4, frameBytes: bytes) == live - 4)
    #expect(delay(pending: bytes + 1, elapsed: 0) == live)
    // Too many separate drains in this frame.
    #expect(delay(pending: 1, elapsed: 10, drains: drains) == live - 10)
    // Never zero once flooding, even at the very end of a frame.
    #expect(delay(pending: 1, elapsed: Double(live) - 0.1, drains: drains) >= 1)
    // A new frame starts fresh.
    #expect(delay(pending: 1, elapsed: Double(live), frameBytes: bytes * 4, drains: drains * 4) == 0)
}

@Test("Explicit immediate drains are unchanged")
func displayBatchImmediateStaysImmediate() {
    for elapsed in [nil, 0, 1_000] as [Double?] {
        #expect(delay(immediate: true, pending: 1 << 20, elapsed: elapsed,
                      frameBytes: 1 << 20, drains: 100) == 0)
    }
    #expect(TerminalDisplayBatchPolicy.floodBytesPerFrame >= 64 * 1024)
    #expect(TerminalDisplayBatchPolicy.floodDrainsPerFrame >= 2)
}
