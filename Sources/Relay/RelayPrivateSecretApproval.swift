import AppKit
import Foundation

/// This primitive is not an MCP endpoint. The caller must authenticate the
/// requesting session and provide a trusted consumer before showing it.
struct RelayPrivateSecretProposal: Equatable {
    let instance: UUID
    let requestID: UUID
    let paneID: UUID
    let sessionID: UUID
    let requester: String
    let host: String
    let purpose: String
    let destination: String

    var isValid: Bool {
        [requester, host, purpose, destination].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 160 && $0.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
        }
    }
}

/// A single-use, native secret prompt. Values never appear in receipts; the
/// synchronous consumer is a trusted native operation, not agent code.
@MainActor final class RelayPrivateSecretApproval {
    enum Status: String { case awaitingApproval = "awaiting_approval", running, cancelled, staleOrExpired = "stale_or_expired", completed, outcomeUnknown = "outcome_unknown" }
    let instance = UUID()
    private var proposals: [UUID: RelayPrivateSecretProposal] = [:]
    private var statuses: [UUID: Status] = [:]
    private var pending: UUID?
    private let journal: RelayPrivateOperationJournal

    init(journal: RelayPrivateOperationJournal? = nil) {
        self.journal = journal ?? RelayPrivateOperationJournal(url: RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/PrivateOperations/receipts.json"))
    }
    func durableStatus(_ id: UUID, owner: String, request: String? = nil) throws -> Status? {
        if let value = try journal.lookup(id, owner: owner, request: request) {
            return statuses[id] ?? Status(rawValue: value) ?? .outcomeUnknown
        }
        return nil
    }
    private func record(_ id: UUID, _ status: Status) throws {
        do { try journal.finish(id, status: status.rawValue); statuses[id] = status }
        catch { statuses[id] = .outcomeUnknown; throw error }
    }

    func status(_ id: UUID) -> Status? { statuses[id] }

    func request(_ proposal: RelayPrivateSecretProposal, window: NSWindow,
                 owner: String, requestDigest: String,
                 stillCurrent: @escaping @MainActor () -> Bool,
                 consume: @escaping @MainActor (Data) async throws -> Void) throws -> Status {
        guard proposal.instance == instance, proposal.isValid else { throw PluginError.invalid("Invalid private request") }
        if let prior = try durableStatus(proposal.requestID, owner: owner, request: requestDigest) { return prior }
        if let prior = proposals[proposal.requestID] {
            guard prior == proposal, let status = statuses[proposal.requestID] else { throw PluginError.invalid("Conflicting private request") }
            return status
        }
        guard pending == nil, proposals.count < 256, window.attachedSheet == nil, stillCurrent() else {
            throw PluginError.invalid("Private request unavailable")
        }
        // Persist single-use admission before showing a prompt or consuming data.
        try journal.admit(proposal.requestID, owner: owner, request: requestDigest)
        proposals[proposal.requestID] = proposal
        statuses[proposal.requestID] = .awaitingApproval
        pending = proposal.requestID
        let deadline = DispatchTime.now() + .seconds(120)
        let alert = RelayTheme.alert()
        alert.messageText = "Provide a secret for this operation?"
        alert.informativeText = "Requester: \(proposal.requester)\nHost: \(proposal.host)\nPurpose: \(proposal.purpose)\nDestination: \(proposal.destination)\nThe value goes to the approved native consumer, not the agent conversation. Saving a credential does not attach it to or enable an account."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Provide secret")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        field.placeholderString = "Secret"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { field.stringValue = ""; return }
            defer { field.stringValue = ""; self.pending = nil }
            guard response == .alertSecondButtonReturn else { try? self.record(proposal.requestID, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds ? .staleOrExpired : .cancelled); return }
            guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds, stillCurrent() else { try? self.record(proposal.requestID, .staleOrExpired); return }
            let submitted = Data(field.stringValue.utf8)
            guard !submitted.isEmpty, submitted.count <= 65_536 else { try? self.record(proposal.requestID, .cancelled); return }
            do { try self.record(proposal.requestID, .running) }
            catch { self.statuses[proposal.requestID] = .outcomeUnknown; return }
            Task { @MainActor in
                var value = submitted
                defer { value.resetBytes(in: 0..<value.count) }
                do {
                    try await consume(value)
                    try self.record(proposal.requestID, .completed)
                } catch {
                    self.statuses[proposal.requestID] = .outcomeUnknown
                    try? self.record(proposal.requestID, .outcomeUnknown)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self, weak window] in
            guard let self, self.pending == proposal.requestID, let window else { return }
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        return .awaitingApproval
    }
}
