import Foundation
import Testing
@testable import Relay

@Test("Plugin agent snapshots prioritize attention, bound rows and preserve stable identities")
func pluginAgentSnapshot() {
    var agents = (0..<150).map { SubagentActivity(id: "id-\($0)", label: "Same name", startedAt: Date(timeIntervalSince1970: Double($0))) }
    agents[0].phase = .needsInput
    agents[0].threadID = "thread-special"
    let snapshot = PluginAgentSnapshot(agents: agents, events: [], now: Date(timeIntervalSince1970: 999))
    #expect(snapshot.total == 150)
    #expect(snapshot.agents.count == 100)
    #expect(snapshot.agents.first?.id == "id-0")
    #expect(snapshot.agents[1].id == "id-149")
    #expect(snapshot.matching("thread-special").map(\.id) == ["id-0"])
    #expect(snapshot.matching("not here").isEmpty)
    agents[0].phase = .exited
    #expect(snapshot.agents.first?.phase == .needsInput)
}
