import CryptoKit
import Foundation

// Plan cards: one card, an ordered list of steps, one Run. Every step is an
// MCP control request (same routes as single cards); a step may target the pane
// an earlier step created ("pane created by step 1"), filled in at Run.

/// A step's pane: an existing snapshot pane, or the pane an earlier step created.
enum RelayAssistantPaneRef: Equatable, Sendable {
    case pane(UUID)
    case step(Int)

    var label: String {
        switch self {
        case .pane(let id): id.uuidString.lowercased()
        case .step(let index): "pane created by step \(index)"
        }
    }
}

struct RelayAssistantPlanStep: Equatable {
    enum Op: String, CaseIterable, Sendable {
        case newTab = "new_tab", split, startAgent = "start_agent", sendCommand = "send_command", link, select
        case agentCommand = "agent_command"
        /// Never accepted from the model: a send_command step that carries a
        /// message to an agent, sent through message_pane instead of typed.
        case message
        static let proposable = allCases.filter { $0 != .message }
    }
    let index: Int
    var op: Op
    let requestID: UUID
    var target: RelayAssistantPaneRef
    var source: RelayAssistantPaneRef? = nil
    var host: String? = nil
    var directory: String? = nil
    var action: String? = nil
    var text: String? = nil
    var agent: String? = nil
    /// start_agent: the account label the model asked for (nil: the
    /// workspace default), and the account resolved for the card.
    var account: String? = nil
    var launchAccount: RelayAgentAccount? = nil
    /// start_agent: the existing pane whose workspace owns the target (the
    /// pane itself, or the source an earlier new_tab/split creates beside),
    /// and that workspace as captured for the card. The launch is refused if
    /// the target's owner differs when the step runs.
    var ownerPane: UUID? = nil
    var launchWorkspace: UUID? = nil
    /// The exact effect shown on the card (escaped).
    var description = ""
    var blockedReason: String? = nil
    /// Typing steps: the input revision proven empty (at proposal for an
    /// existing pane, at Run for a pane an earlier step created).
    var inputRevision: UInt64? = nil
    /// start_agent: the launch contract shown on the card.
    var launchFingerprint: String? = nil
    /// message: the verified recipient conversation shown on the card (nil for
    /// a pane this plan creates; verified when the step runs).
    var recipient: RelayAssistantRecipient? = nil

    var createsPane: Bool { op == .newTab || op == .split }
    var requiredCapabilities: [MCPWorkspaceCapability] {
        switch op {
        case .newTab: [.create]
        case .split: [.create, .layout]
        case .startAgent, .sendCommand, .agentCommand, .message: [.input]
        case .link: [.layout]
        case .select: [.navigate]
        }
    }
}

/// How Relay itself starts an agent in a pane: the shell resolves `codex` or
/// `claude` to Relay's shim, which runs relayd's managed launch.
/// - claude: relayd's runClaude execs `claude --settings ~/.relay/claude-hooks.json`
///   and regenerates that hooks file at every launch; the assistant types `claude`.
/// - codex: the shim applies ~/.codex/relay-launch-defaults.json unless explicit
///   permission flags are given. The assistant types the defaults resolved at
///   proposal as explicit flags, so a later change to the defaults cannot alter
///   what runs, and also refuses at Run if the defaults or shim changed.
struct RelayAssistantLaunch: Equatable, Sendable {
    let agent: String
    let typed: String
    let resolved: String
    let blockedReason: String?
    /// Shim version plus resolved permissions; compared again at Run.
    var fingerprint: String = ""

    static let shimDirectory = "~/.local/share/relay/shims"
    static let codexDefaults = "~/.codex/relay-launch-defaults.json"
    static let claudeSettings = "~/.relay/claude-hooks.json"
    static let sandboxModes: Set<String> = ["read-only", "workspace-write", "danger-full-access"]
    static let approvalPolicies: Set<String> = ["untrusted", "on-failure", "on-request", "never"]

    /// `stat`/`read` are host file RPCs (file_stat / file_read through the MCP host route).
    @MainActor static func resolve(agent: String, stat: (String) async -> [String: Any]?,
                                   read: (String, String, Int) async -> Data?) async -> Self {
        await resolve(agent: agent, account: nil, stat: stat, read: read)
    }

