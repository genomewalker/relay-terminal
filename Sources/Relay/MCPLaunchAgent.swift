import CryptoKit
import Foundation

/// `relay_launch_agent`: one call starts an interactive Claude or Codex agent
/// in a new shell pane that Relay itself creates, on a chosen host, directory,
/// model and provider account, with a brief file as the initial prompt.
///
/// Everything is validated before anything is created. The request ID is
/// claimed synchronously, so one owner creates and starts exactly once; a
/// repeated identical request returns the stored receipt and only re-observes
/// the bound and provider stages. Input is typed only into the new pane's
/// verified-empty shell prompt, never into an existing pane or a live agent.
/// Admitted by the existing one-time workspace grants (create and input, plus
/// layout when stacking); nothing here requests, widens or records a grant.
struct MCPLaunchAgentProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    /// "This Mac" or an exact configured Relay SSH host alias.
    let host: String
    let cwd: String
    let provider: String
    let model: String
    let account: String
    let briefPath: String
    var targetPaneID: UUID? = nil
    var anchorTabID: UUID? = nil
    var anchorPaneID: UUID? = nil

    static let required: Set<String> = ["instance", "requestID", "host", "cwd", "provider", "model", "account", "briefPath"]
    static let keys: Set<String> = required.union(["targetPaneID", "anchorTabID", "anchorPaneID"])
    static let briefLimit = 64 << 10

    /// Exact keys, bounded body, and every field valid; nil otherwise.
    static func decode(_ body: Data) -> Self? {
        guard body.count <= 16384, (try? RelayCapacityJSON.validate(body)) != nil,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(fields.keys).isSubset(of: keys), required.isSubset(of: Set(fields.keys)),
              let proposal = try? JSONDecoder().decode(Self.self, from: body), proposal.isValid else { return nil }
        return proposal
    }

    var isValid: Bool {
        RelayAgentAccount.providers.contains(provider) && Self.validModel(model) && RelayAgentAccount.validLabel(account) &&
            Self.validPath(cwd) && Self.validPath(briefPath) && !host.isEmpty && host.utf8.count <= 256 &&
            [targetPaneID, anchorTabID, anchorPaneID].compactMap { $0 }.count <= 1
    }

    static func validModel(_ model: String) -> Bool {
        model.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Absolute, bounded, and free of control characters (newlines included):
    /// typed into a shell, so nothing that could end or continue a line.
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    var placement: String {
        if targetPaneID != nil { return "stack" }
        if anchorTabID != nil || anchorPaneID != nil { return "anchored_tab" }
        return "active_session_tab"
    }
}

/// The one shell command typed into the new pane.
enum MCPLaunchAgentCommand {
    /// The new shell exits with this when cd, reading the brief or exec fails,
    /// so a Relay launch failure is never mistaken for a provider outcome.
    static let launchFailureExitCode = 97
    /// Exits that mean the launch, not the provider, failed when no binding
    /// was seen: 97 from this command, 126/127 from env when the launcher
    /// cannot be executed.
    static let launchFailureExitCodes: Set<Int> = [97, 126, 127]
    /// sendAssistantShellCommand's input bound.
    static let commandLimit = 16 << 10

    /// POSIX single quoting: every byte literal, including $, `, \, " and newlines.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `cd` to cwd, read the brief, and exec the provider through Relay's exact
    /// managed launcher with only the account's variable set (or, for the
    /// default account, unset). The shell itself refuses an unreadable, empty
    /// or option-like brief, so a brief changed after validation can never
    /// become a CLI flag or launch an agent without it. The prompt is the last
    /// argument. nil when any value does not qualify.
    static func build(account: RelayAgentAccount, model: String, cwd: String, briefPath: String) -> String? {
        guard account.isValid, MCPLaunchAgentProposal.validModel(model),
              MCPLaunchAgentProposal.validPath(cwd), MCPLaunchAgentProposal.validPath(briefPath) else { return nil }
        let assignment = account.launchAssignment
        guard !assignment.isEmpty else { return nil }
        // `exec VAR=x prog` would try to run "VAR=x"; env takes both forms.
        let environment = assignment.hasPrefix("env ") ? assignment : "env " + assignment
        let flag = account.provider == "codex" ? "-m" : "--model"
        let failure = String(launchFailureExitCode)
        let command = "cd -- " + quote(cwd) +
            // Unquoted on purpose: an assignment does not split, and no double
            // quote surrounds the path, so `!` never meets history expansion.
            " && relay_brief=$(cat -- " + quote(briefPath) + ")" +
            " && case \"$relay_brief\" in ''|-*) exit " + failure + ";; esac" +
            " && exec " + environment + " " + RelayAgentAccount.managedShimCommand(account.provider) +
            " " + flag + " " + quote(model) + " \"$relay_brief\" || exit " + failure
        return command.utf8.count <= commandLimit ? command : nil
    }

