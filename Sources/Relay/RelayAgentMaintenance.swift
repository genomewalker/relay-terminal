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
    /// relayd's reason code for resumeError (absent from an older relayd).
    var resumeErrorCode: String? = nil
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
    var moveErrorCode: String? = nil
    /// The Codex is bound to Codex's own daemon, not through Relay's proxy.
    var codexOutsideProxy: Bool? = nil
    /// Codex: the ChatGPT login in the running agent's folder and its pin.
    var login: RelayAgentLoginObservation? = nil
    /// Codex: how the pane's account config.toml trusts the conversation's
    /// directory for a relaunch (relayd's codex_trust).
    var codexTrust: RelayCodexTrustObservation? = nil
    var unavailable: String? = nil
    var worker: RelayPaneWorkerObservation? = nil
    var context: RelayPaneContextObservation? = nil
    /// Set by Relay, never decoded: the user forced an account move of this
    /// pane, choosing to interrupt its turn and stop its background work.
    /// Background, subagent and footer-work evidence then do not hold the
    /// move's own inputs; identity, revision, approval and screen fences do.
    var forcedByUser = false

    enum CodingKeys: String, CodingKey {
        case version, provider, bound, lifecycle, revision, owner, unavailable
        case paneID = "paneId", processID = "processId", processStart, sessionID = "sessionId"
        case installedUpdate, installedImageCurrent, runningVersion, installedVersion, outdatedOtherInstall
        case backgroundWork, subagentWork, harnessStatus, backgroundAgentJobs, resumeCommand, resumeError, resumeErrorCode, worker, context, configDir, accountMatches, moveCommand, moveError, moveErrorCode, login, codexTrust, codexOutsideProxy
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
    /// How long a hook-reported subagent may run before its host files
    /// exist. Within this window an "active" entry always counts.
    static let subagentHostEvidenceGrace: TimeInterval = 600

    /// Hook-reported subagents that may still be working. Relay learns of
    /// subagents from hook events; a lost stop event leaves an entry "active"
    /// forever. relayd's proof reads the session's subagent files on the host,
    /// so when it shows no subagent work and Claude reports itself idle, an
    /// entry older than the grace window has no evidence and is not counted.
    /// Unknown host facts (nil) never discount anything.
    static func countedActiveSubagents(_ subagents: [SubagentActivity], proof: RelayAgentMaintenanceProbe,
                                       now: Date = Date()) -> Int {
        let hostShowsNone = proof.provider == "claude" && proof.subagentWork == false
            && proof.harnessStatus == "idle"
        return subagents.count { subagent in
            guard subagent.phase == .active else { return false }
            guard hostShowsNone, subagent.provider == .claude else { return true }
            return now.timeIntervalSince(subagent.startedAt) <= subagentHostEvidenceGrace
        }
    }

    /// The facts `explainedFooterAgents` decides on, for a held receipt.
    /// Host facts and counts only: no labels, prompts or transcript text.
    static func footerAgentFacts(_ proof: RelayAgentMaintenanceProbe, subagents: [SubagentActivity],
                                 now: Date = Date()) -> String {
        func text(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "unknown" }
        let reported = subagents.count { $0.phase == .active }
        let counted = countedActiveSubagents(subagents, proof: proof, now: now)
        return "harness_status=\(proof.harnessStatus ?? "unknown") subagent_work=\(text(proof.subagentWork)) " +
            "background_work=\(text(proof.backgroundWork)) " +
            "background_agent_jobs=\(proof.backgroundAgentJobs.map(String.init) ?? "unknown") " +
            "active_subagents=\(counted) of \(reported) reported"
    }

    static func explainedFooterAgents(_ proof: RelayAgentMaintenanceProbe, subagents: [SubagentActivity],
                                      now: Date = Date()) -> Int {
        explainedFooterAgents(proof, activeSubagents: countedActiveSubagents(subagents, proof: proof, now: now))
    }

    static func explainedFooterAgents(_ proof: RelayAgentMaintenanceProbe, activeSubagents: Int) -> Int {
        if proof.forcedByUser { return RelayAgentMaintenancePrompt.allWorkExplained }
        guard proof.provider == "claude", proof.subagentWork == false, activeSubagents == 0,
              proof.harnessStatus == "idle" else { return 0 }
        if proof.backgroundWork == false { return RelayAgentMaintenancePrompt.waitingSessionsExplained }
        guard let jobs = proof.backgroundAgentJobs, jobs > 0 else { return 0 }
        return jobs
    }

    static func idleEvidence(_ proof: RelayAgentMaintenanceProbe, emptyPrompt: Bool, hasDraft: Bool) -> Bool {
        if proof.forcedByUser { return forcedIdle(proof) }
        let harnessIdle = proof.provider == "claude" && proof.harnessStatus == "idle" &&
            proof.backgroundWork == false && proof.subagentWork == false && emptyPrompt && !hasDraft
        let harnessBusy = proof.provider == "claude" && proof.harnessStatus != nil && proof.harnessStatus != "idle"
        return !harnessBusy && (proof.lifecycle == "quiet" || harnessIdle)
    }

    /// A forced move's turn evidence: Claude's own harness status when it is
    /// known, else a quiet transcript. Claude reports "shell" while background
    /// shells run, also after its turn ended (07fa914c, 2026-11-15: "done ·
    /// 2 shells still running"), so "shell" with a quiet transcript is idle.
    /// Background shells and subagents are not otherwise consulted.
    static func forcedIdle(_ proof: RelayAgentMaintenanceProbe) -> Bool {
        if proof.provider == "claude", let status = proof.harnessStatus {
            return status == "idle" || (status == "shell" && proof.lifecycle == "quiet")
        }
        return proof.lifecycle == "quiet"
    }

    /// Whether a forced move first sends its Esc: anything but a harness that
    /// says idle, since "shell" can also be a foreground command in a turn.
    /// One Esc at an idle prompt changes nothing.
    static func forcedNeedsInterrupt(_ proof: RelayAgentMaintenanceProbe) -> Bool {
        if proof.provider == "claude", let status = proof.harnessStatus { return status != "idle" }
        return proof.lifecycle != "quiet"
    }

    /// An update result's old → new versions, from the native probes before
    /// and after the restart (never the assumed installed version).
    static func updateVersionFields(before: RelayAgentMaintenanceProbe, after: RelayAgentMaintenanceProbe)
        -> [String: RelayPaneHealthJSON] {
        let old = before.runningVersion ?? "unknown", new = after.runningVersion ?? "unknown"
        return ["from_version": .string(old), "to_version": .string(new), "version_transition": .string(old + " → " + new)]
    }

    /// Whether a Codex at `version` ("0.170.0") is at least `minimum`.
    static func codexVersion(_ version: String?, atLeast minimum: [Int]) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (index, wanted) in minimum.enumerated() {
            let have = index < parts.count ? parts[index] : 0
            if have != wanted { return have > wanted }
        }
        return true
    }

    /// Case 10 (7b68ee70): a Codex relaunch that would stop at its
    /// folder-trust dialog is held before any input, so the old process keeps
    /// running. 0.170.0 stopped for a non-git folder trusted only through its
    /// parent (inferred from one case, not confirmed in Codex's source). Nil
    /// otherwise; a dialog that still appears is caught after the launch.
    static func codexTrustHold(_ proof: RelayAgentMaintenanceProbe, reason: Reason) -> RelayPaneOperationRefusal? {
        guard proof.provider == "codex", let trust = proof.codexTrust else { return nil }
        let target = proof.installedVersion ?? proof.runningVersion
        // Only the observed case is held before exit; other states are left
        // to the post-launch dialog check rather than held on a guess.
        let stops = trust.status == "parent_only" && codexVersion(target, atLeast: [0, 170, 0])
        guard stops else { return nil }
        let what = reason == .update ? "Update " + (proof.versionTransition ?? "installed") + " available" : "Restart needed"
        return .init(.trustPrompt, what + ", held: Codex folder trust required for " + trust.cwd)
    }

    /// Lowercase, unique, sorted pane UUIDs, at most 256; nil when any is invalid.
    static func validProtectedPanes(_ ids: [String]) -> [String]? {
        guard ids.count <= 256 else { return nil }
        var result = Set<String>()
        for id in ids {
            guard let uuid = UUID(uuidString: id) else { return nil }
            result.insert(uuid.uuidString.lowercased())
        }
        return result.sorted()
    }

    /// The agent_maintenance_protected_panes setting: exactly {"panes": [UUID]}.
    static func protectedPanes(_ data: Data) throws -> [String] {
        struct Value: Decodable { let panes: [String] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.keys.sorted() == ["panes"],
              let value = try? JSONDecoder().decode(Value.self, from: data),
              let panes = validProtectedPanes(value.panes) else {
            throw RelaySettingsPolicy.ControlError.invalid("agent_maintenance_protected_panes needs {\"panes\": [pane UUIDs]}, at most 256")
        }
        return panes
    }

    /// Why maintenance holds an automatic restart before any input: a
    /// protected pane is never restarted on its own, and paused update
    /// restarts hold updates only (binding repairs and health checks go on).
    static func automaticRestartHold(reason: Reason, paneID: UUID, paused: Bool, protected: [String],
                                     transition: String?) -> RelayPaneOperationRefusal? {
        let what = reason == .update ? "Update " + (transition ?? "installed") + " available" : "Binding repair needed"
        if protected.contains(paneID.uuidString.lowercased()) {
            return .init(.protectedPane, what + ", held: protected")
        }
        if reason == .update, paused { return .init(.updatesPaused, what + ", held: update restarts are paused") }
        return nil
    }

    static func deferral(_ proof: RelayAgentMaintenanceProbe, paneID: UUID,
        emptyPrompt: Bool, hasDraft: Bool, pendingApprovals: Int, inputAge: TimeInterval,
        preservingDraft: Bool = false, recordedAccount: RelayAgentAccount? = nil,
        promptBlocker: String? = nil, requiresResume: Bool = true) -> String? {
        deferralReason(proof, paneID: paneID, emptyPrompt: emptyPrompt, hasDraft: hasDraft, pendingApprovals: pendingApprovals,
            inputAge: inputAge, preservingDraft: preservingDraft, recordedAccount: recordedAccount,
            promptBlocker: promptBlocker, requiresResume: requiresResume)?.blocker
    }

    /// `deferral` with its reason code and how to clear it; the blocker is
    /// exactly the text `deferral` returns.
    static func deferralReason(_ proof: RelayAgentMaintenanceProbe, paneID: UUID,
        emptyPrompt: Bool, hasDraft: Bool, pendingApprovals: Int, inputAge: TimeInterval,
        preservingDraft: Bool = false, recordedAccount: RelayAgentAccount? = nil,
        promptBlocker: String? = nil, requiresResume: Bool = true) -> RelayPaneOperationRefusal? {
        typealias Refusal = RelayPaneOperationRefusal
        guard proof.valid(for: paneID) else {
            return Refusal(.identityUnavailable, proof.unavailable ?? "Native identity is unavailable")
        }
        // The account is part of the agent's identity. A restart would resume
        // in the running agent's own account, so a difference from the
        // account the pane was started in is reported and never acted on.
        if let recordedAccount, recordedAccount.provider == proof.provider, let observed = proof.configDir,
           !(proof.accountMatches ?? recordedAccount.matches(observedDirectory: observed)) {
            let reason = recordedAccount.explicitClaudeDefault(observedDirectory: observed)
                ? " (explicit ~/.claude uses a different .claude.json)" : ""
            return Refusal(.accountMismatch, "Held: the running agent uses a different \(recordedAccount.provider) account than this pane's " +
                "\(recordedAccount.label) account\(reason); Relay will not restart or switch it")
        }
        guard pendingApprovals == 0 else { return Refusal(.approvalPending, "Waiting for the pending approval") }
        guard preservingDraft || !hasDraft else { return Refusal(.draftPresent, "Waiting for the unsent prompt to be cleared or sent") }
        if !proof.forcedByUser && proof.backgroundWork == true {
            return Refusal(.backgroundWork, "Waiting for the agent's background shells or agent processes to finish")
        }
        if !proof.forcedByUser && proof.provider == "claude" && proof.backgroundWork == nil {
            return Refusal(.backgroundWork, "Waiting for background work to be verified absent: the native process check is unavailable")
        }
        // Lifecycle evidence of a running subagent holds on its own, whatever
        // the screen shows: a footer can be stale, clipped or absent.
        if !proof.forcedByUser && proof.provider == "claude" && proof.subagentWork == true {
            return Refusal(.subagentWork, "Waiting for the session's subagents to finish: Claude's lifecycle records show one still running")
        }
        guard preservingDraft || emptyPrompt else {
            let blocker = "Waiting for the original prompt to be confirmed empty" + (promptBlocker.map { ": " + $0 } ?? "")
            let goal = promptBlocker.map(RelayAgentMaintenancePrompt.isGoalBlocker) ?? false
            let trust = promptBlocker == RelayAgentMaintenancePrompt.folderTrustBlocker
            return Refusal(goal ? .goalActive : trust ? .trustPrompt : .promptUnverified, blocker)
        }
        // A current, process-start-matched Claude harness observation can
        // supersede a transcript's cached active phase (for example after
        // "Claude session ended"). CPU usage and summary text are not proof.
        // An explicitly busy harness overrides even a quiet transcript.
        guard idleEvidence(proof, emptyPrompt: emptyPrompt, hasDraft: hasDraft) else {
            if proof.forcedByUser { return Refusal(.turnActive, "The agent's turn did not stop after Relay's interrupt") }
            return proof.lifecycle == "settling" ? Refusal(.transcriptSettling, "Waiting for the conversation transcript to stop changing")
                : Refusal(.turnActive, "Waiting for the current turn to finish")
        }
        guard inputAge >= 15 else { return Refusal(.userTyping, "Waiting until you finish typing") }
        if requiresResume, proof.resumeCommand == nil {
            let code = Refusal.code(host: proof.resumeErrorCode, message: proof.resumeError, fallback: .resumeUnavailable)
            return Refusal(code, proof.resumeError ?? "The exact agent resume command is unavailable")
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
            let configured = RelayAgentAccountDirectory.shared.account(for: profile, provider: provider,
                                                                       observedDirectory: directory)
            pane.observeAgentAccount(provider: provider, directory: directory,
                label: matches == true ? pane.agentAccount?.recorded?.label : configured?.label,
                matches: matches, configured: configured)
            if provider == "codex" { pane.observeAgentLogin(proof.login) }
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
    /// Panes whose automatic restart is held by the operator (protected or
    /// paused update restarts), with the reason code.
    @Published private(set) var holds: [UUID: RelayPaneOperationRefusal] = [:]
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
        var updateRestartsPaused = false
        var protectedPanes: [String] = []
        /// Held automatic restarts by pane: reason_code, blocker, how_to_clear.
        var holds: [String: [String: String]] = [:]
        /// Journal entries left out of recentActions; the journal keeps them.
        var omittedActions = 0
    }

    /// The caller-audit record of one automatic restart step (caller
    /// "agent-maintenance"); the request ID is the journal action ID.
    static func auditRecord(action: String, paneID: UUID, reason: RelayAgentMaintenancePolicy.Reason, outcome: String,
                            detail: String?, at: Date = Date()) -> RelayCallerControl.Audit {
        var record = RelayCallerControl.Audit(id: UUID(), at: at, caller: RelayCallerControl.maintenanceCaller,
            path: "in-process/agent-maintenance", operation: "agent_maintenance." + reason.rawValue + "_restart",
            requestID: String(action.prefix(128)), tabID: nil, paneID: paneID.uuidString.lowercased(), jobID: nil,
            outcome: String(outcome.prefix(64)))
        record.preview = detail.map { String($0.prefix(240)) }
        return record
    }

    /// Audits one step; `required` fails the step when the audit cannot be written.
    private func audit(_ action: String, pane: UUID, reason: RelayAgentMaintenancePolicy.Reason, _ outcome: String, _ detail: String? = nil,
                       required: Bool = false) throws {
        let record = Self.auditRecord(action: action, paneID: pane, reason: reason, outcome: outcome, detail: detail)
        do { try auditSink(record) } catch { if required { throw error } }
    }
    var auditSink: @MainActor (RelayCallerControl.Audit) throws -> Void = { try RelayCallerControl.shared.recordMaintenanceAction($0) }

    /// Every action of the last 24 hours and every unsettled one, newest
    /// first, up to `limit`; the count left out is reported, never dropped
    /// silently (af242052 fell off a fixed 16-entry list).
    static func recentActions(_ entries: [RelayAgentMaintenanceJournal.Entry], now: Date = Date(), limit: Int = 128)
        -> (entries: [RelayAgentMaintenanceJournal.Entry], omitted: Int) {
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        let recent = sorted.enumerated().filter { index, entry in
            index < 16 || now.timeIntervalSince(entry.createdAt) < 86_400 ||
                !RelayAgentMaintenanceJournal.settledStates.contains(entry.state)
        }.map(\.element)
        let kept = Array(recent.prefix(limit))
        return (kept, sorted.count - kept.count)
    }

    func snapshot() -> Snapshot {
        let recent = Self.recentActions(Array(journal.entries.values))
        return Snapshot(enabled: RelayPreferences.shared.automaticAgentMaintenance,
            statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.uuidString.lowercased(), $0.value) }),
            recentActions: recent.entries,
            haiku: RelayPaneHealthCoordinator.shared.snapshot(),
            agents: RelayPaneHealthCoordinator.shared.agentVersions(),
            updateRestartsPaused: RelayPreferences.shared.agentUpdateRestartsPaused,
            protectedPanes: RelayPreferences.shared.maintenanceProtectedPanes,
            holds: Dictionary(uniqueKeysWithValues: holds.map { ($0.key.uuidString.lowercased(), $0.value.fields) }),
            omittedActions: recent.omitted)
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
        RelayCodexLoginWatch.shared.tick(workspace, now: now)
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
        if let hold = RelayAgentMaintenancePolicy.automaticRestartHold(reason: reason, paneID: pane.id,
            paused: RelayPreferences.shared.agentUpdateRestartsPaused,
            protected: RelayPreferences.shared.maintenanceProtectedPanes, transition: proof.versionTransition) {
            statuses[pane.id] = hold.blocker
            holds[pane.id] = hold
            completeHaikuTool(pane, state: "held", message: hold.blocker, proof: proof)
            return
        }
        if let trust = RelayAgentMaintenancePolicy.codexTrustHold(proof, reason: reason) {
            // Opt-in only: mirror the parent's existing trust for this exact
            // folder, then restart on a later check. Never answers the dialog.
            if RelayPreferences.shared.codexTrustMirrorParent, proof.codexTrust?.status == "parent_only",
               let cwd = proof.codexTrust?.cwd, let parent = proof.codexTrust?.parent {
                let command = RelayHostExecution.daemonCommand(profile: profile,
                    arguments: ["codex-trust-like-parent", proof.configDir.flatMap { $0.isEmpty ? nil : $0 } ?? "-", cwd])
                let result = try await RelayHostExecution.capture(profile: profile, command: command, timeout: 15, maximumBytes: 4096)
                let note = result.exitCode == 0
                    ? "Relay trusted " + cwd + " in the pane's Codex config.toml, mirroring the trusted parent " + parent +
                        " (setting codex_trust_mirror_parent); the update restart follows on the next check"
                    : "Relay could not write the trust entry for " + cwd + ": " +
                        RelayPaneOperationRefusal.hostBlocker(stderr: result.stderr)
                try? audit("trust:" + cwd, pane: pane.id, reason: reason, result.exitCode == 0 ? "trust_written" : "trust_write_failed", note)
                let held = RelayPaneOperationRefusal(.trustPrompt, trust.blocker + ". " + note)
                statuses[pane.id] = held.blocker
                holds[pane.id] = held
                completeHaikuTool(pane, state: "held", message: held.blocker, proof: proof)
                return
            }
            statuses[pane.id] = trust.blocker
            holds[pane.id] = trust
            completeHaikuTool(pane, state: "held", message: trust.blocker, proof: proof)
            return
        }
        holds.removeValue(forKey: pane.id)
        if await RelayCapacityManagementCoordinator.shared.shouldUseCombined(pane) {
            statuses[pane.id] = "Installed-image adoption shares the combined native lane; retirement/preservation capability unavailable. No additional maintenance restart is submitted."
            completeHaikuTool(pane, state: "held", message: statuses[pane.id]!, proof: proof)
            return
        }
        let draft = pane.composerStateIfCreated?.hasPendingInput ?? false
        if pane.composerStateIfCreated.map({ $0.submitting || $0.nativeDeliveryHeld }) == true {
            statuses[pane.id] = "Waiting for the current prompt delivery to finish"
            return
        }
        await pane.runtime.prepareAgentMaintenancePromptProof()
        if let refusal = RelayAgentMaintenancePolicy.deferralReason(proof, paneID: pane.id,
            emptyPrompt: pane.runtime.agentMaintenanceTerminalPromptIsEmpty(
                explainedAgents: RelayAgentMaintenancePolicy.explainedFooterAgents(proof, subagents: pane.subagents)), hasDraft: draft,
            pendingApprovals: pane.pendingAgentApprovals, inputAge: Date().timeIntervalSince(pane.agentLastInputAt),
            preservingDraft: true, recordedAccount: pane.agentAccount?.recorded) {
            let held = refusal.blocker
            holds[pane.id] = refusal
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
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(fresh, subagents: pane.subagents)
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
                let id = try self.journal.claim(pane: pane.id, host: profile.connectionKey, proof: fresh, reason: reason,
                    modelOperationID: grant?.operationID, modelToolID: grant?.toolID)
                // Durable in the caller audit before any restart input.
                if let id {
                    try self.audit(id, pane: pane.id, reason: reason, "admitted", fresh.versionTransition, required: true)
                }
                return id
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
            holds[pane.id] = .init(.promptUnverified, held)
            statuses[pane.id] = held
            completeHaikuTool(pane, state: "held", message: held, proof: fresh)
        case .noDraftContract:
            statuses[pane.id] = "Waiting for an exact draft capture contract for this agent"
        case .cooling:
            statuses[pane.id] = "A recent restart is recorded; automatic retry is held"
            holds[pane.id] = .init(.coolingDown, "The previous native maintenance action is held or cooling down")
            completeHaikuTool(pane, state: "held", message: "The previous native maintenance action is held or cooling down.", proof: fresh)
            requested.remove(pane.id)
        case .held(_, let why):
            let message = "Restart held: " + why + "; nothing was typed"
            holds[pane.id] = .init(RelayPaneOperationRefusal.classify(why), message)
            statuses[pane.id] = message
            completeHaikuTool(pane, state: "held", message: message + ".", proof: fresh)
        case .busy:
            statuses[pane.id] = "Restart held: the pane was still resizing or reconnecting; nothing was typed"
            holds[pane.id] = .init(.paneNotConnected, "The pane was still resizing or reconnecting after about 30 s; nothing was typed")
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
        // A relaunched Codex stopped at its folder-trust dialog: held with its
        // reason, not left as verification_required. Relay never answers it.
        if action.stage == .verify, action.proof.provider == "codex",
           RelayAgentMaintenancePrompt.isCodexFolderTrustDialog(pane.runtime.sidePanelViewportText()) {
            try journal.mark(action.id, "held_trust_prompt")
            let cwd = action.proof.codexTrust?.cwd ?? "the conversation's folder"
            let held = RelayPaneOperationRefusal(.trustPrompt, "Restart held: Codex folder trust required for " + cwd)
            try? audit(action.id, pane: pane.id, reason: action.reason, "held_trust_prompt", cwd)
            statuses[pane.id] = held.blocker
            holds[pane.id] = held
            pending.removeValue(forKey: pane.id); requested.remove(pane.id)
            completeHaikuTool(pane, state: "held", message: held.blocker + ". " + held.howToClear)
            return
        }
        guard Date() < action.deadline, action.attempts < Self.pendingVerifyAttempts else {
            try journal.mark(action.id, "verification_required")
            try? audit(action.id, pane: pane.id, reason: action.reason, "verification_required")
            statuses[pane.id] = "Restart needs attention; no automatic retry"
            pending.removeValue(forKey: pane.id); requested.remove(pane.id)
            completeHaikuTool(pane, state: "verification_unknown", message: "The native restart needs review; no retry was submitted.")
            return
        }
        if action.stage == .shell {
            guard pane.agentInputRevision == action.inputRevision else {
                try journal.mark(action.id, "user_input_after_exit")
                try? audit(action.id, pane: pane.id, reason: action.reason, "user_input_after_exit")
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
                    try? audit(action.id, pane: pane.id, reason: action.reason, "resume_outcome_unknown")
                    statuses[pane.id] = "Resume needs attention; no automatic retry"
                    pending.removeValue(forKey: pane.id); requested.remove(pane.id)
                    completeHaikuTool(pane, state: "verification_unknown", message: "The resume outcome is unknown; no retry was submitted.")
                }
                return
            }
            try journal.mark(action.id, "resume_submitted")
            try? audit(action.id, pane: pane.id, reason: action.reason, "resume_submitted")
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
        let transition = (action.proof.runningVersion ?? "unknown") + " → " + (proof.runningVersion ?? "unknown")
        try? audit(action.id, pane: pane.id, reason: action.reason, "verified", action.reason == .update ? transition : nil)
        statuses[pane.id] = action.reason == .binding ? "Conversation binding recovered" :
            "Installed update " + (proof.runningVersion.map { $0 + " " } ?? "") + "applied (" + transition + "); conversation preserved"
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
    private func protection(_ id: UUID) -> Binding<Bool> {
        let key = id.uuidString.lowercased()
        return Binding(get: { preferences.maintenanceProtectedPanes.contains(key) }, set: { on in
            var panes = Set(preferences.maintenanceProtectedPanes)
            if on { panes.insert(key) } else { panes.remove(key) }
            preferences.maintenanceProtectedPanes = RelayAgentMaintenancePolicy.validProtectedPanes(Array(panes))
                ?? preferences.maintenanceProtectedPanes
        })
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
            Toggle("Pause automatic update restarts", isOn: $preferences.agentUpdateRestartsPaused)
                .accessibilityIdentifier("relay.settings.agent-maintenance.update-restarts-paused")
            Text("Freezes restarts onto a newly installed agent version (for a release freeze); health checks and link repairs continue. Held panes report \"update available, held\".")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            Toggle("Trust a Codex folder like its trusted parent before restarting", isOn: $preferences.codexTrustMirrorParent)
                .accessibilityIdentifier("relay.settings.agent-maintenance.codex-trust-mirror-parent")
            Text("Off: a Codex restart that would stop at the folder-trust dialog is held and reported. On: Relay first adds that exact folder to the account's config.toml, mirroring its trusted parent, and says so.")
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
                HStack {
                    Text("\(id.uuidString.prefix(8)): \(maintenance.statuses[id] ?? "")")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    Spacer()
                    Toggle("Protected", isOn: protection(id)).toggleStyle(.checkbox)
                        .help("Never restart this pane automatically")
                }
            }
            ForEach(preferences.maintenanceProtectedPanes.filter { id in
                !maintenance.statuses.keys.contains { $0.uuidString.lowercased() == id } }, id: \.self) { id in
                HStack {
                    Text("\(id.prefix(8)): protected from automatic restarts")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    Spacer()
                    if let uuid = UUID(uuidString: id) {
                        Toggle("Protected", isOn: protection(uuid)).toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(16)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .background(RelayWindowVisibilityReader(feed: health).frame(width: 0, height: 0))
        .onDisappear { health.setVisible(false) }
    }
}
