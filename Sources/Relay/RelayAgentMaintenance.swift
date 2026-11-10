import CryptoKit
import Foundation
import SwiftUI

/// Maintenance uses native identity and terminal leases. The intelligence layer
/// can explain a deferral; its text can never supply a command or restart fence.
struct RelayAgentMaintenanceProbe: Decodable, Equatable, Sendable {
    let version: Int
    var paneID: String? = nil
    var provider: String? = nil
    var processID: Int? = nil
    var processStart: UInt64? = nil
    var sessionID: String? = nil
    var bound: Bool? = nil
    var lifecycle: String? = nil
    var revision: String? = nil
    var owner: RelayPromptOwnerBinding? = nil
    var installedUpdate: Bool? = nil
    var installedImageCurrent: Bool? = nil
    var runningVersion: String? = nil
    var installedVersion: String? = nil
    var outdatedOtherInstall: Bool? = nil
    var backgroundWork: Bool? = nil
    /// Claude: false only when every in-process subagent of the session has a
    /// terminal lifecycle record in the main transcript (or there are none);
    /// nil when relayd could not tell.
    var subagentWork: Bool? = nil
    /// Claude's own status for the bound process from its sessions/<pid>.json,
    /// matched by pid and process start ("idle", "shell", …); nil when absent.
    var harnessStatus: String? = nil
    /// The user's live Claude background agent jobs (kind "bg" session
    /// records) on the host that are not the bound process or below it.
    var backgroundAgentJobs: Int? = nil
    var resumeCommand: String? = nil
    var resumeError: String? = nil
    /// The running agent's provider account directory: "" for the provider
    /// default, "~/name" below the host home, else absolute.
    var configDir: String? = nil
    /// relayd's resolved real-path comparison of the running account with the
    /// pane's recorded one (nil when none was asked for).
    var accountMatches: Bool? = nil
    /// A user-requested account move: the same resume in the target account,
    /// or why the target cannot resume this conversation.
    var moveCommand: String? = nil
    var moveError: String? = nil
    var unavailable: String? = nil
    var worker: RelayPaneWorkerObservation? = nil
    var context: RelayPaneContextObservation? = nil

    enum CodingKeys: String, CodingKey {
        case version, provider, bound, lifecycle, revision, owner, unavailable
        case paneID = "paneId", processID = "processId", processStart, sessionID = "sessionId"
        case installedUpdate, installedImageCurrent, runningVersion, installedVersion, outdatedOtherInstall
        case backgroundWork, subagentWork, harnessStatus, backgroundAgentJobs, resumeCommand, resumeError, worker, context, configDir, accountMatches, moveCommand, moveError
    }

    /// Native image versions on the pane's host; nil when either is unverified.
    var versionTransition: String? {
        guard let runningVersion, let installedVersion, runningVersion != installedVersion else { return nil }
        return runningVersion + " → " + installedVersion
    }

    func valid(for paneID: UUID) -> Bool {
        version == 1 && self.paneID == paneID.uuidString.lowercased() &&
        ["claude", "codex"].contains(provider ?? "") &&
        (processID ?? 0) > 1 && (processStart ?? 0) > 0 &&
        sessionID?.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil &&
        revision?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil &&
        owner?.isValid(for: paneID) == true && owner?.provider == provider &&
        owner?.processId == processID && owner?.processStart == processStart
    }

    func sameSource(as other: Self) -> Bool {
        paneID == other.paneID && provider == other.provider && processID == other.processID &&
        processStart == other.processStart && sessionID == other.sessionID && owner == other.owner &&
        revision == other.revision && resumeCommand == other.resumeCommand && backgroundWork == other.backgroundWork &&
        subagentWork == other.subagentWork && harnessStatus == other.harnessStatus &&
        backgroundAgentJobs == other.backgroundAgentJobs
    }

    /// A retained shell has no agent conversation or restart authority.
    func validShell(for paneID: UUID) -> Bool {
        version == 1 && self.paneID == paneID.uuidString.lowercased() && provider == "shell" &&
        owner?.isValid(for: paneID) == true && owner?.provider == "shell" &&
        owner?.processId == processID && owner?.processStart == processStart &&
        sessionID == nil && bound == nil && installedUpdate != true
    }
}

enum RelayAgentMaintenancePolicy {
    enum Reason: String, Codable, Sendable { case binding, update }
    struct ModelGrant: Equatable, Sendable {
        let operationID: String
        let toolID: String
        let action: String
        let evidenceID: String
        let expires: Date
    }

    static func modelRequestIsCurrent(_ grant: ModelGrant?, reason: Reason,
        evidenceID: String, now: Date = Date()) -> Bool {
        // Native maintenance is authorized by its explicit operator setting.
        // Only actions requested by the model need a model-grant comparison.
        guard let grant else { return true }
        let action = reason == .binding ? "repair_agent_link" : "apply_installed_update"
        return grant.expires > now && grant.action == action && grant.evidenceID == evidenceID
    }

