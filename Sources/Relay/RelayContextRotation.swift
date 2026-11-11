import CryptoKit
import Foundation

// Automatic context rotation on stock Claude and Codex CLIs
// (work/context-clear-20261101/DESIGN.md). User-approved contract exception
// 2026-11-01 ("Stock CLIs, guarded /clear"): Relay types a capsule request,
// `/clear` and a restore prompt, only through the agent-maintenance input
// fence. The decision to rotate is deterministic and measured.

// MARK: - Measurement

/// The provider's own report of the context its last request carried.
struct RelayContextMeasurement: Equatable, Sendable {
    let provider: String
    /// Every input token of the last model request (cached and uncached).
    let contextTokens: Int
    /// The window the provider reported, when it reports one.
    let window: Int?
}

enum RelayContextUsage {
    /// The last complete usage record in a transcript tail; nil when there is
    /// none or it is inconsistent. A partial first line is ignored.
    static func measure(tail: String, provider: String, startsMidFile: Bool) -> RelayContextMeasurement? {
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard line.utf8.count <= 1 << 20, let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch provider {
            case "claude":
                guard object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                guard let input = count(usage["input_tokens"]), let created = count(usage["cache_creation_input_tokens"] ?? 0),
                      let read = count(usage["cache_read_input_tokens"] ?? 0) else { return nil }
                let (sum1, o1) = input.addingReportingOverflow(created)
                let (sum, o2) = sum1.addingReportingOverflow(read)
                guard !o1, !o2, sum > 0 else { return nil }
                return .init(provider: provider, contextTokens: sum, window: nil)
            case "codex":
                guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { continue }
                // A token_count without info is a rate-limit-only update.
                guard let info = payload["info"] as? [String: Any] else { continue }
                guard let last = info["last_token_usage"] as? [String: Any], let input = count(last["input_tokens"]),
                      input > 0 else { return nil }
                let window = info["model_context_window"].flatMap(count)
                if let window, window <= 0 { return nil }
                return .init(provider: provider, contextTokens: input, window: window)
            default:
                return nil
            }
        }
        return nil
    }

    /// A non-negative JSON integer below 2^53 (no booleans, no fractions).
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double < 9_007_199_254_740_992, double.rounded() == double else { return nil }
        return number.intValue
    }
}

// MARK: - Capsule and prompts

enum RelayContextCapsule {
    static let maximumBytes = 6000

    static func path(_ transition: UUID) -> String {
        "~/.local/share/relay/rotation/" + transition.uuidString.lowercased() + ".md"
    }

    static func header(_ transition: UUID) -> String { "relay-capsule " + transition.uuidString.lowercased() }

    enum Refusal: Error, Equatable { case missing, oversize, encoding, header, historyMarker, empty }

