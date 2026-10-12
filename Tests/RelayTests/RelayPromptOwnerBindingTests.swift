import Foundation
import Testing
@testable import Relay

@Test func promptReconnectRequiresExactIdentityDraftAndCaret() throws {
    let pane = UUID(uuidString: "b275f897-f877-4034-afe6-454c57112411")!
    let host = UUID(uuidString: "6687c9a8-ba4e-4a97-8709-3a4662fc7516")!
    let row: [String: Any] = ["version":1, "pane_id":pane.uuidString.lowercased(),
        "node_boot_id":"kernel-boot", "worker_pid":100, "worker_start":1000001,
        "shell_pid":101, "shell_start":1000002, "provider":"codex", "process_id":102,
        "process_start":1000003, "session_id":"original-session", "transcript_identity":"1:2"]
    func binding(_ changes: [String: Any] = [:]) throws -> RelayPromptOwnerBinding {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayPromptOwnerBinding.self,
            from: JSONSerialization.data(withJSONObject: row.merging(changes) { _, new in new }))
    }
    let original = RelayPromptOwnerIdentity(hostID:host, binding:try binding())
    let draft = TerminalPromptBuffer.Snapshot(characters:Array("A👩🏽‍💻B\n漢字"), cursor:3)
    #expect(original.binding.isValid(for:pane))
    #expect(original.permitsHistoryRestore(observed:original, expected:draft, rendered:draft))
    #expect(!original.permitsHistoryRestore(observed:nil, expected:draft, rendered:draft))
    for change: [String:Any] in [["worker_start":1000009], ["shell_start":1000009],
        ["process_start":1000009], ["session_id":"different"], ["transcript_identity":"1:3"],
        ["node_boot_id":"different-boot"], ["pane_id":UUID().uuidString.lowercased()]] {
        let changed = RelayPromptOwnerIdentity(hostID:host, binding:try binding(change))
        #expect(!original.permitsHistoryRestore(observed:changed, expected:draft, rendered:draft))
    }
    let otherHost = RelayPromptOwnerIdentity(hostID:UUID(), binding:original.binding)
    #expect(!original.permitsHistoryRestore(observed:otherHost, expected:draft, rendered:draft))
    #expect(!original.permitsHistoryRestore(observed:original, expected:draft,
        rendered:.init(characters:draft.characters, cursor:2)))
    #expect(!original.permitsHistoryRestore(observed:original, expected:draft,
        rendered:.init(characters:Array("different"), cursor:3)))
    #expect(!(try binding(["process_start":0])).isValid(for:pane))
}

@Test func promptHistoryExecutionMarkersPreserveEveryBoundary() {
    let tracker = TerminalSemanticPromptStateTracker()
    #expect(tracker.observe(Data("\u{001B}]133;B\u{0007}".utf8)) == true)
    let before = tracker.executionGeneration
    // The final state equals the starting prompt, but a command ran in between.
    #expect(tracker.observe(Data("\u{001B}]133;C\u{0007}output\u{001B}]133;B\u{0007}".utf8)) == true)
    #expect(tracker.executionGeneration == before + 1)
    #expect(!TerminalPromptReconnectBoundaryPolicy.invalidatesHistory(
        executionChanged:true, replaying:true, remoteSequence:50, knownSequence:50))
    #expect(TerminalPromptReconnectBoundaryPolicy.invalidatesHistory(
        executionChanged:true, replaying:true, remoteSequence:51, knownSequence:50))
    #expect(TerminalPromptReconnectBoundaryPolicy.invalidatesHistory(
        executionChanged:true, replaying:false, remoteSequence:0, knownSequence:50))
    #expect(!TerminalPromptReconnectBoundaryPolicy.invalidatesHistory(
        executionChanged:false, replaying:false, remoteSequence:51, knownSequence:50))
    let fragmented = TerminalSemanticPromptStateTracker()
    _ = fragmented.observe(Data("\u{001B}]133;".utf8))
    #expect(fragmented.executionGeneration == 0)
    _ = fragmented.observe(Data("C\u{0007}\u{001B}]133;C\u{0007}".utf8))
    #expect(fragmented.executionGeneration == 2)
}

@Test func bootstrapInputOwnerFlagSurvivesTheEditorWireCodec() throws {
    let pane = UUID()
    let row: [String: Any] = ["version": 1, "pane_id": pane.uuidString.lowercased(),
        "node_boot_id": "kernel-boot", "worker_pid": 100, "worker_start": 1001,
        "shell_pid": 101, "shell_start": 1002, "provider": "claude", "process_id": 102,
        "process_start": 1003, "session_id": "actual-session",
        "transcript_identity": "input:" + String(repeating: "a", count: 48), "input_only": true]
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let owner = try decoder.decode(RelayPromptOwnerBinding.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(owner.isInputOnly && owner.isValid(for: pane))
    let encoded = try JSONEncoder().encode(owner)
    let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(wire["input_only"] as? Bool == true)
    #expect(wire["process_start"] as? Int == 1003)
    #expect(try decoder.decode(RelayPromptOwnerBinding.self, from: encoded) == owner)
    var missingFlag = row; missingFlag.removeValue(forKey: "input_only")
    #expect(!(try decoder.decode(RelayPromptOwnerBinding.self,
        from: JSONSerialization.data(withJSONObject: missingFlag))).isValid(for: pane))
}