    static func updateBanner(_ text: String) -> Bool {
        // A quoted transcript or available-download notice does not suffice.
        let footer = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(14)
        return footer.contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.contains("Update installed") && value.contains("/restart to apply") &&
                !value.hasPrefix("❯") && !value.hasPrefix(">") && !value.contains("\"")
        }
    }

    static func reason(_ proof: RelayAgentMaintenanceProbe, updateBanner: Bool) -> Reason? {
        if proof.bound == false { return .binding }
        if proof.installedUpdate == true { return .update }
        return nil
    }

    /// The one update postcondition shared by completion, recovery and the
    /// journal: native image identity. Unknown (nil) is never success.
    static func installedImageVerified(_ proof: RelayAgentMaintenanceProbe) -> Bool {
        proof.installedImageCurrent == true
    }

    static func updateApplied(before: RelayAgentMaintenanceProbe, after: RelayAgentMaintenanceProbe) -> Bool {
        installedImageVerified(after)
    }

    static func exitCommand(provider: String?) -> String? {
        switch provider {
        case "claude": return "/exit"
        case "codex": return "/quit"
        default: return nil
        }
    }

    /// How many "← N agent" footer agents relayd's evidence accounts for. Zero
    /// (any footer agent holds) unless every one of these is verified: the
    /// session's in-process subagents all finished by the main transcript's
    /// lifecycle records, relayd's live event state shows no active subagent,
    /// and Claude's own sessions/<pid>.json reports the bound process idle.
    /// Then the footer may show up to the host's live background agent jobs,
    /// which Claude counts for every pane but which this pane does not own.
    ///
    /// When relayd also finds no child agent or shell under the bound process
    /// (`backgroundWork == false`), the pane has no agent work of its own, and
    /// the "← N agent(s)" agents-view nudge, which counts only other sessions
    /// waiting for input, is explained whatever its number.
    static func explainedFooterAgents(_ proof: RelayAgentMaintenanceProbe, activeSubagents: Int) -> Int {
        guard proof.provider == "claude", proof.subagentWork == false, activeSubagents == 0,
              proof.harnessStatus == "idle" else { return 0 }
        if proof.backgroundWork == false { return RelayAgentMaintenancePrompt.waitingSessionsExplained }
        guard let jobs = proof.backgroundAgentJobs, jobs > 0 else { return 0 }
        return jobs
    }

    static func idleEvidence(_ proof: RelayAgentMaintenanceProbe, emptyPrompt: Bool, hasDraft: Bool) -> Bool {
        let harnessIdle = proof.provider == "claude" && proof.harnessStatus == "idle" &&
            proof.backgroundWork == false && proof.subagentWork == false && emptyPrompt && !hasDraft
        let harnessBusy = proof.provider == "claude" && proof.harnessStatus != nil && proof.harnessStatus != "idle"
        return !harnessBusy && (proof.lifecycle == "quiet" || harnessIdle)
    }

    static func deferral(_ proof: RelayAgentMaintenanceProbe, paneID: UUID,
        emptyPrompt: Bool, hasDraft: Bool, pendingApprovals: Int, inputAge: TimeInterval,
        preservingDraft: Bool = false, recordedAccount: RelayAgentAccount? = nil,
        promptBlocker: String? = nil) -> String? {
        guard proof.valid(for: paneID) else { return proof.unavailable ?? "Native identity is unavailable" }
        // The account is part of the agent's identity. A restart would resume
        // in the running agent's own account, so a difference from the
        // account the pane was started in is reported and never acted on.
        if let recordedAccount, recordedAccount.provider == proof.provider, let observed = proof.configDir,
           !(proof.accountMatches ?? recordedAccount.matches(observedDirectory: observed)) {
            let reason = recordedAccount.explicitClaudeDefault(observedDirectory: observed)
                ? " (explicit ~/.claude uses a different .claude.json)" : ""
            return "Held: the running agent uses a different \(recordedAccount.provider) account than this pane's " +
                "\(recordedAccount.label) account\(reason); Relay will not restart or switch it"
        }
        guard pendingApprovals == 0 else { return "Waiting for the pending approval" }
        guard preservingDraft || !hasDraft else { return "Waiting for the unsent prompt to be cleared or sent" }
        if proof.backgroundWork == true {
            return "Waiting for the agent's background shells or agent processes to finish"
        }
        if proof.provider == "claude" && proof.backgroundWork == nil {
            return "Waiting for background work to be verified absent: the native process check is unavailable"
        }
        // Lifecycle evidence of a running subagent holds on its own, whatever
        // the screen shows: a footer can be stale, clipped or absent.
        if proof.provider == "claude" && proof.subagentWork == true {
            return "Waiting for the session's subagents to finish: Claude's lifecycle records show one still running"
        }
        guard preservingDraft || emptyPrompt else {
            return "Waiting for the original prompt to be confirmed empty" + (promptBlocker.map { ": " + $0 } ?? "")
        }
        // A current, process-start-matched Claude harness observation can
        // supersede a transcript's cached active phase (for example after
        // "Claude session ended"). CPU usage and summary text are not proof.
        // An explicitly busy harness overrides even a quiet transcript.
        guard idleEvidence(proof, emptyPrompt: emptyPrompt, hasDraft: hasDraft) else {
            return proof.lifecycle == "settling" ? "Waiting for the conversation transcript to stop changing"
                : "Waiting for the current turn to finish"
        }
        guard inputAge >= 15 else { return "Waiting until you finish typing" }
        if proof.resumeCommand == nil {
            return proof.resumeError ?? "The exact agent resume command is unavailable"
        }
        return nil
    }
}

@MainActor enum RelayAgentMaintenanceReader {
    /// The pane's recorded account is compared by relayd as resolved real
    /// paths; `targetAccount` asks for a move command into that account.
    /// relayd kills the host check after this many seconds.
    nonisolated static let timeout: TimeInterval = 25

    /// The host check exited unsuccessfully. relayd reports a check it killed
    /// at the timeout as exit status -1. Only the first stderr line is kept,
    /// bounded, with assignments and long tokens redacted.
    struct InspectFailure: LocalizedError, Equatable, Sendable {
        let exitCode: Int
        let detail: String

        init(exitCode: Int, stderr: Data) {
            self.exitCode = exitCode
            let line = String(decoding: stderr.prefix(4096), as: UTF8.self)
                .split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            detail = String(Self.redacted(line).prefix(160))
        }

        var timedOut: Bool { exitCode == -1 }

        var errorDescription: String? {
            (timedOut ? "the host check was stopped after \(Int(RelayAgentMaintenanceReader.timeout)) s (timed out or killed)"
                : "the host check exited with status \(exitCode)") + (detail.isEmpty ? "" : ": " + detail)
        }

        /// `NAME=value` keeps only the name; any 24+ character token is dropped.
        static func redacted(_ line: String) -> String {
            line.replacingOccurrences(of: #"([A-Za-z_][A-Za-z0-9_]*)=\S+"#, with: "$1=…", options: .regularExpression)
                .replacingOccurrences(of: #"[A-Za-z0-9+/_.~-]{24,}"#, with: "…", options: .regularExpression)
        }
    }

    static func inspect(_ pane: PaneModel, targetAccount: RelayAgentAccount? = nil,
                        expectAccount: RelayAgentAccount? = nil) async throws -> RelayAgentMaintenanceProbe {
        let profile = pane.profile
        let command = try maintenanceCommand(profile: profile, paneID: pane.id,
            expectedAccount: expectAccount ?? pane.agentAccount?.recorded, targetAccount: targetAccount)
        let result = try await RelayHostExecution.capture(profile: profile, command: command,
            timeout: Int(timeout), maximumBytes: 32 << 10)
        guard pane.profile == profile else { throw RemoteCatalogError.invalidResponse }
        guard result.exitCode == 0 else { throw InspectFailure(exitCode: result.exitCode, stderr: result.stderr) }
        // The owner decoder uses the established snake-case wire conversion.
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: result.stdout)
        if expectAccount == nil, proof.valid(for: pane.id), let provider = proof.provider, let directory = proof.configDir {
            let matches = pane.agentAccount?.recorded?.provider == provider ? proof.accountMatches : nil
            pane.observeAgentAccount(provider: provider, directory: directory,
                label: matches == true ? pane.agentAccount?.recorded?.label
                    : RelayAgentAccountDirectory.shared.label(for: profile, provider: provider, observedDirectory: directory),
                matches: matches)
        }
        return proof
    }

    nonisolated static func maintenanceCommand(profile: ConnectionProfile, paneID: UUID,
        expectedAccount: RelayAgentAccount?, targetAccount: RelayAgentAccount?) throws -> String {
        var arguments = ["agent-maintenance", "--pane", paneID.uuidString.lowercased()]
        // Validated account directories contain no quote or shell character.
        let expected = expectedAccount
        if let expected, expected.isValid {
            arguments += ["--expect-account", expected.dir]
        }
        if let targetAccount {
            guard targetAccount.isValid else { throw RemoteCatalogError.invalidResponse }
            arguments += ["--target-account", targetAccount.dir]
        }
        return RelayHostExecution.daemonCommand(profile: profile, arguments: arguments)
    }

}

/// The journal is written before input. Unknown or partially completed actions
/// survive a GUI restart and cannot be automatically replayed.
@MainActor final class RelayAgentMaintenanceJournal {
    struct Entry: Codable, Sendable {
        let id: String
        let paneID: UUID
        let host: String
        let reason: RelayAgentMaintenancePolicy.Reason
        let sessionID: String
        let createdAt: Date
        var state: String
        let modelOperationID: String?
        let modelToolID: String?
        let resumeCommand: String?
        let originalOwner: RelayPromptOwnerBinding?
        let originalProcessID: Int?
        let originalProcessStart: UInt64?
        var draftDigest: String? = nil
        var draftRestored: Bool? = nil
    }
    let url: URL
    private(set) var entries: [String: Entry] = [:]
    private(set) var loadFailed = false