    /// The exact capsule file Relay asked for, or why it is not usable.
    static func validate(_ data: Data, transition: UUID, nonce: String) -> Result<(text: String, sha256: String), Refusal> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard data.count <= maximumBytes else { return .failure(.oversize) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return .failure(.encoding) }
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        // Exact; a CRLF file may end the line with a carriage return.
        guard first == header(transition) || first == header(transition) + "\r" else { return .failure(.header) }
        guard !text.contains(nonce) else { return .failure(.historyMarker) }
        guard text.dropFirst(first.count).contains(where: { !$0.isWhitespace }) else { return .failure(.empty) }
        return .success((text, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    static func historyMarker(_ nonce: String) -> String { "relay-history-marker " + nonce }

    static func request(transition: UUID, nonce: String) -> String {
        let id = transition.uuidString.lowercased()
        return """
        [Relay context rotation \(id)] Your context is large. Relay will clear it and restore a capsule you write now. \
        Write your current working capsule to the exact file \(path(transition)) (create the directory if needed), at most \
        \(maximumBytes) bytes of UTF-8. Its first line must be exactly: \(header(transition)) . Then sections: Goal; Decisions \
        and constraints (keep user rules verbatim); Unfinished action; Next step; Job, receipt and message IDs; Evidence \
        paths and hashes. No transcript, logs or memory dumps. Do not copy this message or the marker \
        \(historyMarker(nonce)) into it. Also save the same text to Chitta. Start no new work. When the file is written, \
        reply with exactly: CAPSULE \(id)
        """
    }

    static func restore(transition: UUID, capsule: String) -> String {
        let id = transition.uuidString.lowercased()
        return "relay-capsule-restore \(id)\nRelay cleared your previous context. This is the capsule you wrote before " +
            "the clear; treat it as your current state.\n\n" + capsule +
            "\n\nReply first with exactly: ACK \(id) . Then continue with the next step."
    }

    static func ack(_ transition: UUID) -> String { "ACK " + transition.uuidString.lowercased() }
}

// MARK: - Transition machine (pure)

enum RelayContextRotationMachine {
    enum State: String, Codable, Equatable, Sendable, CaseIterable {
        case idle, armed
        case sendingCapsuleRequest, capsuleRequested, capsuleVerified
        case sendingClear, clearSubmitted, clearVerified
        case sendingRestore, restoreSubmitted
        case done, aborted, attention
        // Chitta ledger path only (r2).
        /// rotation_signal recorded.
        case signaled
        /// rotation_claim held (a live fencing token).
        case claimed
        /// rotation_intent recorded; `/clear` may be typed.
        case intentRecorded
        /// The new conversation is observed; rotation_bind pending.
        case clearSeen
        /// ACK seen; rotation_ack pending.
        case acknowledging

        var terminal: Bool { [.done, .aborted, .attention].contains(self) }
        /// Before `/clear` was typed: the old context is intact.
        var beforeClear: Bool {
            [.idle, .armed, .signaled, .sendingCapsuleRequest, .capsuleRequested, .claimed, .capsuleVerified, .intentRecorded]
                .contains(self)
        }
    }

    enum Event: String, CaseIterable, Sendable {
        case measuredOver, measuredUnder, unmeasured
        /// Every fence holds right now (quiet, empty prompt, same identity, no human input).
        case fenceOpen
        case sendOK, sendUnconfirmed
        /// The pane completed the turn after a submitted step.
        case turnCompleted
        case capsuleOK, capsuleBad, capsuleMissing
        case bindingNew, bindingSame, bindingOtherProcess
        case ackSeen, ackMissing
        case humanInput, settingOff, deadline
        /// The app restarted and reloaded the persisted state.
        case appRestart
        // Chitta ledger outcomes (r2). A file-path transition ignores them.
        case ledgerOK, ledgerRefused, ledgerAmbiguous, staleToken
    }

    enum Action: String, Equatable, Sendable {
        case typeCapsuleRequest, readCapsule, typeClear, readBinding, typeRestore, readAck
        // Chitta ledger operations (r2).
        case signal, claim, saveCapsule, recordIntent, bind, ack, release
    }

    static let ledgerOutcomes: Set<Event> = [.ledgerOK, .ledgerRefused, .ledgerAmbiguous, .staleToken]

    /// A live Chitta claim exists that Relay must release when it stops before the clear.
    static func holdsClaim(_ state: State, ledger: Bool) -> Bool {
        ledger && [.claimed, .capsuleVerified, .intentRecorded].contains(state)
    }

    /// Stopping before the clear: aborted, releasing a held claim.
    private static func abort(_ state: State, ledger: Bool) -> (State, Action?) {
        (.aborted, holdsClaim(state, ledger: ledger) ? .release : nil)
    }

    /// `ledger` is fixed for a transition at creation: true for the Chitta path, false for the r1 file path.
    static func step(_ state: State, _ event: Event, ledger: Bool = false) -> (State, Action?) {
        if state.terminal { return (state, nil) }
        switch event {
        case .humanInput, .settingOff:
            if state == .idle { return (state, nil) }
            return state.beforeClear && !isSending(state) ? abort(state, ledger: ledger) : (.attention, nil)
        case .appRestart:
            // A send in flight may or may not have reached the pane: never repeated.
            return (isSending(state) ? .attention : state, nil)
        case .deadline:
            switch state {
            case .idle: return (state, nil)
            case .armed, .capsuleRequested: return (.aborted, nil)
            case .signaled, .claimed, .capsuleVerified, .intentRecorded:
                // r3 (user decision): a deadline before the clear aborts on both paths, as DESIGN.md
                // says (aborted: old context intact, before clear). r1 left the file path's
                // capsuleVerified deadline at attention; nothing was typed after the capsule request.
                return abort(state, ledger: ledger)
            default: return (.attention, nil)
            }
        case .ledgerRefused, .ledgerAmbiguous, .staleToken:
            guard ledger else { return (state, nil) }
            switch state {
            // Each is the state whose ledger operation can fail: signal, claim, save, intent.
            case .armed, .capsuleRequested, .claimed, .capsuleVerified: return abort(state, ledger: ledger)
            // bind and ack, after the clear: never repeated blindly.
            case .clearSeen, .acknowledging: return (.attention, nil)
            default: return (state, nil)
            }
        default: break
        }
        if ledger {
            switch (state, event) {
            case (.idle, .measuredOver): return (.armed, .signal)
            case (.armed, .ledgerOK): return (.signaled, nil)
            case (.signaled, .fenceOpen): return (.sendingCapsuleRequest, .typeCapsuleRequest)
            case (.sendingCapsuleRequest, .sendOK): return (.capsuleRequested, nil)
            case (.capsuleRequested, .turnCompleted): return (.capsuleRequested, .claim)
            case (.capsuleRequested, .ledgerOK): return (.claimed, nil)
            case (.claimed, .turnCompleted): return (.claimed, .saveCapsule)
            case (.claimed, .capsuleOK): return (.capsuleVerified, .recordIntent)
            case (.claimed, .capsuleBad): return abort(state, ledger: ledger)
            case (.capsuleVerified, .ledgerOK): return (.intentRecorded, nil)
            case (.intentRecorded, .fenceOpen): return (.sendingClear, .typeClear)
            case (.sendingClear, .sendOK): return (.clearSubmitted, nil)
            case (.clearSubmitted, .turnCompleted): return (.clearSubmitted, .readBinding)
            case (.clearSubmitted, .bindingNew): return (.clearSeen, .bind)
            case (.clearSubmitted, .bindingOtherProcess): return (.attention, nil)
            case (.clearSeen, .ledgerOK): return (.clearVerified, nil)
            case (.clearVerified, .fenceOpen): return (.sendingRestore, .typeRestore)
            case (.sendingRestore, .sendOK): return (.restoreSubmitted, nil)
            case (.restoreSubmitted, .turnCompleted): return (.restoreSubmitted, .readAck)
            case (.restoreSubmitted, .ackSeen): return (.acknowledging, .ack)
            case (.acknowledging, .ledgerOK): return (.done, nil)
            case (_, .sendUnconfirmed) where isSending(state): return (.attention, nil)
            default: return (state, nil)
            }
        }
        switch (state, event) {
        case (.idle, .measuredOver): return (.armed, nil)
        case (.armed, .fenceOpen): return (.sendingCapsuleRequest, .typeCapsuleRequest)
        case (.sendingCapsuleRequest, .sendOK): return (.capsuleRequested, nil)
        case (.capsuleRequested, .turnCompleted): return (.capsuleRequested, .readCapsule)
        case (.capsuleRequested, .capsuleOK): return (.capsuleVerified, nil)
        case (.capsuleRequested, .capsuleBad): return (.aborted, nil)
        case (.capsuleVerified, .fenceOpen): return (.sendingClear, .typeClear)
        case (.sendingClear, .sendOK): return (.clearSubmitted, nil)
        case (.clearSubmitted, .turnCompleted): return (.clearSubmitted, .readBinding)
        case (.clearSubmitted, .bindingNew): return (.clearVerified, nil)
        case (.clearSubmitted, .bindingOtherProcess): return (.attention, nil)
        case (.clearVerified, .fenceOpen): return (.sendingRestore, .typeRestore)
        case (.sendingRestore, .sendOK): return (.restoreSubmitted, nil)
        case (.restoreSubmitted, .turnCompleted): return (.restoreSubmitted, .readAck)
        case (.restoreSubmitted, .ackSeen): return (.done, nil)
        case (_, .sendUnconfirmed) where isSending(state): return (.attention, nil)
        default: return (state, nil)
        }
    }

    static func isSending(_ state: State) -> Bool { [.sendingCapsuleRequest, .sendingClear, .sendingRestore].contains(state) }
}

// MARK: - Durable record

struct RelayContextRotationRecord: Codable, Equatable, Sendable {
    let transition: UUID
    let paneID: UUID
    let host: String
    let provider: String
    let processID: Int
    let processStart: UInt64
    /// The conversation being rotated; kept as the archive (resume it to recover).
    let sourceSession: String
    let sourceTranscript: String
    let nonce: String
    let measuredTokens: Int
    let window: Int?
    var state: RelayContextRotationMachine.State
    var reason: String?
    var capsuleSHA256: String?
    var newSession: String?
    var newTranscript: String?
    var newMeasuredTokens: Int?
    let createdAt: Date
    var updatedAt: Date
    var stepStartedAt: Date
    /// r2: the Chitta ledger path's state; nil is the r1 file path. Fixed at creation (the journal
    /// refuses a write that adds or drops it), so a transition never falls back mid-way.
    var ledger: RelayRotationLedgerRecord? = nil
    /// Why the file path was chosen, when Chitta was not usable at arming.
    var pathNote: String? = nil

    var usesLedger: Bool { ledger != nil }
}

/// One record per transition, durable and owner-only. A record that cannot be
/// read stops all new rotations (fail closed).
@MainActor final class RelayContextRotationJournal {
    private struct Disk: Codable { var version = 1; var records: [RelayContextRotationRecord] }
    static let limit = 256
    let url: URL?
    private(set) var records: [UUID: RelayContextRotationRecord] = [:]
    private(set) var ready = true
    var failWrites = false

    init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 8 << 20 else { throw RelayHostRPCError.invalidRequest }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let disk = try decoder.decode(Disk.self, from: data)
            guard disk.version == 1 else { throw RelayHostRPCError.invalidRequest }
            for var record in disk.records {
                guard records[record.transition] == nil else { throw RelayHostRPCError.invalidRequest }
                record.state = RelayContextRotationMachine.step(record.state, .appRestart, ledger: record.usesLedger).0
                if record.state == .attention, record.reason == nil {
                    record.reason = "Relay restarted while a rotation input was being sent; it is not repeated"
                }
                records[record.transition] = record
            }
        } catch {
            records = [:]
            ready = false
        }
    }

