import Foundation

/// One instance, one owning process and one serial executor per snapshot URL.
/// The adapter must enforce that ownership; this class never executes work.
public final class RelayMikoTaskEngine {
    public enum Status: String, Codable { case queued, running, waiting, reconcile, blocked, reportedComplete, cancelled }
    public enum Outcome: String, Codable { case succeeded, failed, unknown }
    public enum Failure: Error { case invalid, missing, duplicateConflict, staleReceipt, notDispatchable, capacity }
    public struct ChecklistItem: Codable, Equatable {
        public let id: String
        public let text: String
        public var done: Bool
        public init(id: String, text: String, done: Bool = false) { self.id = id; self.text = text; self.done = done }
    }
    public struct Event: Codable, Equatable {
        public let id: String
        public let key: String
        public let detail: String
        public init(id: String, key: String, detail: String) { self.id = id; self.key = key; self.detail = detail }
    }
    public struct Receipt: Codable, Equatable {
        public let taskID: String
        public let operationID: String
        public let leaseID: String
        public let outcome: Outcome
        public let evidence: String
        public let responsePayload: Data?
        public init(taskID: String, operationID: String, leaseID: String, outcome: Outcome, evidence: String, responsePayload: Data? = nil) {
            self.taskID = taskID; self.operationID = operationID; self.leaseID = leaseID
            self.outcome = outcome; self.evidence = evidence; self.responsePayload = responsePayload
        }
    }
    public struct Operation: Codable, Equatable {
        public let id: String
        public let leaseID: String
        public let instruction: String
        public let eventIDs: [String]
        public let requestPayload: Data?
        public var receipt: Receipt?
        /// Checkpoint supplied with the current receipt, retained for exact duplicate validation.
        public var receiptCheckpointPayload: Data?
        public var unresolved: Bool { receipt == nil || receipt?.outcome == .unknown }
    }
    public struct Task: Codable, Equatable {
        public let id: String
        public let objective: String
        public let scope: String
        public var checklist: [ChecklistItem]
        public var status: Status
        public var events: [String: Event]
        public var pending: [String: Event]
        public var operations: [Operation]
        public var checkpoint: String
        public var checkpointPayload: Data?
        public var archivedOperationCount: Int = 0
        public var completionReport: String?
        public var verificationEvidence: String?
    }
    public struct Delta: Codable {
        public let revision: Int
        public let taskID: String
        public let detail: String
    }
    public struct Snapshot: Codable {
        public var version = 1
        public var revision = 0
        public var tasks: [String: Task] = [:]
        public var deltas: [Delta] = []
        /// Structural removals require consumers with older cursors to refresh their snapshot.
        public var snapshotRequiredAfterRevision: Int?
    }
    public struct Summary {
        public let revision: Int
        /// When true, older deltas were compacted; consume the task snapshot too.
        public let requiresSnapshot: Bool
        public let deltas: [Delta]
        /// Never truncated; admitted tasks/operations have explicit capacity limits.
        public let unresolved: [String: [Operation]]
    }
    private let url: URL
    private let persist: (Data, URL) throws -> Void
    public private(set) var snapshot: Snapshot
    public static let maxTasks = 64, maxEvents = 256, maxOperations = 64, maxDeltas = 64
    public static let maxPayloadBytes = 256 * 1024, maxSnapshotBytes = 128 * 1024 * 1024