    init(url: URL = RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/agent-maintenance/journal.json")) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 512 << 10 else { throw RemoteCatalogError.invalidResponse }
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                entries = try decoder.decode([String: Entry].self, from: data)
            }
        } catch { loadFailed = true }
    }

    func claim(pane: UUID, host: String, proof: RelayAgentMaintenanceProbe,
        reason: RelayAgentMaintenancePolicy.Reason, modelOperationID: String? = nil,
        modelToolID: String? = nil) throws -> String? {
        guard !loadFailed, entries.count < 1024, let session = proof.sessionID else {
            throw RemoteCatalogError.failed("Maintenance journal needs attention")
        }
        guard !entries.values.contains(where: {
            $0.paneID == pane && $0.host == host &&
            (!Self.settledStates.contains($0.state) ||
             Date().timeIntervalSince($0.createdAt) < 1800)
        }) else { return nil }
        let source = [host, pane.uuidString, String(proof.processID ?? 0), String(proof.processStart ?? 0),
                      reason.rawValue, proof.revision ?? ""]
            .joined(separator: ":")
        let id = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard entries[id] == nil else { return nil }
        entries[id] = Entry(id: id, paneID: pane, host: host, reason: reason,
            sessionID: session, createdAt: Date(), state: "input_pending",
            modelOperationID: modelOperationID, modelToolID: modelToolID,
            resumeCommand: proof.resumeCommand, originalOwner: proof.owner,
            originalProcessID: proof.processID, originalProcessStart: proof.processStart)
        try save()
        return id
    }

    func mark(_ id: String, _ state: String) throws {
        guard entries[id] != nil else { throw RemoteCatalogError.invalidResponse }
        entries[id]?.state = state
        try save()
    }

    func savedDraft(_ id: String, digest: String) throws {
        guard entries[id] != nil else { throw RemoteCatalogError.invalidResponse }
        entries[id]?.draftDigest = digest; entries[id]?.draftRestored = false
        entries[id]?.state = "draft_saved"
        try save()
    }

    func restoredDraft(_ id: String) throws {
        guard entries[id]?.draftDigest != nil else { throw RemoteCatalogError.invalidResponse }
        entries[id]?.draftRestored = true
        try save()
    }

    /// A saved draft whose text is already in the prompt of the same agent
    /// process (same start time and conversation) was never lost: the restart
    /// did not happen. The record is settled as restored without a restart.
    func settleDraftAlreadyInPrompt(_ id: String, proof: RelayAgentMaintenanceProbe, prompt: Data) throws -> Bool {
        guard !loadFailed, let entry = entries[id], let digest = entry.draftDigest, entry.draftRestored != true,
              entry.state == "draft_saved", entry.sessionID == proof.sessionID,
              let process = proof.processID, let start = proof.processStart,
              entry.originalProcessID == process, entry.originalProcessStart == start,
              RelayPromptEditorRPC.digest(prompt) == digest else { return false }
        entries[id]?.draftRestored = true
        entries[id]?.state = "draft_restored_without_restart"
        try save()
        return true
    }

    /// States that no longer hold a new action once their cooldown has passed.
    static let settledStates: Set<String> = ["verified", "draft_restored_without_restart", "draft_restore_held",
                                             "restart_not_admitted"]

    /// A restart whose admission outcome was unknown did not happen when the
    /// same process, with the same start time and conversation, is still the
    /// pane's agent. Nothing is resent; the record only stops holding the pane.
    func resolveUnadmittedRestarts(pane: UUID, host: String, proof: RelayAgentMaintenanceProbe) throws -> Bool {
        guard !loadFailed, proof.valid(for: pane), proof.bound == true, let session = proof.sessionID,
              let process = proof.processID, let start = proof.processStart else { return false }
        let ids = entries.values.filter {
            $0.paneID == pane && $0.host == host && $0.sessionID == session &&
            $0.state == "restart_admission_unknown" &&
            $0.originalProcessID == process && $0.originalProcessStart == start
        }.map(\.id)
        guard !ids.isEmpty else { return false }
        for id in ids { entries[id]?.state = "restart_not_admitted" }
        try save()
        return true
    }

    /// Reconcile a repair from its exact binding and, for updates, the running
    /// installed image. This never resends an unknown command.
    func reconcileBinding(pane: UUID, host: String, proof: RelayAgentMaintenanceProbe) throws -> Bool {
        guard !loadFailed, proof.valid(for: pane), proof.bound == true,
              let session = proof.sessionID else { return false }
        let ids = entries.values.filter {
            $0.paneID == pane && $0.host == host && $0.sessionID == session &&
            ($0.reason == .binding || $0.reason == .update && RelayAgentMaintenancePolicy.installedImageVerified(proof)) &&
            $0.state != "verified" &&
            ($0.draftDigest == nil || $0.draftRestored == true) &&
            $0.state != "user_input_after_exit"
        }.map(\.id)
        guard !ids.isEmpty else { return false }
        for id in ids { entries[id]?.state = "verified" }
        try save()
        return true
    }

    private func save() throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A refused maintenance exit is retried only when the refusal proves nothing
/// was typed and the cause was an open output phase (a resize or reconnect).
/// Every attempt re-runs the full admission; any other refusal ends the
/// retry with today's "no automatic retry" handling.
enum RelayAgentMaintenanceRestartAdmission {
    /// 60 attempts after the first, 500 ms apart: about 30 s, the failsafe
    /// after which an open reconnect replay is closed (TerminalIOBridge).
    static let retryLimit = 60
    static let retryInterval: Duration = .milliseconds(500)

    typealias Outcome = TerminalRuntime.AgentMaintenanceSendOutcome

    /// What every retry must re-establish after its wait, before it may type.
    enum Readmission: Equatable {
        case admit(RelayAgentMaintenanceProbe)
        case hold(String)
    }

    struct Result: Equatable {
        let outcome: Outcome
        /// Set when a retry was refused at readmission; nothing was typed.
        let held: String?
    }

    /// Sends the exit once against `initial`. Only an open output phase (a
    /// resize or reconnect, nothing typed) is retried. After each sleep,
    /// `readmit` must re-establish the exact native owner, background-work
    /// evidence, grant and pane authority; the retry then sends against that
    /// refreshed evidence, never against the evidence from before the wait.
    @MainActor
    static func send(initial: RelayAgentMaintenanceProbe,
                     attempt: (RelayAgentMaintenanceProbe) -> Outcome,
                     readmit: () async throws -> Readmission,
                     sleep: () async throws -> Void,
                     limit: Int = retryLimit) async throws -> Result {
        var outcome = attempt(initial)
        var retries = 0
        while outcome == .outputPhaseOpen, retries < limit {
            retries += 1
            try await sleep()
            switch try await readmit() {
            case .hold(let reason):
                return Result(outcome: .outputPhaseOpen, held: reason)
            case .admit(let current):
                // No suspension between readmission and the attempt.
                outcome = attempt(current)
            }
        }
        return Result(outcome: outcome, held: nil)
    }

