import Foundation

/// Admission evidence comes from the public ledger and the enrolled backend,
/// never from terminal text or a model's suggested action.
struct RelayRotationAdmission: Sendable {
    let sourceThreadID: String
    let owner: String
    let client: String
    let enrolled: Bool
    let turnIdle: Bool
    let epoch: String
    let signalSequence: Int
    let completedTurnSequence: Int
    let claimID: String
    let fencingToken: Int
    let claimExpiresAt: Date
    let capsuleRevision: Int
    let capsuleLedgerSequence: Int
    let codeHead: String

    func admits(now: Date) -> Bool {
        enrolled && owner == "relay" && ["codex", "claude"].contains(client) && turnIdle &&
        !sourceThreadID.isEmpty && sourceThreadID.utf8.count <= 110 &&
        !claimID.isEmpty && claimID.utf8.count <= 110 && !epoch.isEmpty && epoch.utf8.count <= 110 &&
        signalSequence > 0 && completedTurnSequence > signalSequence &&
        fencingToken > completedTurnSequence && claimExpiresAt > now &&
        capsuleRevision > 0 && capsuleLedgerSequence >= completedTurnSequence &&
        codeHead.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil
    }
}

/// Implementations must recheck the live fencing token and exact session for
/// each operation. Starting uses the supported app-server API, not PTY input.
protocol RelayRotationLifecycle: Sendable {
    var client: String { get }
    func validate(_ admission: RelayRotationAdmission) async throws
    func persistIntent(_ admission: RelayRotationAdmission, intentID: String) async throws
    func startFreshThread(_ admission: RelayRotationAdmission, intentID: String) async throws -> String
    func bind(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) async throws
    func loadCapsuleAndCompleteFirstTurn(_ admission: RelayRotationAdmission, freshThreadID: String) async throws
    func acknowledge(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) async throws
    func retire(_ admission: RelayRotationAdmission, freshThreadID: String) async throws
}

enum RelayRotationExecutionResult: Equatable, Sendable {
    case rejected
    case reconciliationRequired(RelayRotationPhase)
    case completed(String)
}

/// A persisted intent is consumed even when the start response is lost. A
/// later invocation must reconcile; it may never create a second fresh thread.
actor RelayChittaRotationExecutor {
    private let journal: RelayRotationJournal
    private var executing = false

    init(journal: RelayRotationJournal) { self.journal = journal }

    func execute(_ admission: RelayRotationAdmission, using lifecycle: any RelayRotationLifecycle,
                 now: Date = Date()) async -> RelayRotationExecutionResult {
        guard !executing, lifecycle.client == admission.client, admission.admits(now: now) else { return .rejected }
        executing = true
        defer { executing = false }
        var record = RelayRotationRecord(claimID: admission.claimID,
            sourceThreadID: admission.sourceThreadID, epoch: admission.epoch,
            capsuleRevision: admission.capsuleRevision, codeHead: admission.codeHead,
            phase: .startIntent, freshThreadID: nil)
        // v1 journals identify intents by claim ID. The wire intent must use
        // that same stable ID for reconciliation after a process restart.
        let intentID = admission.claimID
        do {
            try await lifecycle.validate(admission)
        } catch { return .rejected }
        guard journal.begin(record) else { return .reconciliationRequired(.startIntent) }
        do {
            try await lifecycle.persistIntent(admission, intentID: intentID)
            try await lifecycle.validate(admission)
            let fresh = try await lifecycle.startFreshThread(admission, intentID: intentID)
            guard !fresh.isEmpty, fresh != admission.sourceThreadID, fresh.utf8.count <= 110 else {
                return .reconciliationRequired(record.phase)
            }
            record.freshThreadID = fresh
            record.phase = .freshThreadStarted
            guard journal.record(record) else { return .reconciliationRequired(.startIntent) }
            try await lifecycle.bind(admission, intentID: intentID, freshThreadID: fresh)
            try await lifecycle.validate(admission)
            try await lifecycle.loadCapsuleAndCompleteFirstTurn(admission, freshThreadID: fresh)
            record.phase = .firstTurnCompleted
            guard journal.record(record) else { return .reconciliationRequired(.freshThreadStarted) }
            try await lifecycle.validate(admission)
            try await lifecycle.acknowledge(admission, intentID: intentID, freshThreadID: fresh)
            record.phase = .chittaAcknowledged
            guard journal.record(record) else { return .reconciliationRequired(.firstTurnCompleted) }
            // An ack closes the claim. retire must verify the durable ack and
            // exact old/new identities rather than require a still-live lease.
            try await lifecycle.retire(admission, freshThreadID: fresh)
            record.phase = .oldThreadRetired
            guard journal.record(record) else { return .reconciliationRequired(.chittaAcknowledged) }
            return .completed(fresh)
        } catch { return .reconciliationRequired(record.phase) }
    }
}
