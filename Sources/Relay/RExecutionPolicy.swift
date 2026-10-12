import Foundation

/// Pure admission policy for structured R operations, never generic PTY input.
/// The transport must verify this identity from its authenticated binding, not
/// trust a caller-supplied host, actor or process label.
struct RExecutionTarget: Equatable, Sendable, Codable {
    let paneID: UUID
    let host: String
    let projectRoot: String
    let sessionID: String
    let connectionGeneration: UUID
}

enum RExecutionMode: Sendable { case unknown, plan, execute }
enum RConsoleOwnership: Sendable { case unknown, human, automation }

struct RExecutionGrant: Sendable {
    let id: UUID
    let target: RExecutionTarget
    let actors: Set<String>
    /// Continuous clock: changing wall time must not extend an authorization.
    let expiresAt: ContinuousClock.Instant
    let maximumRuns: Int
}

/// One owner, bounded receipts, explicit unknown outcomes. A grant permits R
/// evaluation with the R process's OS permissions; it does not sandbox R.
struct RExecutionAdmission {
    enum Status: String, Codable { case admitted, running, completed, failed, interrupted, unknown }
    enum Rejection: Error, LocalizedError {
        case invalid, duplicateConflict, unauthorized, expired, paused, busy, capacity, stale, invalidTransition
        var code: String {
            switch self {
            case .invalid: "r_invalid_request"
            case .duplicateConflict: "r_request_id_conflict"
            case .unauthorized: "r_not_authorized"
            case .expired: "r_authorization_expired"
            case .paused: "r_paused"
            case .busy: "r_run_unresolved"
            case .capacity: "r_receipt_capacity"
            case .stale: "r_preconditions_changed"
            case .invalidTransition: "r_invalid_transition"
            }
        }
        var errorDescription: String? {
            let action: String
            switch self {
            case .paused: action = "Agent execution is paused by human control. No code was submitted. Only explicit user direction may resume agent execution; do not retry or reauthorize to bypass takeover. Read relay_r_session_status."
            case .busy: action = "A managed R run is unresolved. Read its original receipt; do not resend it."
            case .unauthorized: action = "This actor is not authorized for the exact R session. Obtain user direction before authorizing."
            case .expired: action = "The R authorization expired. Obtain user direction before renewing it."
            case .duplicateConflict: action = "This request ID belongs to different code or source. Inspect the original request."
            case .capacity: action = "The bounded R request history is full. Human review is required before further execution."
            case .stale: action = "The R session, authorization or ownership changed before dispatch. Rediscover status; do not retry automatically."
            case .invalid: action = "Invalid R execution request or authorization."
            case .invalidTransition: action = "R execution state changed. Inspect the original receipt before proceeding."
            }
            return code + ": " + action
        }
    }
    struct Request: Equatable, Codable {
        let id: UUID
        let actor: String
        let target: RExecutionTarget
        let code: String
    }
    struct Receipt: Codable {
        let request: Request
        var status: Status
    }
    private(set) var grant: RExecutionGrant?
    private(set) var paused = true
    private(set) var active: UUID?
    private(set) var receipts: [UUID: Receipt] = [:]
    private var admittedRuns = 0
    private let capacity = 256

    struct Snapshot: Codable {
        let target: RExecutionTarget
        let paused: Bool
        let active: UUID?
        let receipts: [UUID: Receipt]
        let admittedRuns: Int
    }

    var snapshot: Snapshot? {
        guard let grant else { return nil }
        return Snapshot(target: grant.target, paused: paused, active: active,
                        receipts: receipts, admittedRuns: admittedRuns)
    }

    init() {}