    /// The pure readmission decision, taken with no suspension before the
    /// attempt. Changed or unknown evidence holds; it never authorizes a new
    /// owner. Returns nil to admit, or the reason to hold.
    static func readmissionHold(paneID: UUID, original: RelayAgentMaintenanceProbe,
                                refreshed: RelayAgentMaintenanceProbe?,
                                paneCurrent: Bool, automaticMaintenance: Bool, inputUnchanged: Bool,
                                grantAtStart: RelayAgentMaintenancePolicy.ModelGrant?,
                                grantNow: RelayAgentMaintenancePolicy.ModelGrant?,
                                reason: RelayAgentMaintenancePolicy.Reason,
                                evidenceID: String?, now: Date) -> String? {
        guard paneCurrent else { return "the pane or its connection changed" }
        guard automaticMaintenance else { return "automatic maintenance was turned off" }
        guard inputUnchanged else { return "you entered input" }
        guard let refreshed else { return "native evidence is unavailable" }
        guard refreshed.valid(for: paneID) else { return "the exact native identity is unavailable" }
        // Same process, start, session, owner, revision and background or
        // subagent work as the evidence the exit was admitted on.
        guard refreshed.sameSource(as: original) else { return "the native owner or its background work changed" }
        guard refreshed.lifecycle == "quiet" else { return "the agent is no longer quiet" }
        guard grantNow == grantAtStart, let evidenceID,
              RelayAgentMaintenancePolicy.modelRequestIsCurrent(grantNow, reason: reason, evidenceID: evidenceID, now: now) else {
            return "the model repair grant expired or changed"
        }
        return nil
    }

    /// The readmission the maintenance call site runs after each retry wait:
    /// a fresh native inspection and prompt proof (the suspensions), then
    /// every check synchronously against the state after the last of them.
    @MainActor
    static func readmission(pane: PaneModel, paneID: UUID, original: RelayAgentMaintenanceProbe,
                            inputRevision: UInt64, reason: RelayAgentMaintenancePolicy.Reason,
                            grantAtStart: RelayAgentMaintenancePolicy.ModelGrant?,
                            paneCurrent: @escaping @MainActor () -> Bool,
                            currentGrant: @escaping @MainActor () -> RelayAgentMaintenancePolicy.ModelGrant?,
                            automaticMaintenance: @escaping @MainActor () -> Bool,
                            evidenceID: @escaping @MainActor (RelayAgentMaintenanceProbe) -> String,
                            inspect: @escaping @MainActor (PaneModel) async throws -> RelayAgentMaintenanceProbe,
                            now: @escaping () -> Date) -> @MainActor () async throws -> Readmission {
        return {
            let refreshed = try? await inspect(pane)
            await pane.runtime.prepareAgentMaintenancePromptProof()
            if let hold = readmissionHold(paneID: paneID, original: original, refreshed: refreshed,
                paneCurrent: paneCurrent(), automaticMaintenance: automaticMaintenance(),
                inputUnchanged: pane.agentInputRevision == inputRevision,
                grantAtStart: grantAtStart, grantNow: currentGrant(), reason: reason,
                evidenceID: refreshed.map(evidenceID), now: now()) {
                return .hold(hold)
            }
            return .admit(refreshed!)
        }
    }

    /// What the maintenance call site does after native admission. Every
    /// suspension (draft capture, prompt clearing, prompt proof, retry waits)
    /// is followed by `readmit` before any exit is typed, including the first.
    struct Orchestration {
        var promptIsEmpty: @MainActor () -> Bool
        var promptHasTypedText: @MainActor () -> Bool
        var promptBlocker: @MainActor () -> String?
        var provider: String?
        /// Reads the typed draft and clears it; `beforeApply` runs with the
        /// text before the clear is applied, so the backup precedes the edit.
        var captureDraft: @MainActor (_ beforeApply: (Data) throws -> Void) async throws -> Void
        /// Reads the prompt back; it must be empty after the capture.
        var readPrompt: @MainActor () async throws -> Data
        var preparePrompt: @MainActor () async -> Void
        /// Claims the journal action, or nil while one is held or cooling down.
        var claim: @MainActor () throws -> String?
        /// Saves the draft backup under the action and records its digest.
        var saveDraft: @MainActor (_ actionID: String, _ text: Data) throws -> Void
        var mark: @MainActor (_ actionID: String, _ state: String) throws -> Void
        var readmit: @MainActor () async throws -> Readmission
        /// nil when the provider has no exit command.
        var attempt: (@MainActor (RelayAgentMaintenanceProbe) -> Outcome)?
        var sleep: @MainActor () async throws -> Void
    }

    enum Decision: Equatable {
        /// The prompt is neither confirmed empty nor a readable typed draft.
        case promptUnconfirmed(String)
        case noDraftContract
        /// A recent action is recorded; nothing claimed, nothing typed.
        case cooling
        /// Authority or native evidence changed after a suspension; nothing
        /// was typed. A captured draft stays saved for the restore flow.
        case held(actionID: String, reason: String)
        /// The pane kept resizing or reconnecting through every retry.
        case busy(actionID: String)
        /// The write was refused or its outcome is unknown; never retried.
        case unknown(actionID: String)
        case submitted(actionID: String, probe: RelayAgentMaintenanceProbe)
    }

    @MainActor
    static func orchestrate(_ o: Orchestration, limit: Int = retryLimit) async throws -> Decision {
        var capturedID: String?
        if !o.promptIsEmpty() {
            // Capture only a draft that is actually visible. An unreadable or
            // unrecognized prompt is held with its reason, never guessed at.
            guard o.promptHasTypedText() else {
                return .promptUnconfirmed(o.promptBlocker() ?? "no typed text was seen")
            }
            guard o.provider == "claude" else { return .noDraftContract }
            try await o.captureDraft { text in
                guard let id = try o.claim() else { throw RelayPromptEditorRPC.Failure.changedConnection }
                capturedID = id
                try o.saveDraft(id, text)
            }
            guard try await o.readPrompt().isEmpty else { throw RelayPromptEditorRPC.Failure.invalidResponse }
            await o.preparePrompt()
        }
        guard let id = try capturedID ?? o.claim() else { return .cooling }
        guard let attempt = o.attempt else {
            try o.mark(id, "restart_admission_unknown")
            return .unknown(actionID: id)
        }
        // The first exit passes the same fresh native and authority boundary
        // as every retry: preference, grant, input, owner and quiet state are
        // read after the last suspension above, not before it.
        let first: RelayAgentMaintenanceProbe
        switch try await o.readmit() {
        case .hold(let reason):
            try o.mark(id, "restart_held_changed")
            return .held(actionID: id, reason: reason)
        case .admit(let current):
            first = current
        }
        var admitted = first
        let result = try await send(initial: first,
            attempt: { probe in admitted = probe; return attempt(probe) },
            readmit: o.readmit, sleep: o.sleep, limit: limit)
        if let reason = result.held {
            try o.mark(id, "restart_held_changed")
            return .held(actionID: id, reason: reason)
        }
        switch result.outcome {
        case .outputPhaseOpen:
            try o.mark(id, "restart_held_busy")
            return .busy(actionID: id)
        case .refused:
            try o.mark(id, "restart_admission_unknown")
            return .unknown(actionID: id)
        case .sent:
            try o.mark(id, "restart_submitted")
            return .submitted(actionID: id, probe: admitted)
        }
    }