    /// Why this brief cannot be an initial prompt, or nil. Checked on the bytes
    /// read at validation; the shell repeats the empty/option check at launch.
    static func briefRefusal(_ data: Data) -> String? {
        guard !data.isEmpty else { return "The brief is empty" }
        guard data.count <= MCPLaunchAgentProposal.briefLimit else { return "The brief exceeds 64 KiB" }
        guard let text = String(data: data, encoding: .utf8) else { return "The brief must be UTF-8 text" }
        guard !text.contains("\0") else { return "The brief contains a NUL byte" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The brief is blank" }
        // "$(cat)" keeps leading whitespace, so only a first byte of "-" is an option.
        guard !text.hasPrefix("-") else { return "The brief must not start with \"-\": the CLI would read it as an option" }
        // Both CLIs take a bare first word as a subcommand (claude mcp, codex resume).
        guard trimmed.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) == nil else {
            return "A one-word brief would be read as a CLI subcommand; write a sentence"
        }
        return nil
    }
}

/// The receipt: request summary plus four independently reported stages.
struct MCPLaunchAgentReceipt: Codable, Equatable {
    struct Request: Codable, Equatable {
        var host: String
        var cwd: String
        var provider: String
        var model: String
        var account: String
        /// The account's directory as configured ("" is the provider default).
        var configDir: String
        var configVariable: String
        var briefPath: String
        var briefBytes: Int
        var briefSHA256: String
        var placement: String
        enum CodingKeys: String, CodingKey {
            case host, cwd, provider, model, account, placement
            case configDir = "config_dir", configVariable = "config_variable", briefPath = "brief_path"
            case briefBytes = "brief_bytes", briefSHA256 = "brief_sha256"
        }
    }
    /// pending | created | failed
    struct Created: Codable, Equatable {
        var status = "pending"
        var paneID: String?
        var tabID: String?
        var reason: String?
        enum CodingKeys: String, CodingKey { case status, reason, paneID = "pane_id", tabID = "tab_id" }
    }
    /// pending | submitted | failed | not_attempted. submitted means the
    /// command was typed into the new, verified-empty shell prompt.
    struct Started: Codable, Equatable {
        var status = "pending"
        var reason: String?
    }
    /// not_attempted | pending | bound | failed
    struct Bound: Codable, Equatable {
        var status = "not_attempted"
        var provider: String?
        var pid: Int?
        var sessionID: String?
        var configDir: String?
        var account: String?
        var accountMatches: Bool?
        var transcriptPath: String?
        var reason: String?
        enum CodingKeys: String, CodingKey {
            case status, provider, pid, account, reason
            case sessionID = "session_id", configDir = "config_dir", accountMatches = "account_matches",
                 transcriptPath = "transcript_path"
        }
    }
    /// pending | admitted | refused | exited | unknown
    struct Provider: Codable, Equatable {
        var status = "pending"
        /// Assistant output was observed at some point (latched).
        var admitted: Bool?
        /// transcript | exit | none
        var evidence: String?
        var exitCode: Int?
        var excerpt: String?
        var observedModel: String?
        var detail: String?
        enum CodingKeys: String, CodingKey {
            case status, admitted, evidence, excerpt, detail
            case exitCode = "exit_code", observedModel = "observed_model"
        }
    }

    var requestID: String
    /// in_progress while the first call runs; launched once input was
    /// submitted; launch_failed when a pane was created but not started.
    var status = "in_progress"
    var request: Request
    var created = Created()
    var started = Started()
    var bound = Bound()
    var provider = Provider()
    var observedAt: String = ""
    var note = "Repeat this exact call to re-observe bound and provider; nothing is created or typed again."

    enum CodingKeys: String, CodingKey {
        case status, request, created, started, bound, provider, note
        case requestID = "request_id", observedAt = "observed_at"
    }
}

/// Pure stage decisions over what was observed; no I/O.
enum MCPLaunchAgentObservation {
    struct TranscriptEvidence: Equatable {
        var admitted = false
        var refusal: String?
        /// A Codex error event before any output. Its shape is not confirmed
        /// by Relay's own readers, so it is reported as unknown, not refused.
        var providerError: String?
        var model: String?
    }

