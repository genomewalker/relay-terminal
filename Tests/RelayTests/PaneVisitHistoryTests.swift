import Foundation
import Testing
@testable import Relay

@Suite("Go to pane: recent and frequently used panes")
struct PaneVisitHistoryTests {
    private typealias Index = RelayWorkOverviewIndex
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pane(_ id: String, title: String = "Pane", location: String = "Research › Analysis",
                      fields: [String] = [], attention: Bool = false, current: Bool = false,
                      active: Bool = false, visited: TimeInterval? = nil, frecency: Double = 0) -> Index.Entry {
        .init(id: id, title: title, location: location, status: "Idle", details: "",
              symbol: "terminal", destination: .pane(UUID(), UUID()), searchFields: fields,
              needsAttention: attention, isCurrent: current, changedAt: nil,
              lastVisitedAt: visited.map { t0.addingTimeInterval($0) }, frecency: frecency, isActivePane: active)
    }

    // MARK: Ordering and grouping

    @Test("Recent spans workspaces, sits below attention and above current work, newest first")
    func crossWorkspaceOrdering() {
        let rows = Index.results([
            pane("current", current: true),
            pane("other-ws-old", location: "Assembly › Run", visited: 10),
            pane("attention", attention: true),
            pane("third-ws-new", location: "Notes › Draft", visited: 30),
            pane("this-ws", current: true, visited: 20),
            pane("unvisited")
        ], query: "")
        #expect(rows.map(\.id) == ["attention", "third-ws-new", "this-ws", "other-ws-old", "current", "unvisited"])
        #expect(rows.filter { $0.group == .visited }.map(\.id) == ["third-ws-new", "this-ws", "other-ws-old"])
        #expect(Index.Group.visited.title == "Recent")
        let order = Index.Group.allCases
        #expect(order.firstIndex(of: .attention)! < order.firstIndex(of: .visited)!)
        #expect(order.firstIndex(of: .visited)! < order.firstIndex(of: .current)!)
    }

    @Test("Equal visit times fall back to frecency")
    func frecencyTieBreak() {
        let rows = Index.results([
            pane("rare", visited: 10, frecency: 1),
            pane("frequent", visited: 10, frecency: 5)
        ], query: "")
        #expect(rows.map(\.id) == ["frequent", "rare"])
    }

    @Test("The active pane is not listed as recent, and no pane appears in two groups")
    func currentPaneExcludedAndNoDuplicates() {
        let rows = Index.results([
            pane("active", current: true, active: true, visited: 50),
            pane("waiting", attention: true, visited: 40),
            pane("previous", visited: 30)
        ], query: "")
        #expect(rows.first { $0.id == "active" }?.group == .current)
        #expect(rows.first { $0.id == "waiting" }?.group == .attention)
        #expect(rows.filter { $0.group == .visited }.map(\.id) == ["previous"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        let sections = Index.sections(rows, query: "")
        let listed = sections.flatMap(\.entries).map(\.id)
        #expect(listed.count == Set(listed).count)
        #expect(listed == rows.map(\.id))
    }

    @Test("Recent is capped; older visited panes stay in their usual group")
    func recentCap() {
        let entries = (0..<(Index.recentLimit + 3)).map { pane("p\($0)", visited: TimeInterval($0)) }
        let rows = Index.results(entries, query: "")
        #expect(rows.filter { $0.group == .visited }.count == Index.recentLimit)
        #expect(rows.first { $0.id == "p0" }?.group == .other)
    }

    @Test("Without a query the previously visited pane is preselected, even below attention")
    func previousPanePreselected() {
        let rows = Index.results([
            pane("active", current: true, active: true, visited: 50),
            pane("alert", attention: true),
            pane("older", visited: 10),
            pane("previous", visited: 40)
        ], query: "")
        #expect(Index.selectedID(nil, in: rows, query: "") == "previous")
        #expect(Index.movedSelection(nil, by: 1, in: rows, query: "") == "older")
        // An explicit selection is kept by identity.
        #expect(Index.selectedID("alert", in: rows, query: "") == "alert")
        // Nothing visited: the first row, as before.
        let plain = Index.results([pane("a"), pane("b")], query: "")
        #expect(Index.selectedID(nil, in: plain, query: "") == "a")
    }

    @Test("A query ranks by match quality first, then frecency, as one list")
    func queryRanking() {
        let entries = [
            pane("field-hot", title: "Shell", fields: ["assembler"], visited: 90, frecency: 9),
            pane("contains", title: "Run assembler", visited: 10, frecency: 1),
            pane("prefix-cold", title: "Assembler notes", frecency: 0),
            pane("prefix-warm", title: "Assembler logs", visited: 20, frecency: 3),
            pane("exact", title: "assembler")
        ]
        let rows = Index.results(entries, query: "Assembler")
        #expect(rows.map(\.id) == ["exact", "prefix-warm", "prefix-cold", "contains", "field-hot"])
        #expect(Index.selectedID(nil, in: rows, query: "Assembler") == "exact")
        let sections = Index.sections(rows, query: "Assembler")
        #expect(sections.count == 1)
        #expect(sections[0].entries.map(\.id) == rows.map(\.id))
    }

    // MARK: History