    /// The draft backup the call site saves before the prompt is cleared.
    @MainActor
    static func saveCapturedDraft(actionID: String, text: Data, paneID: UUID, host: String,
                                  proof: RelayAgentMaintenanceProbe,
                                  drafts: RelayAgentMaintenanceDraftStore,
                                  journal: RelayAgentMaintenanceJournal) throws {
        guard let owner = proof.owner, let session = proof.sessionID else {
            throw RelayPromptEditorRPC.Failure.changedConnection
        }
        let saved = try RelayAgentMaintenanceDraft(actionID: actionID, paneID: paneID, host: host,
            sessionID: session, originalOwner: owner, text: text)
        try drafts.save(saved)
        try journal.savedDraft(actionID, digest: saved.digest)
    }

    /// The saved draft that the same-conversation restore flow must put back
    /// before any new maintenance action on this pane.
    @MainActor
    static func pendingDraftRestore(_ journal: RelayAgentMaintenanceJournal, paneID: UUID, host: String,
                                    sessionID: String?) -> RelayAgentMaintenanceJournal.Entry? {
        journal.entries.values.first(where: {
            $0.paneID == paneID && $0.host == host && $0.sessionID == sessionID &&
            $0.draftDigest != nil && $0.draftRestored != true && $0.state != "draft_restore_held"
        })
    }
}

@MainActor final class RelayAgentMaintenance: ObservableObject {
    static let shared = RelayAgentMaintenance()
    @Published private(set) var statuses: [UUID: String] = [:]
    private let journal = RelayAgentMaintenanceJournal()
    private let drafts = RelayAgentMaintenanceDraftStore()
    private var lastChecked: [UUID: Date] = [:]
    private var requested: Set<UUID> = []
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private struct Pending {
        enum Stage { case shell, verify }
        let id: String
        let proof: RelayAgentMaintenanceProbe
        let profile: ConnectionProfile
        let reason: RelayAgentMaintenancePolicy.Reason
        let deadline: Date
        var stage: Stage
        var inputRevision: UInt64
        /// Verification probes so far; each is a durable host job.
        var attempts = 0
    }
    /// Verification probes run every 5 s; a resume that is not verified
    /// within this many needs attention, as when the deadline passes.
    static let pendingVerifyAttempts = 12
    private var pending: [UUID: Pending] = [:]
    /// Panes a user-requested account move owns; maintenance leaves them alone.
    private(set) var held: Set<UUID> = []

    /// Claims a pane for an account move unless maintenance is acting on it.
    func hold(_ id: UUID) -> Bool {
        guard pending[id] == nil, haikuGrants[id] == nil, !held.contains(id) else { return false }
        held.insert(id)
        return true
    }

    func release(_ id: UUID) { held.remove(id) }
    private typealias HaikuGrant = RelayAgentMaintenancePolicy.ModelGrant
    private var haikuGrants: [UUID: HaikuGrant] = [:]
    private var haikuCompletions: [UUID: (RelayPaneHealthJSON) -> Void] = [:]
    private var haikuTimeouts: [UUID: Task<Void, Never>] = [:]

    struct AgentVersion: Codable, Equatable, Sendable {
        let provider: String
        let running: String?
        let installed: String?
        let imageCurrent: Bool?
        let updateInstalled: Bool
        var outdatedOtherInstall = false

        init?(_ proof: RelayAgentMaintenanceProbe, paneID: UUID) {
            guard proof.valid(for: paneID), let provider = proof.provider else { return nil }
            self.provider = provider; running = proof.runningVersion; installed = proof.installedVersion
            imageCurrent = proof.installedImageCurrent; updateInstalled = proof.installedUpdate == true
            outdatedOtherInstall = proof.outdatedOtherInstall == true
        }
    }
    struct Snapshot: Codable, Sendable {
        let enabled: Bool
        let statuses: [String: String]
        let recentActions: [RelayAgentMaintenanceJournal.Entry]
        let haiku: RelayPaneHealthCoordinator.Snapshot
        var agents: [String: AgentVersion] = [:]
    }