    /// The launch in one provider account: the account variable prefixes the
    /// typed command (the default account unsets it) and the program is the
    /// exact managed launcher, never a PATH lookup. Codex's launch defaults
    /// are read from that account's CODEX_HOME (as relayd applies them), and
    /// the fingerprint includes the account and the launcher.
    @MainActor static func resolve(agent: String, account: RelayAgentAccount?, stat: (String) async -> [String: Any]?,
                                   read: (String, String, Int) async -> Data?) async -> Self {
        let account = account.flatMap { $0.provider == agent && $0.isValid ? $0 : nil }
        let codexDefaults = account.map { $0.dir.isEmpty ? Self.codexDefaults : $0.dir + "/relay-launch-defaults.json" } ?? Self.codexDefaults
        let base = await resolveDefault(agent: agent, codexDefaults: codexDefaults, stat: stat, read: read)
        guard let account else { return base }
        let typed = account.launchCommand(base.typed)
        return Self(agent: agent, typed: typed,
            resolved: base.blockedReason == nil ? account.launchCommand(base.resolved) + " (account \(account.label))" : base.resolved,
            blockedReason: base.blockedReason ?? (typed.isEmpty ? "Relay could not build the \(agent) launch for the \(account.label) account." : nil),
            fingerprint: base.fingerprint + "|account:\(account.label):\(account.dir)|launcher:" + RelayAgentAccount.managedShimCommand(agent))
    }

    @MainActor private static func resolveDefault(agent: String, codexDefaults: String, stat: (String) async -> [String: Any]?,
                                                  read: (String, String, Int) async -> Data?) async -> Self {
        let shim = shimDirectory + "/" + agent
        guard let info = await stat(shim), info["directory"] as? Bool == false else {
            return Self(agent: agent, typed: agent, resolved: "unavailable",
                blockedReason: "Relay's \(agent) launcher (\(shim)) was not found on this host, so typing \(agent) would bypass Relay's launch path.")
        }
        let shimVersion = info["version"] as? String ?? ""
        if agent == "claude" {
            return Self(agent: agent, typed: "claude",
                resolved: "claude → relayd: claude --settings \(claudeSettings) (hooks file regenerated by relayd at launch; shim \(shim))",
                blockedReason: nil, fingerprint: "claude|" + shimVersion)
        }
        guard let defaults = await stat(codexDefaults), let version = defaults["version"] as? String,
              let size = defaults["size"] as? Int, (1...4096).contains(size),
              let data = await read(codexDefaults, version, size),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["version"] as? Int == 1, Set(value.keys) == ["version", "sandbox_mode", "approval_policy"],
              let sandbox = value["sandbox_mode"] as? String, sandboxModes.contains(sandbox),
              let approval = value["approval_policy"] as? String, approvalPolicies.contains(approval) else {
            return Self(agent: agent, typed: "codex", resolved: "unavailable",
                blockedReason: "Relay's Codex launch defaults (\(codexDefaults)) could not be read on this host, so the usual permissions are unknown.")
        }
        let typed = "codex --sandbox \(sandbox) --ask-for-approval \(approval)"
        return Self(agent: agent, typed: typed,
            resolved: typed + " → relayd managed Codex (permissions frozen from \(codexDefaults); shim \(shim))",
            blockedReason: nil, fingerprint: "codex|\(shimVersion)|\(sandbox)|\(approval)")
    }
}

enum RelayAssistantPlan {
    static let maxSteps = 8

