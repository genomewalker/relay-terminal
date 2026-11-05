import CryptoKit
import Foundation

// Relay assistant Change actions (phase 2). The model can only *propose* these.
// Each proposal becomes an action card showing the exact request Relay will
// send; nothing runs until the user clicks Run, and Run sends those same bytes
// once through the MCP control route (`RelaySidePanelServer.route`), so the
// assistant can never do more than MCP control allows.

/// The in-app MCP control entry. Production: `RelaySidePanelServer`.
@MainActor protocol RelayAssistantActionExecutor: AnyObject {
    /// The control server incarnation every mutating MCP route requires.
    var instance: UUID? { get }
    func permits(_ capability: MCPWorkspaceCapability) -> Bool
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data)
    func performMiko(method: String, path: String, body: Data) async -> (status: Int, body: Data)
}

extension RelayAssistantActionExecutor {
    func performMiko(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        await perform(method: method, path: path, body: body)
    }
}

/// A validated Change proposal. Every identifier came from the current snapshot.
struct RelayAssistantChange: Equatable, Sendable {
    let tool: RelayAssistantToolName
    var paneID: UUID? = nil
    var tabID: UUID? = nil
    var targetTabID: UUID? = nil
    var host: String? = nil
    var text: String? = nil
    var action: String? = nil
    var enabled: Bool? = nil
    var cwd: String? = nil
    var timeoutSeconds: Int? = nil
    var name: String? = nil
    var placement: String? = nil
    /// Starting directory for a new tab or split pane, from the snapshot.
    var directory: String? = nil
    /// new_tab_layout: number of panes (1...4) and split direction.
    var paneCount: Int? = nil
    /// apply_migration (the open preview) and undo_migration (an applied record).
    var migrationID: UUID? = nil
    /// send_command: the empty-prompt proof taken when the card is built.
    var promptProof: RelayAssistantInputFence.Proof? = nil
}



struct RelayAssistantActionCard: Identifiable, Equatable {
    var relayToolName: String? = nil
    var mikoGeneration: UInt64? = nil
    struct Row: Equatable, Hashable {
        let label: String
        let value: String
    }
    /// Stable MCP request ID (and job ID for exec); never reused or retried.
    let id: UUID
    let tool: RelayAssistantToolName
    let title: String
    let rows: [Row]
    /// Verbatim text/command, with control characters made visible.
    let literal: String?
    let literalLabel: String?
    let requiredCapabilities: [MCPWorkspaceCapability]
    var blockedReason: String?
    let proposedAt: Date
    let expiresAt: Date
    // Exactly what Run sends.
    let method: String
    let path: String
    let body: Data
    let argumentsDigest: String
    let preview: String
    // Run-time re-validation.
    let paneID: UUID?
    let tabID: UUID?
    let host: String?
    let paneObject: ObjectIdentifier?
    let bindingFingerprint: String?
    /// Plan cards: ordered steps run by one Run (empty for single actions).
    var planSteps: [RelayAssistantPlanStep] = []
    /// Identity of each existing pane a plan step targets, captured at proposal.
    var planPaneIdentities: [UUID: AffectedPane] = [:]
    var directory: String? = nil
    /// tab_action close: the exact panes it will close, with their identities.
    var affectedPanes: [AffectedPane] = []

    struct AffectedPane: Equatable {
        let id: UUID
        let object: ObjectIdentifier
        let binding: String?
    }
}

enum RelayAssistantActions {
    static let workspaceActions = ["newTab", "splitRight", "splitDown", "float", "dock", "balance", "close",
                                   "conversation", "terminal"]
    static let previewKinds = ["pdf", "svg", "png", "jpeg", "jpg", "markdown", "diagram", "equation"]

