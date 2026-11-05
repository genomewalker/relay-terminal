import Foundation
import Testing
@testable import Relay

/// /api/local-pane/request (the approval-card route) cannot place a tab
/// beside an anchor, so an anchored proposal must be refused, never silently
/// treated as a default tab. Only relay_new_local_tab accepts anchors.
@MainActor @Suite("Local pane approval route refuses anchors")
struct MCPLocalPaneAnchorRefusalTests {
    static func body(anchorPane: UUID? = nil, anchorTab: UUID? = nil, instance: UUID, request: UUID) -> Data {
        var object = ["instance": instance.uuidString, "requestID": request.uuidString]
        if let anchorPane { object["anchorPaneID"] = anchorPane.uuidString }
        if let anchorTab { object["anchorTabID"] = anchorTab.uuidString }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func refusal(_ body: Data) -> String? {
        do {
            _ = try MCPDirectTabRequests.localPaneApprovalProposal(body)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func unanchoredProposalIsAdmittedUnchanged() throws {
        let instance = UUID(), request = UUID()
        let proposal = try MCPDirectTabRequests.localPaneApprovalProposal(Self.body(instance: instance, request: request))
        #expect(proposal == LocalPaneProposal(instance: instance, requestID: request))
        #expect(!proposal.isAnchored)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func anchoredProposalIsRefused(pane: Bool, tab: Bool) {
        let body = Self.body(anchorPane: pane ? UUID() : nil, anchorTab: tab ? UUID() : nil,
                             instance: UUID(), request: UUID())
        #expect(Self.refusal(body) == "Anchors are accepted only by new-local-tab")
    }

    @Test func malformedProposalIsRefusedAsUndecodable() {
        let refusal = Self.refusal(Data(#"{"instance":"not-a-uuid"}"#.utf8))
        #expect(refusal != nil)
        #expect(refusal != "Anchors are accepted only by new-local-tab")
    }
}