    static var productionURL: URL {
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay", isDirectory: true)
            .appendingPathComponent("context-rotation-v1.json")
    }

    func active(pane: UUID) -> RelayContextRotationRecord? {
        records.values.first { $0.paneID == pane && !$0.state.terminal }
    }

    func latest(pane: UUID) -> RelayContextRotationRecord? {
        records.values.filter { $0.paneID == pane }.max { $0.createdAt < $1.createdAt }
    }

    /// Persists `record`; false (and nothing changed) when it cannot be written.
    func put(_ record: RelayContextRotationRecord) -> Bool {
        guard ready, !failWrites else { return false }
        // The path is fixed per transition: never a fallback mid-transition.
        if let existing = records[record.transition], existing.usesLedger != record.usesLedger { return false }
        var next = records
        next[record.transition] = record
        if next.count > Self.limit {
            // Only finished records leave, oldest first; unresolved ones never do.
            let removable = next.values.filter { $0.state.terminal }.sorted { $0.updatedAt < $1.updatedAt }
            for old in removable.prefix(next.count - Self.limit) { next[old.transition] = nil }
            guard next.count <= Self.limit else { return false }
        }
        if let url {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let ordered = next.values.sorted { ($0.createdAt, $0.transition.uuidString) < ($1.createdAt, $1.transition.uuidString) }
                let data = try encoder.encode(Disk(records: ordered))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { return false }
        }
        records = next
        return true
    }
}

// MARK: - Fences

enum RelayContextRotationInput: String, Sendable { case capsuleRequest, clear, restore }

enum RelayStockRotationPolicy {
    static let defaultBudget = 160_000
    static let windowFraction = 0.9
    static let cooldown: TimeInterval = 30 * 60
    static let settle: TimeInterval = 10
    static func deadline(_ state: RelayContextRotationMachine.State) -> TimeInterval {
        switch state {
        case .armed, .signaled: 30 * 60
        case .capsuleRequested, .restoreSubmitted: 10 * 60
        case .clearSubmitted, .clearSeen, .acknowledging: 2 * 60
        case .capsuleVerified, .clearVerified, .claimed, .intentRecorded: 10 * 60
        default: 60
        }
    }

    static func over(_ measurement: RelayContextMeasurement, budget: Int) -> Bool {
        if measurement.contextTokens >= budget { return true }
        if let window = measurement.window { return Double(measurement.contextTokens) >= Double(window) * windowFraction }
        return false
    }

    /// The exact text each input kind may carry. Nothing else is ever typed.
    static func admits(_ text: String, kind: RelayContextRotationInput) -> Bool {
        switch kind {
        case .clear: text == "/clear"
        case .capsuleRequest: text.hasPrefix("[Relay context rotation ") && text.utf8.count <= 4096 && !text.contains("\r")
        case .restore: text.hasPrefix("relay-capsule-restore ") && text.utf8.count <= 8192 && !text.contains("\r")
        }
    }

    /// Why Relay must not type into the agent now, or nil. A typed draft
    /// defers (it is never saved and restored around a rotation).
    static func blocker(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, emptyPrompt: Bool, hasDraft: Bool,
                        pendingApprovals: Int, inputAge: TimeInterval) -> String? {
        guard proof.valid(for: paneID), proof.bound == true else { return proof.unavailable ?? "Native identity is unavailable" }
        guard pendingApprovals == 0 else { return "Waiting for the pending approval" }
        guard !hasDraft else { return "Waiting for the unsent prompt to be cleared or sent" }
        if proof.backgroundWork == true { return "Waiting for the agent's background work to finish" }
        if proof.provider == "claude" && proof.backgroundWork == nil { return "Background work cannot be verified absent" }
        if proof.provider == "claude" && proof.subagentWork != false { return "Subagent work cannot be verified finished" }
        guard emptyPrompt else { return "Waiting for the prompt to be confirmed empty" }
        guard RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: emptyPrompt, hasDraft: hasDraft) else {
            return "Waiting for the current turn to finish"
        }
        guard inputAge >= 15 else { return "Waiting until you finish typing" }
        return nil
    }

    /// r3: the gates at the send instant. The prompt, composer draft, approvals and input
    /// revision are read live on the Mac; lifecycle, background and subagent work are the
    /// native proof of the observation that opened the fence, taken after the last host
    /// round trip of that tick. Both the coordinator (before it journals the send) and the
    /// production send boundary call this one function.
    static func sendBlocker(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, emptyPrompt: Bool, hasDraft: Bool,
                            pendingApprovals: Int, inputRevision: UInt64, expectedRevision: UInt64,
                            text: String, kind: RelayContextRotationInput) -> String? {
        guard inputRevision == expectedRevision else { return "New input in the pane" }
        guard admits(text, kind: kind) else { return "Internal: the \(kind.rawValue) text is not admissible" }
        // An unchanged input revision since the observation means no new input; the observation
        // itself required 15 s of input quiet.
        return blocker(proof, paneID: paneID, emptyPrompt: emptyPrompt, hasDraft: hasDraft,
                       pendingApprovals: pendingApprovals, inputAge: .infinity)
    }
}

extension PaneModel {
    /// An unsent composer draft, attachment, submission or held native delivery.
    var contextRotationDraftPending: Bool {
        composerStateIfCreated.map { !$0.draft.isEmpty || !$0.attachmentQueue.attachments.isEmpty ||
            $0.submitting || $0.nativeDeliveryHeld } ?? false
    }
}

/// What one observation of the pane established.
struct RelayContextRotationObservation: Equatable, Sendable {
    let provider: String
    let processID: Int
    let processStart: UInt64
    let sessionID: String
    let transcriptPath: String?
    let quiet: Bool
    /// nil when every typing fence holds right now.
    let fenceBlocker: String?
    /// The native proof the production send boundary rechecks.
    var proof: RelayAgentMaintenanceProbe? = nil
}

/// The one pane that may rotate: an exact pane plus provider process
/// incarnation. Nothing else is enrolled, so a restarted or replaced agent
/// in the same pane is not rotated until the user enrolls it again.
struct RelayContextRotationEnrollment: Codable, Equatable, Sendable {
    let paneID: UUID
    let provider: String
    let processID: Int
    let processStart: UInt64

    func admits(paneID: UUID, observation: RelayContextRotationObservation) -> Bool {
        paneID == self.paneID && observation.provider == provider &&
            observation.processID == processID && observation.processStart == processStart
    }
}

@MainActor protocol RelayContextRotationEnvironment: AnyObject {
    var enabled: Bool { get }
    /// nil: no pane is enrolled and nothing new is armed.
    var enrollment: RelayContextRotationEnrollment? { get }
    var budget: Int { get }
    func observe(_ pane: PaneModel) async -> RelayContextRotationObservation?
    /// The last `maxBytes` of a host file; nil when it is missing or unreadable.
    func tail(_ profile: ConnectionProfile, path: String, maxBytes: Int) async -> (text: String, partial: Bool)?
    /// r3: why the send must wait, from the live Mac-side gates and the observation's proof
    /// (RelayStockRotationPolicy.sendBlocker); nil when it may go now. Synchronous: nothing
    /// can run between it, the journaled send and the send itself.
    func liveBlocker(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
                     observation: RelayContextRotationObservation, inputRevision: UInt64) -> String?
    func send(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
              observation: RelayContextRotationObservation, inputRevision: UInt64) -> Bool
    /// One `chitta ledger_op` on the pane's host (r2). Never retried by the caller.
    func ledger(_ profile: ConnectionProfile, op: String, args: [String: Any]) async -> RelayRotationLedgerReply
}

