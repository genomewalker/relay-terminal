import Foundation
import Testing
@testable import Relay

@Test @MainActor func paneLinkSelectionIsExplicitBoundedAndReversible() {
    let selection = PaneLinkSelection()
    let ids = (0..<9).map { _ in UUID() }
    selection.toggle(ids[0])
    #expect(selection.paneIDs.isEmpty)
    selection.begin(tabID: UUID(), paneIDs: Set(ids))
    for id in ids { selection.toggle(id) }
    #expect(selection.paneIDs.count == 8)
    #expect(!selection.paneIDs.contains(ids[8]))
    selection.toggle(ids[0])
    #expect(selection.paneIDs.count == 7)
    selection.reviewing = true
    selection.cancel()
    #expect(!selection.active && !selection.reviewing && selection.paneIDs.isEmpty)
}

@Test @MainActor func paneHeaderLinkChoosesAcrossTabsAndConnectsOnlyTwoDistinctPanes() {
    let selection = PaneLinkSelection()
    let first = UUID(), otherTab = UUID(), third = UUID()
    var requests: [([UUID], UUID)] = []
    selection.connectPair = { requests.append(($0, $1)) }
    selection.selectPairPane(first)
    #expect(selection.active && selection.pairMode && selection.acrossApp)
    #expect(selection.paneIDs == [first] && requests.isEmpty)
    #expect(selection.canSelect(otherTab))
    selection.selectPairPane(otherTab)
    #expect(selection.connecting && requests.count == 1)
    #expect(requests[0].0 == [first, otherTab])
    selection.selectPairPane(third)
    #expect(requests.count == 1 && !selection.paneIDs.contains(third))
    selection.finishPair(requests[0].0, generation: requests[0].1, failure: nil)
    #expect(!selection.active && !selection.connecting)
    #expect(selection.resultMessage == "Panes linked")
}

@Test @MainActor func paneHeaderLinkCanCancelWithoutConnecting() {
    let selection = PaneLinkSelection()
    let first = UUID()
    var requests = 0
    selection.connectPair = { _, _ in requests += 1 }
    selection.selectPairPane(first)
    selection.selectPairPane(first)
    #expect(!selection.active && selection.paneIDs.isEmpty && requests == 0)
}

@Test @MainActor func paneHeaderLinkLateCompletionCannotReplaceAnotherSelection() {
    let selection = PaneLinkSelection()
    let first = UUID(), second = UUID(), next = UUID()
    var generation: UUID?
    selection.connectPair = { _, request in generation = request }
    selection.selectPairPane(first)
    selection.selectPairPane(second)
    selection.cancel()
    selection.selectPairPane(next)
    selection.finishPair([first, second], generation: generation!, failure: nil)
    #expect(selection.active && selection.paneIDs == [next] && !selection.connecting)
    #expect(selection.resultMessage == nil)
}

@Test @MainActor func paneHeaderLinkFailureRemainsVisibleAndCanBeReplacedExplicitly() {
    let selection = PaneLinkSelection()
    let first = UUID(), second = UUID(), next = UUID()
    var generation: UUID?
    selection.connectPair = { _, request in generation = request }
    selection.selectPairPane(first)
    selection.selectPairPane(second)
    selection.finishPair([first, second], generation: generation!, failure: "Pane unavailable")
    #expect(selection.pairFailure == "Pane unavailable" && !selection.connecting)
    #expect(selection.resultMessage == nil)
    selection.selectPairPane(next)
    #expect(selection.paneIDs == [next] && selection.pairFailure == nil)
}


