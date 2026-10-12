import Foundation
import AppKit
import Testing
@testable import Relay

@Test("Cancelled network proposals are idempotent and never launch helpers")
@MainActor func peerNetworkApprovalCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = PeerNetworkController(root: root)
    var config = PeerLinkConfiguration()
    config.host = "test"; config.localName = "local"; config.localSession = "a"
    config.remoteName = "remote"; config.remoteSession = "b"; config.remoteLabel = "remote"
    config.localPID = "123"; config.remotePID = "456"
    #expect(controller.save(config))
    var presentations = 0
    var complete: ((NSApplication.ModalResponse) -> Void)?
    let approvals = PeerNetworkApproval { alert, callback in
        presentations += 1
        #expect(alert.buttons[0].title == "Cancel")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        complete = callback
        return true
    }
    let instance = UUID(), id = UUID()
    let proposal = PeerNetworkProposal(instance: instance, requestID: id, linkID: config.id, action: "connect")
    #expect(try approvals.propose(proposal, instance: instance, controller: controller).status == "awaiting_approval")
    #expect(try approvals.propose(proposal, instance: instance, controller: controller).status == "awaiting_approval")
    #expect(presentations == 1)
    let competing = PeerNetworkProposal(instance: instance, requestID: UUID(), linkID: config.id, action: "connect")
    #expect(throws: (any Error).self) { try approvals.propose(competing, instance: instance, controller: controller) }
    #expect(approvals.receipt(competing.requestID) == nil)
    let collision = PeerNetworkProposal(instance: instance, requestID: id, linkID: config.id, action: "disconnect")
    #expect(throws: (any Error).self) { try approvals.propose(collision, instance: instance, controller: controller) }
    complete?(.alertFirstButtonReturn)
    for _ in 0..<100 {
        if approvals.receipt(id)?.status == "cancelled" { break }
        await Task.yield()
    }
    #expect(approvals.receipt(id)?.status == "cancelled")
    complete?(.alertSecondButtonReturn)
    for _ in 0..<10 { await Task.yield() }
    #expect(approvals.receipt(id)?.status == "cancelled")
    #expect(try approvals.propose(proposal, instance: instance, controller: controller).status == "cancelled")
    #expect(presentations == 1)
    #expect(controller.running.isEmpty)
}

@Test("Unavailable approval window releases admission and leaves no phantom receipt")
@MainActor func peerNetworkApprovalPresentationFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = PeerNetworkController(root: root)
    var config = PeerLinkConfiguration()
    config.host = "test"; config.localName = "local"; config.localSession = "a"
    config.remoteName = "remote"; config.remoteSession = "b"; config.remoteLabel = "remote"
    config.localPID = "123"; config.remotePID = "456"
    #expect(controller.save(config))
    var attempts = 0
    let approvals = PeerNetworkApproval { _, _ in attempts += 1; return false }
    let instance = UUID()
    let proposal = PeerNetworkProposal(instance: instance, requestID: UUID(), linkID: config.id, action: "connect")
    for _ in 0..<2 {
        #expect(throws: (any Error).self) { try approvals.propose(proposal, instance: instance, controller: controller) }
        #expect(approvals.receipt(proposal.requestID) == nil)
    }
    #expect(attempts == 2)
    #expect(controller.running.isEmpty)
}

@Test("Network confirmation rejects expiry, edited targets and intervening link changes")
func peerNetworkApprovalContextValidation() {
    let configuration = PeerLinkConfiguration()
    let deadline = Date(timeIntervalSince1970: 1000)
    let context = PeerNetworkApprovalContext(configuration: configuration, revision: 7,
                                            wasRunning: false, deadline: deadline)
    let before = deadline.addingTimeInterval(-1)
    #expect(context.isCurrent(now: before, revision: 7, configurations: [configuration], running: []))
    #expect(!context.isCurrent(now: deadline, revision: 7, configurations: [configuration], running: []))
    #expect(!context.isCurrent(now: before, revision: 8, configurations: [configuration], running: []))
    #expect(!context.isCurrent(now: before, revision: 7, configurations: [], running: []))
    #expect(!context.isCurrent(now: before, revision: 7, configurations: [configuration], running: [configuration.id]))
    var edited = configuration
    edited.host = "another-host"
    #expect(!context.isCurrent(now: before, revision: 7, configurations: [edited], running: []))
}

@Test("Network approval rejects stale instances and unsupported actions before opening UI")
@MainActor func peerNetworkApprovalValidation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = PeerNetworkController(root: root)
    let approvals = PeerNetworkApproval()
    let instance = UUID()
    for proposal in [
        PeerNetworkProposal(instance: UUID(), requestID: UUID(), linkID: UUID(), action: "connect"),
        PeerNetworkProposal(instance: instance, requestID: UUID(), linkID: UUID(), action: "kill")
    ] {
        #expect(throws: (any Error).self) {
            try approvals.propose(proposal, instance: instance, controller: controller)
        }
        #expect(approvals.receipt(proposal.requestID) == nil)
    }
    #expect(controller.running.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