extension RelayContextUsage {
    /// Whether the provider's assistant (not a user message or a tool) said
    /// `phrase` in this tail.
    static func assistantSaid(_ phrase: String, tail: String, provider: String) -> Bool {
        for line in tail.split(separator: "\n") where line.contains(phrase) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if provider == "claude", object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]],
               content.contains(where: { $0["type"] as? String == "text" && ($0["text"] as? String)?.contains(phrase) == true }) {
                return true
            }
            if provider == "codex", let payload = object["payload"] as? [String: Any] {
                if object["type"] as? String == "event_msg", payload["type"] as? String == "agent_message",
                   (payload["message"] as? String)?.contains(phrase) == true { return true }
                if object["type"] as? String == "response_item", payload["type"] as? String == "message",
                   payload["role"] as? String == "assistant", let content = payload["content"] as? [[String: Any]],
                   content.contains(where: { ($0["text"] as? String)?.contains(phrase) == true }) { return true }
            }
        }
        return false
    }
}

// MARK: - Coordinator

@MainActor final class RelayContextRotation: ObservableObject {
    static let shared = RelayContextRotation(journal: RelayContextRotationJournal(url: RelayContextRotationJournal.productionURL),
                                             environment: RelayContextRotationHostEnvironment())
    @Published private(set) var statuses: [UUID: String] = [:]
    let journal: RelayContextRotationJournal
    let environment: RelayContextRotationEnvironment
    var now: () -> Date = Date.init
    private var inFlight: Set<UUID> = []
    /// The pane's input revision after Relay's own last input; any later
    /// change is a human (or reconnect) event.
    private var baselines: [UUID: UInt64] = [:]
    /// Test seam: runs at each suspension point of `advance` with its index.
    var suspension: (@MainActor (Int) -> Void)?

    init(journal: RelayContextRotationJournal, environment: RelayContextRotationEnvironment) {
        self.journal = journal
        self.environment = environment
    }

    /// Measurement interval for a pane with no rotation in progress.
    static let idleInterval: TimeInterval = 60
    private var lastChecked: [UUID: Date] = [:]

    func tick(_ workspace: WorkspaceModel, now date: Date = Date()) {
        for pane in workspace.panes.values where pane.contentKind == .terminal && pane.profile.backend == .relay &&
            pane.connectionState == .connected && (pane.kind == .claude || pane.kind == .codex) {
            let active = journal.active(pane: pane.id) != nil
            guard permitted(pane.id) || active, !inFlight.contains(pane.id) else { continue }
            if !active, let last = lastChecked[pane.id], date.timeIntervalSince(last) < Self.idleInterval { continue }
            lastChecked[pane.id] = date
            inFlight.insert(pane.id)
            Task { @MainActor in
                defer { self.inFlight.remove(pane.id) }
                await self.advance(pane, workspace: workspace)
            }
        }
    }

    private func pause(_ index: Int) { suspension?(index) }

    /// The setting is on and this pane is the enrolled one.
    private func permitted(_ paneID: UUID) -> Bool {
        environment.enabled && environment.enrollment?.paneID == paneID
    }

    private func save(_ record: RelayContextRotationRecord, _ event: RelayContextRotationMachine.Event,
                      reason: String? = nil, change: (inout RelayContextRotationRecord) -> Void = { _ in }) -> RelayContextRotationRecord? {
        var next = record
        let (state, action) = RelayContextRotationMachine.step(record.state, event, ledger: record.usesLedger)
        change(&next)
        if state != record.state { next.stepStartedAt = now() }
        next.state = state
        next.updatedAt = now()
        if let reason { next.reason = reason }
        guard journal.put(next) else {
            statuses[record.paneID] = "Rotation record could not be saved; nothing more is typed"
            return nil
        }
        statuses[record.paneID] = Self.describe(next)
        if action == .release { pendingRelease.insert(next.transition) }
        return next
    }