    func snapshot() -> Snapshot {
        Snapshot(enabled: RelayPreferences.shared.automaticAgentMaintenance,
            statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.uuidString.lowercased(), $0.value) }),
            recentActions: Array(journal.entries.values.sorted { $0.createdAt > $1.createdAt }.prefix(16)),
            haiku: RelayPaneHealthCoordinator.shared.snapshot(),
            agents: RelayPaneHealthCoordinator.shared.agentVersions())
    }

    func performHaikuTool(_ action: String, pane: PaneModel, workspace: WorkspaceModel,
                          evidenceID: String, operationID: String, toolID: String) async -> RelayPaneHealthJSON {
        guard RelayPreferences.shared.haikuPaneHealth, RelayPreferences.shared.automaticAgentMaintenance,
              ["repair_agent_link", "apply_installed_update"].contains(action),
              workspace.panes[pane.id] === pane, pending[pane.id] == nil,
              haikuGrants[pane.id] == nil, !held.contains(pane.id) else {
            return .object(["state": .string("held"), "message": .string("An existing action or operator setting holds this repair.")])
        }
        return await withCheckedContinuation { continuation in
            haikuGrants[pane.id] = HaikuGrant(operationID: operationID, toolID: toolID, action: action,
                evidenceID: evidenceID, expires: Date().addingTimeInterval(60))
            haikuCompletions[pane.id] = { continuation.resume(returning: $0) }
            requested.insert(pane.id); lastChecked.removeValue(forKey: pane.id)
            haikuTimeouts[pane.id] = Task { @MainActor [weak self, pane] in
                try? await Task.sleep(for: .seconds(110))
                guard !Task.isCancelled, let self else { return }
                self.completeHaikuTool(pane, state: "verification_unknown", message: "The native action has not been verified; no retry was submitted.")
            }
            tick(workspace)
        }
    }

    private func completeHaikuTool(_ pane: PaneModel, state: String, message: String,
                                   proof: RelayAgentMaintenanceProbe? = nil) {
        guard let completion = haikuCompletions.removeValue(forKey: pane.id) else { return }
        haikuGrants.removeValue(forKey: pane.id)
        haikuTimeouts.removeValue(forKey: pane.id)?.cancel()
        let facts = RelayPaneHealthFacts.read(pane, proof: proof)
        completion(.object(["state": .string(state), "message": .string(message), "pane": facts.value]))
    }

    func reconcileHaikuTool(operationID: String, toolID: String, pane: PaneModel,
                            proof: RelayAgentMaintenanceProbe, updateApplied: Bool) -> Bool {
        guard proof.valid(for: pane.id), proof.bound == true else { return false }
        let matches = journal.entries.values.filter {
            Self.recoveredReceipt($0, pane: pane.id, host: pane.profile.connectionKey, proof: proof,
                operationID: operationID, toolID: toolID, updateApplied: updateApplied)
        }
        guard !matches.isEmpty else { return false }
        do {
            for match in matches { try journal.mark(match.id, "verified") }
            return true
        } catch { return false }
    }

    /// A recovered update receipt needs the same native image proof as the
    /// ordinary completion path; a cleared update flag alone is not enough.
    static func recoveredReceipt(_ entry: RelayAgentMaintenanceJournal.Entry, pane: UUID, host: String,
        proof: RelayAgentMaintenanceProbe, operationID: String, toolID: String, updateApplied: Bool) -> Bool {
        entry.paneID == pane && entry.host == host && entry.sessionID == proof.sessionID &&
            entry.modelOperationID == operationID && entry.modelToolID == toolID &&
            (entry.reason == .binding || updateApplied && RelayAgentMaintenancePolicy.installedImageVerified(proof)) &&
            entry.state != "user_input_after_exit"
    }

    func requestRepair(_ ids: [UUID]) {
        requested.formUnion(ids)
        for id in ids { statuses[id] = "Checking the native conversation binding" }
    }

    /// Uses the supervisor heartbeat; Haiku tools retain the same native repair
    /// admission and postcondition checks as operator-requested maintenance.
    func tick(_ workspace: WorkspaceModel, now: Date = Date()) {
        RelayPaneHealthCoordinator.shared.heartbeat(workspace, now: now)
        RelayMikoShepherdCoordinator.shared.heartbeat(workspace, now: now)
        guard !RelayPreferences.shared.shepherd.enabled,
              (RelayPreferences.shared.automaticAgentMaintenance || RelayPreferences.shared.haikuPaneHealth),
              !RelayLaunchMode.isRunningTests else { return }
        var contexts = Dictionary(uniqueKeysWithValues: workspace.panes.values.map { ($0.id, ($0, workspace)) })
        for (id, context) in RelayPaneHealthCoordinator.shared.monitoredContexts() { contexts[id] = context }
        for id in Set(pending.keys).union(requested) {
            if let context = RelayPaneHealthCoordinator.shared.context(for: id) { contexts[id] = context }
        }
        let candidates = contexts.values.filter { pane, _ in
            pane.contentKind == .terminal && pane.profile.backend == .relay && pane.connectionState == .connected &&
            pane.phase != .exited && pane.remoteExitCode == nil &&
            hostTasks[pane.profile.connectionKey] == nil && !held.contains(pane.id)
        }
        let due = candidates.filter { pane, _ in
            let interval: TimeInterval = pending[pane.id] != nil ? 5 : requested.contains(pane.id) ? 15 : 120
            return now.timeIntervalSince(lastChecked[pane.id] ?? .distantPast) >= interval &&
                (pending[pane.id] != nil || requested.contains(pane.id) ||
                 RelayPaneHealthCoordinator.shared.hostObservationAllowsMaintenanceInspection(pane, now: now))
        }
        guard let (pane, targetWorkspace) = due.sorted(by: { lhs, rhs in
            let lp = pending[lhs.0.id] != nil || requested.contains(lhs.0.id)
            let rp = pending[rhs.0.id] != nil || requested.contains(rhs.0.id)
            if lp != rp { return lp }
            return (lastChecked[lhs.0.id] ?? .distantPast) < (lastChecked[rhs.0.id] ?? .distantPast)
        }).first else { return }
        lastChecked[pane.id] = now
        let host = pane.profile.connectionKey
        hostTasks[host] = Task { @MainActor [weak self, weak targetWorkspace, weak pane] in
            defer { self?.hostTasks.removeValue(forKey: host) }
            guard let self, let workspace = targetWorkspace, let pane, workspace.panes[pane.id] === pane else { return }
            let capturedProfile = pane.profile
            do {
                if RelayPreferences.shared.automaticAgentMaintenance, let action = self.pending[pane.id] {
                    try await self.advance(pane, workspace: workspace, action: action)
                } else {
                    try await self.inspect(pane, workspace: workspace)
                }
            } catch {
                guard pane.profile == capturedProfile else { return }
                RelayPaneHealthCoordinator.shared.observe(pane, proof: RelayAgentMaintenanceProbe(
                    version: 1, unavailable: "Native inspection could not be verified."))
                self.statuses[pane.id] = "Maintenance deferred: " + String(error.localizedDescription.prefix(180))
                self.completeHaikuTool(pane, state: "held", message: "Native inspection or recovery could not be verified.")
            }
        }
    }

    private func inspect(_ pane: PaneModel, workspace: WorkspaceModel) async throws {
        let profile = pane.profile
        let revision = pane.agentInputRevision
        let proof = try await RelayAgentMaintenanceReader.inspect(pane)
        guard workspace.panes[pane.id] === pane, pane.profile == profile else { return }
        RelayPaneHealthCoordinator.shared.observe(pane, proof: proof)
        guard RelayPreferences.shared.automaticAgentMaintenance else { return }
        let wasRequested = requested.remove(pane.id) != nil
        guard proof.valid(for: pane.id) else {
            if wasRequested { statuses[pane.id] = proof.unavailable ?? "Native maintenance evidence is unavailable" }
            completeHaikuTool(pane, state: "held", message: "The exact native identity is unavailable.", proof: proof)
            return
        }
        if let entry = RelayAgentMaintenanceRestartAdmission.pendingDraftRestore(journal, paneID: pane.id,
            host: profile.connectionKey, sessionID: proof.sessionID) {
            guard proof.bound == true, proof.lifecycle == "quiet" else {
                statuses[pane.id] = "Draft saved; waiting for the original conversation to resume"
                return
            }
            guard try await restoreDraft(entry, pane: pane, proof: proof) else { return }
            let original = proof.processID == entry.originalProcessID && proof.processStart == entry.originalProcessStart
            if original { try journal.mark(entry.id, "draft_restored_without_restart") }
            statuses[pane.id] = "Saved draft restored and verified"
            return
        }
        if try journal.resolveUnadmittedRestarts(pane: pane.id, host: profile.connectionKey, proof: proof) {
            statuses[pane.id] = "The earlier restart did not happen; the same agent process is still running"
        }
        if try journal.reconcileBinding(pane: pane.id, host: profile.connectionKey, proof: proof) {
            statuses[pane.id] = "The recorded maintenance result is verified; conversation preserved"
            completeHaikuTool(pane, state: "verified", message: "The original conversation binding is recovered.", proof: proof)
            return
        }
        let banner = RelayAgentMaintenancePolicy.updateBanner(pane.runtime.sidePanelViewportText() ?? "")
        guard let reason = RelayAgentMaintenancePolicy.reason(proof, updateBanner: banner) else {
            requested.remove(pane.id)
            if pending[pane.id] == nil {
                // A newer copy in another install is never applied by a restart.
                statuses[pane.id] = proof.outdatedOtherInstall == true ?
                    "Outdated in a different or unverified install" + (proof.versionTransition.map { " (" + $0 + ")" } ?? "") + "; not restarted" : nil
            }
            completeHaikuTool(pane, state: "already_healthy", message: "Native evidence does not require a restart.", proof: proof)
            return
        }
        if await RelayCapacityManagementCoordinator.shared.shouldUseCombined(pane) {
            statuses[pane.id] = "Installed-image adoption shares the combined native lane; retirement/preservation capability unavailable. No additional maintenance restart is submitted."
            completeHaikuTool(pane, state: "held", message: statuses[pane.id]!, proof: proof)
            return
        }
        let draft = pane.composerStateIfCreated.map { !$0.draft.isEmpty || !$0.attachmentQueue.attachments.isEmpty || $0.submitting || $0.nativeDeliveryHeld } ?? false
        if pane.composerStateIfCreated.map({ $0.submitting || $0.nativeDeliveryHeld }) == true {
            statuses[pane.id] = "Waiting for the current prompt delivery to finish"
            return
        }
        await pane.runtime.prepareAgentMaintenancePromptProof()
        if let held = RelayAgentMaintenancePolicy.deferral(proof, paneID: pane.id,
            emptyPrompt: pane.runtime.agentMaintenanceTerminalPromptIsEmpty(
                explainedAgents: RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: pane.activeSubagents)), hasDraft: draft,
            pendingApprovals: pane.pendingAgentApprovals, inputAge: Date().timeIntervalSince(pane.agentLastInputAt),
            preservingDraft: true, recordedAccount: pane.agentAccount?.recorded) {
            statuses[pane.id] = reason == .update ? "Update " + (proof.versionTransition ?? "installed") + ": " + held : held
            completeHaikuTool(pane, state: "held", message: held, proof: proof)
            return
        }
        let grant = haikuGrants[pane.id]
        // The operator's automatic-maintenance setting authorizes native
        // repairs independently of the advisory model and its spending limit.
        // A model-requested repair must still match its exact scoped evidence.
        guard RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant, reason: reason,
            evidenceID: RelayPaneHealthFacts.read(pane, proof: proof).evidenceID) else {
            statuses[pane.id] = "The model repair request needs fresh native evidence"
            completeHaikuTool(pane, state: "held", message: "The tool evidence changed or this action is not currently admissible.", proof: proof)
            return
        }
        // A second native read fences changes during inspection, including a
        // session switch, a new tool turn, another viewer, and new keyboard input.
        let fresh = try await RelayAgentMaintenanceReader.inspect(pane)
        await pane.runtime.prepareAgentMaintenancePromptProof()
        guard workspace.panes[pane.id] === pane, pane.profile == profile,
              pane.agentInputRevision == revision, fresh.sameSource(as: proof),
              fresh.lifecycle == "quiet", RelayPreferences.shared.automaticAgentMaintenance else { return }
        if grant != haikuGrants[pane.id] || !RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant,
            reason: reason, evidenceID: RelayPaneHealthFacts.read(pane, proof: fresh).evidenceID) {
            completeHaikuTool(pane, state: "held", message: "The pane changed during native admission.", proof: fresh)
            return
        }
        // The separate agent-window composer stays in place. Persist its text
        // and attachments before allowing the terminal underneath it to restart.
        pane.composerStateIfCreated?.persist(hostID: profile.id.uuidString, paneID: pane.id, immediate: true)
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(fresh, activeSubagents: pane.activeSubagents)
        let command = RelayAgentMaintenancePolicy.exitCommand(provider: fresh.provider)
        let readmit = RelayAgentMaintenanceRestartAdmission.readmission(pane: pane, paneID: pane.id,
            original: fresh, inputRevision: revision, reason: reason, grantAtStart: grant,
            paneCurrent: { workspace.panes[pane.id] === pane && pane.profile == profile },
            currentGrant: { self.haikuGrants[pane.id] },
            automaticMaintenance: { RelayPreferences.shared.automaticAgentMaintenance },
            evidenceID: { RelayPaneHealthFacts.read(pane, proof: $0).evidenceID },
            inspect: { try await RelayAgentMaintenanceReader.inspect($0) },
            now: { Date() })
        var attempt: (@MainActor (RelayAgentMaintenanceProbe) -> RelayAgentMaintenanceRestartAdmission.Outcome)?
        if let command {
            attempt = { current in pane.runtime.sendAgentMaintenanceCommandOutcome(command, proof: current,
                inputRevision: revision, preservingComposerDraft: true) }
        }
        let decision = try await RelayAgentMaintenanceRestartAdmission.orchestrate(.init(
            promptIsEmpty: { pane.runtime.agentMaintenanceTerminalPromptIsEmpty(explainedAgents: explained) },
            promptHasTypedText: { pane.runtime.agentMaintenanceTerminalPromptHasTypedText },
            promptBlocker: { pane.runtime.agentMaintenanceTerminalPromptBlocker(explainedAgents: explained) },
            provider: fresh.provider,
            captureDraft: { beforeApply in
                _ = try await pane.runtime.editAgentMaintenanceDraft(proof: fresh, inputRevision: revision,
                    expected: nil, replacement: Data(), beforeApply: beforeApply)
            },
            readPrompt: {
                try await pane.runtime.editAgentMaintenanceDraft(proof: fresh, inputRevision: revision,
                    expected: Data(), replacement: nil)
            },
            preparePrompt: { await pane.runtime.prepareAgentMaintenancePromptProof() },
            claim: {
                try self.journal.claim(pane: pane.id, host: profile.connectionKey, proof: fresh, reason: reason,
                    modelOperationID: grant?.operationID, modelToolID: grant?.toolID)
            },
            saveDraft: { id, text in
                try RelayAgentMaintenanceRestartAdmission.saveCapturedDraft(actionID: id, text: text,
                    paneID: pane.id, host: profile.connectionKey, proof: fresh,
                    drafts: self.drafts, journal: self.journal)
            },
            mark: { id, state in try self.journal.mark(id, state) },
            readmit: readmit,
            attempt: attempt,
            sleep: { try await Task.sleep(for: RelayAgentMaintenanceRestartAdmission.retryInterval) }))
        switch decision {
        case .promptUnconfirmed(let blocker):
            let held = "Waiting for the prompt to be confirmed empty or to show a typed draft: " + blocker
            statuses[pane.id] = held
            completeHaikuTool(pane, state: "held", message: held, proof: fresh)
        case .noDraftContract:
            statuses[pane.id] = "Waiting for an exact draft capture contract for this agent"
        case .cooling:
            statuses[pane.id] = "A recent restart is recorded; automatic retry is held"
            completeHaikuTool(pane, state: "held", message: "The previous native maintenance action is held or cooling down.", proof: fresh)
            requested.remove(pane.id)
        case .held(_, let why):
            let message = "Restart held: " + why + "; nothing was typed"
            statuses[pane.id] = message
            completeHaikuTool(pane, state: "held", message: message + ".", proof: fresh)
        case .busy:
            statuses[pane.id] = "Restart held: the pane was still resizing or reconnecting; nothing was typed"
            completeHaikuTool(pane, state: "held",
                message: "The pane was still resizing or reconnecting after about 30 s; nothing was typed.", proof: fresh)
        case .unknown:
            statuses[pane.id] = "Restart admission was not confirmed; no automatic retry"
            completeHaikuTool(pane, state: "verification_unknown", message: "Restart admission was not confirmed; no automatic retry.", proof: fresh)
        case .submitted(let id, _):
            // The resume and verification stay bound to the original
            // admission evidence; every readmitted probe matched its source.
            pending[pane.id] = Pending(id: id, proof: fresh, profile: profile, reason: reason,
                deadline: Date().addingTimeInterval(90), stage: .shell,
                inputRevision: pane.agentInputRevision)
            statuses[pane.id] = "Waiting for the agent to exit cleanly"
        }
    }

    private func advance(_ pane: PaneModel, workspace: WorkspaceModel, action: Pending) async throws {
        guard pane.profile == action.profile, workspace.panes[pane.id] === pane else { return }
        guard Date() < action.deadline, action.attempts < Self.pendingVerifyAttempts else {
            try journal.mark(action.id, "verification_required")
            statuses[pane.id] = "Restart needs attention; no automatic retry"
            pending.removeValue(forKey: pane.id); requested.remove(pane.id)
            completeHaikuTool(pane, state: "verification_unknown", message: "The native restart needs review; no retry was submitted.")
            return
        }
        if action.stage == .shell {
            guard pane.agentInputRevision == action.inputRevision else {
                try journal.mark(action.id, "user_input_after_exit")
                statuses[pane.id] = "Restart paused because you entered input"
                pending.removeValue(forKey: pane.id); requested.remove(pane.id)
                completeHaikuTool(pane, state: "held", message: "Input arrived after the agent exited; the resume was held.")
                return
            }
            guard let command = action.proof.resumeCommand else { return }
            var attempted = false
            let sent = try await pane.runtime.resumeAgentAfterMaintenance(command, original: action.proof,
                inputRevision: action.inputRevision, willSend: {
                    try self.journal.mark(action.id, "resume_pending")
                    attempted = true
                })
            guard sent else {
                if attempted {
                    try journal.mark(action.id, "resume_outcome_unknown")
                    statuses[pane.id] = "Resume needs attention; no automatic retry"
                    pending.removeValue(forKey: pane.id); requested.remove(pane.id)
                    completeHaikuTool(pane, state: "verification_unknown", message: "The resume outcome is unknown; no retry was submitted.")
                }
                return
            }
            try journal.mark(action.id, "resume_submitted")
            var next = action; next.stage = .verify; next.inputRevision = pane.agentInputRevision
            pending[pane.id] = next
            statuses[pane.id] = "Resume submitted; verifying the exact conversation"
            return
        }
        var counted = action; counted.attempts += 1
        pending[pane.id] = counted
        let proof = try await RelayAgentMaintenanceReader.inspect(pane)
        guard workspace.panes[pane.id] === pane, pane.profile == action.profile,
              proof.valid(for: pane.id), proof.bound == true, proof.sessionID == action.proof.sessionID else { return }
        let applied = action.reason == .binding ||
            RelayAgentMaintenancePolicy.updateApplied(before: action.proof, after: proof)
        guard applied else {
            if action.reason == .update, proof.installedImageCurrent == false,
               proof.processID != action.proof.processID || proof.processStart != action.proof.processStart {
                statuses[pane.id] = "Resumed, but not on the installed image" +
                    (proof.runningVersion.map { " (running " + $0 + ")" } ?? "") + "; waiting for verification"
            }
            return
        }
        RelayPaneHealthCoordinator.shared.observe(pane, proof: proof)
        if let entry = journal.entries[action.id], entry.draftDigest != nil, entry.draftRestored != true,
           try await !restoreDraft(entry, pane: pane, proof: proof) {
            pending.removeValue(forKey: pane.id); requested.remove(pane.id)
            completeHaikuTool(pane, state: "verified", message: "The update was applied. The saved draft was kept because new input arrived.", proof: proof)
            return
        }
        try journal.mark(action.id, "verified")
        statuses[pane.id] = action.reason == .binding ? "Conversation binding recovered" :
            "Installed update " + (proof.runningVersion.map { $0 + " " } ?? "") + "applied; conversation preserved"
        pending.removeValue(forKey: pane.id); requested.remove(pane.id)
        completeHaikuTool(pane, state: "verified", message: statuses[pane.id] ?? "The original conversation was verified.", proof: proof)
        RelayRecoveryStore.shared.record(kind: "agent_maintenance_verified", paneID: pane.id, profile: pane.profile)
    }

    /// Returns false when new input holds the saved draft; the backup is kept
    /// and automatic restoration stops for that action.
    private func restoreDraft(_ entry: RelayAgentMaintenanceJournal.Entry, pane: PaneModel,
        proof: RelayAgentMaintenanceProbe) async throws -> Bool {
        guard let digest = entry.draftDigest, entry.sessionID == proof.sessionID,
              entry.host == pane.profile.connectionKey, entry.paneID == pane.id,
              proof.valid(for: pane.id), proof.bound == true, proof.lifecycle == "quiet" else {
            throw RelayPromptEditorRPC.Failure.changedConnection
        }
        let saved = try drafts.load(entry.id)
        guard saved.valid(actionID: entry.id, paneID: pane.id, host: entry.host,
            sessionID: entry.sessionID, digest: digest) else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        let revision = pane.agentInputRevision
        let current = try await pane.runtime.editAgentMaintenanceDraft(proof: proof, inputRevision: revision,
            expected: nil, replacement: nil)
        // The backup is kept: settling a record never discards the user's text.
        if try journal.settleDraftAlreadyInPrompt(entry.id, proof: proof, prompt: current) { return true }
        if current != saved.text {
            guard current.isEmpty else {
                try journal.mark(entry.id, "draft_restore_held")
                statuses[pane.id] = "Draft saved; new input prevents automatic restoration"
                return false
            }
            _ = try await pane.runtime.editAgentMaintenanceDraft(proof: proof, inputRevision: revision,
                expected: Data(), replacement: saved.text)
            let readback = try await pane.runtime.editAgentMaintenanceDraft(proof: proof, inputRevision: revision,
                expected: saved.text, replacement: nil)
            guard readback == saved.text else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        }
        try journal.restoredDraft(entry.id)
        try? drafts.remove(entry.id)
        return true
    }
}

