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

    /// A hidden pane's screen is not resent until the user opens it; routes
    /// that did not ask to wait (agent observers, workspace sync) still resume.
    @Test func hiddenPaneScreensWaitUntilShownButObserversResume() {
        let panes = Set(hidden.prefix(15))
        let waves = RelayNodeReattachOrder.waves(sessionIDs: hidden + ["active"], shown: shown,
            waitUntilShown: panes.union(["active"]))
        let resumed = waves.flatMap(\.sessionIDs)
        #expect(resumed.first == "active", "a shown pane resumes even though it may wait")
        #expect(resumed.filter(panes.contains).isEmpty, "no hidden pane screen is resent")
        #expect(Array(resumed.dropFirst()) == Array(hidden.dropFirst(15)), "observer routes still resume")
    }
}
