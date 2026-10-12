import Foundation
import Testing
@testable import Relay

@Test func settingsRejectUnknownKeysAndWrongTypes() {
    for changes: [String: RelaySettingValue] in [
        ["grantStatus": .string("granted")], ["font_size": .bool(true)],
        ["font_size": .number(25)], ["terminal_padding": .number(-1)],
        ["palette": .string("unknown")], ["decision_model_path": .string("relative.json")],
        ["decision_model_sha256": .string("bad")], [:]
    ] {
        #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(changes) }
    }
}

@Test func settingsAcceptAllNativePreferencesAndDefaultShortcuts() throws {
    try RelaySettingsPolicy.validate([
        "intelligence_enabled": .bool(true), "font_size": .number(13.5),
        "font_family": .string("Menlo"), "terminal_padding": .number(9),
        "key_bindings": .bindings([:])])
    #expect(RelaySettingsPolicy.definitions.count == 16)
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
