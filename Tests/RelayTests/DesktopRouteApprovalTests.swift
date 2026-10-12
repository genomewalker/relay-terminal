import AppKit
import Testing
@testable import Relay

@MainActor
@Test("Desktop route proposals reject stale and malformed identities before opening approval")
func desktopRouteProposalValidation() throws {
    let instance = UUID(), request = UUID()
    var presentations = 0
    let approvals = DesktopRouteApproval { _, _ in presentations += 1; return false }
    let valid = DesktopRouteProposal(instance: instance, requestID: request,
        thread: UUID().uuidString.lowercased(), host: "dandy-07", remoteName: "claude-test",
        remoteSession: UUID().uuidString.lowercased(), remotePID: 1234, remoteStart: "123456")
    #expect(throws: Error.self) { try approvals.propose(valid, instance: UUID()) }
    #expect(throws: Error.self) { try approvals.propose(DesktopRouteProposal(
        instance: instance, requestID: request, thread: valid.thread, host: "host;echo injected",
        remoteName: valid.remoteName, remoteSession: valid.remoteSession,
        remotePID: valid.remotePID, remoteStart: valid.remoteStart), instance: instance) }
    #expect(presentations == 0)
    #expect(throws: Error.self) { try approvals.propose(valid, instance: instance) }
    #expect(presentations == 1)
    #expect(approvals.receipt(request) == nil)
}
