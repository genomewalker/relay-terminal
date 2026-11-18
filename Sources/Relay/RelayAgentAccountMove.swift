import CryptoKit
import Foundation

/// Who asked for an account move. Only the user, directly or through an MCP
/// client holding the terminal input grant, can move a pane. The native
/// quota scheduler has a separate exact durable intent; Miko requests and
/// maintenance cannot switch accounts.
enum RelayAgentAccountMoveOrigin: String, Codable, Sendable {
    case user, mcp, assistant, maintenance, quotaFailover
    /// Not a move: Relay updated a pane's recorded account to the configured
    /// account its running agent was found using. Logged so an account change
    /// made outside Relay stays visible.
    case observed
}

enum RelayAgentAccountMovePolicy {
    /// Quota failover selects an already configured account. Only an explicit
    /// manual move may copy onboarding/trust answers into a target config.
    static func preparesTarget(_ origin: RelayAgentAccountMoveOrigin) -> Bool { origin != .quotaFailover }
    /// Removing an account is the user's own action from Settings only; an
    /// MCP client, Miko and maintenance never remove one, whatever grant.
    static func removalRefusal(_ origin: RelayAgentAccountMoveOrigin) -> String? {
        origin == .user ? nil : "Removing an account is user-initiated only, from Relay's Settings."
    }

    /// The provider whose account a pane of this kind can move between, if any.
    static func movableProvider(_ kind: AgentKind) -> String? {
        switch kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .shell, .other: return nil
        }
    }

    static func originRefusal(_ origin: RelayAgentAccountMoveOrigin, inputGranted: Bool) -> String? {
        switch origin {
        case .user: return nil
        case .quotaFailover: return nil // additionally fenced by the durable scheduler intent below
        case .mcp: return inputGranted ? nil : "Moving a pane to another account requires the terminal input grant."
        case .assistant, .maintenance, .observed:
            return "Moving a pane to another account is user-initiated only; Miko and maintenance never switch accounts."
        }
    }

    /// The same proofs a maintenance restart needs (verified idle agent, empty
    /// prompt, no approvals, no background work), plus a move command whose
    /// target account can see this exact conversation. `typedDraft` is
    /// positive evidence of typed text in the agent's prompt: a Claude draft
    /// is saved, cleared and restored by the move; any other agent's is refused.
    static func refusal(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, target: RelayAgentAccount,
                        emptyPrompt: Bool, hasDraft: Bool, typedDraft: Bool = false, pendingApprovals: Int,
                        inputAge: TimeInterval, promptBlocker: String? = nil) -> String? {
        refusalReason(proof, paneID: paneID, target: target, emptyPrompt: emptyPrompt, hasDraft: hasDraft, typedDraft: typedDraft,
                      pendingApprovals: pendingApprovals, inputAge: inputAge, promptBlocker: promptBlocker)?.blocker
    }

    /// `refusal` with its reason code and how to clear it.
    static func refusalReason(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, target: RelayAgentAccount,
                              emptyPrompt: Bool, hasDraft: Bool, typedDraft: Bool = false, pendingApprovals: Int,
                              inputAge: TimeInterval, promptBlocker: String? = nil) -> RelayPaneOperationRefusal? {
        typealias Refusal = RelayPaneOperationRefusal
        guard proof.valid(for: paneID) else {
            return Refusal(.identityUnavailable, proof.unavailable ?? "The agent's native identity could not be verified.")
        }
        guard target.isValid, target.provider == proof.provider else {
            return Refusal(.targetAccountUnavailable,
                           "This pane runs \(proof.provider ?? "another agent"); choose one of its \(proof.provider ?? "") accounts.")
        }
        guard !hasDraft else { return Refusal(.draftPresent, "Send or clear the unsent prompt first; a move needs an empty prompt.") }
        if typedDraft, let refused = draftCaptureRefusal(provider: proof.provider) { return Refusal(.draftPresent, refused) }
        // A move resumes with its own moveCommand. relayd withholds the
        // same-pane resume of a folder holding the wrong Codex login, and a
        // move is exactly how such a pane leaves that folder.
        if let held = RelayAgentMaintenancePolicy.deferralReason(proof, paneID: paneID, emptyPrompt: emptyPrompt || typedDraft,
            hasDraft: hasDraft, pendingApprovals: pendingApprovals, inputAge: inputAge, promptBlocker: promptBlocker,
            requiresResume: proof.login?.status != "mismatch") {
            return held
        }
        guard proof.moveCommand != nil else {
            let code = proof.moveErrorCode.flatMap(Refusal.Code.init(rawValue:)) ??
                (proof.moveError.map(Refusal.classify) ?? .resumeUnavailable)
            return Refusal(code, proof.moveError ?? "This relayd cannot prepare an account move; update Relay on that host.")
        }
        return nil
    }

    /// Only Claude's prompt editor bridge reads and replaces a draft's exact
    /// bytes; another agent's typed prompt is never guessed at from its screen.
    static func draftCaptureRefusal(provider: String?) -> String? {
        provider == "claude" ? nil : "This \(provider ?? "agent") pane has an unsent prompt, and Relay has no exact " +
            "draft capture contract for \(provider ?? "this agent"); send or clear it first. Nothing was sent."
    }

    /// A Codex move that keeps Relay's `--profile relay-terminal` needs that
    /// profile in the target account; relayd writes Relay's managed copy there.
    static func needsRelayCodexProfile(moveCommand: String?, provider: String?, target: RelayAgentAccount) -> Bool {
        guard provider == "codex", target.provider == "codex", !target.dir.isEmpty,
              let words = moveCommand?.split(separator: " ").map(String.init) else { return false }
        return zip(words, words.dropFirst()).contains { flag, value in
            (flag == "--profile" || flag == "-p") && value == "relay-terminal"
        }
    }

    /// relayd's `claude-move-onboarding` result: nil only for a clean exit
    /// reporting a ready or updated target. Anything else, including a relayd
    /// without the command, refuses the move.
    static func claudeOnboardingRefusal(exitCode: Int?, stdout: Data, stderr: Data, target: RelayAgentAccount) -> String? {
        struct Result: Decodable { let status: String }
        if exitCode == 0, let result = try? JSONDecoder().decode(Result.self, from: stdout),
           result.status == "ready" || result.status == "updated" {
            return nil
        }
        let reason = String(decoding: stderr.prefix(400), as: UTF8.self)
            .replacingOccurrences(of: "relayd: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.hasPrefix("unknown command") {
            return "This relayd cannot check the \(target.label) account's first-run state; update Relay on that host. Nothing was sent."
        }
        return "The \(target.label) account is not ready for this conversation" +
            (exitCode == nil ? " (relayd could not be reached)" : reason.isEmpty ? "" : ": " + reason) + "; nothing was sent."
    }

    /// A move is verified only by a new agent process, bound to the same
    /// conversation, whose own environment uses the target account.
    static func verified(before: RelayAgentMaintenanceProbe, after: RelayAgentMaintenanceProbe, paneID: UUID) -> Bool {
        after.valid(for: paneID) && after.bound == true && after.sessionID == before.sessionID &&
            after.provider == before.provider && after.accountMatches == true &&
            (after.processID != before.processID || after.processStart != before.processStart)
    }
}

