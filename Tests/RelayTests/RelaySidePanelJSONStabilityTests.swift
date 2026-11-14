import Foundation
import Testing
@testable import Relay

/// Idempotent MCP endpoints replay a stored result dictionary. JSONEncoder
/// does not keep dictionary key order stable across calls, so a replay could
/// return different bytes than the first reply.
@Suite struct RelaySidePanelJSONStabilityTests {
    @Test func encodingOneDictionaryRepeatedlyGivesIdenticalBytes() {
        for _ in 0..<500 {
            let result = ["status": "applied", "tabID": UUID().uuidString.lowercased(),
                          "selectedTabID": UUID().uuidString.lowercased(),
                          "workspaceID": UUID().uuidString.lowercased()]
            let first = RelaySidePanelHTTPResponse.json(result).body
            for _ in 0..<4 {
                #expect(RelaySidePanelHTTPResponse.json(result).body == first)
            }
        }
    }
}