    /// Validates `propose_plan` input against the snapshot. Pane references are
    /// "here", a snapshot pane ID, or "step:N" for a pane an earlier step created.
    static func validate(_ fields: [String: RelayPaneHealthJSON], snapshot: RelayAssistantSnapshot)
        -> Result<[RelayAssistantPlanStep], RelayAssistantToolError> {
        func fail(_ message: String) -> Result<[RelayAssistantPlanStep], RelayAssistantToolError> { .failure(.init(message: message)) }
        guard Set(fields.keys) == ["steps"], case .array(let raw)? = fields["steps"], (1...maxSteps).contains(raw.count) else {
            return fail("steps must be a list of 1 to \(maxSteps) steps.")
        }
        var steps: [RelayAssistantPlanStep] = []
        // Host and directory of each step's created pane, for defaults.
        var createdPlacement: [Int: (host: String?, directory: String?)] = [:]
        for (offset, item) in raw.enumerated() {
            let index = offset + 1
            guard case .object(let step) = item, case .string(let opName)? = step["op"],
                  let op = RelayAssistantPlanStep.Op(rawValue: opName), op != .message else {
                return fail("Step \(index): op must be one of " + RelayAssistantPlanStep.Op.proposable.map(\.rawValue).joined(separator: ", ") + ".")
            }
            let allowed: Set<String> = switch op {
            case .newTab: ["op", "pane", "host", "directory"]
            case .split: ["op", "pane", "direction", "host", "directory"]
            case .startAgent: ["op", "pane", "agent", "account"]
            case .sendCommand, .agentCommand: ["op", "pane", "text"]
            case .link: ["op", "pane", "source_pane"]
            case .select, .message: ["op", "pane"]
            }
            guard Set(step.keys).isSubset(of: allowed) else {
                return fail("Step \(index): unexpected fields " + Set(step.keys).subtracting(allowed).sorted().joined(separator: ", ") + ".")
            }
            func string(_ key: String) -> String? { if case .string(let v)? = step[key] { v } else { nil } }
            func reference(_ key: String, required: Bool = true) -> Result<RelayAssistantPaneRef?, RelayAssistantToolError> {
                guard let raw = string(key) else {
                    if step[key] == nil && !required { return .success(nil) }
                    // A step without a pane acts from "here" (else the selected pane).
                    if step[key] == nil, key == "pane", let id = snapshot.here?.paneID ?? snapshot.selectedPaneID {
                        return .success(.pane(id))
                    }
                    return .failure(.init(message: "Step \(index): \(key) is required."))
                }
                if raw == "here" {
                    guard let here = snapshot.here else { return .failure(.init(message: "Step \(index): there is no 'here' pane.")) }
                    return .success(.pane(here.paneID))
                }
                if raw.hasPrefix("step:"), let n = Int(raw.dropFirst(5)) {
                    guard n >= 1, n < index, steps[n - 1].createsPane else {
                        return .failure(.init(message: "Step \(index): \(raw) must name an earlier new_tab or split step."))
                    }
                    return .success(.step(n))
                }
                guard let id = UUID(uuidString: raw), snapshot.pane(id) != nil else {
                    return .failure(.init(message: "Step \(index): \(key) must be 'here', 'step:N' or a pane ID from the snapshot."))
                }
                return .success(.pane(id))
            }
            guard case .success(let targetValue) = reference("pane"), let target = targetValue else {
                if case .failure(let error) = reference("pane") { return .failure(error) }
                return fail("Step \(index): pane is required.")
            }
            var planStep = RelayAssistantPlanStep(index: index, op: op, requestID: UUID(), target: target)
            if case .pane(let id) = target, let pane = snapshot.pane(id), pane.contentKind != "terminal", op != .select {
                return fail("Step \(index): the pane must be a terminal.")
            }
            switch op {
            case .newTab, .split:
                if op == .split {
                    let direction = step["direction"] == nil ? "right" : string("direction")
                    guard let direction, ["right", "down"].contains(direction) else {
                        return fail("Step \(index): direction must be right or down.")
                    }
                    planStep.action = direction == "right" ? "splitRight" : "splitDown"
                } else {
                    planStep.action = "newTab"
                }
                // Defaults: the source pane's host and directory (or the step that created it).
                let sourceHost: String?, sourceDirectory: String?
                switch target {
                case .pane(let id): (sourceHost, sourceDirectory) = (snapshot.pane(id)?.hostAlias, snapshot.paneDirectories[id])
                case .step(let n): (sourceHost, sourceDirectory) = createdPlacement[n] ?? (nil, nil)
                }
                var host = sourceHost
                if let value = step["host"] {
                    guard case .string(let name) = value, snapshot.hosts.contains(name) else {
                        return fail("Step \(index): host must be in the snapshot's hosts (workspace or configured Relay hosts).")
                    }
                    host = name
                }
                var directory = host == sourceHost ? sourceDirectory : nil
                if let value = step["directory"] {
                    guard case .string(let path) = value, let host, snapshot.admitsDirectory(path, host: host) else {
                        return fail("Step \(index): directory must be a known pane directory or a folder resolved with find_project_folder on that host.")
                    }
                    directory = path
                }
                planStep.host = host
                planStep.directory = directory
                createdPlacement[index] = (host, directory)
            case .startAgent:
                guard let agent = string("agent"), ["codex", "claude"].contains(agent) else {
                    return fail("Step \(index): agent must be codex or claude.")
                }
                // Launcher text is typed, so only into a shell: an existing shell
                // pane, or one an earlier new_tab/split step creates, launched once.
                if case .pane(let id) = target, snapshot.pane(id)?.kind != "shell" {
                    return fail("Step \(index): start_agent needs a shell pane; this pane runs \(snapshot.pane(id)?.kind ?? "an unknown program"). "
                        + "Use agent_command for a slash command or message_pane for words.")
                }
                guard !steps.contains(where: { $0.op == .startAgent && $0.target == target }) else {
                    return fail("Step \(index): an earlier step already starts an agent in this pane.")
                }
                if let value = step["account"] {
                    guard case .string(let label) = value, RelayAgentAccount.validLabel(label) else {
                        return fail("Step \(index): account must be an account label such as work or personal.")
                    }
                    planStep.account = label
                }
                planStep.agent = agent
                planStep.text = agent
                planStep.host = hostOf(target, snapshot: snapshot, created: createdPlacement)
                planStep.ownerPane = ownerPane(target, before: steps)
            case .sendCommand:
                guard let text = string("text"), !text.isEmpty, text.count <= 8192,
                      !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
                    return fail("Step \(index): text must be 1 to 8192 characters without control characters other than newline or tab.")
                }
                planStep.text = text
                planStep.host = hostOf(target, snapshot: snapshot, created: createdPlacement)
            case .agentCommand:
                guard let text = string("text"), RelayAssistantActions.isAgentCommand(text) else {
                    return fail("Step \(index): agent_command text must be one slash command line (/name, optional arguments up to 200 characters) without newline or control characters.")
                }
                guard agentPane(target, before: steps, snapshot: snapshot) else {
                    return fail("Step \(index): agent_command needs a Claude/Codex pane or a pane an earlier start_agent step starts.")
                }
                planStep.text = text
                planStep.host = hostOf(target, snapshot: snapshot, created: createdPlacement)
            case .link:
                guard case .success(let source) = reference("source_pane"), let source else {
                    return fail("Step \(index): source_pane must be 'here', 'step:N' or a snapshot pane ID.")
                }
                guard source != target else { return fail("Step \(index): a pane cannot be linked to itself.") }
                planStep.source = source
            case .select, .message:
                break
            }
            steps.append(planStep)
        }
        return .success(steps)
    }

    /// The existing pane a reference is created beside: a created pane is
    /// filed in its source pane's workspace, followed back to a snapshot pane.
    static func ownerPane(_ reference: RelayAssistantPaneRef, before steps: [RelayAssistantPlanStep]) -> UUID? {
        switch reference {
        case .pane(let id): id
        case .step(let n): steps.first { $0.index == n && $0.createsPane }.flatMap { ownerPane($0.target, before: steps) }
        }
    }

    /// Claude/Codex in the snapshot, or a pane an earlier step starts an agent in.
    static func agentPane(_ target: RelayAssistantPaneRef, before steps: some Collection<RelayAssistantPlanStep>,
                          snapshot: RelayAssistantSnapshot) -> Bool {
        if case .pane(let id) = target, ["claude", "codex"].contains(snapshot.pane(id)?.kind ?? "") { return true }
        return steps.contains { $0.op == .startAgent && $0.target == target }
    }

    /// The single-card routing guard, per step: a send_command step aimed at an
    /// agent pane always becomes a message step; slash commands use
    /// agent_command. Typing into a fresh shell pane, including a launch
    /// command, stays send_command.
    static func routeMessages(_ steps: [RelayAssistantPlanStep], snapshot: RelayAssistantSnapshot) -> [RelayAssistantPlanStep] {
        var steps = steps
        for index in steps.indices where steps[index].op == .sendCommand &&
            agentPane(steps[index].target, before: steps[..<index], snapshot: snapshot) {
            steps[index].op = .message
        }
        return steps
    }

    static func hostOf(_ ref: RelayAssistantPaneRef, snapshot: RelayAssistantSnapshot,
                       created: [Int: (host: String?, directory: String?)]) -> String? {
        switch ref {
        case .pane(let id): snapshot.pane(id)?.hostAlias
        case .step(let n): created[n]?.host ?? nil
        }
    }

    /// The exact, escaped effect of each step.
    static func describe(_ step: RelayAssistantPlanStep, snapshot: RelayAssistantSnapshot) -> String {
        func pane(_ ref: RelayAssistantPaneRef) -> String {
            switch ref {
            case .pane(let id): RelayAssistantActions.q(snapshot.pane(id)?.title ?? "") + " · " + id.uuidString.lowercased()
            case .step: ref.label
            }
        }
        let host = step.host.map(RelayAssistantActions.q) ?? "host default"
        let directory = step.directory.map(RelayAssistantActions.q) ?? "host default directory"
        switch step.op {
        case .newTab: return "New tab beside \(pane(step.target)) · host \(host) · directory \(directory)"
        case .split: return "Split \(pane(step.target)) \(step.action == "splitDown" ? "down" : "right") · host \(host) · directory \(directory)"
        case .startAgent: return "Start \(step.agent ?? "")" + (step.launchAccount.map { " (\($0.label) account)" } ?? "") +
            " in \(pane(step.target)): type " + RelayAssistantActions.q(step.text ?? "") + " and press Return"
        case .sendCommand: return "Type " + RelayAssistantActions.q(step.text ?? "") + " in \(pane(step.target)) and press Return"
        case .agentCommand: return "Runs \(step.text ?? "") in \(pane(step.target)) (typed into the agent prompt)"
        case .message: return "Message the agent in \(pane(step.target)) from Miko through its message socket (nothing is typed): " +
            RelayAssistantActions.q(step.text ?? "")
        case .link: return "Link \(pane(step.source!)) with \(pane(step.target))"
        case .select: return "Select \(pane(step.target))"
        }
    }

    /// The MCP route request for a step; pane references are resolved from
    /// the IDs earlier steps created. Nil when a reference is unresolved.
    static func request(_ step: RelayAssistantPlanStep, instance: UUID, created: [Int: UUID]) -> (path: String, body: Data)? {
        func resolve(_ ref: RelayAssistantPaneRef) -> String? {
            switch ref {
            case .pane(let id): id.uuidString.lowercased()
            case .step(let n): created[n]?.uuidString.lowercased()
            }
        }
        guard let target = resolve(step.target) else { return nil }
        let base: [String: Any] = ["instance": instance.uuidString.lowercased(), "requestID": step.requestID.uuidString.lowercased()]
        switch step.op {
        case .newTab, .split:
            var object = base.merging(["paneID": target, "action": step.action ?? ""]) { $1 }
            if let host = step.host { object["connectionHost"] = host }
            if let directory = step.directory { object["directory"] = directory }
            return ("/api/workspace/apply", RelayAssistantActions.body(object))
        case .startAgent, .sendCommand, .agentCommand:
            // Typing always carries the draft fence.
            guard let revision = step.inputRevision else { return nil }
            return ("/api/panes/\(target)/input-direct", RelayAssistantActions.body(base.merging(
                ["text": step.text ?? "", "expectedInputRevision": revision]) { $1 }))
        case .link:
            guard let source = step.source.flatMap(resolve) else { return nil }
            return ("/api/pane-links", RelayAssistantActions.body(["sourcePaneID": source, "paneID": target]))
        case .select:
            return ("/api/workspace/select/\(target)", Data("{}".utf8))
        case .message:
            // Sent through relayd's message route, never an MCP input route.
            return nil
        }
    }
}

extension RelayAssistantSnapshot {
    /// A new pane may start only in a known pane directory on that host or a
    /// folder find_project_folder resolved uniquely on that host.
    func admitsDirectory(_ path: String, host: String) -> Bool {
        guard Self.validDirectory(path) else { return false }
        return (directories[host] ?? []).contains(path) || (resolvedDirectories[host] ?? []).contains(path) ||
            paneDirectories.contains { $0.value == path && pane($0.key)?.hostAlias == host }
    }
}