/// Append-only record of account moves (0600), beside the pane identities.
final class RelayAgentAccountMoveAudit: @unchecked Sendable {
    static let shared = RelayAgentAccountMoveAudit()
    struct Record: Codable, Equatable, Sendable {
        let id: String
        let at: Date
        let paneID: UUID
        let host: String
        let origin: RelayAgentAccountMoveOrigin
        let provider: String?
        let sessionID: String?
        let from: RelayAgentAccount?
        let to: RelayAgentAccount
        let state: String
        let detail: String?
    }
    private let url: URL?
    private let lock = NSLock()
    private(set) var memory: [Record] = []

    init(url: URL? = nil) {
        let testing = ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
        self.url = url ?? (testing ? nil : RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentAccounts/moves.jsonl"))
    }

    func append(_ record: Record) {
        lock.lock(); defer { lock.unlock() }
        memory.append(record)
        if memory.count > 64 { memory.removeFirst(memory.count - 64) }
        guard let url, let line = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) ?? .max <= 8 << 20 else { return }
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }
}

/// Moves one agent pane to another account of its provider at the user's
/// request: exit through the provider's own command, resume the same
/// conversation with the target account's directory, verify, and record the
/// new account. Nothing is retried; an uncertain step is reported.
@MainActor final class RelayAgentAccountMove: ObservableObject {
    static let shared = RelayAgentAccountMove()
    struct Outcome: Equatable, Sendable {
        /// refused, verified, held or unknown
        let state: String
        let message: String
        /// Why a refused, held or deferred move stopped, and how to clear it.
        var refusal: RelayPaneOperationRefusal? = nil
        /// The message with how to clear its refusal, for the UI.
        var displayMessage: String { refusal.map { message + " To clear: " + $0.howToClear } ?? message }
        /// Receipt fields: status, message, and the refusal's flat fields.
        var fields: [String: String] {
            (refusal?.fields ?? [:]).merging(["status": state, "message": message]) { $1 }
        }
    }
    /// The agent's terminal prompt as the move's admission reads it.
    struct PromptState: Equatable, Sendable {
        /// Confirmed empty, apart from footer agents relayd accounts for.
        var empty: Bool
        /// Positive evidence of typed text; false also means unknown.
        var typed = false
        /// Why the prompt was not confirmed empty.
        var blocker: String? = nil
        /// The agent-window composer is delivering a prompt.
        var delivering = false
        /// Claude's settings overlay, and nothing else, covers the prompt.
        var overlay = false
    }
    @Published private(set) var statuses: [UUID: String] = [:]
    var audit = RelayAgentAccountMoveAudit.shared
    var exitTimeout: TimeInterval = 60
    var verifyTimeout: TimeInterval = 90
    var capacityRoute: @MainActor (PaneModel) async -> Bool = { pane in
        await RelayCapacityManagementCoordinator.shared.shouldUseCombined(pane)
    }
    var capacityAction: @MainActor (PaneModel, RelayAgentAccount) async -> String = { pane, target in
        await RelayCapacityManagementCoordinator.shared.requestManual(pane, target: target)
    }

    /// How long a presented pane may take to show a readable screen.
    var screenTimeout: TimeInterval = 10
    var screenInterval: TimeInterval = 0.25
    var exitInterval: TimeInterval = 1
    var verifyInterval: TimeInterval = 3
    /// How long the resumed agent may take to become idle before its saved
    /// draft is put back.
    var draftRestoreTimeout: TimeInterval = 30
    /// A draft cleared for a move is saved here before the clear, so a crash
    /// at any later step leaves it on disk.
    var drafts = RelayAgentMaintenanceDraftStore()

