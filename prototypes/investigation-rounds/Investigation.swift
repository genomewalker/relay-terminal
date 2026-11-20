import Foundation

// Single coordinator. The adapter supplies verified session identities and uses
// Miko's existing operation receipts to track delivery separately from acceptance.
struct Investigation: Codable {
    enum Phase: String, Codable { case offered, accepted, refused, returned, verified, disputed }
    enum Failure: Error { case invalid, wrongOwner, wrongPhase }
    struct Finding: Codable, Equatable {
        let claim: String
        let evidence: String
    }
    struct Assignment: Codable {
        let session: String
        let question: String
        var phase: Phase = .offered
        var finding: Finding?
        var review: Finding?
        var refusal: String?
    }

    let coordinator: String
    private(set) var assignments: [Assignment]

    init(coordinator: String, assignments: [(String, String)]) throws {
        let owners = Set(assignments.map { $0.0 })
        guard assignments.count == 2, owners.count == 2, !owners.contains(coordinator),
              !coordinator.isEmpty, assignments.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else { throw Failure.invalid }
        self.coordinator = coordinator
        self.assignments = assignments.map { Assignment(session: $0.0, question: $0.1) }
    }

    mutating func respond(_ index: Int, from session: String, refusal: String? = nil) throws {
        try require(index, session)
        let phase: Phase = refusal == nil ? .accepted : .refused
        let old = assignments[index]
        if old.phase == phase && old.refusal == refusal { return }
        guard old.phase == .offered, refusal?.isEmpty != true else { throw Failure.wrongPhase }
        assignments[index].phase = phase
        assignments[index].refusal = refusal
    }

    mutating func submit(_ finding: Finding, at index: Int, from session: String) throws {
        try require(index, session)
        if assignments[index].finding == finding { return }
        guard assignments[index].phase == .accepted, !finding.claim.isEmpty, !finding.evidence.isEmpty else { throw Failure.wrongPhase }
        assignments[index].finding = finding
        assignments[index].phase = .returned
    }

    mutating func review(_ index: Int, from session: String, confirmed: Bool, check: Finding) throws {
        guard session == coordinator, assignments.indices.contains(index) else { throw Failure.wrongOwner }
        let phase: Phase = confirmed ? .verified : .disputed
        if assignments[index].phase == phase && assignments[index].review == check { return }
        guard assignments[index].phase == .returned, !check.claim.isEmpty, !check.evidence.isEmpty else { throw Failure.wrongPhase }
        assignments[index].phase = phase
        assignments[index].review = check
    }

    private(set) var followUpFor: Int?

    mutating func followUp(for index: Int, from session: String, investigator: String, question: String) throws {
        guard session == coordinator, assignments.indices.contains(index) else { throw Failure.wrongOwner }
        guard assignments.count == 2, [.refused, .disputed].contains(assignments[index].phase),
              assignments.allSatisfy({ [.verified, .disputed, .refused].contains($0.phase) }),
              !investigator.isEmpty, investigator != coordinator, !question.isEmpty else { throw Failure.wrongPhase }
        followUpFor = index
        assignments.append(Assignment(session: investigator, question: question))
    }

    var complete: Bool {
        (0..<2).allSatisfy { index in
            assignments[index].phase == .verified || (followUpFor == index && assignments.last?.phase == .verified)
        }
    }

    private func require(_ index: Int, _ session: String) throws {
        guard assignments.indices.contains(index), assignments[index].session == session else { throw Failure.wrongOwner }
    }
}