    init(restoring snapshot: Snapshot) {
        grant = RExecutionGrant(id: UUID(), target: snapshot.target,
            actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(315_360_000)), maximumRuns: capacity)
        paused = snapshot.paused
        active = snapshot.active
        receipts = snapshot.receipts
        admittedRuns = snapshot.admittedRuns
        // A restart cannot prove whether an admitted command reached R.
        if let active { receipts[active]?.status = .unknown }
    }

    /// Only call after a user links or explicitly authorizes this R session. Renewing does not clear
    /// replay protection or unresolved operations.
    mutating func authorize(_ value: RExecutionGrant) throws {
        guard !value.actors.isEmpty, value.actors.count <= 8,
              value.actors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              value.maximumRuns > 0, value.maximumRuns <= capacity,
              !value.target.host.isEmpty, !value.target.sessionID.isEmpty,
              value.target.projectRoot.hasPrefix("/"), active == nil else { throw Rejection.invalid }
        grant = value
        admittedRuns = 0
        paused = false
    }

    mutating func pause() { paused = true }
    mutating func revoke() { grant = nil; paused = true }

    /// Human console runs preserve ordinary interactive R semantics. An idle
    /// prompt gates subsequent input; without markers, completion is unknown.
    /// Only the native human UI may call this path, never an MCP actor.
    mutating func recordHumanConsoleDispatch(_ request: Request) throws {
        guard request.actor == "human_ui", grant?.target == request.target else { throw Rejection.unauthorized }
        _ = try RWorkspaceCommand.userInput(request.code)
        if let old = receipts[request.id] {
            guard old.request == request else { throw Rejection.duplicateConflict }
            throw Rejection.invalidTransition
        }
        guard active == nil else { throw Rejection.busy }
        guard receipts.count < capacity else { throw Rejection.capacity }
        paused = true
        receipts[request.id] = Receipt(request: request, status: .unknown)
    }

    mutating func admit(_ request: Request, mode: RExecutionMode,
                        ownership: RConsoleOwnership,
                        now: ContinuousClock.Instant = .now) throws -> Receipt {
        if let existing = receipts[request.id] {
            guard existing.request == request else { throw Rejection.duplicateConflict }
            // Return an observation only. Callers MUST NOT dispatch a replay.
            return existing
        }
        guard !request.code.isEmpty, request.code.utf8.count <= RWorkspaceCommand.maximumCodeBytes,
              !request.code.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else { throw Rejection.invalid }
        if ownership == .human, request.actor == "human_ui", mode == .execute {
            guard let grant, grant.target == request.target else { throw Rejection.unauthorized }
            guard active == nil else { throw Rejection.busy }
            guard receipts.count < capacity else { throw Rejection.capacity }
            paused = true
            let receipt = Receipt(request: request, status: .admitted)
            receipts[request.id] = receipt
            active = request.id
            return receipt
        }
        guard let grant, grant.target == request.target, grant.actors.contains(request.actor),
              mode == .execute, ownership == .automation else { throw Rejection.unauthorized }
        guard now < grant.expiresAt else { throw Rejection.expired }
        guard !paused else { throw Rejection.paused }
        guard active == nil else { throw Rejection.busy }
        guard receipts.count < capacity, admittedRuns < grant.maximumRuns else { throw Rejection.capacity }
        let receipt = Receipt(request: request, status: .admitted)
        receipts[request.id] = receipt
        active = request.id
        admittedRuns += 1
        return receipt
    }

    /// Separate pre-dispatch transition closes the admit/revoke race. Once
    /// running, an interruption request is not evidence of interruption.
    mutating func begin(_ id: UUID, target: RExecutionTarget,
                        mode: RExecutionMode, ownership: RConsoleOwnership,
                        now: ContinuousClock.Instant = .now) throws {
        guard let receipt = receipts[id], active == id, receipt.status == .admitted else { throw Rejection.invalidTransition }
        if ownership == .human, receipt.request.actor == "human_ui", mode == .execute {
            guard grant?.target == target, target == receipt.request.target else { throw Rejection.stale }
            receipts[id]?.status = .running
            return
        }
        guard let grant, !paused, target == grant.target, target == receipt.request.target,
              grant.actors.contains(receipt.request.actor), mode == .execute,
              ownership == .automation else { throw Rejection.stale }
        guard now < grant.expiresAt else { throw Rejection.expired }
        receipts[id]?.status = .running
    }

    mutating func finish(_ id: UUID, status: Status) throws {
        guard active == id, let receipt = receipts[id], receipt.status == .running,
              [.completed, .failed, .interrupted, .unknown].contains(status) else { throw Rejection.invalidTransition }
        receipts[id]?.status = status
        // Unknown execution may still be running remotely. Hold ownership
        // until explicit reconciliation with a terminal receipt.
        if status != .unknown { active = nil }
    }

    mutating func reconcile(_ id: UUID, status: Status) throws {
        guard active == id, receipts[id]?.status == .unknown,
              [.completed, .failed, .interrupted].contains(status) else { throw Rejection.invalidTransition }
        receipts[id]?.status = status
        active = nil
    }

    mutating func cancelAdmission(_ id: UUID) throws {
        guard active == id, receipts[id]?.status == .admitted else { throw Rejection.invalidTransition }
        receipts[id]?.status = .interrupted
        active = nil
    }
}