    /// `force` is the user's choice to move a busy pane: Relay records the
    /// shells the agent started, interrupts its turn with one Esc, exits it
    /// with that background work still running, resumes and verifies it in
    /// the target account, tells the resumed agent what was interrupted and
    /// stopped, and then puts a saved draft back. Identity, approval, input
    /// revision, typing and screen fences still apply; only user and MCP
    /// moves can force.
    func move(_ pane: PaneModel, in workspace: WorkspaceModel, to target: RelayAgentAccount,
              origin: RelayAgentAccountMoveOrigin, inputGranted: Bool, force: Bool = false) async -> Outcome {
        let id = UUID().uuidString.lowercased()
        let profile = pane.profile
        let from = pane.agentAccount?.recorded
        let draftID = SHA256.hash(data: Data(("account-move:" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        let draftPath = drafts.directory.appendingPathComponent(draftID + ".json").path
        // A saved draft that is not back in the prompt is named in every outcome.
        var savedDraft: RelayAgentMaintenanceDraft?
        // A forced move's interrupt, named in every outcome after it was sent.
        var interrupted = false
        func record(_ state: String, _ proof: RelayAgentMaintenanceProbe?, _ detail: String?) {
            audit.append(.init(id: id, at: Date(), paneID: pane.id, host: profile.connectionKey, origin: origin,
                provider: proof?.provider ?? target.provider, sessionID: proof?.sessionID, from: from, to: target,
                state: state, detail: detail.map { String($0.prefix(300)) }))
        }
        func finish(_ state: String, _ message: String, _ proof: RelayAgentMaintenanceProbe? = nil,
                    _ code: RelayPaneOperationRefusal.Code? = nil) -> Outcome {
            let blocker = message
            var message = message
            if interrupted && state != "verified" {
                message += " Relay had interrupted the agent's turn with Esc for the forced move."
            }
            if savedDraft != nil {
                record("draft_kept", proof, draftPath)
                message += " Your unsent prompt was saved and not restored; it is kept at " + draftPath + "."
            }
            record(state, proof, message)
            // A held, refused or deferred move names its code; an unknown
            // outcome is not a refusal and must be inspected, not cleared.
            let refusal = ["refused", "held", "deferred"].contains(state)
                ? RelayPaneOperationRefusal(code ?? RelayPaneOperationRefusal.classify(blocker), blocker) : nil
            let outcome = Outcome(state: state, message: message, refusal: refusal)
            statuses[pane.id] = outcome.displayMessage
            return outcome
        }
        if let refused = RelayAgentAccountMovePolicy.originRefusal(origin, inputGranted: inputGranted) {
            return finish("refused", refused)
        }
        if force && origin != .user && origin != .mcp {
            return finish("refused", "Only the user can force an account move.")
        }
        if await capacityRoute(pane) {
            return finish("held", await capacityAction(pane, target))
        }
        if origin == .quotaFailover {
            guard RelayClaudeQuotaScheduler.shared.authorizes(pane.id, target: target) else {
                return finish("refused", "No durable quota failover intent authorizes this move.")
            }
        } else if !RelayLaunchMode.isRunningTests {
            RelayClaudeQuotaScheduler.shared.userClaimed(pane)
        }
        guard workspace.panes[pane.id] === pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              target.isValid else { return finish("refused", "The pane cannot be moved.", nil, .unsupportedPane) }
        guard RelayAgentMaintenance.shared.hold(pane.id) else {
            return finish(origin == .quotaFailover ? "deferred" : "refused", "Maintenance or another move is acting on this pane; try again when it finishes.")
        }
        defer { RelayAgentMaintenance.shared.release(pane.id) }
        guard pane.connectionState == .connected else {
            return finish("refused", "Relay cannot read this pane's screen: the pane is not connected")
        }
        // A pane not shown since Relay started has no complete screen. The
        // workspace can show a pane only by selecting it, which also takes
        // keyboard focus; the move selects it, waits a bounded time for its
        // screen, and gives the earlier selection and focus back before any
        // input is sent. The hidden renderer keeps the replayed screen.
        var shownByMove = false
        var restoreTo: (tab: UUID?, pane: UUID?)?
        func restoreSelection() {
            guard let saved = restoreTo else { return }
            restoreTo = nil
            // A selection the user made meanwhile is left alone.
            guard workspace.activePaneID == pane.id else { return }
            if let previous = saved.pane, workspace.panes[previous] != nil {
                workspace.revealPane(previous, origin: .programmatic)
            } else if let tab = saved.tab, workspace.tabs.contains(where: { $0.id == tab }) {
                workspace.selectTab(tab)
            }
        }
        defer { restoreSelection() }
        // Worker state first: a hidden pane asks its worker for one fresh
        // screen (nothing typed, no focus change). Only when that gives none
        // is the pane shown, as before.
        if screenRefusal(pane) != nil, await refreshWorkerScreen(pane), screenRefusal(pane) == nil {
            statuses[pane.id] = "Read the hidden pane's screen from its worker"
        }
        if screenRefusal(pane) != nil {
            if workspace.activePaneID != pane.id {
                shownByMove = true
                restoreTo = (workspace.selectedTabID, workspace.activePaneID)
            }
            statuses[pane.id] = "Showing the pane so Relay can read its screen"
            presentPane(pane, workspace)
            let screenDeadline = Date().addingTimeInterval(screenTimeout)
            while let unreadable = screenRefusal(pane) {
                guard workspace.panes[pane.id] === pane, pane.profile == profile, pane.connectionState == .connected else {
                    return finish("refused", "The pane changed or disconnected while Relay waited for its screen; nothing was sent.")
                }
                guard Date() < screenDeadline else {
                    return finish("refused", "Relay showed this pane but could not read its screen within " +
                        "\(Int(screenTimeout)) s (\(unreadable)); nothing was sent.", nil, .noRendererForIdleProof)
                }
                try? await Task.sleep(nanoseconds: UInt64(screenInterval * 1e9))
            }
            restoreSelection()
            if let unreadable = screenRefusal(pane) {
                return finish("refused", "Relay read this pane's screen while it was shown, but not after the earlier " +
                    "selection was restored (\(unreadable)); nothing was sent.", nil, .noRendererForIdleProof)
            }
        }
        // Input never goes to a pane that is key only because the move showed it.
        func shownForInput() -> Bool { shownByMove && workspace.activePaneID == pane.id }
        if shownForInput() {
            return finish("refused", "Relay could not give the keyboard back to the earlier selection; nothing was sent.")
        }
        // Until the exit is pending nothing has been sent, so a failed native
        // read refuses the move. A check relayd stopped at its timeout (NFS
        // stalls) is read once more.
        var exitPending = false
        var reinspected = false
        func read() async throws -> RelayAgentMaintenanceProbe {
            var proof: RelayAgentMaintenanceProbe
            do {
                proof = try await inspect(pane, target, nil)
            } catch let failure as RelayAgentMaintenanceReader.InspectFailure where failure.timedOut && !reinspected {
                reinspected = true
                record("inspect_retry", nil, failure.localizedDescription)
                proof = try await inspect(pane, target, nil)
            }
            proof.forcedByUser = force
            return proof
        }
        var stopped: [RelayForcedMoveCommand] = []
        do {
            let revision = pane.agentInputRevision
            var proof = try await read()
            guard workspace.panes[pane.id] === pane, pane.profile == profile else { return finish("refused", "The pane changed.") }
            if origin == .quotaFailover {
                guard RelayClaudeQuotaScheduler.shared.authorizes(pane.id, target: target, proof: proof) else {
                    return finish("refused", "The native agent changed after the quota move was scheduled.", proof)
                }
                let prompt = await readPrompt(pane, proof)
                guard prompt.empty, !prompt.typed, !prompt.delivering, !prompt.overlay else {
                    return finish("deferred", "Automatic account moves require a verified empty prompt; a draft or overlay is left for the user.", proof)
                }
            }
            if await readPrompt(pane, proof).overlay {
                // Claude's settings overlay hides the prompt and footer; one
                // Esc closes it, then the prompt is read as usual.
                statuses[pane.id] = "Closing Claude's settings overlay"
                record("overlay_dismiss", proof, nil)
                guard dismissOverlay(pane, proof, revision) else {
                    return finish("refused", "Claude's settings overlay covers the prompt and could not be closed; nothing was sent.", proof)
                }
                let deadline = Date().addingTimeInterval(screenTimeout)
                while Date() < deadline, workspace.panes[pane.id] === pane, pane.profile == profile {
                    let prompt = await readPrompt(pane, proof)
                    if !prompt.overlay && (prompt.empty || prompt.typed) { break }
                    try? await Task.sleep(nanoseconds: UInt64(screenInterval * 1e9))
                }
            }
            if force {
                guard proof.valid(for: pane.id), let agentPID = proof.processID else {
                    return finish("refused", proof.unavailable ?? "The agent's native identity could not be verified; nothing was sent.", proof)
                }
                if RelayAgentMaintenancePolicy.forcedNeedsInterrupt(proof) {
                    statuses[pane.id] = "Forced move: interrupting the agent's turn"
                    guard pane.pendingAgentApprovals == 0 else {
                        return finish("refused", "A permission prompt is waiting for your answer; a forced move does not answer it. Nothing was sent.", proof)
                    }
                    guard !shownForInput(), interrupt(pane, proof, revision) else {
                        return finish("refused", "Relay could not send the interrupt to the agent; nothing was sent.", proof)
                    }
                    interrupted = true
                    record("force_interrupt", proof, nil)
                    let deadline = Date().addingTimeInterval(interruptTimeout)
                    while true {
                        try await Task.sleep(nanoseconds: UInt64(verifyInterval * 1e9))
                        guard workspace.panes[pane.id] === pane, pane.profile == profile else { return finish("refused", "The pane changed.") }
                        let next = try await read()
                        // The interrupt changes the transcript and the harness
                        // status; the process and conversation must not.
                        guard next.valid(for: pane.id), next.provider == proof.provider, next.processID == proof.processID,
                              next.processStart == proof.processStart, next.sessionID == proof.sessionID,
                              next.owner == proof.owner else {
                            return finish("refused", "The agent changed after the interrupt; nothing more was sent.", next)
                        }
                        if RelayAgentMaintenancePolicy.forcedIdle(next) { proof = next; break }
                        guard Date() < deadline else {
                            return finish("refused", "The agent's turn did not stop within \(Int(interruptTimeout)) s of the interrupt; " +
                                "nothing more was sent.", next)
                        }
                    }
                }
                statuses[pane.id] = "Forced move: recording the agent's background commands"
                guard let commands = await backgroundCommands(pane, agentPID) else {
                    return finish("refused", "Relay could not read the host's process table to record the agent's background " +
                        "commands; nothing more was sent.", proof)
                }
                stopped = commands
                record("force_background", proof, commands.isEmpty ? "none" : commands.map(\.command).joined(separator: " | "))
            }
            if let refused = await admission(pane, proof: proof, target: target).refusal {
                return finish(origin == .quotaFailover && proof.moveCommand != nil && proof.resumeCommand != nil ? "deferred" : "refused",
                              refused.blocker, proof, refused.code)
            }
            // A second native read fences a turn, a draft or a session switch
            // that started during the first one.
            let fresh = try await read()
            guard workspace.panes[pane.id] === pane, pane.profile == profile, pane.agentInputRevision == revision,
                  fresh.sameSource(as: proof), fresh.moveCommand == proof.moveCommand else {
                return finish("refused", "The agent changed while the move was being checked; nothing was sent.", fresh)
            }
            let admitted = await admission(pane, proof: fresh, target: target)
            if let refused = admitted.refusal {
                return finish(origin == .quotaFailover && fresh.moveCommand != nil && fresh.resumeCommand != nil ? "deferred" : "refused",
                              refused.blocker, fresh, refused.code)
            }
            if origin == .quotaFailover && !admitted.prompt.empty {
                return finish("deferred", "A draft appeared during the automatic move; nothing was sent.", fresh)
            }
            guard let command = fresh.moveCommand, let exit = RelayAgentMaintenancePolicy.exitCommand(provider: fresh.provider) else {
                return finish("refused", "The move command is unavailable.", fresh)
            }
            if RelayAgentAccountMovePolicy.preparesTarget(origin) {
                if let refused = await prepareTarget(profile, proof: fresh, command: command, target: target) {
                    return finish("refused", refused, fresh)
                }
            }
            guard workspace.panes[pane.id] === pane, pane.profile == profile, pane.agentInputRevision == revision else {
                return finish("refused", "The pane changed while the target account was prepared; nothing was sent.", fresh)
            }
            if !admitted.prompt.empty {
                // Admission allowed a non-empty prompt only for a typed Claude
                // draft. Its exact bytes are saved before the editor clears it.
                statuses[pane.id] = "Saving the unsent prompt"
                do {
                    _ = try await editDraft(pane, fresh, revision, nil, Data()) { text in
                        guard let owner = fresh.owner, let session = fresh.sessionID else {
                            throw RelayPromptEditorRPC.Failure.changedConnection
                        }
                        let draft = try RelayAgentMaintenanceDraft(actionID: draftID, paneID: pane.id,
                            host: profile.connectionKey, sessionID: session, originalOwner: owner, text: text)
                        try self.drafts.save(draft)
                        savedDraft = draft
                        record("draft_saved", fresh, draftPath)
                    }
                } catch {
                    let reason = String(error.localizedDescription.prefix(200))
                    return savedDraft == nil
                        ? finish("refused", "The unsent prompt could not be saved (\(reason)); nothing was sent.", fresh)
                        : finish("held", "Clearing the saved prompt was not confirmed (\(reason)); nothing was sent.", fresh)
                }
                let cleared = try? await editDraft(pane, fresh, revision, Data(), nil) { _ in }
                let prompt = await readPrompt(pane, fresh)
                guard cleared == Data(), prompt.empty, workspace.panes[pane.id] === pane, pane.profile == profile,
                      pane.agentInputRevision == revision else {
                    // Nothing was sent: the same agent gets its draft back,
                    // unless input arrived since the clear.
                    var failure: String? = "it was not saved"
                    if let draft = savedDraft {
                        failure = await restoreDraft(draft, pane: pane, proof: fresh, revision: revision)
                    }
                    if failure == nil {
                        savedDraft = nil
                        record("draft_restored", fresh, nil)
                        return finish("refused", "The prompt could not be confirmed empty after its draft was saved" +
                            (prompt.blocker.map { " (\($0))" } ?? "") + "; the draft was put back and nothing was sent.", fresh)
                    }
                    return finish("held", "The prompt could not be confirmed empty after its draft was saved, and the draft " +
                        "was not put back (\(failure ?? "")); nothing was sent.", fresh)
                }
            }
            // The agent-window composer stays in place across the restart.
            pane.composerStateIfCreated?.persist(hostID: profile.id.uuidString, paneID: pane.id, immediate: true)
            guard !shownForInput() else {
                return finish("refused", "This pane is selected only because the move showed it; nothing was sent.", fresh)
            }
            exitPending = true
            record("exit_pending", fresh, nil)
            guard sendExit(pane, exit, fresh, revision) else {
                return finish("unknown", "The exit was not confirmed; nothing more was sent and nothing will be retried.", fresh)
            }
            statuses[pane.id] = "Waiting for the agent to exit"
            let afterExit = pane.agentInputRevision
            var resumable = fresh
            resumable.resumeCommand = command
            var attempted = false
            var exitDialogAnswered = false
            let exitDeadline = Date().addingTimeInterval(exitTimeout)
            while true {
                guard workspace.panes[pane.id] === pane, pane.profile == profile else {
                    return finish("unknown", "The pane changed after the agent exited; the resume was not sent.", fresh)
                }
                guard pane.agentInputRevision == afterExit else {
                    return finish("held", "Input arrived after the agent exited; the resume was not sent. Resume it yourself with the target account.", fresh)
                }
                // With background work running Claude asks before exiting; a
                // forced move chose to stop that work, so it confirms once.
                if force, !exitDialogAnswered, await confirmExitDialog(pane, fresh) {
                    exitDialogAnswered = true
                    record("force_exit_dialog", fresh, "Exit and stop tasks")
                    statuses[pane.id] = "Forced move: confirmed Exit and stop tasks"
                    try await Task.sleep(nanoseconds: UInt64(exitInterval * 1e9))
                    continue
                }
                let sent = try await resume(pane, command, resumable, afterExit) { attempted = true; record("resume_pending", fresh, nil) }
                if sent { break }
                if attempted { return finish("unknown", "The resume outcome is unknown; it was not retried.", fresh) }
                guard Date() < exitDeadline else {
                    return finish("unknown", "The agent did not return to an empty, verified shell prompt within " +
                        "\(Int(exitTimeout)) s; the resume was not sent. To resume it yourself in \(target.label), run: " + command, fresh)
                }
                try await Task.sleep(nanoseconds: UInt64(exitInterval * 1e9))
            }
            // The move's own resume input is the last it expects; any later
            // input is the user's, and a saved draft is then not put back.
            let afterResume = pane.agentInputRevision
            record("resume_submitted", fresh, nil)
            statuses[pane.id] = "Resumed in \(target.label); verifying the conversation"
            let verifyDeadline = Date().addingTimeInterval(verifyTimeout)
            while Date() < verifyDeadline {
                try await Task.sleep(nanoseconds: UInt64(verifyInterval * 1e9))
                guard workspace.panes[pane.id] === pane, pane.profile == profile else { break }
                guard let after = try? await inspect(pane, nil, target) else { continue }
                if RelayAgentAccountMovePolicy.verified(before: fresh, after: after, paneID: pane.id) {
                    pane.recordAgentAccount(target)
                    if let directory = after.configDir {
                        pane.observeAgentAccount(provider: target.provider, directory: directory, label: target.label, matches: true)
                    }
                    var moved = "Moved to \(target.label); the same conversation resumed and was verified."
                    var restoreRevision = afterResume
                    var idle: RelayAgentMaintenanceProbe?
                    if force {
                        let survivors: Set<Int>? = stopped.isEmpty ? [] : await survivingCommands(pane, stopped.map(\.pid))
                        if let notice = RelayForcedAccountMove.notice(account: target.label, interrupted: interrupted,
                                                                       commands: stopped, survivors: survivors) {
                            moved += interrupted ? " Its turn had been interrupted." : ""
                            moved += stopped.isEmpty ? "" : " Background commands found before the exit: " +
                                stopped.map { "`\($0.command)`" + ((survivors?.contains($0.pid) ?? false) ? " (still running)" : "") }
                                    .joined(separator: "; ") + "."
                            statuses[pane.id] = "Telling the agent what the forced move stopped"
                            let ready = await idleAfterResume(pane, workspace: workspace, after: after, target: target)
                            if pane.agentInputRevision == afterResume, sendNotice(pane, notice, ready, afterResume) {
                                record("force_notice", ready, notice)
                                moved += " The agent was told."
                                restoreRevision = pane.agentInputRevision
                                if savedDraft != nil {
                                    statuses[pane.id] = "Waiting for the agent to read the notice before putting the prompt back"
                                    idle = await idleAfterNotice(pane, workspace: workspace, after: ready, target: target)
                                }
                            } else {
                                record("force_notice_failed", ready, nil)
                                moved += " Relay could not submit its notice to the agent; tell it yourself."
                            }
                        }
                    }
                    guard let draft = savedDraft else { return finish("verified", moved, after) }
                    statuses[pane.id] = "Putting the unsent prompt back"
                    let settled: RelayAgentMaintenanceProbe
                    if let idle { settled = idle } else {
                        settled = await idleAfterResume(pane, workspace: workspace, after: after, target: target)
                    }
                    savedDraft = nil
                    if let failure = await restoreDraft(draft, pane: pane, proof: settled, revision: restoreRevision) {
                        record("draft_restore_failed", settled, failure)
                        return finish("verified", moved + " Your unsent prompt could not be put back (\(failure)); " +
                            "it is kept at " + draftPath + ".", settled)
                    }
                    record("draft_restored", settled, nil)
                    return finish("verified", moved + " Your unsent prompt was put back.", settled)
                }
            }
            return finish("unknown", "The resumed agent could not be verified in the \(target.label) account. Check the pane; nothing will be retried.", fresh)
        } catch {
            guard exitPending else {
                return finish("refused", "Relay could not read the agent's native state (" +
                    String(error.localizedDescription.prefix(240)) + "); nothing was sent.")
            }
            return finish("unknown", "The move could not be verified: " + String(error.localizedDescription.prefix(200)))
        }
    }

    /// Everything the target account needs before the source agent exits.
    /// Returns why the move is refused, or nil when the target is ready.
    func prepareTarget(_ profile: ConnectionProfile, proof: RelayAgentMaintenanceProbe, command: String,
                       target: RelayAgentAccount) async -> String? {
        if RelayAgentAccountMovePolicy.needsRelayCodexProfile(moveCommand: command, provider: proof.provider, target: target),
           let refused = await prepareRelayCodexProfile(profile, target) {
            return refused
        }
        if proof.provider == "claude" {
            guard let source = proof.configDir, let pid = proof.processID, pid > 1 else {
                return "The agent's own Claude account could not be read; nothing was sent."
            }
            return await prepareClaudeOnboarding(profile, source, target, pid)
        }
        return nil
    }

    /// Has relayd check, on the pane's host, that the target Claude account
    /// finished first-run onboarding and trusts the agent's folder, copying
    /// only those answers from the agent's own account when it did not.
    /// Returns why it failed, or nil once relayd verified the target.
    var prepareClaudeOnboarding: (ConnectionProfile, String, RelayAgentAccount, Int) async -> String? = { profile, source, target, pid in
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: [
            "claude-move-onboarding", source.isEmpty ? "-" : source, target.dir.isEmpty ? "-" : target.dir, String(pid)])
        let result = try? await RelayHostExecution.capture(profile: profile, command: command, timeout: 15, maximumBytes: 8_192)
        return RelayAgentAccountMovePolicy.claudeOnboardingRefusal(exitCode: result?.exitCode, stdout: result?.stdout ?? Data(),
                                                                   stderr: result?.stderr ?? Data(), target: target)
    }

    /// Writes Relay's managed `relay-terminal` Codex profile into the target
    /// account before the source agent exits. Returns why it failed, or nil.
    var prepareRelayCodexProfile: (ConnectionProfile, RelayAgentAccount) async -> String? = { profile, target in
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: ["codex-relay-profile", target.dir])
        guard let result = try? await RelayHostExecution.capture(profile: profile, command: command,
                                                                  timeout: 15, maximumBytes: 8_192) else {
            return "Relay's Codex profile could not be prepared in the \(target.label) account; nothing was sent."
        }
        guard result.exitCode == 0 else {
            // relayd names why: a stale Relay profile or a user's own file is
            // never replaced.
            let reason = String(decoding: result.stderr.prefix(400), as: UTF8.self)
                .replacingOccurrences(of: "relayd: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "Relay's Codex profile could not be prepared in the \(target.label) account" +
                (reason.isEmpty ? "" : ": " + reason) + "; nothing was sent."
        }
        return nil
    }

    /// Shows the pane, as selecting it in the workspace does.
    var presentPane: @MainActor (PaneModel, WorkspaceModel) -> Void = { pane, workspace in
        _ = try? workspace.selectWorkspacePane(pane.id)
    }
    /// Asks a hidden pane's worker for one fresh screen; true once it arrived.
    var refreshWorkerScreen: @MainActor (PaneModel) async -> Bool = { pane in
        await pane.runtime.refreshHiddenScreenBaseForInstalledUpdate()
    }
    /// Why the pane's screen cannot be read yet, or nil once it can.
    var screenRefusal: @MainActor (PaneModel) -> String? = { $0.runtime.accountMoveScreenRefusal() }
    /// A native read: with a target account it carries the move command;
    /// with an expected account it checks the resumed agent's account.
    var inspect: @MainActor (PaneModel, _ target: RelayAgentAccount?, _ expect: RelayAgentAccount?) async throws
        -> RelayAgentMaintenanceProbe = { pane, target, expect in
        try await RelayAgentMaintenanceReader.inspect(pane, targetAccount: target, expectAccount: expect)
    }
    /// The terminal prompt; the agent-window composer's text and attachments
    /// stay in place across the restart, so only its delivery holds a move.
    var readPrompt: @MainActor (PaneModel, RelayAgentMaintenanceProbe) async -> PromptState = { pane, proof in
        await pane.runtime.prepareAgentMaintenancePromptProof()
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(proof, subagents: pane.subagents)
        let empty = pane.runtime.agentMaintenanceTerminalPromptIsEmpty(explainedAgents: explained)
        return PromptState(empty: empty, typed: !empty && pane.runtime.agentMaintenanceTerminalPromptHasTypedText,
            blocker: empty ? nil : pane.runtime.agentMaintenanceTerminalPromptBlocker(explainedAgents: explained),
            delivering: pane.composerStateIfCreated.map { $0.submitting || $0.nativeDeliveryHeld } ?? false,
            overlay: !empty && pane.runtime.agentMaintenanceClaudeSettingsOverlay)
    }
    /// One Esc that closes Claude's settings overlay; false when it was not sent.
    var dismissOverlay: @MainActor (PaneModel, RelayAgentMaintenanceProbe, UInt64) -> Bool = { pane, proof, revision in
        pane.runtime.dismissClaudeSettingsOverlay(proof: proof, inputRevision: revision)
    }
    /// Claude's prompt editor bridge: (pane, proof, input revision, expected
    /// text, replacement, before apply) returns the prompt's exact bytes.
    var editDraft: @MainActor (PaneModel, RelayAgentMaintenanceProbe, UInt64, Data?, Data?, (Data) throws -> Void) async throws
        -> Data = { pane, proof, revision, expected, replacement, beforeApply in
        try await pane.runtime.editAgentMaintenanceDraft(proof: proof, inputRevision: revision,
            expected: expected, replacement: replacement, beforeApply: beforeApply)
    }
    var sendExit: @MainActor (PaneModel, String, RelayAgentMaintenanceProbe, UInt64) -> Bool = { pane, command, proof, revision in
        pane.runtime.sendAgentMaintenanceCommand(command, proof: proof, inputRevision: revision, preservingComposerDraft: true)
    }
    var resume: @MainActor (PaneModel, String, RelayAgentMaintenanceProbe, UInt64, () throws -> Void) async throws
        -> Bool = { pane, command, original, revision, willSend in
        try await pane.runtime.resumeAgentAfterMaintenance(command, original: original, inputRevision: revision, willSend: willSend)
    }

    /// How long a forced move waits for the interrupted turn to stop.
    var interruptTimeout: TimeInterval = 20
    /// How long a forced move waits for the agent to finish reading its
    /// notice before a saved draft is put back.
    var noticeTurnTimeout: TimeInterval = 300
    /// A notice turn not seen running within this long is taken as done.
    var noticeTurnStartGrace: TimeInterval = 10
    /// One Esc that interrupts the agent's turn for a forced move.
    var interrupt: @MainActor (PaneModel, RelayAgentMaintenanceProbe, UInt64) -> Bool = { pane, proof, revision in
        pane.runtime.interruptAgentTurnForForcedMove(proof: proof, inputRevision: revision)
    }
    /// The shells the agent process started, from the host's process table;
    /// nil when the table could not be read.
    var backgroundCommands: @MainActor (PaneModel, Int) async -> [RelayForcedMoveCommand]? = { pane, pid in
        guard let result = try? await RelayHostExecution.capture(profile: pane.profile,
                command: RelayForcedAccountMove.processTableCommand, timeout: 10, maximumBytes: 4 << 20),
              result.exitCode == 0 else { return nil }
        return RelayForcedAccountMove.backgroundCommands(processTable: String(decoding: result.stdout, as: UTF8.self), agentPID: pid)
    }
    /// Which of the recorded pids still run after the resume; nil when unknown.
    var survivingCommands: @MainActor (PaneModel, [Int]) async -> Set<Int>? = { pane, pids in
        guard let result = try? await RelayHostExecution.capture(profile: pane.profile,
                command: RelayForcedAccountMove.survivorCommand(pids), timeout: 10, maximumBytes: 64 << 10),
              result.exitCode == 0 else { return nil }
        return RelayForcedAccountMove.survivors(processList: String(decoding: result.stdout, as: UTF8.self), pids: pids)
    }
    /// Confirms "Exit and stop tasks" in Claude's exit dialog for a forced
    /// move; false when the dialog is not shown or nothing was sent.
    var confirmExitDialog: @MainActor (PaneModel, RelayAgentMaintenanceProbe) async -> Bool = { pane, proof in
        await pane.runtime.prepareAgentMaintenancePromptProof()
        return pane.runtime.confirmForcedExitStopTasks(proof: proof)
    }
    /// Submits Relay's notice to the resumed agent; false when it was not sent.
    var sendNotice: @MainActor (PaneModel, String, RelayAgentMaintenanceProbe, UInt64) -> Bool = { pane, text, proof, revision in
        pane.runtime.sendForcedMoveNotice(text, proof: proof, inputRevision: revision)
    }

    /// After the notice is submitted, waits, bounded, for the agent's turn
    /// on it to start and finish, so a draft is put back into an idle prompt.
    private func idleAfterNotice(_ pane: PaneModel, workspace: WorkspaceModel, after: RelayAgentMaintenanceProbe,
                                 target: RelayAgentAccount) async -> RelayAgentMaintenanceProbe {
        var proof = after
        var sawTurn = false
        let started = Date()
        let deadline = started.addingTimeInterval(noticeTurnTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(verifyInterval * 1e9))
            guard workspace.panes[pane.id] === pane else { break }
            guard let next = try? await inspect(pane, nil, target), next.valid(for: pane.id),
                  next.processID == after.processID, next.processStart == after.processStart,
                  next.sessionID == after.sessionID else { continue }
            proof = next
            let idle = next.lifecycle == "quiet" && next.backgroundWork == false &&
                (next.provider != "claude" || next.harnessStatus == nil || next.harnessStatus == "idle")
            if !idle { sawTurn = true } else if sawTurn || Date().timeIntervalSince(started) >= noticeTurnStartGrace { break }
        }
        return proof
    }

    private func admission(_ pane: PaneModel, proof: RelayAgentMaintenanceProbe,
                           target: RelayAgentAccount) async -> (refusal: RelayPaneOperationRefusal?, prompt: PromptState) {
        let prompt = await readPrompt(pane, proof)
        if prompt.delivering {
            return (.init(.operationInProgress, "Waiting for the current prompt delivery to finish; nothing was sent."), prompt)
        }
        return (RelayAgentAccountMovePolicy.refusalReason(proof, paneID: pane.id, target: target,
            emptyPrompt: prompt.empty, hasDraft: false, typedDraft: !prompt.empty && prompt.typed,
            pendingApprovals: pane.pendingAgentApprovals, inputAge: Date().timeIntervalSince(pane.agentLastInputAt),
            promptBlocker: prompt.empty ? nil : prompt.blocker), prompt)
    }

    /// The editor bridge needs an idle agent; a just-resumed one may still be
    /// settling. Re-reads, bounded, until the same verified process is quiet.
    private func idleAfterResume(_ pane: PaneModel, workspace: WorkspaceModel, after: RelayAgentMaintenanceProbe,
                                 target: RelayAgentAccount) async -> RelayAgentMaintenanceProbe {
        var proof = after
        let deadline = Date().addingTimeInterval(draftRestoreTimeout)
        while !(proof.lifecycle == "quiet" && proof.backgroundWork == false), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(verifyInterval * 1e9))
            guard workspace.panes[pane.id] === pane else { break }
            if let next = try? await inspect(pane, nil, target), next.valid(for: pane.id),
               next.processID == after.processID, next.processStart == after.processStart, next.sessionID == after.sessionID {
                proof = next
            }
        }
        return proof
    }

    /// Puts a saved draft into the agent's empty prompt once and reads it
    /// back, only while the pane's input revision is still the move's own
    /// `revision`. Returns why it failed, or nil; on failure the saved copy stays.
    private func restoreDraft(_ draft: RelayAgentMaintenanceDraft, pane: PaneModel,
                              proof: RelayAgentMaintenanceProbe, revision: UInt64) async -> String? {
        guard pane.agentInputRevision == revision else {
            return "you entered input after the move cleared the prompt, so it was left as you set it"
        }
        do {
            // Text typed since the clear is never replaced: the commit
            // expects an empty prompt.
            _ = try await editDraft(pane, proof, revision, Data(), draft.text) { _ in }
            let readback = try await editDraft(pane, proof, revision, draft.text, nil) { _ in }
            guard readback == draft.text else { return "the prompt did not read back the saved text" }
        } catch {
            return String(error.localizedDescription.prefix(200))
        }
        try? drafts.remove(draft.actionID)
        return nil
    }
}