    static func describe(_ record: RelayContextRotationRecord) -> String {
        let reason = record.reason.map { ": " + $0 } ?? ""
        switch record.state {
        case .done: return "Context rotated and restored (\(record.measuredTokens) tokens before" +
            (record.newMeasuredTokens.map { ", \($0) after" } ?? "") + ")"
        case .aborted: return "Context rotation stopped before clearing; the conversation is unchanged" + reason
        case .attention: return "Context rotation needs attention; capsule \(RelayContextCapsule.path(record.transition))" + reason
        default: return "Context rotation: " + record.state.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1",
                                                                                        options: .regularExpression).lowercased()
        }
    }

    /// Transitions that stopped before the clear while holding a Chitta claim. Drained only by
    /// the owning pane's advance (r3). Internal for tests.
    var pendingRelease: Set<UUID> = []

    func advance(_ pane: PaneModel, workspace: WorkspaceModel) async {
        let profile = pane.profile
        await advanceOnce(pane, workspace: workspace)
        // r3: only this pane's transitions, so the release runs on the host that holds the claim.
        for transition in pendingRelease {
            guard let record = journal.records[transition] else { pendingRelease.remove(transition); continue }
            guard record.paneID == pane.id else { continue }
            pendingRelease.remove(transition)
            await release(record, profile: profile)
        }
    }

    private func advanceOnce(_ pane: PaneModel, workspace: WorkspaceModel) async {
        let profile = pane.profile
        // Captured before the first await.
        let revision = pane.agentInputRevision
        let host = RelayAgentLaunchHostName.label(profile)
        let record = journal.active(pane: pane.id)
        if let current = record {
            if let baseline = baselines[pane.id], baseline != revision {
                _ = save(current, .humanInput, reason: "New input in the pane (human or reconnect) wins")
                baselines[pane.id] = nil
                return
            }
            if !permitted(current.paneID) {
                _ = save(current, .settingOff, reason: "Automatic context rotation was turned off or the pane was unenrolled")
                return
            }
            if now().timeIntervalSince(current.stepStartedAt) > RelayStockRotationPolicy.deadline(current.state) {
                _ = save(current, .deadline, reason: "No progress before the \(current.state.rawValue) deadline")
                return
            }
        }
        pause(0)
        guard let observation = await environment.observe(pane) else { return }
        pause(1)
        guard workspace.panes[pane.id] === pane, pane.profile == profile, pane.agentInputRevision == revision else { return }
        if record == nil {
            guard permitted(pane.id), environment.enrollment?.admits(paneID: pane.id, observation: observation) == true else {
                statuses[pane.id] = environment.enrollment?.paneID == pane.id
                    ? "Context rotation not armed: the enrolled agent process is not the one running now" : nil
                return
            }
            guard journal.ready, observation.quiet, let transcript = observation.transcriptPath else { return }
            if let last = journal.latest(pane: pane.id), now().timeIntervalSince(last.updatedAt) < RelayStockRotationPolicy.cooldown { return }
            // r2: the path is chosen here, once. Chitta when it knows this session; the r1 file path when
            // chitta is missing, its status fails or the session is unknown. A live claim, an ambiguous
            // intent or an acknowledged epoch refuses arming instead (never a fallback).
            var ledgerStatus: [String: Any]?
            var pathNote: String?
            let status = await environment.ledger(profile, op: "rotation_status", args: ["session_id": observation.sessionID])
            pause(7)
            guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
            switch status.kind {
            case .value:
                guard let v = status.value, v["session_id"] as? String == observation.sessionID else {
                    pathNote = "Chitta's status named another session; file capsule"
                    break
                }
                if v["live"] as? Bool == true {
                    statuses[pane.id] = "Context rotation not armed: Chitta shows a live rotation claim on this session"
                    return
                }
                if (v["intent"] as? [String: Any])?["state"] as? String == "ambiguous" {
                    statuses[pane.id] = "Context rotation not armed: Chitta shows an unreconciled rotation intent"
                    return
                }
                if v["ack"] is [String: Any] {
                    statuses[pane.id] = "Context rotation not armed: Chitta already acknowledged a rotation of this session"
                    return
                }
                ledgerStatus = v
            case .missing: pathNote = "chitta is not installed on the host; file capsule"
            case .refused(let code): pathNote = "Chitta refused rotation_status (\(code)); file capsule"
            case .ambiguous(let why): pathNote = "Chitta status unavailable (\(why)); file capsule"
            }
            var measurement: RelayContextMeasurement?
            if let usage = ledgerStatus?["usage"] as? [String: Any], let tokens = RelayRotationJSON.int(usage["context_tokens"]),
               tokens > 0 {
                let window = RelayRotationJSON.int(usage["context_window"])
                measurement = .init(provider: observation.provider, contextTokens: tokens, window: (window ?? 0) > 0 ? window : nil)
            }
            if measurement == nil {
                guard let tail = await environment.tail(profile, path: transcript, maxBytes: 256 << 10) else {
                    statuses[pane.id] = "Context size unmeasured: the transcript could not be read"
                    return
                }
                pause(2)
                guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
                measurement = RelayContextUsage.measure(tail: tail.text, provider: observation.provider, startsMidFile: tail.partial)
            }
            guard let measurement else {
                statuses[pane.id] = "Context size unmeasured: no complete usage record"
                return
            }
            guard RelayStockRotationPolicy.over(measurement, budget: environment.budget) else {
                statuses[pane.id] = "Context \(measurement.contextTokens) tokens; below the rotation budget"
                return
            }
            let date = now()
            let transition = UUID()
            var created = RelayContextRotationRecord(
                transition: transition, paneID: pane.id, host: host, provider: observation.provider,
                processID: observation.processID, processStart: observation.processStart,
                sourceSession: observation.sessionID, sourceTranscript: transcript,
                nonce: UUID().uuidString.lowercased(), measuredTokens: measurement.contextTokens, window: measurement.window,
                state: .idle, reason: nil, capsuleSHA256: nil, newSession: nil, newTranscript: nil, newMeasuredTokens: nil,
                createdAt: date, updatedAt: date, stepStartedAt: date)
            if ledgerStatus != nil {
                created.ledger = RelayRotationLedgerRecord(epoch: transition.uuidString.lowercased(),
                                                           claimant: "relay/" + pane.id.uuidString.lowercased())
            } else {
                created.pathNote = pathNote
            }
            guard save(created, .measuredOver) != nil else { return }
            baselines[pane.id] = revision
            // r3: arming made host round trips after the observation, so nothing is typed on
            // it; the next tick observes again.
            return
        }
        guard var current = record else { return }
        // The same provider process throughout; the conversation is the
        // source one until the clear is verified, the new one after.
        guard observation.provider == current.provider, observation.processID == current.processID,
              observation.processStart == current.processStart else {
            _ = save(current, .humanInput, reason: "A different provider process now owns the pane")
            return
        }
        let expectedSession = current.state.beforeClear || current.state == .sendingClear ? current.sourceSession : current.newSession
        if current.state != .clearSubmitted, let expectedSession, observation.sessionID != expectedSession {
            _ = save(current, .humanInput, reason: "The pane's conversation changed outside the rotation")
            return
        }
        let settled = observation.quiet && now().timeIntervalSince(current.stepStartedAt) >= RelayStockRotationPolicy.settle
        let typing: Set<RelayContextRotationMachine.State> = current.usesLedger
            ? [.signaled, .intentRecorded, .clearVerified] : [.armed, .capsuleVerified, .clearVerified]
        if typing.contains(current.state) {
            guard observation.quiet, observation.fenceBlocker == nil else {
                statuses[pane.id] = "Context rotation waiting: " + (observation.fenceBlocker ?? "the turn is not finished")
                return
            }
            let kind: RelayContextRotationInput
            let text: String
            // The observation whose native proof opens the fence: none older than the tick's last host round trip.
            var fenceObservation = observation
            switch current.state {
            case .armed:
                kind = .capsuleRequest; text = RelayContextCapsule.request(transition: current.transition, nonce: current.nonce)
            case .signaled:
                kind = .capsuleRequest; text = RelayRollCapsule.request(transition: current.transition, nonce: current.nonce)
            case .capsuleVerified, .intentRecorded:
                kind = .clear; text = "/clear"
            default:
                kind = .restore
                if current.usesLedger {
                    // Only from the journaled snapshot, hash-checked; never a live re-read.
                    guard let snapshot = current.ledger?.snapshot, let data = Optional(Data(snapshot.utf8)),
                          RelayRotationJSON.sha256(data) == current.ledger?.snapshotSHA256,
                          let restore = RelayRollCapsule.restore(transition: current.transition, snapshot: data),
                          !restore.contains(current.nonce) else {
                        _ = save(current, .deadline, reason: "The journaled capsule snapshot failed its hash check before restore")
                        return
                    }
                    text = restore
                } else {
                    // The exact capsule, read again and hash-checked before it is typed.
                    guard let capsule = await environment.tail(profile, path: RelayContextCapsule.path(current.transition),
                                                               maxBytes: RelayContextCapsule.maximumBytes + 1), !capsule.partial,
                          case .success(let valid) = RelayContextCapsule.validate(Data(capsule.text.utf8), transition: current.transition,
                                                                                 nonce: current.nonce),
                          valid.sha256 == current.capsuleSHA256 else {
                        _ = save(current, .deadline, reason: "The capsule changed or could not be read back before restore")
                        return
                    }
                    pause(3)
                    guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
                    // r3: the read was a host round trip; the fence is judged on an observation taken after it.
                    guard let fresh = await environment.observe(pane) else { return }
                    pause(17)
                    guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision,
                          fresh.processID == current.processID, fresh.processStart == current.processStart,
                          fresh.sessionID == current.newSession else { return }
                    guard fresh.quiet, fresh.fenceBlocker == nil else {
                        statuses[pane.id] = "Context rotation waiting: " + (fresh.fenceBlocker ?? "the turn is not finished")
                        return
                    }
                    fenceObservation = fresh
                    text = RelayContextCapsule.restore(transition: current.transition, capsule: valid.text)
                }
            }
            guard RelayStockRotationPolicy.admits(text, kind: kind) else {
                _ = save(current, .deadline, reason: "Internal: the \(kind.rawValue) text is not admissible")
                return
            }
            // r3: the live gates, synchronously: nothing runs between this, the journaled send and the send.
            guard permitted(pane.id) else {
                _ = save(current, .settingOff, reason: "Automatic context rotation was turned off or the pane was unenrolled")
                return
            }
            if let blocker = environment.liveBlocker(pane, text, kind: kind, observation: fenceObservation,
                                                     inputRevision: revision) {
                statuses[pane.id] = "Context rotation waiting: " + blocker
                return
            }
            // Persisted before the send: a crash after this is never repeated.
            guard let sending = save(current, .fenceOpen) else { return }
            guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision,
                  permitted(pane.id) else {
                _ = save(sending, .sendUnconfirmed, reason: "The pane changed at the send boundary; nothing was typed")
                return
            }
            let sent = environment.send(pane, text, kind: kind, observation: fenceObservation, inputRevision: revision)
            baselines[pane.id] = pane.agentInputRevision
            _ = save(sending, sent ? .sendOK : .sendUnconfirmed,
                     reason: sent ? nil : "The \(kind.rawValue) input was not confirmed; it is not repeated")
            return
        }
        if current.usesLedger, await advanceLedger(&current, pane: pane, workspace: workspace, observation: observation,
                                                   revision: revision, settled: settled) {
            return
        }
        switch current.state {
        case .capsuleRequested:
            guard settled else { return }
            guard let file = await environment.tail(profile, path: RelayContextCapsule.path(current.transition),
                                                    maxBytes: RelayContextCapsule.maximumBytes + 1) else {
                statuses[pane.id] = "Waiting for the agent's capsule file"
                return
            }
            pause(4)
            guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
            switch RelayContextCapsule.validate(Data(file.text.utf8), transition: current.transition, nonce: current.nonce) {
            case .success(let valid) where !file.partial:
                current = save(current, .capsuleOK) { $0.capsuleSHA256 = valid.sha256 } ?? current
            case .success:
                _ = save(current, .capsuleBad, reason: "The capsule exceeds \(RelayContextCapsule.maximumBytes) bytes")
            case .failure(let refusal):
                _ = save(current, .capsuleBad, reason: "The capsule is not usable (\(refusal))")
            }
        case .clearSubmitted:
            guard observation.quiet else { return }
            guard observation.sessionID != current.sourceSession else {
                statuses[pane.id] = "Waiting for the clear to start a new conversation"
                return
            }
            guard let transcript = observation.transcriptPath, transcript != current.sourceTranscript,
                  let tail = await environment.tail(profile, path: transcript, maxBytes: 256 << 10) else {
                statuses[pane.id] = "Waiting for the new conversation's transcript"
                return
            }
            pause(5)
            guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
            guard !tail.text.contains(current.nonce) else {
                _ = save(current, .deadline, reason: "The new conversation still contains the previous history marker")
                return
            }
            _ = save(current, .bindingNew) {
                $0.newSession = observation.sessionID
                $0.newTranscript = transcript
            }
        case .restoreSubmitted:
            guard settled, let transcript = current.newTranscript,
                  let tail = await environment.tail(profile, path: transcript, maxBytes: 256 << 10) else { return }
            pause(6)
            guard workspace.panes[pane.id] === pane, pane.agentInputRevision == revision else { return }
            guard !tail.text.contains(current.nonce) else {
                _ = save(current, .deadline, reason: "The restored conversation contains the previous history marker")
                return
            }
            let marker: String
            if let ledger = current.ledger {
                guard let capsuleRevision = ledger.capsuleRevision, let sha = ledger.snapshotSHA256 else { return }
                marker = RelayRollCapsule.header(current.transition, revision: capsuleRevision, sha: sha)
            } else {
                marker = RelayContextCapsule.header(current.transition)
            }
            guard tail.text.contains(marker),
                  RelayContextUsage.assistantSaid(RelayContextCapsule.ack(current.transition), tail: tail.text,
                                                  provider: current.provider) else {
                statuses[pane.id] = "Waiting for the agent to acknowledge the restored capsule"
                return
            }
            let after = RelayContextUsage.measure(tail: tail.text, provider: current.provider, startsMidFile: tail.partial)
            _ = save(current, .ackSeen) { $0.newMeasuredTokens = after?.contextTokens }
        default:
            return
        }
    }
}

