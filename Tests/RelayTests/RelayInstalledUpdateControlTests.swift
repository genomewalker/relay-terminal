import Foundation
import Testing
@testable import Relay

struct RelayInstalledUpdateControlTests {
    @Test func receiptsFenceAuthorityIdentityAndReplay() throws {
        let instance = UUID(), pane = UUID(), id = UUID()
        let request = RelayInstalledUpdateRequest(instance: instance, requestID: id)
        var receipts = RelayInstalledUpdateReceipts()
        guard case .refused = receipts.begin(pane: pane, request: request, instance: instance, granted: false) else { Issue.record("grant bypass"); return }
        guard case .refused = receipts.begin(pane: pane, request: request, instance: UUID(), granted: true) else { Issue.record("stale instance"); return }
        guard case .admitted = receipts.begin(pane: pane, request: request, instance: instance, granted: true) else { Issue.record("not admitted"); return }
        guard case .existing(let pending) = receipts.begin(pane: pane, request: request, instance: instance, granted: true) else { Issue.record("replayed action"); return }
        #expect(pending["state"]?.string == "pending")
        guard case .refused = receipts.begin(pane: UUID(), request: request, instance: instance, granted: true) else { Issue.record("cross-pane replay"); return }
        receipts.finish(id, result: .object(["state": .string("verification_unknown")]))
        #expect(receipts.result(pane: pane, request: request, instance: instance)?["state"]?.string == "verification_unknown")
        #expect(receipts.result(pane: pane, request: request, instance: UUID()) == nil)
        #expect(receipts.result(pane: UUID(), request: request, instance: instance) == nil)
        var object: [String: String] = ["instance": instance.uuidString, "requestID": id.uuidString]
        #expect(try RelayInstalledUpdateRequest.decode(JSONSerialization.data(withJSONObject: object)) == request)
        object["command"] = "forbidden"
        #expect(throws: (any Error).self) { try RelayInstalledUpdateRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func successNeedsTheOriginalConversationAndNativeImage() throws {
        let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":true}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var before = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        before.configDir = "~/.codex"
        var after = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.replacingOccurrences(of: "42", with: "43").utf8))
        after.configDir = before.configDir; after.installedUpdate = false; after.installedImageCurrent = true
        #expect(RelayInstalledUpdatePostcondition.verified(before: before, after: after, pane: pane))
        for current in [false, nil] as [Bool?] {
            var wrong = after; wrong.installedImageCurrent = current
            #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: wrong, pane: pane))
        }
        var wrong = after; wrong.sessionID = "another-session"
        #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: wrong, pane: pane))
        wrong = after; wrong.configDir = "~/.codex-other"
        #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: wrong, pane: pane))
        wrong = after; wrong.accountMatches = false
        #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: wrong, pane: pane))
        wrong = after; wrong.bound = false
        #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: wrong, pane: pane))
        #expect(!RelayInstalledUpdatePostcondition.verified(before: before, after: after, pane: UUID()))
    }
}
