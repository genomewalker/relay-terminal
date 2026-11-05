import Foundation
import Testing
@testable import Relay

@Suite("Overview settings and tool navigation")
struct WorkOverviewNavigationTests {
    private typealias Index = RelayWorkOverviewIndex
    private func destinations(_ query: String) -> [Index.Destination] {
        Index.results(Index.navigationEntries(query: query), query: query).map(\.destination)
    }

    @Test("Public control aliases resolve to exact native sections")
    func settingsRoutes() {
        for section in RelaySettingsSearch.sections {
            #expect(destinations(section.title).contains(.settings(section.id)))
        }
        for (query, section) in [("change font size", "general"), ("keyboard shortcuts", "keyboard"),
                                 ("codex mcp", "agent-accounts"), ("api credentials", "accounts"),
                                 ("remote ssh", "connections"), ("miko budget", "intelligence")] {
            #expect(destinations(query).contains(.settings(section)))
        }
        #expect(!destinations("keyboard shortcuts").contains(.settings("accounts")))
    }

    @Test("Control Center is explicit and Miko is a fallback for free text")
    func toolRoutes() {
        #expect(destinations("control center").contains(.controlCenter))
        #expect(destinations("help me understand this work").contains(.askMiko))
        let rows = Index.results(Index.navigationEntries(query: "keyboard"), query: "keyboard")
        #expect(rows.first?.destination == .settings("keyboard"))
        #expect(rows.last?.destination == .askMiko)
        #expect(Index.movedSelection(rows.first?.id, by: 1, in: rows) == rows.last?.id)
        #expect(Set(Index.navigationEntries(query: "").map(\.id)).count == 11)
    }
}
