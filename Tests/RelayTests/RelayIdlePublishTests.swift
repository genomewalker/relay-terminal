import Combine
import Foundation
import Testing
@testable import Relay

/// The 5 s supervisor loop must not invalidate WorkspaceModel observers.
/// Each tick rebuilds recommendations with a fresh `observedAt`, so a
/// published property here re-rendered the whole window every 5 s while idle.
@MainActor @Test("Supervisor ticks update recommendations without publishing the workspace")
func supervisorTickDoesNotPublishWorkspace() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try! #require(workspace.activePane)
    pane.received("OpenAI Codex CLI\nworking\n")
    let start = Date()
    workspace.refreshSupervisorRecommendations(now: start)
    let first = try! #require(workspace.supervisorRecommendations[pane.id])

    var publishes = 0
    let subscription = workspace.objectWillChange.sink { _ in publishes += 1 }
    for step in 1...3 {
        workspace.refreshSupervisorRecommendations(now: start.addingTimeInterval(Double(step) * 5))
    }
    subscription.cancel()

    #expect(publishes == 0)
    // State is still exactly current for on-demand readers.
    let latest = try! #require(workspace.supervisorRecommendations[pane.id])
    #expect(latest.observedAt == start.addingTimeInterval(15))
    #expect(latest.observedAt > first.observedAt)
    #expect(latest.identity.paneID == pane.id)
    workspace.shutdown()
}

/// The former two-pass decode (generic envelope, re-encode, typed decode),
/// kept here only as the parity oracle for `decodeReply`.
private func legacyDecode(_ raw: Data) throws -> RelayPaneHealthHostControllerStatus {
    let envelope = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: raw)
    if let error = envelope["error"]?.string { throw RelayHostRotationRPC.Failure.refused(String(error.prefix(240))) }
    guard let result = envelope["result"] else { throw RelayHostRotationRPC.Failure.invalidResponse }
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RelayPaneHealthHostControllerStatus.self, from: RelayPaneHealthJSON.data(result))
}

@Test("Single-pass controller reply decode matches the former two-pass decode")
func controllerReplyDecodeMatchesLegacy() throws {
    let pane = "11111111-2222-4333-8444-555555555555"
    let owner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let raw = Data(("""
    {"request_id":"rpc-1","result":{"v":1,"status":"controller_status","controller":"relayd",
     "supervisor_pid":42,"supervisor_start_time":1792151059130068,"next_check_seconds":120,
     "configuration":{"host_id":"owned-host","owner_id":"\(owner)","generation":4,"enabled":true,
      "haiku_enabled":true,"panes":["\(pane)"],"configured_at":1792149222.451235},
     "state":{"generation":4,"status":"ok","last_tick_at":1792151308.01098,"last_model_at":1792149232.631014,
      "model_operations":["m-1"],"report":{"score":0.5,"nested":{"count":3,"big":18446744073709551615,"list":[1,2.5,"x",null,true]}},
      "action_requests":{"a-1":{"id":"a-1","operation_id":"op-a","generation":4,"state":"pending_native",
        "call":{"type":"tool_use","id":"t-1","name":"reconnect","input":{"pane_id":"\(pane)","n":2}},
        "before":{"pane_id":"\(pane)","connection":"disconnected","process_start":1792149222,"ratio":0.25}}}}}}
    """).utf8)
    let new = try RelayPaneHealthHostControllerRPC.decodeReply(raw)
    let old = try legacyDecode(raw)
    #expect(new.valid(host: "owned-host", owner: owner, paneIDs: [pane]))
    #expect(old.valid(host: "owned-host", owner: owner, paneIDs: [pane]))
    #expect(new.supervisorStartTime == old.supervisorStartTime)
    #expect(new.configuration?.generation == old.configuration?.generation)
    #expect(new.currentState?.lastModelAt == old.currentState?.lastModelAt)
    #expect(new.currentState?.modelOperations == old.currentState?.modelOperations)
    #expect(new.currentState?.report == old.currentState?.report)
    let newRequest = try #require(new.currentState?.actionRequests?["a-1"])
    let oldRequest = try #require(old.currentState?.actionRequests?["a-1"])
    #expect(newRequest.before == oldRequest.before)
    #expect(newRequest.call == oldRequest.call)
    #expect(RelayPaneHealthJSON.digest(newRequest.before) == RelayPaneHealthJSON.digest(oldRequest.before))
}

@Test("Controller reply errors keep their former precedence")
func controllerReplyErrorsKeepPrecedence() throws {
    func refusal(_ json: String) -> String? {
        do { _ = try RelayPaneHealthHostControllerRPC.decodeReply(Data(json.utf8)); return nil }
        catch RelayHostRotationRPC.Failure.refused(let message) { return message }
        catch { return "other" }
    }
    // A string error wins, even over a malformed result.
    #expect(refusal(#"{"error":"denied","result":{"v":"bad"}}"#) == "denied")
    #expect(refusal("{\"error\":\"" + String(repeating: "e", count: 300) + "\"}")?.count == 240)
    // A missing result is invalid, as before.
    #expect(throws: (any Error).self) { try RelayPaneHealthHostControllerRPC.decodeReply(Data(#"{"request_id":"x"}"#.utf8)) }
    #expect(throws: (any Error).self) { try legacyDecode(Data(#"{"request_id":"x"}"#.utf8)) }
    // A non-string error is ignored by both paths.
    let ignored = #"{"error":{"code":1},"result":{"v":1,"status":"controller_status"}}"#
    #expect(try RelayPaneHealthHostControllerRPC.decodeReply(Data(ignored.utf8)).status == "controller_status")
    #expect(try legacyDecode(Data(ignored.utf8)).status == "controller_status")
}
