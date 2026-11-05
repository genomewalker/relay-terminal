import Foundation
import Testing
@testable import Relay

@Suite("Miko pane inventory")
struct RelayMikoPaneInventoryTests {
    private func inventory() -> RelayAssistantSnapshot {
        let tab = UUID(), session = UUID()
        let panes = (0..<75).map { index in
            RelayAssistantSnapshot.Pane(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                tabID: tab, sessionID: session, title: "Pane \(index)", host: "dandy-07",
                kind: "claude", contentKind: "terminal", connection: "Connected", phase: "quiet",
                selected: false, zoomed: false, hostAlias: "dandy-07",
                account: index.isMultiple(of: 2) ? "business" : "personal")
        }
        return .init(panes: Array(panes.reversed()), tabs: [], selectedTabID: nil, selectedPaneID: nil, zoomedPaneID: nil)
    }

    @Test("Every pane is reachable once and pages stay inside the host byte limit")
    func completeInventory() throws {
        let snapshot = inventory()
        var offset = 0
        var seen: [String] = []
        repeat {
            let page = snapshot.panePage(query: nil, offset: offset)
            #expect(try RelayPaneHealthJSON.data(RelayPaneHealthJSON.object(page)).count <= 7_000)
            #expect(page["count"] == .integer(75))
            let rows = try #require(page["panes"]?.array)
            #expect(!rows.isEmpty && rows.count <= 32)
            seen += rows.compactMap { $0["pane_id"]?.string }
            guard case .integer(let next)? = page["next_offset"] else { break }
            try #require(next > offset)
            offset = Int(next)
        } while true
        #expect(seen.count == 75 && Set(seen).count == 75)
        #expect(seen == seen.sorted())
    }

    @Test("Account filtering and offsets use the same inventory")
    func accountFilter() throws {
        let snapshot = inventory()
        let page = snapshot.panePage(query: "business", offset: 35)
        #expect(page["count"] == .integer(38))
        #expect(page["panes"]?.array?.count == 3)
        #expect(page["next_offset"] == .null)
        #expect(page["panes"]?.array?.allSatisfy { $0["account"] == .string("business") } == true)
        let end = snapshot.panePage(query: "business", offset: 1_000_000)
        #expect(end["panes"] == .array([]) && end["next_offset"] == .null)
    }

    @Test("Relay owns the complete counts and tab-ID lookup independently of model paging")
    func canonicalMapSummary() throws {
        var snapshot = inventory()
        let first = snapshot.panePage(query: nil, offset: 0)
        let later = snapshot.panePage(query: nil, offset: 50)
        let summary = try #require(first["inventory_summary"])
        #expect(summary["pane_count"] == .integer(75))
        #expect(summary["tab_count"] == .integer(1))
        #expect(summary["groups_truncated"] == .bool(false))
        let groups = try #require(summary["by_host_kind_account"]?.array)
        let total = groups.compactMap { row -> Int64? in if case .integer(let count)? = row["count"] { return count }; return nil }.reduce(0, +)
        #expect(total == 75)
        #expect(summary == later["inventory_summary"])
        #expect(first["inventory_id"] == later["inventory_id"])
        let tab = try #require(snapshot.panes.first?.tabID)
        #expect(snapshot.panePage(query: tab.uuidString, offset: 0)["count"] == .integer(75))
        snapshot.selectedPaneID = snapshot.panes[0].id
        #expect(snapshot.panePage(query: nil, offset: 0)["inventory_id"] == first["inventory_id"])
        snapshot.panes[0].account = "another-account"
        #expect(snapshot.panePage(query: nil, offset: 0)["inventory_id"] != first["inventory_id"])
    }

    @Test("Offsets reject invalid types and bounds before reading")
    func offsetValidation() throws {
        let snapshot = inventory()
        #expect(try RelayAssistantToolValidator.validate(name: "list_panes",
            input: .object(["offset": .integer(32)]), snapshot: snapshot).get() == .listPanes(query: nil, offset: 32))
        for value: RelayPaneHealthJSON in [.integer(-1), .integer(1_000_001), .bool(true), .string("32")] {
            if case .success = RelayAssistantToolValidator.validate(name: "list_panes",
                input: .object(["offset": value]), snapshot: snapshot) {
                Issue.record("Invalid offset accepted: \(value)")
            }
        }
    }
}