    public init(url: URL, persist: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.url = url; self.persist = persist
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= Self.maxSnapshotBytes else { throw Failure.capacity }
            snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
        } else { snapshot = Snapshot() }
        try validate(snapshot)
        var next = snapshot
        for id in next.tasks.keys.sorted() {
            if next.tasks[id]!.status != .cancelled && next.tasks[id]!.operations.contains(where: \.unresolved) {
                next.tasks[id]!.status = .reconcile
                appendDelta(&next, id, "Reopened unresolved dispatch; reconcile exact operation, do not replay")
            }
        }
        if next.revision != snapshot.revision { try commit(next) }
    }

    public func create(id: String, objective: String, scope: String, checklist: [ChecklistItem]) throws {
        guard valid(id, 128), valid(objective), valid(scope), !checklist.isEmpty, checklist.count <= 64,
              Set(checklist.map(\.id)).count == checklist.count,
              checklist.allSatisfy({ valid($0.id, 128) && valid($0.text) }) else { throw Failure.invalid }
        guard snapshot.tasks[id] == nil else { throw Failure.duplicateConflict }
        guard snapshot.tasks.count < Self.maxTasks else { throw Failure.capacity }
        var next = snapshot
        next.tasks[id] = Task(id: id, objective: objective, scope: scope, checklist: checklist, status: .queued,
                              events: [:], pending: [:], operations: [], checkpoint: "")
        appendDelta(&next, id, "Task created"); try commit(next)
    }

    /// Exact event retransmissions are no-ops. Same-key events coalesce only in the wake queue.
    @discardableResult public func enqueue(taskID: String, event: Event) throws -> Bool {
        guard valid(event.id, 128), valid(event.key, 128), valid(event.detail) else { throw Failure.invalid }
        guard let task = snapshot.tasks[taskID] else { throw Failure.missing }
        if let previous = task.events[event.id] {
            guard previous == event else { throw Failure.duplicateConflict }; return false
        }
        guard task.status != .cancelled && task.status != .reportedComplete else { throw Failure.notDispatchable }
        guard task.events.count < Self.maxEvents else { throw Failure.capacity }
        try change(taskID, "Event received") { task in
            task.events[event.id] = event; task.pending[event.key] = event
            if task.status == .waiting { task.status = .queued }
        }
        return true
    }

    /// Persist intent BEFORE returning the dispatch token. Callers dispatch this token at most once.
    /// A thrown persistence error means no token is returned and no in-memory change occurs.
    /// A non-nil checkpoint payload replaces the structured checkpoint in this same commit.
    /// Nil preserves the prior checkpoint. Payload bytes are opaque to the engine.
    public func beginDispatch(taskID: String, instruction: String, requestPayload: Data? = nil,
                              checkpointPayload: Data? = nil) throws -> Operation {
        try validatePayload(requestPayload); try validatePayload(checkpointPayload)
        guard valid(instruction), let task = snapshot.tasks[taskID] else { throw Failure.invalid }
        guard task.status == .queued, !task.operations.contains(where: \.unresolved) else { throw Failure.notDispatchable }
        guard task.operations.count < Self.maxOperations,
              task.archivedOperationCount < Int.max - task.operations.count else { throw Failure.capacity }
        // The lifetime sequence never decreases when settled records are archived.
        let sequence = task.archivedOperationCount + task.operations.count + 1
        let operation = Operation(id: "\(sequence)-\(UUID().uuidString)", leaseID: UUID().uuidString, instruction: instruction,
                                  eventIDs: task.pending.values.map(\.id).sorted(), requestPayload: requestPayload, receipt: nil)
        try change(taskID, "Dispatch intent persisted") { task in
            task.operations.append(operation); task.pending.removeAll(); task.status = .running
            if let checkpointPayload { task.checkpointPayload = checkpointPayload }
        }
        return operation
    }

    /// Unknown is provisional; only an exact correlated terminal receipt can resolve it.
    @discardableResult public func receive(_ receipt: Receipt, checkpointPayload: Data? = nil) throws -> Bool {
        try validatePayload(receipt.responsePayload); try validatePayload(checkpointPayload)
        guard valid(receipt.evidence), let task = snapshot.tasks[receipt.taskID],
              let index = task.operations.firstIndex(where: { $0.id == receipt.operationID }),
              task.operations[index].leaseID == receipt.leaseID else { throw Failure.staleReceipt }
        if let prior = task.operations[index].receipt {
            if prior == receipt {
                guard checkpointPayload == nil || task.operations[index].receiptCheckpointPayload == checkpointPayload else {
                    throw Failure.staleReceipt
                }
                return false
            }
            guard prior.outcome == .unknown && receipt.outcome != .unknown else { throw Failure.staleReceipt }
        }
        try change(receipt.taskID, "Correlated receipt: \(receipt.outcome.rawValue)") { task in
            task.operations[index].receipt = receipt
            task.operations[index].receiptCheckpointPayload = checkpointPayload
            if let checkpointPayload { task.checkpointPayload = checkpointPayload }
            guard task.status != .cancelled else { return }
            switch receipt.outcome {
            case .unknown: task.status = .reconcile
            case .failed: task.status = .blocked
            case .succeeded: task.status = task.pending.isEmpty ? .waiting : .queued
            }
        }
        return true
    }

    public func cancel(taskID: String) throws {
        guard let task = snapshot.tasks[taskID] else { throw Failure.missing }
        if task.status == .cancelled { return }
        try change(taskID, "Cancelled; unresolved external work remains tracked") { $0.status = .cancelled; $0.pending.removeAll() }
    }

    /// Adapter calls this only on an explicit decision/event, never from a polling timer.
    public func resume(taskID: String) throws {
        guard let task = snapshot.tasks[taskID], [.waiting, .blocked].contains(task.status),
              !task.operations.contains(where: \.unresolved) else { throw Failure.notDispatchable }
        try change(taskID, "Explicit resume") { $0.status = .queued }
    }

    /// Nil payload preserves the structured checkpoint; use non-nil Data to replace it.
    public func checkpoint(taskID: String, text: String, completedItemIDs: Set<String>, payload: Data? = nil) throws {
        try validatePayload(payload)
        guard valid(text), let task = snapshot.tasks[taskID], task.status != .cancelled,
              task.status != .reportedComplete, completedItemIDs.isSubset(of: Set(task.checklist.map(\.id))) else { throw Failure.invalid }
        try change(taskID, "Checkpoint updated") { task in
            task.checkpoint = text
            if let payload { task.checkpointPayload = payload }
            for index in task.checklist.indices { task.checklist[index].done = completedItemIDs.contains(task.checklist[index].id) }
        }
    }

    /// Explicitly discard selected terminal operation records, never unresolved work.
    /// No receipt tombstones are replayable: any later receipt for a removed ID is stale.
    /// Event deduplication, pending events, checkpoint, status and task identity are untouched.
    @discardableResult public func archiveSettledOperations(taskID: String, operationIDs: Set<String>) throws -> Int {
        guard let task = snapshot.tasks[taskID] else { throw Failure.missing }
        if operationIDs.isEmpty { return 0 }
        let selected = task.operations.filter { operationIDs.contains($0.id) }
        guard selected.count == operationIDs.count else { throw Failure.staleReceipt }
        guard !selected.contains(where: \.unresolved) else { throw Failure.notDispatchable }
        guard task.archivedOperationCount <= Int.max - selected.count else { throw Failure.capacity }
        try change(taskID, "Archived \(selected.count) settled operations") { task in
            task.operations.removeAll { operationIDs.contains($0.id) }
            task.archivedOperationCount += selected.count
        }
        return selected.count
    }

    /// Write complete terminal evidence first, then remove the task from live state.
    /// Both URLs must have the same exclusive owner. Existing different bytes are never overwritten.
    /// A failed live commit leaves both records; an explicit retry may reuse identical archive bytes.
    public func archiveTerminalTask(taskID: String, archiveURL: URL) throws {
        guard let task = snapshot.tasks[taskID] else { throw Failure.missing }
        guard [.reportedComplete, .cancelled].contains(task.status), task.pending.isEmpty,
              !task.operations.contains(where: \.unresolved) else { throw Failure.notDispatchable }
        guard archiveURL.isFileURL,
              archiveURL.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw Failure.invalid
        }
        guard snapshot.revision < Int.max - 1 else { throw Failure.capacity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(task)
        guard bytes.count <= Self.maxSnapshotBytes else { throw Failure.capacity }
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            guard try Data(contentsOf: archiveURL) == bytes else { throw Failure.duplicateConflict }
        } else {
            try persist(bytes, archiveURL)
        }
        var next = snapshot
        next.tasks.removeValue(forKey: taskID)
        next.deltas.removeAll { $0.taskID == taskID }
        next.revision += 1
        next.snapshotRequiredAfterRevision = next.revision
        try commit(next)
    }

    public func reportComplete(taskID: String, report: String) throws {
        guard valid(report), let task = snapshot.tasks[taskID], task.status != .cancelled,
              task.status != .reportedComplete, task.checklist.allSatisfy(\.done), task.pending.isEmpty,
              !task.operations.contains(where: \.unresolved) else { throw Failure.invalid }
        try change(taskID, "Completion reported; verification pending") { $0.status = .reportedComplete; $0.completionReport = report }
    }

    /// Evidence must be supplied by an independent verifier in the integrating adapter.
    public func recordVerification(taskID: String, evidence: String) throws {
        guard valid(evidence), snapshot.tasks[taskID]?.status == .reportedComplete else { throw Failure.invalid }
        try change(taskID, "Verification evidence recorded") { $0.verificationEvidence = evidence }
    }

    public func summary(since revision: Int) -> Summary {
        Summary(revision: snapshot.revision,
                requiresSnapshot: revision > snapshot.revision || revision < (snapshot.deltas.first?.revision ?? 1) - 1 ||
                    revision < (snapshot.snapshotRequiredAfterRevision ?? 0),
                deltas: snapshot.deltas.filter { $0.revision > revision },
                unresolved: snapshot.tasks.mapValues { $0.operations.filter(\.unresolved) }.filter { !$0.value.isEmpty })
    }

    private func valid(_ text: String, _ max: Int = 4096) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= max
    }
    private func validatePayload(_ payload: Data?) throws {
        guard (payload?.count ?? 0) <= Self.maxPayloadBytes else { throw Failure.capacity }
    }
    private func validate(_ state: Snapshot) throws {
        guard state.version == 1, state.revision >= 0, state.revision < Int.max,
              state.tasks.count <= Self.maxTasks, state.deltas.count <= Self.maxDeltas,
              (state.snapshotRequiredAfterRevision ?? 0) >= 0,
              (state.snapshotRequiredAfterRevision ?? 0) <= state.revision else { throw Failure.invalid }
        var previousRevision = 0
        for delta in state.deltas {
            guard delta.revision > previousRevision, delta.revision <= state.revision,
                  state.tasks[delta.taskID] != nil, valid(delta.detail) else { throw Failure.invalid }
            previousRevision = delta.revision
        }
        for (id, task) in state.tasks {
            try validatePayload(task.checkpointPayload)
            guard id == task.id, valid(id, 128), valid(task.objective), valid(task.scope),
                  !task.checklist.isEmpty, task.checklist.count <= 64,
                  Set(task.checklist.map(\.id)).count == task.checklist.count,
                  task.checklist.allSatisfy({ valid($0.id, 128) && valid($0.text) }),
                  task.events.count <= Self.maxEvents, task.operations.count <= Self.maxOperations,
                  task.checkpoint.utf8.count <= 4096,
                  task.archivedOperationCount >= 0, task.archivedOperationCount <= Int.max - task.operations.count,
                  task.completionReport.map({ valid($0) }) ?? true,
                  task.verificationEvidence.map({ valid($0) }) ?? true,
                  Set(task.operations.map(\.id)).count == task.operations.count,
                  Set(task.operations.map(\.leaseID)).count == task.operations.count else { throw Failure.invalid }
            for (eventID, event) in task.events {
                guard eventID == event.id, valid(event.id, 128), valid(event.key, 128), valid(event.detail) else { throw Failure.invalid }
            }
            for (key, event) in task.pending {
                guard key == event.key, task.events[event.id] == event else { throw Failure.invalid }
            }
            for operation in task.operations {
                try validatePayload(operation.requestPayload)
                try validatePayload(operation.receiptCheckpointPayload)
                guard operation.receipt != nil || operation.receiptCheckpointPayload == nil else { throw Failure.invalid }
                guard valid(operation.id, 128), valid(operation.leaseID, 128), valid(operation.instruction),
                      Set(operation.eventIDs).count == operation.eventIDs.count,
                      operation.eventIDs.allSatisfy({ task.events[$0] != nil }) else { throw Failure.invalid }
                if let receipt = operation.receipt {
                    try validatePayload(receipt.responsePayload)
                    guard receipt.taskID == id, receipt.operationID == operation.id,
                          receipt.leaseID == operation.leaseID, valid(receipt.evidence) else { throw Failure.invalid }
                }
            }
            let unresolved = task.operations.filter(\.unresolved).count
            guard unresolved <= 1 else { throw Failure.invalid }
            switch task.status {
            case .queued, .waiting, .blocked, .reportedComplete:
                guard unresolved == 0 else { throw Failure.invalid }
            case .running, .reconcile:
                guard unresolved == 1 else { throw Failure.invalid }
            case .cancelled: break
            }
            if task.status == .reportedComplete {
                guard task.completionReport != nil, task.checklist.allSatisfy(\.done), task.pending.isEmpty else { throw Failure.invalid }
            }
            if task.verificationEvidence != nil {
                guard task.completionReport != nil else { throw Failure.invalid }
            }
        }
    }
    private func change(_ id: String, _ detail: String, _ mutate: (inout Task) throws -> Void) throws {
        var next = snapshot
        guard var task = next.tasks[id] else { throw Failure.missing }
        try mutate(&task); next.tasks[id] = task; appendDelta(&next, id, detail); try commit(next)
    }
    private func appendDelta(_ next: inout Snapshot, _ id: String, _ detail: String) {
        next.revision += 1
        next.deltas.append(Delta(revision: next.revision, taskID: id, detail: detail))
        if next.deltas.count > Self.maxDeltas { next.deltas.removeFirst(next.deltas.count - Self.maxDeltas) }
    }
    private func commit(_ next: Snapshot) throws {
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= Self.maxSnapshotBytes else { throw Failure.capacity }
        try persist(bytes, url)
        snapshot = next
    }
}