enum RelayAgentLaunchHostName {
    static func label(_ profile: ConnectionProfile) -> String { profile.kind == .local ? "This Mac" : profile.name }
}

// MARK: - Production environment

@MainActor final class RelayContextRotationHostEnvironment: RelayContextRotationEnvironment {
    var enabled: Bool { RelayPreferences.shared.automaticContextRotation }
    var enrollment: RelayContextRotationEnrollment? { RelayPreferences.shared.contextRotationEnrollment }
    var budget: Int { RelayPreferences.shared.contextRotationBudget }

    func observe(_ pane: PaneModel) async -> RelayContextRotationObservation? {
        guard let proof = try? await RelayAgentMaintenanceReader.inspect(pane), proof.valid(for: pane.id), proof.bound == true,
              let provider = proof.provider, let pid = proof.processID, let start = proof.processStart,
              let session = proof.sessionID else { return nil }
        await pane.runtime.prepareAgentMaintenancePromptProof()
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(proof, subagents: pane.subagents)
        let empty = pane.runtime.agentMaintenancePromptIsEmpty(explainedAgents: explained)
        let draft = pane.contextRotationDraftPending
        let blocker = RelayStockRotationPolicy.blocker(proof, paneID: pane.id, emptyPrompt: empty, hasDraft: draft,
            pendingApprovals: pane.pendingAgentApprovals, inputAge: Date().timeIntervalSince(pane.agentLastInputAt))
        return .init(provider: provider, processID: pid, processStart: start, sessionID: session,
                     transcriptPath: await transcriptPath(pane, session: session),
                     quiet: proof.lifecycle == "quiet", fenceBlocker: blocker, proof: proof)
    }

    /// The verified binding's transcript, only when it names the same session.
    private func transcriptPath(_ pane: PaneModel, session: String) async -> String? {
        let profile = pane.profile
        let paneID = pane.id.uuidString.lowercased()
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: ["agent-binding", paneID])
        guard let result = try? await RelayHostExecution.capture(profile: profile, command: command, timeout: 10, maximumBytes: 65_536),
              result.exitCode == 0,
              let binding = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              binding["version"] as? Int == 1, (binding["producer"] as? [String: Any])?["pane_id"] as? String == paneID,
              binding["session_id"] as? String == session, let path = binding["transcript_path"] as? String,
              path.hasPrefix("/") else { return nil }
        return path
    }

    func tail(_ profile: ConnectionProfile, path: String, maxBytes: Int) async -> (text: String, partial: Bool)? {
        guard let tail = try? await RelayHostFiles.text(path: path, profile: profile, maxBytes: maxBytes) else { return nil }
        return (tail.text, tail.partial)
    }

    func liveBlocker(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
                     observation: RelayContextRotationObservation, inputRevision: UInt64) -> String? {
        guard let proof = observation.proof else { return "Native identity is unavailable" }
        return pane.runtime.contextRotationSendBlocker(text, kind: kind, proof: proof, inputRevision: inputRevision)
    }

    func send(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
              observation: RelayContextRotationObservation, inputRevision: UInt64) -> Bool {
        guard let proof = observation.proof else { return false }
        return pane.runtime.sendContextRotationInput(text, kind: kind, proof: proof, inputRevision: inputRevision)
    }

    /// The chitta CLI on the pane's own host, through the same node channel as the
    /// transcript reads (a dandy-07 pane uses dandy-07's chitta). Arguments go on stdin.
    func ledger(_ profile: ConnectionProfile, op: String, args: [String: Any]) async -> RelayRotationLedgerReply {
        guard let command = RelayRotationLedgerPolicy.command(op: op),
              let input = RelayRotationJSON.canonical(args) else { return .ambiguous("operation not allowed") }
        do {
            let result = try await RelayHostExecution.capture(profile: profile, command: command, input: input,
                                                              timeout: 20, maximumBytes: 1 << 20)
            return RelayRotationLedgerReply.classify(stdout: result.stdout, exitCode: result.exitCode)
        } catch {
            return .ambiguous("host execution: \(error.localizedDescription)")
        }
    }
}