    /// The first assistant output, a refusal or a provider API error, and the
    /// model, from a bounded transcript prefix. Malformed lines are skipped.
    static func scan(_ data: Data, provider: String) -> TranscriptEvidence {
        var evidence = TranscriptEvidence()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if provider == "claude" {
                guard row["type"] as? String == "assistant", let message = row["message"] as? [String: Any] else { continue }
                // Only an outcome before the first admitted output counts as the launch's refusal.
                if row["isApiErrorMessage"] as? Bool == true {
                    if !evidence.admitted { evidence.refusal = evidence.refusal ?? "provider API error: " + excerpt(claudeText(message)) }
                } else if message["stop_reason"] as? String == "refusal" {
                    if !evidence.admitted { evidence.refusal = evidence.refusal ?? "stop_reason refusal: " + excerpt(claudeText(message)) }
                } else {
                    evidence.admitted = true
                }
                if let model = message["model"] as? String, model != "<synthetic>", evidence.model == nil { evidence.model = model }
            } else {
                let type = row["type"] as? String
                guard let payload = row["payload"] as? [String: Any] else { continue }
                let kind = payload["type"] as? String
                if type == "turn_context", let model = payload["model"] as? String, evidence.model == nil { evidence.model = model }
                if type == "event_msg", kind == "agent_message" { evidence.admitted = true }
                if type == "response_item", kind == "message", payload["role"] as? String == "assistant" { evidence.admitted = true }
                if type == "event_msg", kind == "error", !evidence.admitted {
                    evidence.providerError = evidence.providerError ?? "provider error event: " + excerpt(payload["message"] as? String ?? "")
                }
            }
        }
        return evidence
    }

    private static func claudeText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    static func excerpt(_ text: String, limit: Int = 400) -> String {
        let flat = text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.suffix(limit))
    }

    /// The provider stage. `exitCode` is the pane's exit status once its
    /// process ended (nil while it runs). Admission and refusal latch; a
    /// refusal counts only before any admitted output.
    static func provider(_ previous: MCPLaunchAgentReceipt.Provider, evidence: TranscriptEvidence?,
                         exitCode: Int?, everBound: Bool, hasTranscriptPath: Bool, transcriptReadable: Bool,
                         screen: String?, paneClosed: Bool = false) -> MCPLaunchAgentReceipt.Provider {
        if previous.status == "refused" { return previous }
        var stage = previous
        if let model = evidence?.model { stage.observedModel = model }
        let admitted = previous.admitted == true || evidence?.admitted == true
        stage.admitted = admitted
        stage.detail = nil
        if !admitted, let refusal = evidence?.refusal {
            stage.status = "refused"; stage.evidence = "transcript"; stage.excerpt = refusal; stage.exitCode = exitCode
            return stage
        }
        if !admitted, let error = evidence?.providerError {
            stage.status = "unknown"; stage.evidence = "transcript"; stage.excerpt = error; stage.exitCode = exitCode
            stage.detail = "Codex reported an error event before any output; it may be a refusal or a transient failure."
            return stage
        }
        if let code = exitCode {
            stage.exitCode = code
            if MCPLaunchAgentCommand.launchFailureExitCodes.contains(code) && !everBound && !admitted {
                stage.status = "unknown"; stage.evidence = "none"
                stage.excerpt = screen.map { excerpt($0) }
                stage.detail = "The provider never started: the new pane exited \(code) (cd, brief, or Relay's launcher failed); see started."
                return stage
            }
            stage.evidence = "exit"
            stage.excerpt = admitted ? nil : screen.map { excerpt($0) }
            if !everBound && !admitted && code != 0 {
                stage.status = "unknown"
                stage.detail = "The pane's process exited \(code) before a verified binding; it may be the provider or Relay's launcher. See excerpt."
                return stage
            }
            if !admitted && code != 0 {
                stage.status = "refused"
                stage.detail = "The provider exited \(code) before any assistant output."
            } else {
                stage.status = "exited"
                stage.detail = admitted ? "The provider admitted the brief and later exited \(code)."
                    : "The provider exited \(code) before any assistant output."
            }
            return stage
        }
        if admitted {
            stage.status = "admitted"; stage.evidence = "transcript"
            return stage
        }
        if paneClosed {
            stage.status = "unknown"; stage.evidence = "none"
            stage.detail = "The pane was closed before any assistant output was observed."
            return stage
        }
        if everBound && !hasTranscriptPath {
            stage.status = "unknown"; stage.evidence = "none"
            stage.detail = "The verified binding names no transcript, so assistant output cannot be observed."
            return stage
        }
        stage.status = "pending"; stage.evidence = "none"
        stage.detail = !everBound ? "Waiting for the agent's verified binding."
            : transcriptReadable ? "Bound; no assistant output yet." : "Bound; the transcript is not readable yet."
        return stage
    }

    /// The bound stage from one binding read. A binding seen once latches;
    /// it is not withdrawn when the agent later exits.
    static func bound(_ previous: MCPLaunchAgentReceipt.Bound, binding: [String: Any]?, unavailable: String?,
                      exitCode: Int?, paneClosed: Bool, target: RelayAgentAccount,
                      label: (String) -> String?) -> MCPLaunchAgentReceipt.Bound {
        if previous.status == "bound" { return previous }
        var stage = previous
        if let binding, let producer = binding["producer"] as? [String: Any] {
            stage.status = "bound"
            stage.provider = producer["provider"] as? String
            stage.pid = producer["process_id"] as? Int
            stage.sessionID = binding["session_id"] as? String
            stage.transcriptPath = (binding["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let directory = producer["config_dir"] as? String {
                stage.configDir = directory
                stage.account = label(directory)
                stage.accountMatches = target.matches(observedDirectory: directory)
            } else {
                stage.configDir = nil
                stage.account = label("")
                stage.accountMatches = target.matches(observedDirectory: "")
            }
            stage.reason = stage.provider == target.provider ? nil : "Bound provider differs from the requested provider"
            return stage
        }
        if paneClosed {
            stage.status = "failed"; stage.reason = "The pane was closed before a verified binding"
        } else if let exitCode {
            stage.status = "failed"; stage.reason = "The pane exited (\(exitCode)) before a verified binding"
        } else {
            stage.status = "pending"
            stage.reason = unavailable.map { excerpt($0, limit: 300) }
        }
        return stage
    }
}