struct RelayAgentMaintenanceSettingsView: View {
    @ObservedObject private var preferences = RelayPreferences.shared
    @ObservedObject private var maintenance = RelayAgentMaintenance.shared
    /// Cached rows, refreshed only while this window shows. The body must not
    /// call RelayPaneHealthCoordinator.snapshot(): it reads every pane's screen.
    @StateObject private var health = RelayPaneHealthSettingsFeed.settings()
    @StateObject private var profiles = ProfileStore()
    private var mikoHosts: [ConnectionProfile] {
        [ConnectionProfile.local] + profiles.connectableHosts.filter { $0.backend == .relay }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automatic maintenance").font(RelayTheme.font(size: 14, weight: .semibold))
            Picker("Miko runs on", selection: $preferences.mikoHostKey) {
                ForEach(mikoHosts, id: \.connectionKey) { profile in
                    Text(profile.kind == .local ? "This Mac" : profile.name).tag(profile.connectionKey)
                }
                if !mikoHosts.contains(where: { $0.connectionKey == preferences.mikoHostKey }) {
                    Text("Unknown host (Miko is refused until you choose one)").tag(preferences.mikoHostKey)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("relay.settings.miko-host")
            Text("Miko uses this host's API account and limits, whichever pane has focus.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            Toggle("Repair agent links and apply installed updates", isOn: $preferences.automaticAgentMaintenance)
                .accessibilityIdentifier("relay.settings.agent-maintenance.enabled")
            Text("Waits for an idle agent and an empty prompt, preserves the conversation, and verifies the new binding. An uncertain restart is held for review.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            Toggle("Use Haiku to monitor panes and take safe actions", isOn: $preferences.haikuPaneHealth)
                .accessibilityIdentifier("relay.settings.haiku-pane-health.enabled")
            Text("Uses the saved API account and spending limits on each host. Haiku can inspect panes, reconnect retained terminals, repair idle agents and verify recovery. Uses low effort with thinking off.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            ForEach(health.value, id: \.host) { host in
                Text("\(host.name): \(host.freshObservations)/\(host.panes) recent native checks, \(host.endedPanes) ended. Haiku: \(host.state)")
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            }
            ForEach(maintenance.statuses.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                Text("\(id.uuidString.prefix(8)): \(maintenance.statuses[id] ?? "")")
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            }
        }
        .padding(16)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .background(RelayWindowVisibilityReader(feed: health).frame(width: 0, height: 0))
        .onDisappear { health.setVisible(false) }
    }
}