// MARK: - Chitta ledger path (r2)

extension RelayContextRotation {
    /// The reducer event for a failed ledger reply. A vanished chitta mid-transition is
    /// ambiguous, never a reason to fall back to the file path.
    static func failure(_ reply: RelayRotationLedgerReply) -> (RelayContextRotationMachine.Event, String) {
        switch reply.kind {
        case .value: return (.ledgerAmbiguous, "unexpected reply")
        case .refused(let code) where code == "stale_token" || code == "claim_expired": return (.staleToken, code)
        case .refused(let code): return (.ledgerRefused, code)
        case .missing: return (.ledgerAmbiguous, "chitta is no longer available")
        case .ambiguous(let why): return (.ledgerAmbiguous, why)
        }
    }

    private func fail(_ record: RelayContextRotationRecord, _ op: String, _ reply: RelayRotationLedgerReply) {
        let (event, why) = Self.failure(reply)
        _ = save(record, event, reason: "Chitta \(op): \(why)") { $0.ledger?.note = "\(op): \(why)" }
    }

    private func status(_ record: RelayContextRotationRecord, _ profile: ConnectionProfile) async -> [String: Any]? {
        guard let ledger = record.ledger else { return nil }
        let reply = await environment.ledger(profile, op: "rotation_status",
                                             args: ["session_id": record.sourceSession, "epoch": ledger.epoch])
        guard reply.kind == .value, let v = reply.value, v["session_id"] as? String == record.sourceSession,
              v["epoch"] as? String == ledger.epoch else { return nil }
        return v
    }