/// The verified native binding read used by relay_agent_binding.
enum MCPAgentBindingRead {
    enum Outcome {
        case bound([String: Any])
        case unavailable(String)
        case conflict(String)
    }

    @MainActor static func read(_ pane: PaneModel, paneID: UUID, workspace: WorkspaceModel) async -> Outcome {
        guard workspace.panes[paneID] === pane, pane.contentKind == .terminal else {
            return .conflict("Exact terminal pane required")
        }
        let profile = pane.profile
        do {
            let command = RelayHostExecution.daemonCommand(profile: profile,
                arguments: ["agent-binding", paneID.uuidString.lowercased()])
            let result = try await RelayHostExecution.capture(profile: profile, command: command,
                timeout: 10, maximumBytes: 65_536)
            guard workspace.panes[paneID] === pane, pane.profile == profile else {
                return .conflict("Pane or host changed during binding observation")
            }
            guard result.exitCode == 0 else {
                return .unavailable(String(String(decoding: result.stderr, as: UTF8.self).prefix(2_048)))
            }
            guard let binding = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  binding["version"] as? Int == 1,
                  let producer = binding["producer"] as? [String: Any],
                  producer["pane_id"] as? String == paneID.uuidString.lowercased() else {
                return .conflict("Binding reader returned mismatched evidence")
            }
            return .bound(binding)
        } catch {
            return .conflict("Binding observation unavailable: \(error.localizedDescription)")
        }
    }
}

@MainActor final class MCPLaunchAgentRequests {
    /// The I/O this handler performs, replaceable in tests.
    struct Environment {
        var resolveHost: @MainActor (String) -> ConnectionProfile?
        /// The host's own registry entry for provider/label; nil when absent.
        var resolveAccount: @MainActor (ConnectionProfile, String, String) async throws -> RelayAgentAccount?
        var launcherRefusal: @MainActor (ConnectionProfile, String) async -> String?
        /// True only for an existing directory.
        var isDirectory: @MainActor (ConnectionProfile, String) async throws -> Bool
        /// The whole regular file, refused above `limit` bytes.
        var readFile: @MainActor (ConnectionProfile, String, Int) async throws -> Data
        /// A bounded prefix of a file (transcripts); nil when unreadable.
        var readPrefix: @MainActor (ConnectionProfile, String, Int) async -> Data?
        /// Waits for the new pane's empty shell prompt, then types; nil once submitted.
        var start: @MainActor (PaneModel, String, ContinuousClock.Instant, @escaping @MainActor () -> Bool) async -> String?
        var readBinding: @MainActor (PaneModel, UUID, WorkspaceModel) async -> MCPAgentBindingRead.Outcome
        var screen: @MainActor (PaneModel) async -> String?
        var accountLabel: @MainActor (ConnectionProfile, String, String) -> String?
        /// Whole first call (relay-mcp's HTTP client allows 60 s), the part of
        /// it the new shell may take to show an empty prompt, and one replay's
        /// observation. A stalled host RPC can still extend a call.
        var launchBudget: Duration = .seconds(30)
        var shellBudget: Duration = .seconds(20)
        var observeBudget: Duration = .seconds(8)
        var pollInterval: Duration = .seconds(1)
    }