extension RelayMikoTaskEngine.Task {
    private enum CodingKeys: String, CodingKey {
        case id, objective, scope, checklist, status, events, pending, operations, checkpoint
        case checkpointPayload, archivedOperationCount, completionReport, verificationEvidence
    }

    /// Legacy snapshots omit the optional payloads and archive counter.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        objective = try values.decode(String.self, forKey: .objective)
        scope = try values.decode(String.self, forKey: .scope)
        checklist = try values.decode([RelayMikoTaskEngine.ChecklistItem].self, forKey: .checklist)
        status = try values.decode(RelayMikoTaskEngine.Status.self, forKey: .status)
        events = try values.decode([String: RelayMikoTaskEngine.Event].self, forKey: .events)
        pending = try values.decode([String: RelayMikoTaskEngine.Event].self, forKey: .pending)
        operations = try values.decode([RelayMikoTaskEngine.Operation].self, forKey: .operations)
        checkpoint = try values.decode(String.self, forKey: .checkpoint)
        checkpointPayload = try values.decodeIfPresent(Data.self, forKey: .checkpointPayload)
        archivedOperationCount = try values.decodeIfPresent(Int.self, forKey: .archivedOperationCount) ?? 0
        completionReport = try values.decodeIfPresent(String.self, forKey: .completionReport)
        verificationEvidence = try values.decodeIfPresent(String.self, forKey: .verificationEvidence)
    }
}
