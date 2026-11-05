import Foundation
import Testing
@testable import Relay

@Test func questionThreadRouteRefusesInvalidArgumentsBeforeAnyBinding() throws {
    func body(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["paneID": UUID().uuidString.lowercased(), "threadID": "q:thread-1", "realm": "project:relay"]
            .merging(fields) { $1 })
    }
    let refused: [[String: Any]] = [
        ["threadID": "../escape"],
        ["threadID": ""],
        ["threadID": String(repeating: "a", count: 129)],
        ["realm": "a/b"],
        ["realm": NSNull()],
        ["ttl": "29"],
        ["ttl": "86401"],
        ["ttl": "30x"],
        ["ttl": "+30"],
    ]
    for fields in refused {
        let response = RelayQuestionThreadInput.rejection(method: "POST", body: try body(fields))
        #expect(response?.status == 400, "accepted \(fields)")
    }
    #expect(RelayQuestionThreadInput.rejection(method: "POST", body: Data("not json".utf8))?.status == 400)
    #expect(RelayQuestionThreadInput.rejection(method: "POST", body: try body(["ttl": "900"])) == nil)
    #expect(RelayQuestionThreadInput.rejection(method: "POST", body: try body([:])) == nil)
    #expect(RelayQuestionThreadInput.rejection(method: "DELETE", body: Data("not json".utf8)) == nil)
}

/// The same literals as remote/relayd/internal/daemon/question_thread_test.go.
private let questionBindPacketFromSwift = #"{"operation":"question_bind","pane_id":"11111111-1111-4111-8111-111111111111","realm":"project:relay","source_pane_id":"11111111-1111-4111-8111-111111111111","thread_id":"q:thread-1","ttl":"900"}"#
private let questionUnbindPacketFromSwift = #"{"operation":"question_unbind","pane_id":"11111111-1111-4111-8111-111111111111","source_pane_id":"11111111-1111-4111-8111-111111111111"}"#

private func sortedJSON(_ packet: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: packet, options: .sortedKeys), as: UTF8.self)
}

@Test func questionThreadRoutePacketBindsOnlyTheTargetPane() throws {
    let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    // A foreign callerPaneID in the body is ignored: the packet names only the target pane.
    let body = try JSONSerialization.data(withJSONObject: [
        "paneID": pane.uuidString.lowercased(), "threadID": "q:thread-1", "realm": "project:relay", "ttl": "900",
        "callerPaneID": UUID().uuidString.lowercased(),
    ])
    let input = try JSONDecoder().decode(RelayQuestionThreadInput.Binding.self, from: body)
    let bind = RelayQuestionThreadInput.bindPacket(paneID: input.paneID, threadID: "q:thread-1",
                                                   realm: "project:relay", ttl: input.ttl)
    #expect(try sortedJSON(bind) == questionBindPacketFromSwift)
    let unbind = RelayQuestionThreadInput.unbindPacket(paneID: input.paneID)
    #expect(try sortedJSON(unbind) == questionUnbindPacketFromSwift)
}

@MainActor @Test func questionThreadRouteAdmitsOnlyOwnerUIAndAssistant() {
    #expect(RelayQuestionThreadInput.admits(caller: "legacy-unattributed"))
    #expect(RelayQuestionThreadInput.admits(caller: RelayCallerControl.assistantCaller))
    #expect(!RelayQuestionThreadInput.admits(caller: UUID().uuidString.lowercased()))
    #expect(!RelayQuestionThreadInput.admits(caller: nil))
}