    private struct Entry {
        let proposal: MCPLaunchAgentProposal
        var receipt: MCPLaunchAgentReceipt
        weak var pane: PaneModel?
        var account: RelayAgentAccount?
        var profile: ConnectionProfile?
        var running = true
        var observing = false
    }
    private var entries: [UUID: Entry] = [:]
    let receiptLimit: Int

    init(receiptLimit: Int = 256) { self.receiptLimit = receiptLimit }

    static let transcriptPrefix = 4 << 20

    func launch(_ body: Data, instance: UUID, permits: @escaping (MCPWorkspaceCapability) -> Bool,
                workspace: WorkspaceModel, environment: Environment) async -> RelaySidePanelHTTPResponse {
        guard let proposal = MCPLaunchAgentProposal.decode(body), proposal.instance == instance else {
            return .text("Invalid or stale launch request: exact instance, request_id, host, absolute cwd and brief_path, provider claude or codex, model, account label, and at most one placement",
                         status: 400, reason: "Bad Request")
        }
        let needed: [MCPWorkspaceCapability] = proposal.targetPaneID != nil ? [.create, .input, .layout] : [.create, .input]
        guard needed.allSatisfy(permits) else {
            return .text("MCP terminal creation and input capabilities\(proposal.targetPaneID != nil ? " and layout" : "") are not all granted",
                         status: 403, reason: "Forbidden")
        }
        if let old = entries[proposal.requestID] {
            guard old.proposal == proposal else {
                return .text("Conflicting launch request ID", status: 409, reason: "Conflict")
            }
            return await replay(proposal.requestID, workspace: workspace, environment: environment)
        }
        // Receipts are never evicted: an evicted request_id could launch twice.
        guard entries.count < receiptLimit else {
            return .text("Agent launch receipt limit reached; restart Relay to clear receipts", status: 409, reason: "Conflict")
        }
        // Claimed before the first suspension: one owner per request ID.
        let request = MCPLaunchAgentReceipt.Request(host: proposal.host, cwd: proposal.cwd, provider: proposal.provider,
            model: proposal.model, account: proposal.account, configDir: "", configVariable: RelayAgentAccount.variable(proposal.provider),
            briefPath: proposal.briefPath, briefBytes: 0, briefSHA256: "", placement: proposal.placement)
        entries[proposal.requestID] = Entry(proposal: proposal,
            receipt: MCPLaunchAgentReceipt(requestID: proposal.requestID.uuidString.lowercased(), request: request))
        let deadline = ContinuousClock.now + environment.launchBudget

        // 1. Validate; nothing exists yet, so a refusal releases the claim.
        func refuse(_ text: String, status: Int = 409) -> RelaySidePanelHTTPResponse {
            entries[proposal.requestID] = nil
            return .text(text + ". Nothing was created.", status: status,
                         reason: status == 400 ? "Bad Request" : "Conflict")
        }
        guard let profile = environment.resolveHost(proposal.host) else {
            return refuse("Use This Mac or an exact configured SSH host alias", status: 400)
        }
        let account: RelayAgentAccount
        do {
            guard let found = try await environment.resolveAccount(profile, proposal.provider, proposal.account), found.isValid else {
                return refuse("There is no \(proposal.provider) account named \(proposal.account) on \(proposal.host)")
            }
            account = found
        } catch {
            return refuse("The \(proposal.provider) accounts of \(proposal.host) could not be read: \(error.localizedDescription)")
        }
        if let refusal = await environment.launcherRefusal(profile, proposal.provider) {
            return refuse(refusal.replacingOccurrences(of: " Nothing was typed.", with: ""))
        }
        do {
            guard try await environment.isDirectory(profile, proposal.cwd) else {
                return refuse("cwd is not a directory on \(proposal.host)")
            }
        } catch {
            return refuse("cwd is not an accessible directory on \(proposal.host): \(error.localizedDescription)")
        }
        let brief: Data
        do {
            brief = try await environment.readFile(profile, proposal.briefPath, MCPLaunchAgentProposal.briefLimit)
        } catch {
            return refuse("brief_path is not a readable regular file of at most 64 KiB on \(proposal.host): \(error.localizedDescription)")
        }
        if let refusal = MCPLaunchAgentCommand.briefRefusal(brief) { return refuse(refusal) }
        guard let command = MCPLaunchAgentCommand.build(account: account, model: proposal.model,
                                                        cwd: proposal.cwd, briefPath: proposal.briefPath) else {
            return refuse("The launch command could not be built from these values")
        }
        guard needed.allSatisfy(permits) else {
            return refuse("A required workspace capability was withdrawn", status: 409)
        }
        entries[proposal.requestID]?.receipt.request.configDir = account.dir
        entries[proposal.requestID]?.receipt.request.briefBytes = brief.count
        entries[proposal.requestID]?.receipt.request.briefSHA256 = SHA256.hash(data: brief).map { String(format: "%02x", $0) }.joined()
        entries[proposal.requestID]?.account = account
        entries[proposal.requestID]?.profile = profile

        // 2. Create. Synchronous from here to the recorded pane.
        let before = Set(workspace.panes.keys)
        let created = Self.create(proposal, profile: profile, workspace: workspace, before: before)
        let pane: PaneModel
        switch created {
        case .refused(let reason):
            return refuse("The pane could not be created: \(reason)")
        case .createdUnusable(let paneID, let tabID, let reason):
            update(proposal.requestID) {
                $0.receipt.created = .init(status: "failed", paneID: paneID.map(Self.id), tabID: tabID.map(Self.id),
                                           reason: reason + "; a pane was created but nothing was typed into it")
                $0.receipt.started = .init(status: "not_attempted", reason: "creation did not complete")
                $0.receipt.provider = .init(status: "unknown", evidence: "none", detail: "No agent was started.")
                $0.receipt.status = "launch_failed"
                $0.running = false
            }
            return finish(proposal.requestID)
        case .created(let made, let tabID):
            pane = made
            update(proposal.requestID) {
                $0.pane = made
                $0.receipt.created = .init(status: "created", paneID: Self.id(made.id), tabID: Self.id(tabID))
            }
        }

        // 3. Start: only this new pane's verified-empty shell prompt.
        let paneID = pane.id
        let authorized: @MainActor () -> Bool = { [weak workspace] in
            needed.allSatisfy(permits) && workspace?.panes[paneID] === pane
        }
        // The shell gets part of the budget; the rest is for a first observation.
        let shellDeadline = min(deadline, ContinuousClock.now + environment.shellBudget)
        if let reason = await environment.start(pane, command, shellDeadline, authorized) {
            update(proposal.requestID) {
                $0.receipt.started = .init(status: "failed", reason: reason)
                $0.receipt.provider = .init(status: "unknown", evidence: "none", detail: "No agent was started.")
                $0.receipt.status = "launch_failed"
                $0.running = false
            }
            return finish(proposal.requestID)
        }
        pane.recordAgentAccount(account)
        update(proposal.requestID) {
            $0.receipt.started = .init(status: "submitted")
            $0.receipt.status = "launched"
            $0.receipt.bound.status = "pending"
        }

        // 4–5. Observe binding and provider outcome until settled or the budget
        // ends; a call that used its budget returns pending for the client to poll.
        while ContinuousClock.now < deadline {
            await observe(proposal.requestID, workspace: workspace, environment: environment)
            guard let receipt = entries[proposal.requestID]?.receipt else { break }
            let settled = receipt.bound.status != "pending" && receipt.provider.status != "pending"
            if settled || ContinuousClock.now + environment.pollInterval >= deadline { break }
            try? await Task.sleep(for: environment.pollInterval)
        }
        update(proposal.requestID) { $0.running = false }
        return finish(proposal.requestID)
    }

