import Foundation
import Testing
@testable import Relay

private let editorFrameBegin = Data("\u{1b}[?2026h".utf8)
private let editorFrameEnd = Data("\u{1b}[?2026l".utf8)
private let editorFrameBody = Data(repeating: 0x78, count: 512)

@Test func promptEditorFrameTracksSplitSequencesAndRequiresFreshBegin() {
    var tracker = RelayPromptEditorFrameTracker()
    _ = tracker.observe(editorFrameBegin)
    tracker.arm()
    #expect(tracker.observe(editorFrameBody + editorFrameEnd) == nil)
    for byte in editorFrameBegin { #expect(tracker.observe(Data([byte])) == nil) }
    #expect(tracker.observe(editorFrameBody) == nil)
    for byte in editorFrameEnd.dropLast() { #expect(tracker.observe(Data([byte])) == nil) }
    #expect(tracker.observe(Data([editorFrameEnd.last!])) == .completedFrame)
}

@Test func promptEditorFrameIgnoresStringPayloadsAcrossArmBoundary() {
    for introducer in ["\u{1b}]", "\u{1b}P", "\u{1b}_", "\u{1b}^", "\u{1b}X"] {
        var tracker = RelayPromptEditorFrameTracker()
        _ = tracker.observe(Data(introducer.utf8))
        tracker.arm()
        let payload = Data("[?2026h".utf8) + editorFrameBody + Data("[?2026l".utf8)
        for byte in payload { #expect(tracker.observe(Data([byte])) == nil) }
        #expect(tracker.observe(Data("\u{1b}\\".utf8)) == nil)
        #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd) == .completedFrame)
    }
}

@Test func promptEditorFrameRejectsTinyAndUnclosedUpdates() {
    var tracker = RelayPromptEditorFrameTracker()
    tracker.arm()
    #expect(tracker.observe(editorFrameEnd) == nil)
    #expect(tracker.observe(editorFrameBegin + Data("spinner".utf8) + editorFrameEnd) == nil)
    #expect(tracker.observe(editorFrameBegin + editorFrameBody) == nil)
    #expect(tracker.observe(editorFrameBegin) == nil) // repeated enable is not a new frame
    #expect(tracker.observe(editorFrameEnd) == .completedFrame)
    #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd + editorFrameBegin) == nil)
    #expect(tracker.observe(editorFrameEnd) == .completedFrame)
}

@Test func promptEditorFrameHandlesMultipleModesAndOversizedParameters() {
    var tracker = RelayPromptEditorFrameTracker()
    tracker.arm()
    #expect(tracker.observe(Data("\u{1b}[?2026;25h".utf8) + editorFrameBody + Data("\u{1b}[?25;2026l".utf8)) == .completedFrame)
    let oversized = Data(("\u{1b}[?2026;" + String(repeating: "0", count: 100) + "h").utf8)
    #expect(tracker.observe(oversized + editorFrameBody + editorFrameEnd) == nil)
    #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd) == .completedFrame)
}

@Test func promptEditorFrameMatchesNativeParameterLimitIncludingEmptyEntries() {
    for entry in ["", "0"] {
        var rejected = RelayPromptEditorFrameTracker()
        rejected.arm()
        let modes = String(repeating: entry + ";", count: 24) + "2026"
        #expect(rejected.observe(Data("\u{1b}[?\(modes)h".utf8) + editorFrameBody + editorFrameEnd) == nil)
        var accepted = RelayPromptEditorFrameTracker()
        accepted.arm()
        let boundary = String(repeating: entry + ";", count: 23) + "2026"
        #expect(accepted.observe(Data("\u{1b}[?\(boundary)h".utf8) + editorFrameBody + editorFrameEnd) == .completedFrame)
    }
}

@Test func promptEditorFrameOverflowRetainsLexicalStateForNextArm() {
    var tracker = RelayPromptEditorFrameTracker(maximumBytes: 600)
    tracker.arm()
    #expect(tracker.observe(Data("\u{1b}]".utf8) + Data(repeating: 0x78, count: 600)) == .overflow)
    tracker.arm()
    #expect(tracker.observe(Data("[?2026h".utf8) + editorFrameBody + Data("[?2026l".utf8) + Data([7])) == nil)
    tracker.disarm(); tracker.arm()
    #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd) == .completedFrame)
}

@Test(.timeLimit(.minutes(1))) func promptEditorRestorationBarrierRejectsReplayAndOverlappingArms() async {
    let io = TerminalIOBridge()
    let first = io.beginPromptEditorRestorationBarrier()
    var events = first.events.makeAsyncIterator()
    #expect(await events.next() == .armed(revision: 0))
    let second = io.beginPromptEditorRestorationBarrier()
    var conflicting = second.events.makeAsyncIterator()
    #expect(await conflicting.next() == .invalidated)
    #expect(await conflicting.next() == nil)
    io.beginReplay()
    #expect(await events.next() == .invalidated)
    #expect(await events.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func promptEditorRestorationBarrierRejectsTransportRemoval() async {
    let io = TerminalIOBridge()
    let barrier = io.beginPromptEditorRestorationBarrier()
    var events = barrier.events.makeAsyncIterator()
    #expect(await events.next() == .armed(revision: 0))
    _ = io.removeTransport()
    #expect(await events.next() == .invalidated)
    #expect(await events.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func promptEditorRestorationBarrierFinishesWithBridge() async {
    var io: TerminalIOBridge? = TerminalIOBridge()
    let barrier = io!.beginPromptEditorRestorationBarrier()
    var events = barrier.events.makeAsyncIterator()
    #expect(await events.next() == .armed(revision: 0))
    weak var released = io
    io = nil
    #expect(await events.next() == nil)
    #expect(released == nil)
}

@Test func promptEditorFrameRejectsMalformedModeListsAndNonvisualPayloads() {
    var tracker = RelayPromptEditorFrameTracker()
    tracker.arm()
    for invalid in ["?2026;?", "?2026;>", "?2026;:0", "?2026;=25"] {
        #expect(tracker.observe(Data(("\u{1b}[" + invalid + "h").utf8) + editorFrameBody + editorFrameEnd) == nil)
    }
    let title = Data("\u{1b}]0;".utf8) + editorFrameBody + Data([7])
    #expect(tracker.observe(editorFrameBegin + title + editorFrameEnd) == nil)
    #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd) == .completedFrame)
}

@Test func promptEditorFrameMatchesEscAbortsAndContextualC1() {
    for introducer in ["\u{1b}]", "\u{1b}P", "\u{1b}_", "\u{1b}^", "\u{1b}X"] {
        var tracker = RelayPromptEditorFrameTracker()
        _ = tracker.observe(Data(introducer.utf8))
        tracker.arm()
        #expect(tracker.observe(editorFrameBegin + editorFrameBody + editorFrameEnd) == .completedFrame)
    }
    var tracker = RelayPromptEditorFrameTracker()
    tracker.arm()
    // C1 OSC after ESC changes parser state; its text is not a painted frame.
    let c1Title = Data([0x1b, 0x9d]) + Data("0;".utf8) + editorFrameBody + Data([7])
    #expect(tracker.observe(editorFrameBegin + c1Title + editorFrameEnd) == nil)
    // C1 ST terminates DCS, allowing the following actual text to be painted.
    let dcs = Data("\u{1b}Pqpayload".utf8) + Data([0x9c])
    #expect(tracker.observe(editorFrameBegin + dcs + editorFrameBody + editorFrameEnd) == .completedFrame)
    // Standalone C1 bytes in ground state do not introduce CSI in UTF-8 mode.
    #expect(tracker.observe(Data([0x9b]) + Data("?2026h".utf8) + editorFrameBody + editorFrameEnd) == nil)
    #expect(tracker.observe(editorFrameBegin + Data(String(repeating: "Û🧬", count: 128).utf8) + editorFrameEnd) == .completedFrame)
}