@Test @MainActor func paneLinkUXRetryPreservesPairAndIgnoresEarlierCompletion() {
    let selection = PaneLinkSelection()
    let source = UUID(), target = UUID()
    var requests: [([UUID], UUID)] = []
    selection.connectPair = { requests.append(($0, $1)) }
    selection.selectPairPane(source)
    selection.selectPairPane(target)
    selection.finishPair(requests[0].0, generation: requests[0].1, failure: "Unavailable")
    selection.retryPair()
    #expect(requests.count == 2 && requests[1].0 == [source, target])
    #expect(requests[0].1 != requests[1].1 && selection.connecting && selection.pairFailure == nil)
    selection.finishPair(requests[0].0, generation: requests[0].1, failure: nil)
    #expect(selection.connecting && selection.active)
    selection.finishPair(requests[1].0, generation: requests[1].1, failure: nil)
    #expect(selection.resultPaneIDs == [source, target] && !selection.active)
}

@Test @MainActor func paneLinkUXChooseAnotherTargetRetainsSource() {
    let selection = PaneLinkSelection()
    let source = UUID(), target = UUID(), replacement = UUID()
    var requests: [([UUID], UUID)] = []
    selection.connectPair = { requests.append(($0, $1)) }
    selection.selectPairPane(source); selection.selectPairPane(target)
    selection.finishPair(requests[0].0, generation: requests[0].1, failure: "Unavailable")
    selection.chooseAnotherTarget()
    #expect(selection.paneIDs == [source] && selection.orderedPair == [source] && selection.pairFailure == nil)
    selection.selectPairPane(replacement)
    #expect(requests[1].0 == [source, replacement])
}

@Test @MainActor func paneLinkUXSavedMembershipSurvivesCancelAndRejectsStaleRefresh() {
    let selection = PaneLinkSelection()
    let source = UUID(), target = UUID()
    let revision = selection.membershipRevision
    let link = PaneLinkMembership(id: "saved", paneIDs: [source, target], unavailable: false)
    selection.recordMembership(link)
    selection.replaceMemberships([], ifRevision: revision)
    #expect(selection.memberships(for: source) == [link])
    selection.selectPairPane(source); selection.cancel()
    #expect(selection.memberships(for: target) == [link])
    selection.forgetMembership(link.id)
    #expect(selection.memberships.isEmpty)
}

@Test func paneLinkUXMembershipParsingRejectsAmbiguousPairsAndReflectsAvailability() {
    let source = UUID(), target = UUID()
    let record: [String: Any] = ["id": "saved", "members": [["paneID": source.uuidString], ["paneID": target.uuidString]], "transport": "unavailable"]
    #expect(PaneLinkMembership(record: record)?.unavailable == true)
    #expect(PaneLinkMembership(record: ["id": "wrong", "members": [["paneID": source.uuidString], ["paneID": source.uuidString]]]) == nil)
    #expect(PaneLinkMembership(record: ["id": "wrong", "members": [["paneID": "invalid"], ["paneID": target.uuidString]]]) == nil)
}


@Test func paneLinkUXLabelsDistinguishGenericPanesAndPreserveCustomNames() {
    #expect(PaneLinkLabel.make(provider: "Claude", tab: "Local shell", customName: nil, ordinal: nil) == "Claude · Local shell")
    #expect(PaneLinkLabel.make(provider: "Codex", tab: "Local shell 2", customName: nil, ordinal: nil) == "Codex · Local shell 2")
    #expect(PaneLinkLabel.make(provider: "Shell", tab: "Work", customName: nil, ordinal: 2) == "Shell · Work · Pane 2")
    #expect(PaneLinkLabel.make(provider: "Claude", tab: "Work", customName: "Review", ordinal: nil) == "Review")
}

@Test @MainActor func paneHeaderLinkStartsNewPairWithSavedMemberships() {
    let selection = PaneLinkSelection()
    let source = UUID(), target = UUID(), previous = UUID()
    let saved = PaneLinkMembership(id: "retained", paneIDs: [source, previous], unavailable: false)
    selection.recordMembership(saved)
    var requests: [[UUID]] = []
    selection.connectPair = { ids, _ in requests.append(ids) }
    selection.selectPairPane(source)
    #expect(selection.active && selection.pairMode && selection.paneIDs == [source])
    selection.selectPairPane(target)
    #expect(requests == [[source, target]])
    #expect(selection.memberships(for: source) == [saved])
}