    /// The stored receipt; after the first call, bound and provider are
    /// observed again (never created, typed or retried).
    private func replay(_ requestID: UUID, workspace: WorkspaceModel, environment: Environment) async -> RelaySidePanelHTTPResponse {
        guard let entry = entries[requestID] else { return .text("Receipt expired", status: 409, reason: "Conflict") }
        if !entry.running, !entry.observing, entry.receipt.started.status == "submitted" {
            entries[requestID]?.observing = true
            let deadline = ContinuousClock.now + environment.observeBudget
            while true {
                await observe(requestID, workspace: workspace, environment: environment)
                guard let receipt = entries[requestID]?.receipt else { break }
                let settled = receipt.bound.status != "pending" && receipt.provider.status != "pending"
                if settled || ContinuousClock.now + environment.pollInterval >= deadline { break }
                try? await Task.sleep(for: environment.pollInterval)
            }
            entries[requestID]?.observing = false
        }
        return finish(requestID)
    }

    private func observe(_ requestID: UUID, workspace: WorkspaceModel, environment: Environment) async {
        guard let entry = entries[requestID], entry.receipt.started.status == "submitted",
              let account = entry.account, let profile = entry.profile else { return }
        // The entry holds the pane weakly; a closed pane may already be gone.
        let pane = entry.pane
        func live() -> PaneModel? { pane.flatMap { workspace.panes[$0.id] === $0 ? $0 : nil } }
        var binding: [String: Any]?, unavailable: String?
        if entry.receipt.bound.status != "bound", let current = live() {
            switch await environment.readBinding(current, current.id, workspace) {
            case .bound(let value): binding = value
            case .unavailable(let reason), .conflict(let reason): unavailable = reason
            }
        }
        let exitCode = live()?.remoteExitCode
        let paneClosed = live() == nil
        guard var receipt = entries[requestID]?.receipt else { return }
        receipt.bound = MCPLaunchAgentObservation.bound(receipt.bound, binding: binding, unavailable: unavailable,
            exitCode: exitCode, paneClosed: paneClosed, target: account,
            label: { environment.accountLabel(profile, account.provider, $0) })
        var evidence: MCPLaunchAgentObservation.TranscriptEvidence?
        var readable = false
        if receipt.provider.status != "refused", receipt.provider.admitted != true,
           let path = receipt.bound.transcriptPath {
            if let data = await environment.readPrefix(profile, path, Self.transcriptPrefix) {
                evidence = MCPLaunchAgentObservation.scan(data, provider: account.provider)
                readable = true
            }
        }
        var screen: String?
        if exitCode != nil, let current = live() { screen = await environment.screen(current) }
        guard entries[requestID] != nil else { return }
        receipt.provider = MCPLaunchAgentObservation.provider(receipt.provider, evidence: evidence, exitCode: exitCode,
            everBound: receipt.bound.status == "bound", hasTranscriptPath: receipt.bound.transcriptPath != nil,
            transcriptReadable: readable, screen: screen, paneClosed: paneClosed)
        if receipt.bound.status == "failed", let code = exitCode, MCPLaunchAgentCommand.launchFailureExitCodes.contains(code) {
            receipt.started = .init(status: "failed",
                reason: "The new pane exited \(code) before a binding: cd to cwd, reading the brief, or executing Relay's launcher failed")
            receipt.status = "launch_failed"
        }
        receipt.observedAt = ISO8601DateFormatter().string(from: Date())
        // Only the observed stages change; created is the owner's alone.
        entries[requestID]?.receipt.bound = receipt.bound
        entries[requestID]?.receipt.provider = receipt.provider
        entries[requestID]?.receipt.started = receipt.started
        entries[requestID]?.receipt.status = receipt.status
        entries[requestID]?.receipt.observedAt = receipt.observedAt
    }

