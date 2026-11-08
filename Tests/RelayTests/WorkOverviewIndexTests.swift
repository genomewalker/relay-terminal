import Foundation
import Testing
@testable import Relay

@Suite("Go to pane metadata and keyboard selection")
struct WorkOverviewIndexTests {
    private typealias Index = RelayWorkOverviewIndex
    private func entry(_ id: String, title: String = "Pane", location: String = "Research › Analysis",
                       fields: [String] = [], attention: Bool = false, current: Bool = false,
                       changed: TimeInterval? = nil) -> Index.Entry {
        .init(id: id, title: title, location: location, status: "Reported ready", details: "",
              symbol: "terminal", destination: .pane(UUID(), UUID()), searchFields: fields,
              needsAttention: attention, isCurrent: current,
              changedAt: changed.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("Attention precedes current work, timestamped activity and other work")
    func priorityAndRecency() {
        let rows = Index.results([
            entry("other"), entry("older", changed: 5), entry("recent", changed: 10),
            entry("current", current: true), entry("attention", attention: true)
        ], query: "")
        #expect(rows.map(\.id) == ["attention", "current", "recent", "older", "other"])
        #expect(rows.last?.group == .other)
    }

    @Test("Search spans container and hidden-stack metadata with all query words")
    func hiddenStackSearch() {
        let hidden = entry("hidden", title: "Assembler", fields: ["hidden stack", "dandy-07", "/maps/project"])
        let visible = entry("visible", title: "Assembler", fields: ["dandy-08"])
        #expect(Index.results([visible, hidden], query: "research dandy-07 stack").map(\.id) == ["hidden"])
        #expect(Index.results([hidden], query: "   \n  ").count == 1)
        #expect(Index.results([hidden], query: "missing").isEmpty)
    }

    @Test("Arrows clamp at boundaries and an empty result has no Enter target")
    func keyboardBoundaries() {
        let rows = [entry("a"), entry("b"), entry("c")]
        #expect(Index.selectedID(nil, in: rows) == "a")
        #expect(Index.movedSelection(nil, by: -1, in: rows) == "a")
        #expect(Index.movedSelection("a", by: 1, in: rows) == "b")
        #expect(Index.movedSelection("c", by: 1, in: rows) == "c")
        #expect(Index.movedSelection("a", by: 1, in: []) == nil)
        #expect(Index.selectedID("a", in: []) == nil)
    }

    @Test("Live priority changes preserve the selected Enter target by identity")
    func stableSelection() {
        let reordered = [entry("new-alert", attention: true), entry("b"), entry("a")]
        #expect(Index.selectedID("a", in: reordered) == "a")
        #expect(Index.movedSelection("a", by: -1, in: reordered) == "b")
        #expect(Index.selectedID("closed-pane", in: reordered) == "new-alert")
    }

    @Test("All matching results remain reachable beyond five hundred entries")
    func noSilentResultCap() {
        let rows = (0..<520).map { entry("pane-\($0)", title: "Pane \($0)") }
        #expect(Index.results(rows, query: "Pane").count == 520)
        #expect(Index.results(rows, query: "519").map(\.id) == ["pane-519"])
    }
}
