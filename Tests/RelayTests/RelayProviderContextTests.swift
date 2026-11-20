import Foundation
import Testing
@testable import Relay

private func contextFixture(pane: UUID, usage: [String: Int]?) throws -> Data {
    var value: [String: Any] = ["version": 1, "binding": [
        "pane_id": pane.uuidString.lowercased(), "provider": "codex", "process_id": 42,
        "process_start": "kernel:12", "session_id": "current", "source_identity": "4:26"
    ]]
    value["context_usage"] = usage
    return try JSONSerialization.data(withJSONObject: value)
}

@Test func providerContextMatchesExactSessionAndPreservesZero() throws {
    let pane = UUID()
    let data = try contextFixture(pane: pane, usage: ["used_tokens": 0, "limit_tokens": 272_000])
    let context = try #require(RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .codex))
    #expect(context.usedTokens == 0)
    #expect(context.limitTokens == 272_000)
    #expect(context.matches(context.binding))
    let other = RelayAgentConversationBinding(hostID: "host", paneID: pane, provider: "codex",
        processID: 42, processStart: "kernel:12", sessionID: "previous", sourceIdentity: "4:26")
    #expect(!context.matches(other))
    #expect(try RelayProviderContext.decode(data, hostID: "host", paneID: UUID(), provider: .codex) == nil)
    #expect(try RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .claude) == nil)
}

@Test func providerContextMissingOrInvalidValuesStayUnknown() throws {
    let pane = UUID()
    for usage in [nil, ["used_tokens": 24], ["used_tokens": -1, "limit_tokens": 400], ["used_tokens": 42, "limit_tokens": 0]] {
        let data = try contextFixture(pane: pane, usage: usage)
        let context = try #require(RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .codex))
        #expect(context.label == RelayProviderContext.unknown)
    }
}