    private func update(_ requestID: UUID, _ change: (inout Entry) -> Void) {
        guard var entry = entries[requestID] else { return }
        change(&entry)
        entries[requestID] = entry
    }

    private func finish(_ requestID: UUID) -> RelaySidePanelHTTPResponse {
        guard var receipt = entries[requestID]?.receipt else { return .text("Receipt expired", status: 409, reason: "Conflict") }
        if receipt.observedAt.isEmpty { receipt.observedAt = ISO8601DateFormatter().string(from: Date()) }
        return .json(receipt)
    }

    private static func id(_ value: UUID) -> String { value.uuidString.lowercased() }

    enum Creation {
        case created(PaneModel, tabID: UUID)
        case createdUnusable(UUID?, UUID?, String)
        case refused(String)
    }

    /// Creates the shell pane with the existing placement paths and proves
    /// the result is a new shell pane on `profile`, never an existing pane.
    static func create(_ proposal: MCPLaunchAgentProposal, profile: ConnectionProfile, workspace: WorkspaceModel,
                       before: Set<UUID>) -> Creation {
        func fresh() -> [UUID] { workspace.panes.keys.filter { !before.contains($0) } }
        var paneID: UUID?, tabID: UUID?
        do {
            if let target = proposal.targetPaneID {
                guard workspace.panes[target] != nil else { return .refused("target_pane_id is not a pane") }
                let made = try workspace.newStackedPane(onto: target, profile: profile)
                (paneID, tabID) = (made.paneID, made.tabID)
            } else if proposal.anchorTabID != nil || proposal.anchorPaneID != nil {
                let made = try workspace.newLocalTab(anchorPaneID: proposal.anchorPaneID, anchorTabID: proposal.anchorTabID,
                                                     profile: profile)
                (paneID, tabID) = (made.paneID, made.tabID)
            } else {
                // No anchor: a new tab in the active session, filed like an MCP tab.
                workspace.newTabInActiveSession(profile: profile, origin: .agent(sourcePane: nil))
                (paneID, tabID) = (workspace.activePaneID, workspace.selectedTabID)
            }
        } catch {
            let made = fresh()
            if made.isEmpty { return .refused(error.localizedDescription) }
            return .createdUnusable(made.first, made.first.flatMap { workspace.tabID(containingPane: $0) },
                                    error.localizedDescription)
        }
        let made = fresh()
        guard let paneID, let tabID, made == [paneID], let pane = workspace.panes[paneID],
              pane.profile == profile, pane.contentKind == .terminal, pane.kind == .shell,
              workspace.tabID(containingPane: paneID) == tabID else {
            if made.isEmpty { return .refused("no new pane appeared") }
            return .createdUnusable(made.first, made.first.flatMap { workspace.tabID(containingPane: $0) },
                                    "the new pane could not be verified as this request's shell")
        }
        return .created(pane, tabID: tabID)
    }
}