    /// Ledger-only states. True when the state was handled here.
    func advanceLedger(_ current: inout RelayContextRotationRecord, pane: PaneModel, workspace: WorkspaceModel,
                       observation: RelayContextRotationObservation, revision: UInt64, settled: Bool) async -> Bool {
        guard let ledger = current.ledger else { return false }
        let profile = pane.profile
        let source = current.sourceSession
        let same = { workspace.panes[pane.id] === pane && pane.agentInputRevision == revision }
        switch current.state {
        case .armed:
            var usage: [String: Any] = ["context_tokens": current.measuredTokens]
            usage["context_window"] = current.window.map { $0 as Any } ?? NSNull()
            let reply = await environment.ledger(profile, op: "rotation_signal", args: [
                "session_id": source, "epoch": ledger.epoch, "action": "rotate",
                "reason": "context \(current.measuredTokens) >= budget", "usage": usage])
            pause(8)
            // The outcome is recorded even if the pane changed; the next tick sees the human input.
            if reply.kind == .value, let v = reply.value, let seq = RelayRotationJSON.int(v["seq"]), seq > 0,
               v["session_id"] as? String == source, v["epoch"] as? String == ledger.epoch, v["action"] as? String == "rotate" {
                _ = save(current, .ledgerOK) { $0.ledger?.signalSeq = seq }
            } else {
                fail(current, "rotation_signal", reply)
            }
        case .capsuleRequested:
            guard settled, let signalSeq = ledger.signalSeq else { return true }
            guard let st = await status(current, profile) else {
                statuses[pane.id] = "Waiting for Chitta's rotation status"
                return true
            }
            pause(9)
            guard same() else { return true }
            guard let turn = RelayRotationJSON.int(st["turn_seq"]), turn > signalSeq else {
                statuses[pane.id] = "Waiting for Chitta to record the completed capsule turn"
                return true
            }
            let reply = await environment.ledger(profile, op: "rotation_claim", args: [
                "session_id": source, "epoch": ledger.epoch, "claimant": ledger.claimant,
                "lease_ms": RelayRotationLedgerPolicy.leaseMilliseconds, "expected_seq": turn])
            pause(10)
            if reply.kind == .value, let v = reply.value, let id = v["claim_id"] as? String, !id.isEmpty,
               let token = RelayRotationJSON.int(v["token"]), token > 0, v["claimant"] as? String == ledger.claimant,
               RelayRotationJSON.int(v["expected_seq"]) == turn, v["closed"] as? Bool == false {
                _ = save(current, .ledgerOK) {
                    $0.ledger?.claimID = id
                    $0.ledger?.token = token
                    $0.ledger?.claimedSeq = turn
                }
            } else {
                fail(current, "rotation_claim", reply)
                // An ambiguous claim may be live: look it up exactly and release it if it is Relay's.
                if case .ambiguous = reply.kind, let st = await status(current, profile),
                   let claim = st["claim"] as? [String: Any], claim["claimant"] as? String == ledger.claimant,
                   claim["closed"] as? Bool == false, let id = claim["claim_id"] as? String,
                   let token = RelayRotationJSON.int(claim["token"]) {
                    if let stopped = journal.records[current.transition] {
                        var adopted = stopped
                        adopted.ledger?.claimID = id
                        adopted.ledger?.token = token
                        if journal.put(adopted) { pendingRelease.insert(adopted.transition) }
                    }
                }
            }
        case .claimed:
            guard let claimID = ledger.claimID, let token = ledger.token, let seq = ledger.claimedSeq else { return true }
            guard let file = await environment.tail(profile, path: RelayRollCapsule.path(current.transition),
                                                    maxBytes: RelayRollCapsule.maximumFileBytes + 1) else {
                statuses[pane.id] = "Waiting for the agent's capsule file"
                return true
            }
            pause(11)
            guard same() else { return true }
            guard !file.partial else {
                _ = save(current, .capsuleBad, reason: "The capsule exceeds \(RelayRollCapsule.maximumFileBytes) bytes")
                return true
            }
            let parsed: RelayRollCapsule.Parsed
            switch RelayRollCapsule.validate(Data(file.text.utf8), nonce: current.nonce) {
            case .success(let p): parsed = p
            case .failure(let refusal):
                _ = save(current, .capsuleBad, reason: "The capsule is not usable (\(refusal))")
                return true
            }
            guard let dir = parsed.capsule["project_dir"] as? String else { return true }
            // The revision capsule_save fences on is the latest for the capsule key, read here.
            let before = await environment.ledger(profile, op: "capsule_get", args: ["session_id": source, "project_dir": dir])
            guard before.kind == .value, let pre = before.value else {
                fail(current, "capsule_get", before)
                return true
            }
            let expected = RelayRotationJSON.int((pre["capsule"] as? [String: Any])?["revision"]) ?? 0
            let input = RelayRollCapsule.input(parsed, sessionID: source, ledgerSeq: seq)
            let saved = await environment.ledger(profile, op: "capsule_save", args: [
                "epoch": ledger.epoch, "claim_id": claimID, "token": token, "expected_revision": expected, "capsule": input])
            pause(12)
            guard saved.kind == .value, let cap = saved.value else {
                fail(current, "capsule_save", saved)
                return true
            }
            let rev = expected + 1
            guard RelayRotationJSON.int(cap["revision"]) == rev, RelayRollCapsule.matches(cap, sent: input) else {
                _ = save(current, .capsuleBad, reason: "Chitta's saved capsule differs from the one Relay sent")
                return true
            }
            // The fence the ack will check: this epoch's capsule carries Relay's token and watermark.
            guard let st = await status(current, profile), let fenced = st["capsule"] as? [String: Any],
                  RelayRotationJSON.int(fenced["revision"]) == rev, RelayRotationJSON.int(fenced["token"]) == token,
                  RelayRotationJSON.int(fenced["ledger_seq"]) == seq else {
                _ = save(current, .capsuleBad, reason: "Chitta's rotation status does not show the fenced capsule")
                return true
            }
            var key: [String: Any] = ["session_id": source, "project_dir": dir]
            for field in ["repository", "stream_id", "code_head"] { key[field] = cap[field] }
            let got = await environment.ledger(profile, op: "capsule_get", args: key)
            pause(13)
            guard got.kind == .value, let g = got.value, g["status"] as? String == "ok", let back = g["capsule"] as? [String: Any],
                  RelayRotationJSON.int(back["revision"]) == rev, RelayRollCapsule.matches(back, sent: input) else {
                _ = save(current, .capsuleBad, reason: "Chitta's read-back is not the capsule Relay saved")
                return true
            }
            var fields: [String: Any] = [:]
            for key in parsed.capsule.keys { fields[key] = back[key] }
            let snapshot = RelayRollCapsule.Snapshot(transition: current.transition.uuidString.lowercased(), revision: rev,
                                                       sessionID: source, ledgerSeq: seq, fields: fields, rules: parsed.rules)
            guard let data = RelayRollCapsule.encode(snapshot), let text = String(data: data, encoding: .utf8),
                  let restore = RelayRollCapsule.restore(transition: current.transition, snapshot: data),
                  RelayStockRotationPolicy.admits(restore, kind: .restore), !restore.contains(current.nonce) else {
                // Checked before the clear, so an unrenderable capsule never strands a cleared agent.
                _ = save(current, .capsuleBad, reason: "The capsule cannot be rendered as an admissible restore prompt")
                return true
            }
            _ = save(current, .capsuleOK) {
                $0.ledger?.capsuleRevision = rev
                $0.ledger?.snapshot = text
                $0.ledger?.snapshotSHA256 = RelayRotationJSON.sha256(data)
                $0.capsuleSHA256 = RelayRotationJSON.sha256(data)
            }
        case .capsuleVerified:
            guard let claimID = ledger.claimID, let token = ledger.token else { return true }
            // The intent ID is journaled before the ledger hears it.
            if ledger.intentID == nil {
                var next = current
                next.ledger?.intentID = UUID().uuidString.lowercased()
                guard journal.put(next) else {
                    statuses[pane.id] = "Rotation record could not be saved; nothing more is typed"
                    return true
                }
                current = next
            }
            guard let intent = current.ledger?.intentID else { return true }
            let reply = await environment.ledger(profile, op: "rotation_intent", args: [
                "session_id": source, "epoch": ledger.epoch, "claim_id": claimID, "token": token, "intent_id": intent])
            pause(14)
            if reply.kind == .value, let v = reply.value, v["intent_id"] as? String == intent, v["state"] as? String == "ambiguous",
               RelayRotationJSON.int(v["token"]) == token {
                _ = save(current, .ledgerOK)
            } else {
                fail(current, "rotation_intent", reply)
            }
        case .clearSeen:
            guard let claimID = ledger.claimID, let token = ledger.token, let intent = ledger.intentID,
                  let new = current.newSession else { return true }
            let reply = await environment.ledger(profile, op: "rotation_bind", args: [
                "session_id": source, "epoch": ledger.epoch, "claim_id": claimID, "token": token, "intent_id": intent,
                "new_session_id": new])
            pause(15)
            let bound = { (v: [String: Any]?) -> Bool in
                v?["intent_id"] as? String == intent && v?["state"] as? String == "bound" && v?["new_session_id"] as? String == new
            }
            if reply.kind == .value, bound(reply.value) {
                _ = save(current, .ledgerOK)
            } else if let st = await status(current, profile), bound(st["intent"] as? [String: Any]) {
                // Exact lookup, never a blind resend.
                _ = save(current, .ledgerOK) { $0.ledger?.note = "rotation_bind reconciled by rotation_status" }
            } else {
                fail(current, "rotation_bind", reply)
            }
        case .acknowledging:
            guard let claimID = ledger.claimID, let token = ledger.token, let intent = ledger.intentID,
                  let rev = ledger.capsuleRevision, let new = current.newSession else { return true }
            let reply = await environment.ledger(profile, op: "rotation_ack", args: [
                "session_id": source, "epoch": ledger.epoch, "claim_id": claimID, "token": token, "intent_id": intent,
                "capsule_revision": rev, "new_session_id": new])
            pause(16)
            let acked = { (v: [String: Any]?) -> Bool in
                v?["new_session_id"] as? String == new && RelayRotationJSON.int(v?["capsule_revision"]) == rev &&
                    v?["intent_id"] as? String == intent && v?["lifecycle_performed"] as? Bool == true
            }
            if reply.kind == .value, acked(reply.value) {
                _ = save(current, .ledgerOK)
            } else if let st = await status(current, profile), acked(st["ack"] as? [String: Any]) {
                _ = save(current, .ledgerOK) { $0.ledger?.note = "rotation_ack reconciled by rotation_status" }
            } else {
                fail(current, "rotation_ack", reply)
            }
        default:
            return false
        }
        return true
    }

    /// Best effort, once: abandon an unbound intent, then close the claim. The lease expires regardless.
    func release(_ record: RelayContextRotationRecord, profile: ConnectionProfile) async {
        guard record.state == .aborted, let ledger = record.ledger, let claimID = ledger.claimID,
              let token = ledger.token else { return }
        let base: [String: Any] = ["session_id": record.sourceSession, "epoch": ledger.epoch, "claim_id": claimID, "token": token]
        var notes: [String] = []
        if let intent = ledger.intentID {
            var args = base
            args["intent_id"] = intent
            let reply = await environment.ledger(profile, op: "rotation_abandon_intent", args: args)
            notes.append("abandon_intent " + (reply.kind == .value ? "ok" : Self.failure(reply).1))
            // Known limit (r3, documented, not reconciled): Chitta keeps an intent that could not be
            // abandoned as unresolved, and arming refuses this session until it is reconciled by hand.
            if reply.kind != .value {
                statuses[record.paneID] = "Context rotation stopped; Chitta still holds its unbound intent " + intent +
                    ", so this session is not rotated again until that intent is reconciled"
            }
        }
        let reply = await environment.ledger(profile, op: "rotation_release", args: base)
        notes.append("release " + (reply.kind == .value ? "ok" : Self.failure(reply).1))
        guard var latest = journal.records[record.transition] else { return }
        latest.ledger?.note = notes.joined(separator: "; ")
        _ = journal.put(latest)
    }
}