    /// The only input Miko may type into a Claude/Codex prompt: one slash
    /// command line. Words for an agent always go through message_pane.
    static func isAgentCommand(_ text: String) -> Bool {
        text.range(of: #"^/[a-z][a-z0-9-]*( [^\n]{0,200})?$"#, options: .regularExpression) != nil &&
            !text.unicodeScalars.contains { $0.value < 32 || (0x7f...0x9f).contains($0.value) || (0x2028...0x2029).contains($0.value) }
    }

    static func requiredCapabilities(_ change: RelayAssistantChange) -> [MCPWorkspaceCapability] {
        switch change.tool {
        case .sendCommand, .agentCommand, .setContextRotation, .setCapacityPause, .requestCapacityAction, .execCommand,
             .nativeAction, .nativeImage: [.input]
        case .nativeLaunch, .nativeResume: [.create, .input]
        case .terminatePane: [.terminate]
        case .reconnectPane, .recoverPane, .newLocalTab: [.create]
        case .tabAction, .openFilePreview: [.layout]
        case .unlinkPanes, .bindQuestionThread, .unbindQuestionThread: [.layout]
        case .stageMigrationPlan, .applyMigration, .undoMigration: [.layout]
        case .workspaceAction:
            // Mirrors /api/workspace/apply exactly.
            switch change.action {
            case "newTab": [.create]
            case "splitRight", "splitDown": [.create, .layout]
            default: [.layout]
            }
        default: []
        }
    }

    // MARK: Validation (strict schema; IDs from the snapshot)

    static func validate(_ tool: RelayAssistantToolName, fields: [String: RelayPaneHealthJSON],
                         snapshot: RelayAssistantSnapshot) -> Result<RelayAssistantToolCall, RelayAssistantToolError> {
        func fail(_ message: String) -> Result<RelayAssistantToolCall, RelayAssistantToolError> { .failure(.init(message: message)) }
        func string(_ key: String) -> String? { if case .string(let v)? = fields[key] { v } else { nil } }
        func pane() -> Result<RelayAssistantSnapshot.Pane, RelayAssistantToolError> {
            guard let raw = string("pane_id"), let id = UUID(uuidString: raw) else {
                return .failure(.init(message: "pane_id must be a pane ID from the snapshot."))
            }
            guard let pane = snapshot.pane(id) else {
                return .failure(.init(message: "Unknown pane_id \(raw.prefix(40)): no such pane among all \(snapshot.panes.count) " +
                    "panes in this Relay workspace when this request started. Nothing was proposed."))
            }
            return .success(pane)
        }
        func host(_ key: String = "host") -> Result<String, RelayAssistantToolError> {
            guard let value = string(key), snapshot.hosts.contains(value) else {
                return .failure(.init(message: "\(key) must be one of the snapshot's hosts: " + snapshot.hosts.joined(separator: ", ") + "."))
            }
            return .success(value)
        }
        func tab(_ key: String) -> Result<UUID, RelayAssistantToolError> {
            guard let raw = string(key), let id = UUID(uuidString: raw), snapshot.tab(id) != nil else {
                return .failure(.init(message: "\(key) must be a tab ID from the current snapshot. Nothing was proposed."))
            }
            return .success(id)
        }
        do {
            switch tool {
            case .nativeSnapshot, .nativeReceipt, .nativeAction, .nativeImage:
                let target = try pane().get()
                if tool == .nativeAction {
                    guard let raw = string("action_json"), raw.utf8.count <= 60_000,
                          case .object = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: Data(raw.utf8)) else {
                        return fail("action_json must be one bounded native action object without caller-supplied identity or ID.")
                    }
                    return .success(.change(.init(tool: tool, paneID: target.id,
                        text: "{\"operation\":\"action\",\"action\":" + raw + "}")))
                }
                var body = fields
                body.removeValue(forKey: "pane_id")
                body["operation"] = .string(tool.nativeOperation!)
                if tool == .nativeSnapshot {
                    for key in ["before", "afterRevision", "waitMillis"] where body[key] != nil {
                        guard case .integer(let number)? = body[key], number >= 0,
                              key != "waitMillis" || number <= 15_000 else {
                            return fail("Native snapshot bounds must be nonnegative integers; waitMillis is at most 15000.")
                        }
                    }
                }
                let encoded = try RelayPaneHealthJSON.data(RelayPaneHealthJSON.object(body))
                return .success(.change(.init(tool: tool, paneID: target.id,
                    text: String(decoding: encoded, as: UTF8.self))))
            case .nativeLaunch, .nativeResume:
                let target = try pane().get()
                guard let provider = string("provider"), ["claude", "codex"].contains(provider),
                      let account = string("account"),
                      account.range(of: #"^[a-z0-9][a-z0-9_-]{0,23}$"#, options: .regularExpression) != nil else {
                    return fail("Native launch requires a registered Claude/Codex account label.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, action: provider, name: account)))
            case .findProjectFolder:
                let host = try host().get()
                guard let name = string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 255,
                      !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      name.hasPrefix("/") ? RelayAssistantSnapshot.validDirectory(name) : !name.contains("/") else {
                    return fail("name must be a folder name, or an absolute path from earlier candidates.")
                }
                return .success(.findFolder(host: host, name: name))
            case .listPaneLinks:
                return .success(.listLinks)
            case .messagePane:
                let target = try pane().get()
                guard target.contentKind == "terminal" else { return fail("message_pane needs an agent terminal pane.") }
                guard let text = string("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 16384,
                      !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
                    return fail("text must be 1 to 16384 bytes without control characters other than newline or tab.")
                }
                return .success(.message(target.id, text: text))
            case .messageReceipt:
                guard let raw = string("message_id"), let id = UUID(uuidString: raw), let recipient = snapshot.sentMessages[id] else {
                    return fail("message_id must be a message Miko sent in this chat.")
                }
                return .success(.messageReceipt(id, recipient: recipient))
            case .readAssistantInbox:
                return .success(.assistantInbox)
            case .recallMemory:
                guard let query = string("query"), !query.trimmingCharacters(in: .whitespaces).isEmpty, query.count <= 200 else {
                    return fail("query must be 1 to 200 characters.")
                }
                var limit = 3
                if let value = fields["limit"] {
                    guard case .integer(let n) = value, (1...5).contains(n) else { return fail("limit must be 1 to 5.") }
                    limit = Int(n)
                }
                return .success(.recall(query: query, limit: limit))
            case .readAgentContext:
                return .success(.agentContext(try pane().get().id, query: nil))
            case .readViewport:
                return .success(.viewport(try pane().get().id))
            case .readHandoff:
                switch (string("memory_id"), string("checkpoint_key")) {
                case (let id?, nil):
                    guard let target = RelayAssistantExactMemory.memoryID(id) else { return fail("memory_id must be a chitta node ID (digits only).") }
                    return .success(.handoff(target))
                case (nil, let key?):
                    guard let target = RelayAssistantExactMemory.checkpointKey(key) else {
                        return fail("checkpoint_key must be an exact ledger key, session:project.")
                    }
                    return .success(.handoff(target))
                default:
                    return fail("Give exactly one of memory_id or checkpoint_key.")
                }
            case .searchAgentContext:
                let target = try pane().get()
                guard let query = string("query"), !query.isEmpty, query.count <= 120 else { return fail("query must be 1 to 120 characters.") }
                return .success(.agentContext(target.id, query: query))
            case .remember:
                guard let text = string("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else {
                    return fail("text must be 1 to 2000 characters.")
                }
                var tags = ""
                if fields["tags"] != nil {
                    guard let value = string("tags"), value.count <= 200,
                          value.range(of: #"^[A-Za-z0-9_.:-]+(,[A-Za-z0-9_.:-]+)*$"#, options: .regularExpression) != nil else {
                        return fail("tags must be comma-separated words.")
                    }
                    tags = value
                }
                return .success(.change(.init(tool: tool, text: RelayAssistantRedaction.redact(text), name: tags)))
            case .listRecoverablePanes:
                return .success(.listRecoverable(host: try host().get()))
            case .execStatus:
                let host = try host().get()
                guard let job = string("job_id"), snapshot.jobs[job] == host else {
                    return fail("job_id must be a job this conversation started on that host.")
                }
                return .success(.execStatus(host: host, jobID: job))
            case .sendCommand:
                let target = try pane().get()
                guard target.contentKind == "terminal" else { return fail("send_command needs a terminal pane.") }
                guard let text = string("text"), !text.isEmpty, text.count <= 8192, text.utf8.count <= 65536 else {
                    return fail("text must be 1 to 8192 characters.")
                }
                // Mirrors AgentInputProposal.isValid: no control characters but newline and tab.
                guard !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
                    return fail("text contains control characters other than newline or tab; it cannot be sent.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, host: target.hostAlias, text: text)))
            case .agentCommand:
                let target = try pane().get()
                guard target.contentKind == "terminal", ["claude", "codex"].contains(target.kind) else {
                    return fail("agent_command needs a Claude/Codex pane; use send_command for a shell pane.")
                }
                guard let text = string("text"), isAgentCommand(text) else {
                    return fail("agent_command text must be one slash command line (/name, optional arguments up to 200 characters), "
                        + "without newline or control characters. Send words to an agent with message_pane.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, host: target.hostAlias, text: text)))
            case .terminatePane, .reconnectPane:
                let target = try pane().get()
                guard let alias = target.hostAlias, target.contentKind == "terminal" else {
                    return fail("Only Relay-managed terminal panes on This Mac or a configured SSH host qualify.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, host: alias)))
            case .recoverPane:
                let host = try host().get()
                guard let raw = string("pane_id"), let id = UUID(uuidString: raw), snapshot.recoverable[host]?.contains(id) == true else {
                    return fail("pane_id must come from list_recoverable_panes for that host in this request.")
                }
                return .success(.change(.init(tool: tool, paneID: id, host: host)))
            case .setCapacityPause, .requestCapacityAction:
                let target = try pane().get()
                guard target.hostAlias != nil, target.contentKind == "terminal" else { return fail("Capacity management requires a Relay terminal pane.") }
                var change = RelayAssistantChange(tool: tool, paneID: target.id, host: target.hostAlias)
                if tool == .setCapacityPause {
                    guard case .bool(let paused)? = fields["paused"] else { return fail("paused must be a boolean.") }
                    change.action = paused ? "pause" : "resume"
                } else {
                    guard let action = string("action"), ["manual_refresh", "manual_move"].contains(action) else { return fail("action must be manual_refresh or manual_move.") }
                    change.action = action
                    if action == "manual_move" {
                        guard let label = string("target_account"), RelayAgentAccount.validLabel(label) else { return fail("A valid approved target_account is required.") }
                        change.name = label
                    } else if fields["target_account"] != nil { return fail("A context-only refresh keeps the current verified account.") }
                }
                return .success(.change(change))
        case .setContextRotation:
                let target = try pane().get()
                guard case .bool(let enabled)? = fields["enabled"] else { return fail("enabled must be a boolean.") }
                guard target.hostAlias != nil, target.contentKind == "terminal" else {
                    return fail("Context rotation applies only to Relay terminal panes.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, host: target.hostAlias, enabled: enabled)))
            case .execCommand:
                let host = try host().get()
                guard let command = string("command"), !command.trimmingCharacters(in: .whitespaces).isEmpty,
                      command.count <= 8192, !command.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    return fail("command must be 1 to 8192 characters.")
                }
                var change = RelayAssistantChange(tool: tool, host: host, text: command)
                if fields["cwd"] != nil {
                    guard let cwd = string("cwd"), cwd.hasPrefix("/"), cwd.count <= 1024,
                          !cwd.unicodeScalars.contains(where: { $0.value < 32 }) else {
                        return fail("cwd must be an absolute path without control characters.")
                    }
                    change.cwd = cwd
                }
                if let value = fields["timeout_seconds"] {
                    guard case .integer(let seconds) = value, (1...3600).contains(seconds) else {
                        return fail("timeout_seconds must be an integer from 1 to 3600.")
                    }
                    change.timeoutSeconds = Int(seconds)
                }
                return .success(.change(change))
            case .workspaceAction:
                let target = try pane().get()
                guard let action = string("action"), workspaceActions.contains(action) else {
                    return fail("action must be one of " + workspaceActions.joined(separator: ", ") + ".")
                }
                var change = RelayAssistantChange(tool: tool, paneID: target.id, host: nil, action: action)
                let creates = ["newTab", "splitRight", "splitDown"].contains(action)
                if fields["host"] != nil || fields["directory"] != nil {
                    guard creates else { return fail("host and directory are only valid when creating a tab or split pane.") }
                }
                if creates {
                    guard target.contentKind == "terminal" else { return fail("Only a terminal pane can be split or used for a new tab.") }
                    let placement = try newPanePlacement(fields: fields, source: target, snapshot: snapshot)
                    change.host = placement.host
                    change.directory = placement.directory
                }
                return .success(.change(change))
            case .newTabLayout:
                // One plan card: a new tab, then N-1 splits of the pane the previous step created.
                var count = 1
                if let value = fields["panes"] {
                    guard case .integer(let n) = value, (1...4).contains(n) else { return fail("panes must be an integer from 1 to 4.") }
                    count = Int(n)
                }
                var direction = "right"
                if fields["direction"] != nil {
                    guard let value = string("direction"), ["right", "down"].contains(value) else {
                        return fail("direction must be right or down.")
                    }
                    direction = value
                }
                var first: [String: RelayPaneHealthJSON] = ["op": .string("new_tab")]
                if let pane = fields["pane_id"] { first["pane"] = pane }
                else if snapshot.here == nil, let fallback = snapshot.selectedPaneID ?? snapshot.panes.first(where: { $0.contentKind == "terminal" })?.id {
                    first["pane"] = .string(fallback.uuidString.lowercased())
                }
                if let host = fields["host"] { first["host"] = host }
                if let directory = fields["directory"] { first["directory"] = directory }
                var steps: [RelayPaneHealthJSON] = [.object(first)]
                for index in 1..<count {
                    steps.append(.object(["op": .string("split"), "pane": .string("step:\(index)"), "direction": .string(direction)]))
                }
                switch RelayAssistantPlan.validate(["steps": .array(steps)], snapshot: snapshot) {
                case .success(let plan): return .success(.plan(tool, plan))
                case .failure(let error): return .failure(error)
                }
            case .proposePlan:
                switch RelayAssistantPlan.validate(fields, snapshot: snapshot) {
                case .success(let plan): return .success(.plan(tool, plan))
                case .failure(let error): return .failure(error)
                }
            case .linkPanes:
                let target = try pane().get()
                guard let raw = string("source_pane_id"), let source = UUID(uuidString: raw), snapshot.pane(source) != nil, source != target.id else {
                    return fail("source_pane_id must be a different pane ID from the snapshot.")
                }
                return .success(.plan(tool, [RelayAssistantPlanStep(index: 1, op: .link, requestID: UUID(),
                                                                    target: .pane(target.id), source: .pane(source))]))
            case .unlinkPanes:
                guard let link = string("link_id"), snapshot.links.contains(link) else {
                    return fail("link_id must come from list_pane_links in this request.")
                }
                return .success(.change(.init(tool: tool, text: link)))
            case .bindQuestionThread:
                let target = try pane().get()
                guard target.contentKind == "terminal" else { return fail("bind_question_thread needs an agent terminal pane.") }
                guard let thread = string("thread_id"), RelayQuestionThreadInput.validID(thread) != nil else {
                    return fail("thread_id must be 1 to 128 characters from A-Z a-z 0-9 _ : . -.")
                }
                guard let realm = string("realm"), RelayQuestionThreadInput.validID(realm) != nil else {
                    return fail("realm must be 1 to 128 characters from A-Z a-z 0-9 _ : . -.")
                }
                var change = RelayAssistantChange(tool: tool, paneID: target.id, host: target.hostAlias, text: thread, name: realm)
                if fields["ttl"] != nil {
                    guard case .integer(let ttl)? = fields["ttl"], (30...86400).contains(ttl) else {
                        return fail("ttl must be an integer number of seconds from 30 to 86400.")
                    }
                    change.timeoutSeconds = Int(ttl)
                }
                return .success(.change(change))
            case .unbindQuestionThread:
                let target = try pane().get()
                guard target.contentKind == "terminal" else { return fail("unbind_question_thread needs an agent terminal pane.") }
                return .success(.change(.init(tool: tool, paneID: target.id, host: target.hostAlias)))
            case .newLocalTab:
                return .success(.change(.init(tool: tool, host: "This Mac")))
            case .tabAction:
                let tabID = try tab("tab_id").get()
                var change = RelayAssistantChange(tool: tool, tabID: tabID, action: string("action"))
                switch string("action") {
                case "rename":
                    guard Set(fields.keys) == ["tab_id", "action", "name"], let name = string("name"),
                          !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 80,
                          !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
                        return fail("rename needs only a nonempty name of at most 80 characters.")
                    }
                    change.name = name
                case "close":
                    guard Set(fields.keys) == ["tab_id", "action"] else { return fail("close accepts only tab_id and action.") }
                case "move":
                    guard Set(fields.keys) == ["tab_id", "action", "target_tab_id", "placement"],
                          let placement = string("placement"), ["before", "after"].contains(placement) else {
                        return fail("move needs target_tab_id and placement before or after.")
                    }
                    let target = try tab("target_tab_id").get()
                    guard target != tabID else { return fail("A tab cannot move relative to itself.") }
                    change.targetTabID = target
                    change.placement = placement
                default:
                    return fail("action must be rename, close or move.")
                }
                return .success(.change(change))
            case .openFilePreview:
                let target = try pane().get()
                guard let kind = string("kind"), previewKinds.contains(kind) else {
                    return fail("kind must be one of " + previewKinds.joined(separator: ", ") + ".")
                }
                guard let source = string("source"), !source.isEmpty else { return fail("source is required.") }
                if ["pdf", "svg", "png", "jpeg", "jpg"].contains(kind) {
                    guard source.utf8.count <= 4096, (source as NSString).pathExtension.lowercased() == kind,
                          !source.unicodeScalars.contains(where: { $0.value < 32 }) else {
                        return fail("source must be a path on the pane's host whose extension matches kind.")
                    }
                } else if source.utf8.count > 16384 {
                    return fail("source text is limited to 16 KB.")
                }
                return .success(.change(.init(tool: tool, paneID: target.id, host: target.hostAlias, text: source, action: kind)))
            case .stageMigrationPlan:
                guard let path = string("path"), RelayAssistantSnapshot.validDirectory(path), path.hasSuffix(".json") else {
                    return fail("path must be an absolute path to a .json plan file on This Mac.")
                }
                var change = RelayAssistantChange(tool: tool, host: "This Mac", text: path)
                if fields["name"] != nil {
                    guard let name = string("name"), name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil else {
                        return fail("name may use letters, digits, '.', '_' and '-' only.")
                    }
                    change.name = name
                }
                if let value = fields["replace"] {
                    guard case .bool(let replace) = value else { return fail("replace must be a boolean.") }
                    change.enabled = replace
                }
                return .success(.change(change))
            case .applyMigration:
                guard let migration = snapshot.migration, string("preview_id").flatMap(UUID.init(uuidString:)) == migration.previewID,
                      string("checksum") == migration.checksum else {
                    return fail("preview_id and checksum must be the snapshot's workspace_migration values. Nothing was proposed.")
                }
                guard migration.refusals == 0, migration.collisions == 0 else {
                    return fail("The open migration preview has refusals or name collisions; only the user can resolve them.")
                }
                return .success(.change(.init(tool: tool, text: migration.checksum, name: migration.plan, migrationID: migration.previewID)))
            case .undoMigration:
                guard let id = string("migration_id").flatMap(UUID.init(uuidString:)), snapshot.appliedMigrations.contains(id) else {
                    return fail("migration_id must be one of the snapshot's applied_migration_ids.")
                }
                return .success(.change(.init(tool: tool, migrationID: id)))
            default:
                return fail("Not a Change tool.")
            }
        } catch let error as RelayAssistantToolError {
            return .failure(error)
        } catch {
            return fail("Invalid arguments.")
        }
    }


    /// Host and directory for a new pane: given values must come from the
    /// snapshot (hosts, known directories); defaults are the source pane's.
    static func newPanePlacement(fields: [String: RelayPaneHealthJSON], source: RelayAssistantSnapshot.Pane,
                                 snapshot: RelayAssistantSnapshot) throws -> (host: String?, directory: String?) {
        var host = source.hostAlias
        if let value = fields["host"] {
            guard case .string(let name) = value, snapshot.hosts.contains(name) else {
                throw RelayAssistantToolError(message: "host must be in the snapshot's hosts (workspace or configured Relay hosts): " +
                    snapshot.hosts.joined(separator: ", ") + ". Nothing was proposed.")
            }
            host = name
        }
        if let value = fields["directory"] {
            guard case .string(let directory) = value, let host, snapshot.admitsDirectory(directory, host: host) else {
                throw RelayAssistantToolError(message: "directory must be a known working directory of a pane on that host. Nothing was proposed.")
            }
            return (host, directory)
        }
        // Default: the source pane's directory, but only on the source pane's own host.
        let directory = host == source.hostAlias ? snapshot.paneDirectories[source.id] : nil
        return (host, directory)
    }

    // MARK: Request and card

    static func body(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Builds the exact MCP route request, then derives the card from it.
    @MainActor static func card(for change: RelayAssistantChange, actionID: UUID, executor: (any RelayAssistantActionExecutor)?,
                                snapshot: RelayAssistantSnapshot, workspace: WorkspaceModel, facts: RelayAssistantFacts,
                                now: Date, timeout: TimeInterval) -> RelayAssistantActionCard {
        let id = actionID.uuidString.lowercased()
        let instance = executor?.instance?.uuidString.lowercased() ?? ""
        let pane = change.paneID.flatMap(snapshot.pane)
        let paneLabel = pane.map { q($0.title) + " · \($0.id.uuidString.lowercased())" } ??
            change.paneID.map { $0.uuidString.lowercased() }
        var rows: [RelayAssistantActionCard.Row] = []
        var affected: [RelayAssistantActionCard.AffectedPane] = []
        // Every value is one escaped line; supplied strings are additionally quoted by q().
        func row(_ label: String, _ value: String?) { if let value { rows.append(.init(label: label, value: singleLine(value))) } }
        func hostText(_ value: String?) -> String? { value.map(q) }
        var literal: String?, literalLabel: String?
        var method = "POST"
        var path = ""
        var object: [String: Any] = [:]
        var title = ""
        var preview = change.tool.rawValue
        switch change.tool {
        case .sendCommand, .agentCommand:
            title = change.tool == .agentCommand ? "Run an agent slash command" : "Send text to a pane and press Return"
            path = "/api/panes/\(change.paneID!.uuidString.lowercased())/input-direct"
            object = ["instance": instance, "requestID": id, "text": change.text ?? ""]
            if change.tool == .agentCommand {
                row("Effect", "Runs \(change.text ?? "") in \(paneLabel ?? "the pane") (typed into the agent prompt)")
            }
            row("Pane", paneLabel); row("Host", hostText(change.host ?? pane?.host))
            row("Return", "Pressed once after the text")
            if let proof = change.promptProof, proof.empty {
                // Run sends only if this revision is unchanged and the prompt is still empty.
                object["expectedInputRevision"] = proof.inputRevision
                row("Prompt", "empty ✓ (input revision \(proof.inputRevision); Run refuses if anything is typed first)")
            } else {
                row("Prompt", "not verified empty")
            }
            literal = visible(change.text ?? ""); literalLabel = change.tool == .agentCommand ? "Slash command (verbatim)" : "Text (verbatim)"
            preview += " pane=\(change.paneID!.uuidString.lowercased()) text=" + (change.text ?? "")
        case .terminatePane:
            title = "Terminate a pane's process"
            path = "/api/recovery/terminate"
            object = ["instance": instance, "requestID": id, "host": change.host ?? "", "paneID": change.paneID!.uuidString.lowercased()]
            row("Pane", paneLabel); row("Host", hostText(change.host))
            row("Effect", "Ends the Relay-managed terminal process and its children on the host, then closes the pane. Cannot be undone.")
            preview += " pane=\(change.paneID!.uuidString.lowercased()) host=\(change.host ?? "")"
        case .reconnectPane, .recoverPane:
            title = change.tool == .reconnectPane ? "Reconnect a pane to its retained worker" : "Recover a pane from its host"
            path = "/api/recovery/attach"
            object = ["instance": instance, "requestID": id, "host": change.host ?? "", "paneID": change.paneID!.uuidString.lowercased()]
            row("Pane", paneLabel); row("Host", hostText(change.host))
            row("Effect", change.tool == .reconnectPane
                ? "Reattaches this viewer to the pane's existing retained worker. No new process or agent is started."
                : "Attaches the host's existing retained pane into this workspace. No new process is started.")
            preview += " pane=\(change.paneID!.uuidString.lowercased()) host=\(change.host ?? "")"
            case .setCapacityPause, .requestCapacityAction:
            title = change.action == "pause" ? "Pause capacity planning" : change.action == "resume" ? "Resume capacity planning" : "Request a checked native capacity operation"
            path = "/api/panes/\(change.paneID!.uuidString.lowercased())/capacity-action"
            object = ["instance": instance, "requestID": id, "action": change.action ?? "pause"]
            if let target = change.name { object["targetAccount"] = target }
            row("Pane", paneLabel); row("Host", hostText(change.host))
            row("Effect", "Runs the same native policy/coordinator. Actual Codex/Claude retirement remains held without the provider preservation contract; a model request cannot override it.")
            if let target = change.name { row("Approved account", target) }
            preview += " pane=\(change.paneID!.uuidString.lowercased()) capacity_action=\(change.action ?? "")"
        case .setContextRotation:
            title = (change.enabled == true ? "Enable" : "Pause") + " context rotation"
            path = "/api/panes/\(change.paneID!.uuidString.lowercased())/context-rotation"
            object = ["instance": instance, "requestID": id, "enabled": change.enabled ?? false]
            row("Pane", paneLabel); row("Host", hostText(change.host))
            row("Context rotation", change.enabled == true ? "Enable" : "Pause")
            preview += " pane=\(change.paneID!.uuidString.lowercased()) enabled=\(change.enabled == true)"
        case .execCommand:
            title = "Run a command on a host"
            path = "/api/host/request"
            object = ["host": change.host ?? "", "operation": "exec", "job_id": id, "command": change.text ?? "",
                      "request_id": "rpc-" + id]
            if let cwd = change.cwd { object["cwd"] = cwd }
            if let timeout = change.timeoutSeconds { object["timeout_seconds"] = timeout }
            row("Host", hostText(change.host)); row("Working directory", change.cwd.map(q) ?? "Host default")
            row("Timeout", change.timeoutSeconds.map { "\($0) s" } ?? "Host default")
            row("Job ID", id)
            row("Effect", "Starts one durable job through relayd on the host (not typed into a pane).")
            literal = visible(change.text ?? ""); literalLabel = "Command (verbatim)"
            preview += " host=\(change.host ?? "") cwd=\(change.cwd ?? "") command=" + (change.text ?? "")
        case .workspaceAction:
            let action = change.action ?? ""
            let tab = pane.flatMap { snapshot.tab($0.tabID) }
            let names = ["splitRight": "Split a pane to the right", "splitDown": "Split a pane downward",
                         "newTab": "Open a new tab", "close": "Close a pane"]
            title = names[action] ?? "Workspace action: " + action
            path = "/api/workspace/apply"
            object = ["instance": instance, "requestID": id, "paneID": change.paneID!.uuidString.lowercased(), "action": action]
            let creates = ["newTab", "splitRight", "splitDown"].contains(action)
            if creates, let host = change.host { object["connectionHost"] = host }
            if creates, let directory = change.directory { object["directory"] = directory }
            row("Tab", tab.map { q($0.name) + " · \($0.id.uuidString.lowercased())" })
            row(creates ? "Source pane" : "Pane", paneLabel)
            row("Action", action)
            if creates {
                row("Direction", action == "splitRight" ? "Right" : action == "splitDown" ? "Down" : "New tab")
                row("Host", hostText(change.host ?? pane?.host))
                row("Directory", change.directory.map(q) ?? "Host default (no known directory)")
            }
            // The same effect text MCP control shows for this request.
            if let detail = try? workspace.workspaceActionDetail(WorkspaceProposal(instance: executor?.instance ?? UUID(),
                requestID: actionID, paneID: change.paneID!, action: WorkspaceAction(rawValue: action) ?? .select,
                connectionHost: creates ? change.host : nil)) {
                row("Effect", detail)
            }
            preview += " pane=\(change.paneID!.uuidString.lowercased()) action=\(action) host=\(change.host ?? "") dir=\(change.directory ?? "")"
        case .newLocalTab:
            title = "Open a new local tab"
            path = "/api/workspace/new-local-tab"
            object = ["instance": instance, "requestID": id]
            row("Host", "This Mac"); row("Effect", "Creates a new shell tab on This Mac. No command is submitted.")
        case .tabAction:
            title = "Tab action: " + (change.action ?? "")
            path = "/api/workspace/tab-action"
            object = ["instance": instance, "requestID": id, "tabID": change.tabID!.uuidString.lowercased(),
                      "action": change.action ?? ""]
            let tab = change.tabID.flatMap(snapshot.tab)
            row("Tab", tab.map { q($0.name) + " · \($0.id.uuidString.lowercased())" })
            row("Action", change.action)
            if let name = change.name { object["name"] = name; literal = visible(name); literalLabel = "New name (verbatim)" }
            if let target = change.targetTabID {
                object["targetTabID"] = target.uuidString.lowercased(); object["placement"] = change.placement ?? ""
                row("Relative to", q(snapshot.tab(target)?.name ?? "") + " · " + target.uuidString.lowercased())
                row("Placement", change.placement)
            }
            if change.action == "close", let tabID = change.tabID {
                row("Effect", "Closes the tab and exactly these panes in this workspace.")
                for (index, id) in workspace.paneIDs(inTab: tabID).enumerated() {
                    guard let model = workspace.panes[id] else { continue }
                    affected.append(.init(id: id, object: ObjectIdentifier(model), binding: facts.binding(id)))
                    let effect = model.contentKind == .editor ? "closes the editor"
                        : model.profile.backend == .relay ? "detaches; its persistent session keeps running" : "stops its process"
                    row("Closes pane \(index + 1)", q(snapshot.pane(id)?.title ?? model.displayName) + " · " +
                        id.uuidString.lowercased() + " · " + effect)
                }
            }
            preview += " tab=\(change.tabID!.uuidString.lowercased()) action=\(change.action ?? "") name=\(change.name ?? "")"
        case .remember:
            title = "Remember this in chitta"
            method = "MEMORY"
            path = "chitta:remember"
            object = ["text": change.text ?? "", "tags": change.name ?? ""]
            row("Effect", "Stores this text as a private memory in your chitta store. Nothing else changes.")
            row("Tags", (change.name ?? "").isEmpty ? "none" : q(change.name ?? ""))
            literal = visible(change.text ?? ""); literalLabel = "Memory text (verbatim, redacted)"
            preview += " tags=\(change.name ?? "") text=" + (change.text ?? "")
        case .unlinkPanes:
            title = "Unlink two panes"
            method = "DELETE"
            path = "/api/pane-links"
            object = ["linkID": change.text ?? ""]
            row("Link ID", change.text)
            row("Effect", "Removes this saved pane link; the panes stop exchanging Relay messages.")
            preview += " link=\(change.text ?? "")"
        case .bindQuestionThread:
            title = "Bind a pane to a question thread"
            path = "/api/question-threads"
            object = ["paneID": change.paneID!.uuidString.lowercased(), "threadID": change.text ?? "", "realm": change.name ?? ""]
            if let ttl = change.timeoutSeconds { object["ttl"] = String(ttl) }
            row("Pane", paneLabel); row("Host", hostText(change.host ?? pane?.host))
            row("Thread", q(change.text ?? "")); row("Realm", q(change.name ?? ""))
            row("Lease", change.timeoutSeconds.map { "\($0) s" } ?? "Host default")
            row("Effect", "The pane's host takes the chitta lease on this thread, keeps it renewed and posts its notifications to the pane until unbound.")
            preview += " pane=\(change.paneID!.uuidString.lowercased()) thread=\(change.text ?? "") realm=\(change.name ?? "") ttl=\(change.timeoutSeconds.map(String.init) ?? "")"
        case .unbindQuestionThread:
            title = "Unbind a pane from its question thread"
            method = "DELETE"
            path = "/api/question-threads"
            object = ["paneID": change.paneID!.uuidString.lowercased()]
            row("Pane", paneLabel); row("Host", hostText(change.host ?? pane?.host))
            row("Effect", "The pane's host releases its chitta question thread lease and stops posting notifications to the pane.")
            preview += " pane=\(change.paneID!.uuidString.lowercased())"
        case .openFilePreview:
            title = "Open a preview in a pane"
            path = "/api/rich-content"
            object = ["pane_id": change.paneID!.uuidString.lowercased(), "kind": change.action ?? "", "source": change.text ?? ""]
            row("Pane", paneLabel); row("Host", hostText(change.host ?? pane?.host)); row("Kind", change.action)
            literal = visible(change.text ?? "")
            literalLabel = ["pdf", "svg", "png", "jpeg", "jpg"].contains(change.action ?? "") ? "Path on the pane's host" : "Source (verbatim)"
            preview += " pane=\(change.paneID!.uuidString.lowercased()) kind=\(change.action ?? "") source=" + (change.text ?? "")
        case .stageMigrationPlan:
            title = "Stage a workspace migration plan"
            path = "/api/workspace/migration-stage"
            object = ["path": change.text ?? "", "replace": change.enabled ?? false]
            if let name = change.name { object["name"] = name }
            row("Plan file", q(change.text ?? "")); row("Name in plan folder", change.name.map(q) ?? "From the file name")
            row("Open preview", change.enabled == true ? "Replaced if different" : "Kept; refused if a different plan is open")
            row("Effect", "Validates the plan, saves it in Relay's plan folder and opens it as the migration preview. Nothing is applied.")
            preview += " path=" + (change.text ?? "")
        case .applyMigration:
            title = "Apply the workspace migration"
            path = "/api/workspace/migration-apply"
            object = ["preview_id": change.migrationID?.uuidString.lowercased() ?? "", "checksum": change.text ?? ""]
            if let migration = snapshot.migration {
                row("Plan", migration.plan.map(q) ?? "Unnamed")
                row("Changes", "\(migration.tabs) tabs into \(migration.workspaces) workspaces, \(migration.paneMoves) pane moves")
            }
            row("Preview", change.migrationID?.uuidString.lowercased()); row("Checksum", change.text)
            row("Effect", "Re-files tabs into workspaces and moves the listed panes as they are, keeping their processes and conversations. "
                + "Refused if the preview or the workspace changed. Undo stays available.")
            preview += " preview=\(change.migrationID?.uuidString.lowercased() ?? "") checksum=\(change.text ?? "")"
        case .undoMigration:
            title = "Undo a workspace migration"
            path = "/api/workspace/migration-undo"
            object = ["migration_id": change.migrationID?.uuidString.lowercased() ?? ""]
            row("Migration", change.migrationID?.uuidString.lowercased())
            if let record = workspace.ownership.migrations.first(where: { $0.id == change.migrationID }) {
                row("Applied", record.appliedAt.formatted(date: .abbreviated, time: .shortened) + " · \(record.forward.count) tabs, \(record.paneMoves.count) pane moves")
            }
            row("Effect", "Returns tabs and moved panes where they were, unless moved again since. Panes keep their processes.")
            preview += " migration=\(change.migrationID?.uuidString.lowercased() ?? "")"
        default:
            break
        }
        row("Relay route", method + " " + path)
        row("Action ID", id)
        let data = body(object)
        let required = requiredCapabilities(change)
        var blocked: String?
        if change.tool == .sendCommand || change.tool == .agentCommand, change.promptProof?.empty != true {
            // Only positive typed evidence is called a draft; a suggestion or a
            // screen still drawing is unverified. Messages never need the prompt.
            blocked = (change.promptProof?.draft == true
                ? "The pane has a typed draft. Relay never clears or overwrites a draft; clear or send it yourself, then ask again."
                : "The pane's prompt could not be verified empty, so Relay will not type into it.")
                + (["claude", "codex"].contains(pane?.kind ?? "")
                    ? " To message its agent, use message_pane: it goes over the agent's socket and a draft does not block it." : "")
        } else if change.tool == .remember {
            blocked = nil
        } else if executor == nil || executor?.instance == nil {
            blocked = "Relay's control server is not running, so this action cannot run."
        } else if let missing = required.first(where: { !(executor?.permits($0) ?? false) }) {
            blocked = "Requires the MCP \(missing.rawValue) permission, which is not granted. Grant MCP terminal control in Relay first; the assistant cannot grant it."
        }
        let object0 = change.paneID.flatMap { workspace.panes[$0] }.map(ObjectIdentifier.init)
        let digestInput = data
        var card = RelayAssistantActionCard(id: actionID, tool: change.tool, title: title, rows: rows, literal: literal,
            literalLabel: literalLabel, requiredCapabilities: required, blockedReason: blocked, proposedAt: now,
            expiresAt: now.addingTimeInterval(timeout), method: method, path: path, body: data,
            argumentsDigest: SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined(),
            preview: preview, paneID: change.paneID, tabID: change.tabID ?? change.paneID.flatMap { snapshot.pane($0)?.tabID },
            host: change.host, paneObject: object0,
            bindingFingerprint: change.paneID.flatMap { facts.binding($0) })
        card.directory = change.directory
        card.affectedPanes = affected
        return card
    }

    /// Re-checks the target right before Run. Returns a refusal reason or nil.
    @MainActor static func revalidate(_ card: RelayAssistantActionCard, executor: (any RelayAssistantActionExecutor)?,
                                      snapshot: RelayAssistantSnapshot, workspace: WorkspaceModel,
                                      facts: RelayAssistantFacts) -> String? {
        guard let executor, executor.instance != nil else { return "Relay's control server is not running." }
        if let missing = card.requiredCapabilities.first(where: { !executor.permits($0) }) {
            return "The MCP \(missing.rawValue) permission is not granted."
        }
        if let host = card.host, !snapshot.hosts.contains(host) {
            return "The host \(host) is no longer in this workspace."
        }
        if card.tool == .recoverPane { return nil }
        if card.tool == .applyMigration {
            let sent = (try? JSONSerialization.jsonObject(with: card.body)) as? [String: String]
            guard let preview = workspace.migrationPreview, sent?["preview_id"] == preview.id.uuidString.lowercased(),
                  sent?["checksum"] == workspace.migrationChecksum else { return "The open migration preview changed since the card was shown." }
        }
        if card.tool == .undoMigration {
            let sent = (try? JSONSerialization.jsonObject(with: card.body)) as? [String: String]
            guard workspace.ownership.migrations.contains(where: { $0.id.uuidString.lowercased() == sent?["migration_id"] && $0.undoneAt == nil }) else {
                return "That migration is no longer applied."
            }
        }
        if let paneID = card.paneID {
            guard snapshot.pane(paneID) != nil, let pane = workspace.panes[paneID],
                  ObjectIdentifier(pane) == card.paneObject else {
                return "The target pane no longer exists or was replaced."
            }
            if let host = card.host, card.tool != .workspaceAction, snapshot.pane(paneID)?.hostAlias != host {
                return "The target pane moved to another host."
            }
            if facts.binding(paneID) != card.bindingFingerprint {
                return "The target pane's agent binding or process changed since the card was shown."
            }
        }
        if let tabID = card.tabID, snapshot.tab(tabID) == nil { return "The target tab no longer exists." }
        // The starting directory must still be admitted now, not just at proposal.
        if let directory = card.directory, let host = card.host, !snapshot.admitsDirectory(directory, host: host) {
            return "The starting directory is no longer a known directory on \(host)."
        }
        if card.tool == .tabAction || card.relayToolName == "relay_tab_action", let tabID = card.tabID, !card.affectedPanes.isEmpty {
            let current = workspace.paneIDs(inTab: tabID)
            guard current == card.affectedPanes.map(\.id) else {
                return "The tab's panes changed since the card was shown."
            }
            for pane in card.affectedPanes {
                guard let model = workspace.panes[pane.id], ObjectIdentifier(model) == pane.object,
                      facts.binding(pane.id) == pane.binding else {
                    return "A pane in the tab was replaced or its agent changed since the card was shown."
                }
            }
        }
        return nil
    }

    /// MCP routes can answer HTTP 200 with a body saying nothing ran. The
    /// outcome comes from the body, never from the HTTP status alone.
    static func classify(status: Int, body: Data, readOnly: Bool = false) -> String {
        guard (200..<300).contains(status) else {
            // The route can fail its completion audit after dispatching: that is
            // an unresolved outcome, never proof that nothing ran.
            let text = String(decoding: body.prefix(512), as: UTF8.self).lowercased()
            return text.contains("outcome unresolved") || text.contains("do not replay") || text.contains("outcome unavailable") || text.contains("committed but outcome audit failed")
                ? "unknown" : "failed"
        }
        let json = try? JSONSerialization.jsonObject(with: body)
        let object = json as? [String: Any]
        if object?["error"] != nil { return "failed" }
        // Catalog-proven reads return objects or arrays (for example desktop
        // routes). Both are completed observations without mutation receipts.
        if readOnly { return object != nil || json is [Any] ? "ran" : "failed" }
        guard let state = ((object?["status"] ?? object?["state"]) as? String)?.lowercased() else {
            // No status field: only the known success shapes count as ran
            // (host RPC result, saved pane link); anything else is unknown.
            return object?["result"] != nil || (object?["id"] != nil && object?["members"] != nil) ? "ran" : "unknown"
        }
        return outcomes[state] ?? "unknown"
    }

    /// Every status an assistant-reachable route returns, mapped explicitly.
    /// An unrecognised status is "unknown", never "ran".
    static let outcomes: [String: String] = [
        // Completed.
        "applied": "ran", "attached": "ran", "created": "ran", "terminated": "ran", "selected": "ran",
        "published": "ran", "committed": "ran", "retired": "ran", "linked": "ran", "imported": "ran", "staged": "ran", "undone": "ran",
        // Terminal edit transport accepted one native input packet. The caller
        // must observe the screen/receipt before deciding the next interaction.
        "input_submitted": "ran",
        // Pane messages: written to the recipient's socket is delivery, not reading.
        "written_to_socket": "ran", "accepted_by_provider": "ran", "turn_started": "ran", "turn_completed": "ran",
        // Refused before anything ran.
        "refused": "refused", "blocked": "refused", "denied": "refused", "unsupported": "refused",
        "rejected_unverified_source": "refused", "draft_present": "refused", "input_changed": "refused",
        "prompt_unverified": "refused", "not_applied": "refused",
        // Not sent: nothing ran.
        "unavailable": "failed", "not_sent": "failed", "not_found": "failed", "failed": "failed",
        "error": "failed", "conflict": "failed",
        // Submitted or in progress; the result cannot be observed here.
        "submitted_outcome_unknown": "unknown", "outcome_unknown": "unknown", "checking_owner": "unknown",
        "pending": "unknown", "uncertain": "unknown", "resuming": "unknown", "created_session_start_pending": "unknown",
    ]

    /// Literal rendering: every control, format (Cf), bidi, variation
    /// selector, default-ignorable, separator and non-ASCII space character is
    /// shown by name or code point, so nothing invisible can hide in a card.
    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10: out += "↵\n"
            case 9: out += "⇥"
            case 13: out += "␍"
            case 27: out += "␛"
            case 0..<32: out.unicodeScalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 127: out += "␡"
            case 32: out += " "
            default:
                if invisible(scalar) { out += String(format: "⟨U+%04X⟩", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    static func invisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .surrogate, .unassigned:
            return true
        default:
            return properties.isDefaultIgnorableCodePoint || properties.isVariationSelector ||
                properties.isBidiControl || properties.isNoncharacterCodePoint
        }
    }

    /// A supplied string (title, name, host, directory) as one quoted, escaped
    /// line: it cannot add rows, fake labels or hide characters.
    static func q(_ text: String) -> String {
        let escaped = singleLine(text).replacingOccurrences(of: "“", with: "⟨U+201C⟩")
            .replacingOccurrences(of: "”", with: "⟨U+201D⟩")
        return "“" + (escaped.count > 200 ? String(escaped.prefix(199)) + "…" : escaped) + "”"
    }

    static func singleLine(_ text: String) -> String {
        visible(text).replacingOccurrences(of: "↵\n", with: "↵")
    }
}
