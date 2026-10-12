import AppKit
import Testing
@testable import Relay

@Test @MainActor func localPaneApprovalIsExplicitAndIdempotent() throws {
    var answer: ((NSApplication.ModalResponse) -> Void)?
    var created = 0
    let broker = LocalPaneApproval { alert, callback in
        #expect(alert.buttons[0].title == "Cancel")
        answer = callback
        return true
    }
    let instance = UUID(), tab = UUID(), pane = UUID()
    let proposal = LocalPaneProposal(instance: instance, requestID: UUID())
    let create = { created += 1; return Optional((tab, pane)) }
    #expect(try broker.propose(proposal, instance: instance, create: create).status == "awaiting_approval")
    #expect(created == 0)
    #expect(throws: (any Error).self) {
        try broker.propose(LocalPaneProposal(instance: instance, requestID: UUID()), instance: instance, create: create)
    }
    answer?(.alertSecondButtonReturn)
    answer?(.alertSecondButtonReturn)
    #expect(created == 1)
    #expect(try broker.propose(proposal, instance: instance, create: create).paneID == pane)
    #expect(created == 1)
    #expect(broker.receipt(proposal.requestID)?.tabID == tab)
}

@Test @MainActor func localPaneApprovalFailureAndCancellation() throws {
    let instance = UUID()
    let proposal = LocalPaneProposal(instance: instance, requestID: UUID())
    let unavailable = LocalPaneApproval { _, _ in false }
    for _ in 0..<2 {
        #expect(throws: (any Error).self) {
            try unavailable.propose(proposal, instance: instance) { Issue.record("Unexpected creation"); return nil }
        }
        #expect(unavailable.receipt(proposal.requestID) == nil)
    }
    let cancel = LocalPaneApproval { _, callback in callback(.alertFirstButtonReturn); return true }
    #expect(try cancel.propose(proposal, instance: instance) { Issue.record("Unexpected creation"); return nil }.status == "cancelled")
    #expect(throws: (any Error).self) { try cancel.propose(proposal, instance: UUID()) { nil } }
}
