import Foundation
import Testing
@testable import Relay

/// 2026-11-19: when the dandy-07 node reconnected, every pane resumed at once
/// and the screens the user was looking at waited behind ~170 hidden panes'
/// replays on the one shared stream.
@Suite("A reconnected node resumes the panes on screen first")
struct RelayNodeReattachOrderTests {
    let shown: Set<String> = ["active", "beside"]
    let hidden = (0..<20).map { String(format: "hidden-%02d", $0) }

    @Test func shownPanesResumeImmediatelyAndAlone() {
        let waves = RelayNodeReattachOrder.waves(sessionIDs: hidden + ["beside", "active"], shown: shown)
        #expect(waves.first == .init(delayMilliseconds: 0, sessionIDs: ["active", "beside"]))
    }

    @Test func hiddenPanesFollowInSmallStaggeredGroups() {
        let waves = RelayNodeReattachOrder.waves(sessionIDs: hidden + ["active"], shown: shown)
        let later = waves.dropFirst()
        #expect(later.allSatisfy { $0.delayMilliseconds >= RelayNodeReattachOrder.hiddenFirstDelayMilliseconds })
        #expect(later.allSatisfy { $0.sessionIDs.count <= RelayNodeReattachOrder.hiddenGroupSize })
        #expect(zip(later.dropLast(), later.dropFirst()).allSatisfy { $0.delayMilliseconds < $1.delayMilliseconds })
        #expect(later.flatMap(\.sessionIDs) == hidden, "every hidden pane exactly once, in a stable order")
    }

    @Test func withNothingShownEveryPaneStillResumes() {
        let waves = RelayNodeReattachOrder.waves(sessionIDs: hidden, shown: [])
        #expect(waves.flatMap(\.sessionIDs).sorted() == hidden)
        #expect(waves.first?.delayMilliseconds == 0, "the first group starts at once")
    }
}
