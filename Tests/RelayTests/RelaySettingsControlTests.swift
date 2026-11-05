import Foundation
import Testing
@testable import Relay

@Test func settingsRejectUnknownKeysAndWrongTypes() {
    for changes: [String: RelaySettingValue] in [
        ["grantStatus": .string("granted")], ["font_size": .bool(true)],
        ["font_size": .number(25)], ["terminal_padding": .number(-1)],
        ["automatic_agent_maintenance": .string("true")],
        ["haiku_pane_health": .string("true")],
        ["palette": .string("unknown")], ["decision_model_path": .string("relative.json")],
        ["decision_model_sha256": .string("bad")], [:]
    ] {
        #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(changes) }
    }
}

@Test func settingsAcceptAllNativePreferencesAndDefaultShortcuts() throws {
    try RelaySettingsPolicy.validate([
        "intelligence_enabled": .bool(true), "automatic_agent_maintenance": .bool(true), "haiku_pane_health": .bool(true), "font_size": .number(13.5),
        "font_family": .string("Menlo"), "terminal_padding": .number(9),
        "key_bindings": .bindings([:])])
    #expect(RelaySettingsPolicy.definitions.count == 32)
}

@Test func settingsRejectReservedAndDuplicateShortcuts() {
    for bindings in [
        ["newTab": RelayKeyBinding("q", command: true)],
        ["newTab": RelayKeyBinding("d", command: true)],
        ["newTab": RelayKeyBinding("x")],
        ["notACommand": RelayKeyBinding("x", command: true)]
    ] {
        #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["key_bindings": .bindings(bindings)]) }
    }
}

@MainActor @Test func settingsRevisionAndIdempotentReceipt() throws {
    let control = RelaySettingsControl(), instance = UUID(), id = UUID()
    let before = try control.snapshot(instance: instance)
    let proposal = RelaySettingsProposal(instance: instance, requestID: id,
        expectedRevision: before.revision, changes: ["intelligence_enabled": before.values["intelligence_enabled"]!])
    let result = try control.apply(proposal)
    #expect(result.revision == before.revision)
    #expect(try control.apply(proposal).revision == result.revision)
    let conflict = RelaySettingsProposal(instance: instance, requestID: id,
        expectedRevision: before.revision, changes: ["font_size": .number(12)])
    #expect(throws: (any Error).self) { try control.apply(conflict) }
    let stale = RelaySettingsProposal(instance: instance, requestID: UUID(),
        expectedRevision: String(repeating: "0", count: 64), changes: ["font_size": .number(12)])
    #expect(throws: (any Error).self) { try control.apply(stale) }
}

@Test func settingsCLICoversMikoAndRejectsAuthorityChangesByMiko() throws {
    let changes: [String: RelaySettingValue] = [
        "miko_autonomy": .string("cards_for_writes"),
        "miko_actions_per_minute": .number(60), "miko_host_key": .string("local"),
        "miko_shepherd": try RelaySettingsPolicy.json(RelayShepherdSettings()),
        "assistant_hotkey": try RelaySettingsPolicy.json(RelayAssistantHotkey.defaultValue),
        "claude_quota_failover": try RelaySettingsPolicy.json(RelayClaudeQuotaSettings())]
    try RelaySettingsPolicy.validate(changes)
    #expect(RelaySettingsPolicy.allows(changes: changes, assistantIdentity: false))
    #expect(!RelaySettingsPolicy.allows(changes: changes, assistantIdentity: true))
    #expect(RelaySettingsPolicy.allows(changes: ["font_size": .number(12)], assistantIdentity: true))
    #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["miko_actions_per_minute": .number(1.5)]) }
    #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["miko_paused": .bool(true), "font_size": .number(12)]) }
    #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["miko_shepherd": .json(.object(["enabled": .bool(true), "unknown": .bool(true)]))]) }
}

@Test func settingsSearchFindsPublicNamesWithoutIndexingSecrets() {
    #expect(RelaySettingsSearch.matches(section: "general", title: "Appearance", query: "font_size"))
    #expect(RelaySettingsSearch.matches(section: "agent-accounts", title: "Agent Accounts", query: "MCP sync"))
    #expect(RelaySettingsSearch.matches(section: "intelligence", title: "Intelligence", query: "Miko budget"))
    #expect(!RelaySettingsSearch.matches(section: "general", title: "Appearance", query: "api key"))
}

@MainActor @Test func settingsReceiptIsVerifiedAndRejectsStaleReplay() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelaySettingsControl(routing: RelayAgentAccountRouting(url: directory.appendingPathComponent("routing.json"))), instance = UUID()
    let before = try control.snapshot(instance: instance)
    let proposal = RelaySettingsProposal(instance: instance, requestID: UUID(), expectedRevision: before.revision,
        changes: ["intelligence_enabled": before.values["intelligence_enabled"]!])
    let result = try control.apply(proposal)
    #expect(result.receipt?.requestID == proposal.requestID)
    #expect(result.receipt?.verifiedRevision == result.revision)
    #expect(result.receipt?.changedKeys == ["intelligence_enabled"])
    #expect(result.receipt?.outcome == "verified")
    // Only mutate this control's isolated routing store; shared preferences stay unchanged.
    control.routing.update { $0.global["claude"] = "receipt-test" }
    defer { control.routing.update { $0.global.removeValue(forKey: "claude") } }
    #expect(throws: (any Error).self) { try control.apply(proposal) }
}