    @Test("Frecency decays with a fixed half-life and is deterministic for a given now")
    func frecencyDecay() {
        let id = UUID()
        var history = PaneVisitHistory()
        history.record(id, at: t0)
        #expect(history.frecency(of: id, at: t0) == 1)
        let half = history.frecency(of: id, at: t0.addingTimeInterval(PaneVisitHistory.halfLife))
        #expect(abs(half - 0.5) < 1e-9)
        let other = UUID()
        history.record(other, at: t0.addingTimeInterval(PaneVisitHistory.halfLife))
        history.record(id, at: t0.addingTimeInterval(PaneVisitHistory.halfLife))
        #expect(abs(history.frecency(of: id, at: t0.addingTimeInterval(PaneVisitHistory.halfLife)) - 1.5) < 1e-9)
        #expect(history.visit(id)?.visitCount == 2)
        #expect(history.frecency(of: UUID(), at: t0) == 0)
    }

    @Test("Refocusing the most recent pane does not inflate its count")
    func repeatedFocusIsOneVisit() {
        let id = UUID()
        var history = PaneVisitHistory()
        history.record(id, at: t0)
        history.record(id, at: t0.addingTimeInterval(5))
        #expect(history.visit(id)?.visitCount == 1)
        #expect(history.visit(id)?.lastVisitedAt == t0.addingTimeInterval(5))
    }

    @Test("History is bounded, drops the oldest, and prunes closed panes")
    func boundAndPruning() {
        var history = PaneVisitHistory()
        let ids = (0..<(PaneVisitHistory.limit + 5)).map { _ in UUID() }
        for (offset, id) in ids.enumerated() { history.record(id, at: t0.addingTimeInterval(TimeInterval(offset))) }
        #expect(history.visits.count == PaneVisitHistory.limit)
        #expect(history.visit(ids[0]) == nil)
        #expect(history.visit(ids[4]) == nil)
        #expect(history.visit(ids[5]) != nil)
        #expect(history.visits.first?.paneID == ids.last)
        history.prune(keeping: Set(ids.suffix(3)))
        #expect(history.visits.map(\.paneID) == Array(ids.suffix(3).reversed()))
    }

    @Test("Visit history survives an encode/decode round trip and a shared-store merge")
    func persistenceRoundTrip() throws {
        let tab = UUID(), kept = UUID(), closed = UUID()
        var history = PaneVisitHistory()
        history.record(closed, at: t0)
        history.record(kept, at: t0.addingTimeInterval(60))
        let snapshot = WorkspaceSnapshot(tabs: [TabSnapshot(id: tab, sessionID: tab, name: "A",
            layout: .pane(kept), floatingPanes: [], splitRatios: [:])],
            panes: [PaneSnapshot(id: kept, profile: .local, contentKind: .terminal,
                remoteParentSessionID: nil, editorRequest: nil, customName: nil)],
            sessionNames: [:], selectedTabID: tab, activePaneID: kept, paneVisits: history.visits)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.paneVisits == history.visits)
        // A snapshot written before visit history existed still decodes.
        let legacy = WorkspaceSnapshot(tabs: snapshot.tabs, panes: snapshot.panes, sessionNames: [:],
                                       selectedTabID: tab, activePaneID: kept)
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(legacy)).paneVisits == nil)
        // The shared store keeps visits for live panes only.
        let merged = try RelaySharedWorkspaceStore.merge(local: snapshot, baseline: legacy, current: legacy)
        #expect(merged.paneVisits?.map(\.paneID) == [kept])
    }

    @Test("Merging visit histories keeps the newer visit per pane")
    func mergeKeepsNewest() {
        let a = UUID(), b = UUID()
        var mine = PaneVisitHistory(), theirs = PaneVisitHistory()
        mine.record(a, at: t0)
        theirs.record(a, at: t0.addingTimeInterval(30))
        theirs.record(b, at: t0.addingTimeInterval(10))
        let merged = PaneVisitHistory.merged(mine.visits, theirs.visits, keeping: [a, b])
        #expect(merged.map(\.paneID) == [a, b])
        #expect(merged.first?.lastVisitedAt == t0.addingTimeInterval(30))
    }

    // MARK: Recording origin

    @MainActor
    @Test("Only user-initiated pane selection records a visit")
    func programmaticFocusNotRecorded() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newFloatingPane()
        let first = workspace.activePane!.id
        workspace.newFloatingPane()
        let second = workspace.activePane!.id
        #expect(workspace.paneVisits.visits.isEmpty)
        workspace.selectPane(first, origin: .programmatic)
        workspace.revealPane(second, origin: .programmatic)
        #expect(workspace.activePaneID == second)
        #expect(workspace.paneVisits.visits.isEmpty)
        workspace.selectPane(first, origin: .user)
        #expect(workspace.paneVisits.visits.map(\.paneID) == [first])
        workspace.revealPane(second, origin: .user)
        #expect(workspace.paneVisits.visits.map(\.paneID) == [second, first])
        workspace.selectPane(first, origin: .programmatic)
        #expect(workspace.paneVisits.visits.map(\.paneID) == [second, first])
    }

    @MainActor
    @Test("Rapid user visits coalesce into one workspace write that holds the last visit")
    func rapidVisitsCoalesce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-visits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
        defer { workspace.shutdown() }
        workspace.newFloatingPane()
        let first = workspace.activePane!.id
        workspace.newFloatingPane()
        let second = workspace.activePane!.id
        try await Task.sleep(for: .milliseconds(600))
        let before = workspace.workspaceSaveCount
        let ids = [first, second]
        for step in 0..<20 { workspace.selectPane(ids[step % 2], origin: .user) }
        #expect(workspace.workspaceSaveCount == before)
        try await Task.sleep(for: .milliseconds(600))
        #expect(workspace.workspaceSaveCount == before + 1)
        let saved = try #require(try workspace.sharedWorkspaceStore.restore(legacy: nil))
        #expect(saved.paneVisits?.first?.paneID == second)
        #expect(saved.paneVisits?.map(\.paneID) == workspace.paneVisits.visits.map(\.paneID))
    }
}