extension MCPLaunchAgentRequests.Environment {
    /// The production environment: Relay's host RPC, account registry,
    /// binding reader and the openTab start sequence.
    @MainActor static func live(resolveHost: @escaping @MainActor (String) -> ConnectionProfile?) -> Self {
        Self(
            resolveHost: resolveHost,
            resolveAccount: { profile, provider, label in
                let directory = RelayAgentAccountDirectory.shared
                if directory.registeredAccounts(for: profile, provider: provider) == nil {
                    _ = try await directory.refresh(profile)
                }
                // Never the built-in defaults: only the host's own registry.
                return directory.registeredAccounts(for: profile, provider: provider)?.first { $0.label == label }
            },
            launcherRefusal: { profile, provider in
                await RelayAgentAccountDirectory.shared.managedLauncherRefusal(profile, provider: provider)
            },
            isDirectory: { profile, path in
                let stat = try await RelayHostFiles.request(context: RelayExecutionContext(profile: profile, directory: "/"),
                                                            fields: ["operation": "file_stat", "path": path])
                return stat["directory"] as? Bool == true
            },
            readFile: { profile, path, limit in
                // file_read admits only a regular file, so a FIFO or device is refused.
                try await RelayHostFiles.file(path: path, cwd: "/", profile: profile, maxBytes: limit)
            },
            readPrefix: { profile, path, limit in
                guard path.hasPrefix("/") else { return nil }
                let context = RelayExecutionContext(profile: profile, directory: "/")
                guard let stat = try? await RelayHostFiles.request(context: context, fields: ["operation": "file_stat", "path": path]),
                      stat["directory"] as? Bool == false, let size = stat["size"] as? Int, size >= 0,
                      let version = stat["version"] as? String else { return nil }
                guard size > 0 else { return Data() }
                let length = min(size, limit)
                guard let chunk = try? await RelayHostFiles.request(context: context, fields: ["operation": "file_read",
                          "path": path, "version": version, "offset": 0, "length": length]),
                      let encoded = chunk["data"] as? String, let data = Data(base64Encoded: encoded),
                      data.count <= length,
                      chunk["sha256"] as? String == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                else { return nil }
                // Only whole lines; a partially written last line is dropped.
                if let last = data.lastIndex(of: UInt8(ascii: "\n")) { return data[...last] }
                return Data()
            },
            start: { pane, command, deadline, authorized in
                // As WorkspaceModel.openTab: connected, a shell, and an empty
                // prompt owned by its shell before anything is typed.
                while true {
                    guard authorized(), !Task.isCancelled else { return "The pane or a workspace capability changed before input. Nothing was typed." }
                    if pane.connectionState == .connected, pane.kind == .shell, pane.runtime.assistantShellPromptIsEmpty() { break }
                    guard ContinuousClock.now < deadline else {
                        return "The new pane's shell prompt was not verified empty in time. Nothing was typed."
                    }
                    try? await Task.sleep(nanoseconds: 125_000_000)
                }
                guard await pane.runtime.sendAssistantShellCommand(command, authorization: authorized) else {
                    return "The new pane's shell refused the launch command (prompt not empty or not owned by its shell). Nothing was typed."
                }
                return nil
            },
            readBinding: { pane, paneID, workspace in await MCPAgentBindingRead.read(pane, paneID: paneID, workspace: workspace) },
            screen: { pane in await pane.runtime.backgroundViewportText() },
            accountLabel: { profile, provider, directory in
                RelayAgentAccountDirectory.shared.account(for: profile, provider: provider, observedDirectory: directory)?.label
            })
    }
}
