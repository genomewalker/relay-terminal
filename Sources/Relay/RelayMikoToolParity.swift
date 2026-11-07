import CryptoKit
import Foundation

/// Committed from the MCP catalog; the Go catalog test compares every byte of
/// the definitions. Only a page of names or one exact schema enters the prompt.
enum RelayMikoToolCatalog {
    static let aliases = [
        "relay_list_panes": "list_panes", "relay_read_agent_context": "read_agent_context", "relay_select_pane": "select_pane",
        "relay_list_managed_panes": "list_recoverable_panes", "relay_exec_status": "exec_status", "relay_send_command": "send_command",
        "relay_terminate_managed_pane": "terminate_pane", "relay_recover_pane": "recover_pane", "relay_configure_context_rotation": "set_context_rotation",
        "relay_exec": "exec_command", "relay_workspace_action": "workspace_action", "relay_new_local_tab": "new_local_tab",
        "relay_tab_action": "tab_action", "relay_render_content": "open_file_preview", "relay_link_panes": "link_panes",
        "relay_unlink_panes": "unlink_panes", "relay_bind_question_thread": "bind_question_thread", "relay_unbind_question_thread": "unbind_question_thread",
        "relay_message_pane": "message_pane", "relay_pane_message_receipt": "message_receipt", "relay_list_pane_links": "list_pane_links",
        "relay_workspace_migration_stage_plan": "stage_migration_plan", "relay_workspace_migration_apply": "apply_migration", "relay_workspace_migration_undo": "undo_migration"
    ]
    static func related(_ name: String) -> Set<String> {
        var result: Set<String> = [name]
        if let alias = aliases[name] { result.insert(alias) }
        for (exact, alias) in aliases where alias == name { result.insert(exact) }
        return result
    }
    static func catalogDataMatchesBuild(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
            "efac23d0d0acf64271cf4f2c3c6154c83d3051c3d7c174ac6d6df80db914cb94"
    }
    static let definitions: [RelayPaneHealthJSON] = {
        guard let url = Bundle.module.url(forResource: "miko_tool_catalog", withExtension: "json", subdirectory: "Rotation"),
              let data = try? Data(contentsOf: url), catalogDataMatchesBuild(data),
              let value = try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: data),
              case .array(let entries) = value else { return [] }
        return entries
    }()
    static var names: Set<String> { Set(definitions.compactMap { $0["name"]?.string }) }
    static func definition(_ name: String) -> RelayPaneHealthJSON? { definitions.first { $0["name"]?.string == name } }
    static func discover(_ input: RelayPaneHealthJSON) throws -> RelayPaneHealthJSON {
        guard case .object(let fields) = input,
              Set(fields.keys).isSubset(of: ["query", "tool_name", "offset"]) else { throw failure("Unknown catalog arguments.") }
        if let value = fields["tool_name"] {
            guard fields.count == 1, let name = value.string, let entry = definition(name) else { throw failure("Exact exposed tool required.") }
            return entry
        }
        var query = ""
        if let value = fields["query"] { guard let s = value.string, s.utf8.count <= 128 else { throw failure("query must be at most 128 bytes.") }; query = s.lowercased() }
        var offset = 0
        if let value = fields["offset"] { guard case .integer(let n) = value, (0...1024).contains(n) else { throw failure("Invalid catalog offset.") }; offset = Int(n) }
        let matches = definitions.filter { query.isEmpty || (($0["name"]?.string ?? "") + " " + ($0["description"]?.string ?? "")).lowercased().contains(query) }
        let page = matches.dropFirst(offset).prefix(12).map { entry in
            RelayPaneHealthJSON.object(["name": entry["name"] ?? .null, "tier": entry["tier"] ?? .null,
                "description": .string(String((entry["description"]?.string ?? "").prefix(180)))])
        }
        return .object(["tools": .array(page), "total": .integer(Int64(matches.count)),
                        "next_offset": offset + page.count < matches.count ? .integer(Int64(offset + page.count)) : .null])
    }
    static func failure(_ text: String) -> RelayAssistantToolError { .init(message: text) }
}

struct RelayMikoToolRequest: Equatable, Sendable {
    let tool: String
    let tier: String
    let method: String
    let path: String
    let body: Data

    static func decode(_ data: Data, expectedTool: String) throws -> Self {
        guard data.count <= 300_000,
              case .object(let fields) = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: data),
              Set(fields.keys) == ["tool", "tier", "method", "path", "body"],
              fields["tool"]?.string == expectedTool,
              let definition = RelayMikoToolCatalog.definition(expectedTool),
              let tier = fields["tier"]?.string, tier == definition["tier"]?.string,
              let method = fields["method"]?.string, ["GET", "POST", "DELETE"].contains(method),
              let path = fields["path"]?.string, path.hasPrefix("/api/"),
              !path.contains(".."), !path.contains("#"), !path.contains("\n"),
              let bodyValue = fields["body"], case .object = bodyValue else { throw RelayMikoToolCatalog.failure("Invalid MCP request compiler output.") }
        return Self(tool: expectedTool, tier: tier, method: method, path: path,
                    body: try RelayPaneHealthJSON.data(fields["body"]!))
    }

    var capabilities: [MCPWorkspaceCapability] {
        // Read-only file images still use the workspace host-input grant.
        if tool == "relay_workspace_image" || ["relay_account_mcp_preview", "relay_account_mcp_sync", "relay_account_mcp_sync_receipt"].contains(tool) { return [.input] }
        if tier == "read" { return [] }
        switch tool {
        case "relay_select_pane": return [.navigate]
        case "relay_new_local_tab", "relay_recover_pane": return [.create]
        case "relay_new_stacked_pane": return [.create, .layout]
        case "relay_stack_pane", "relay_rename_pane": return [.layout]
        case "relay_terminate_managed_pane": return [.terminate]
        case "relay_workspace_action":
            let object = try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: body)
            switch object?["action"]?.string {
            case "select", "overview", "back", "forward", "up": return [.navigate]
            case "newTab": return [.create]
            case "splitRight", "splitDown": return [.create, .layout]
            default: return [.layout]
            }
        case "relay_host_request", "relay_workspace_request":
            let object = try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: body)
            let operation = object?["operation"]?.string ?? object?["request"]?["operation"]?.string
            if tool == "relay_host_request", operation == "status" { return [] }
            return ["process_signal", "account_force_commit"].contains(operation ?? "") ? [.input, .terminate] : [.input]
        case "relay_update_settings", "relay_check_host_installation", "relay_check_intelligence", "relay_publish_surface",
             "relay_tab_action", "relay_render_content", "relay_link_panes", "relay_unlink_panes",
             "relay_bind_question_thread", "relay_unbind_question_thread", "relay_workspace_migration_stage_plan",
             "relay_workspace_migration_apply", "relay_workspace_migration_undo", "relay_bind_workspace_context": return [.layout]
        case "relay_apply_installed_update", "relay_send_command", "relay_message_pane", "relay_exec", "relay_exec_cancel", "relay_upload_file",
             "relay_install_relayd", "relay_rollback_relayd", "relay_move_pane_account", "relay_configure_context_rotation", "relay_terminal_edit", "relay_codex_resume_pane": return [.input]
        // Editor/R/network operations keep their existing domain-specific
        // approvals. Do not invent an additional terminal-input permission.
        default: return []
        }
    }
}

/// This helper only compiles; it has no live token, endpoint or daemon state.
enum RelayMikoToolCompiler {
    // Return only trusted catalog keys, never rejected arguments or helper
    // stderr. The latter can contain secrets or arbitrarily large input keys.
    static func argumentRefusal(tool: String) -> String {
        guard let schema = RelayMikoToolCatalog.definition(tool)?["inputSchema"],
              case .object(let properties) = schema["properties"] else {
            return "Relay refused the tool arguments; nothing ran. Retrieve the exact tool schema with relay_tools(tool_name:)."
        }
        let allowed = properties.keys.sorted().joined(separator: ", ")
        let required: String
        if case .array(let values) = schema["required"] {
            required = values.compactMap { $0.string }.sorted().joined(separator: ", ")
        } else { required = "" }
        return "Relay refused the tool arguments; nothing ran. Allowed fields: " +
            allowed + ". Required fields: " + required +
            ". Correct the arguments using relay_tools(tool_name:); do not infer field aliases."
    }
    static func compile(tool: String, arguments: String) async throws -> RelayMikoToolRequest {
        guard RelayMikoToolCatalog.names.contains(tool), arguments.utf8.count <= 60_000,
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("relay-mcp"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw RelayMikoToolCatalog.failure("Bundled MCP request compiler unavailable.") }
        // Keep the argument JSON intact: the Go decoder rejects duplicate keys.
        let quoted = String(decoding: try JSONEncoder().encode(tool), as: UTF8.self)
        let input = Data(("{\"tool_name\":" + quoted + ",\"arguments\":" + arguments + "}").utf8)
        let output: Data = try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = executable; process.arguments = ["--miko-plan"]
            process.environment = ["PATH": "/usr/bin:/bin"]
            // Diagnostics never enter the model and cannot fill an undrained
            // pipe (an invalid argument key may itself be tens of KB).
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            try process.run()
            // Concurrent writing avoids pipe-buffer deadlocks for 60 KB input.
            let writer = Task.detached { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            try await writer.value
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 300_000 else { throw RelayMikoToolCatalog.failure(argumentRefusal(tool: tool)) }
            return data
        }.value
        return try RelayMikoToolRequest.decode(output, expectedTool: tool)
    }
}

/// Used by actual dispatch, and enumerated by the bounded tests. Only an event
/// from the user can approve. Taking authority consumes it before any await.
struct RelayMikoDispatchGate {
    enum Origin: CaseIterable { case user, model, pane }
    enum Approval: CaseIterable { case none, pending, approved, expired, cancelled, consumed }
    enum Event: CaseIterable { case approve, cancel, expire, run }
    private(set) var approval: Approval
    init(approval: Approval = .pending) { self.approval = approval }
    mutating func step(_ event: Event, origin: Origin, enabled: Bool, granted: Bool, change: Bool, paneBlocked: Bool = true) -> Bool {
        switch event {
        case .approve: if origin == .user && approval == .pending { approval = .approved }
        case .cancel: if approval != .consumed { approval = .cancelled }
        case .expire: if approval != .consumed { approval = .expired }
        case .run:
            guard enabled, granted, !change || (approval == .approved && !(origin == .pane && paneBlocked)) else { return false }
            if change { approval = .consumed }
            return true
        }
        return false
    }
}


/// Only Settings writes these preferences. They are deliberately absent from
/// RelaySettingsPolicy, the MCP settings allowlist, and all model tool schemas.
struct RelayMikoPolicySettings: Equatable, Sendable {
    enum Autonomy: String, CaseIterable, Sendable {
        case autonomous, cardsForWrites = "cards_for_writes", cardsForAllActions = "cards_for_all_actions"
    }
    var autonomy: Autonomy = .autonomous
    var minute = 60
    var hour = 600
    var targetMinute = 12
    var repetitions = 3
    var bounded: Self {
        var x = self
        x.minute = min(600, max(1, minute)); x.hour = min(10_000, max(1, hour))
        x.targetMinute = min(100, max(1, targetMinute)); x.repetitions = min(20, max(1, repetitions))
        return x
    }
}

enum RelayMikoActionPolicy {
    enum Tier: String, CaseIterable { case read, reversible, coordination }
    /// The single fixed card set. Conditions are evaluated against exact
    /// request fields and the current workspace below; unknown close targets
    /// are treated as active. Arbitrary program behavior retains MCP's trust.
    static let cardRequiredActions: [String: Set<String>] = [
        "relay_terminate_managed_pane": ["active_agent"],
        "relay_workspace_action": ["close_active_agent"],
        "relay_tab_action": ["close_active_agent"],
        "relay_host_request": ["process_signal", "account_force_commit", "file_delete", "cancel", "plugin_signal"],
        "relay_workspace_request": ["process_signal", "account_force_commit", "file_delete", "cancel", "plugin_signal"],
        "relay_exec_cancel": ["always"],
        "relay_install_relayd": ["always"], "relay_rollback_relayd": ["always"],
        "relay_workspace_migration_apply": ["always"], "relay_workspace_migration_undo": ["always"],
        "relay_update_settings": ["agent_account_rules"]
    ]
    static let coordinationTools: Set<String> = [
        "relay_account_mcp_sync",
        "set_capacity_pause", "request_capacity_action", "native_action", "native_image", "native_launch", "native_resume",
        "agent_command", "reconnect_pane", "propose_plan", "new_tab_layout", "relay_exec", "relay_send_command", "relay_host_request", "relay_workspace_request",
        "relay_apply_installed_update", "relay_recover_pane", "relay_move_pane_account", "relay_configure_context_rotation", "relay_codex_resume_pane",
        "relay_update_settings", "relay_new_local_tab", "relay_new_stacked_pane", "relay_terminate_managed_pane",
        "relay_request_r_setup", "relay_request_r_evaluation", "relay_run_editor_selection",
        "relay_run_editor_file", "relay_run_project_file", "relay_run_r_code", "relay_pause_r_session",
        "relay_request_editor_edit", "relay_request_editor_save", "relay_install_relayd",
        "relay_rollback_relayd", "relay_exec_cancel", "relay_request_network_action",
        "relay_request_desktop_route", "relay_create_desktop_route", "relay_send_desktop_message"
    ]
    static func exactName(_ name: String) -> String {
        RelayMikoToolCatalog.aliases.first { $0.value == name }?.key ?? name
    }
    static func tier(_ tool: String, body: RelayPaneHealthJSON = .object([:])) -> Tier {
        let name = exactName(tool)
        if name == "relay_workspace_action" {
            // Native aliases and exact MCP calls classify the effect, not the
            // wrapper name. Creating a retained pane starts a new process lane.
            switch body["action"]?.string {
            case "select", "zoom", "unzoom", "float", "dock", "balance", "close",
                 "conversation", "terminal", "overview", "back", "forward", "up": return .reversible
            case "newTab", "splitRight", "splitDown": return .coordination
            default: return .coordination // Unknown/future effects never inherit reversible authority.
            }
        }
        if ["relay_host_request", "relay_workspace_request"].contains(name),
           let operation = body["request"]?["operation"]?.string ?? body["operation"]?.string,
           ["status", "capabilities", "file_stat", "file_list", "file_read", "file_verify", "process_list"].contains(operation) { return .read }
        if ["relay_host_request", "relay_workspace_request"].contains(name),
           let operation = body["request"]?["operation"]?.string ?? body["operation"]?.string, operation == "plugin",
           let plugin = body["request"]?["plugin"]?["operation"]?.string ?? body["plugin"]?["operation"]?.string,
           ["hpcAccounting", "hpcDetails", "hpcLogs", "hpcJobs", "gitReview", "projectActions", "artifacts", "transfers"].contains(plugin) { return .read }
        if name == "relay_select_editor_code" { return .reversible }
        if coordinationTools.contains(name) { return .coordination }
        if RelayMikoToolCatalog.definition(name)?["tier"]?.string == "read" { return .read }
        if let native = RelayAssistantToolName(rawValue: tool), native.tier == .read { return .read }
        return .reversible
    }
    static func fixedCard(_ tool: String, body: RelayPaneHealthJSON, activeAgent: Bool) -> Bool {
        let name = exactName(tool)
        guard let rules = cardRequiredActions[name] else { return false }
        if rules.contains("always") { return true }
        if rules.contains("active_agent"), activeAgent { return true }
        if rules.contains("close_active_agent"), body["action"]?.string == "close", activeAgent { return true }
        if rules.contains("agent_account_rules"), body["changes"]?["agent_account_rules"] != nil { return true }
        let operation = body["request"]?["operation"]?.string ?? body["operation"]?.string ?? ""
        if operation == "plugin", rules.contains("plugin_signal"),
           (body["request"]?["plugin"]?["operation"]?.string ?? body["plugin"]?["operation"]?.string) == "hpcCancel" { return true }
        return rules.contains(operation)
    }
    static func requiresCard(settings: RelayMikoPolicySettings, tier: Tier, origin: RelayMikoDispatchGate.Origin,
                             fixed: Bool) -> Bool {
        // The user delegates routine and high-impact actions to Miko in this
        // mode. Content provenance remains recorded, but reading a pane does
        // not revoke that standing delegation. Miko asks in its reply when a
        // decision is needed; it must then wait for a new user turn.
        if settings.autonomy == .autonomous { return false }
        return fixed || settings.autonomy == .cardsForAllActions ||
        (settings.autonomy == .cardsForWrites && tier != .read) || (origin == .pane && tier == .coordination)
    }
    static func origin(_ exchange: RelayAssistantExchange) -> RelayMikoDispatchGate.Origin {
        if exchange.paneDerived { return .pane }
        switch exchange.origin { case .agent, .supervisor: return .pane; case .user: return .user; default: return .model }
    }
    /// Only locally compiled discovery is typed metadata. All upstream replies
    /// can contain pane-writable names, configuration, output or echoed errors.
    /// Unknown tools and operations fail closed, including nominal metadata.
    static func readsContent(_ tool: String, input: RelayPaneHealthJSON) -> Bool {
        let name = exactName(tool)
        return name != "relay_tools"
    }

    static func observeContext(_ context: RelayAssistantSnapshot.ModelContext, exchange: inout RelayAssistantExchange) {
        exchange.paneDerived = exchange.paneDerived || context.paneDerived
    }

    static func observeResult(_ tool: String, input: RelayPaneHealthJSON, isError: Bool,
                              exchange: inout RelayAssistantExchange) {
        // Failure is a transport/outcome fact, never a provenance exception.
        if readsContent(tool, input: input) { exchange.paneDerived = true }
    }
    static func activeAgent(paneID: UUID?, tabID: UUID?, snapshot: RelayAssistantSnapshot) -> Bool {
        let panes = snapshot.panes.filter { paneID != nil ? $0.id == paneID : $0.tabID == tabID }
        guard !panes.isEmpty else { return true }
        // An ended/stale phase is not proof that an agent process exited.
        // Known idle shells may close autonomously; other/unknown kinds and
        // busy phases require the card.
        return panes.contains { $0.kind != "shell" || ["active", "working", "busy"].contains($0.phase) }
    }
    /// Hash logical arguments, ignoring only transport idempotency/incarnation
    /// fields. Fresh request IDs must not defeat the repeated-action guard.
    static func lookupIdentityFields(_ tool: String, input: RelayPaneHealthJSON) -> Set<String> {
        let name = exactName(tool)
        let operation = input["request"]?["operation"]?.string ?? input["operation"]?.string
        if ["relay_exec_status", "relay_exec_cancel"].contains(name) || ["status", "input", "cancel"].contains(operation ?? "") { return ["job_id"] }
        if ["relay_remote_install_receipt", "relay_network_receipt", "relay_desktop_route_receipt", "relay_r_operation_receipt",
            "relay_editor_operation_receipt", "relay_read_r_snapshot"].contains(name) { return ["request_id", "requestID"] }
        return []
    }
    static func argumentsDigest(_ input: RelayPaneHealthJSON, identityFields: Set<String> = []) -> String {
        func logical(_ value: RelayPaneHealthJSON) -> RelayPaneHealthJSON {
            switch value {
            case .object(let fields): return .object(fields.filter { identityFields.contains($0.key) || !["request_id", "requestID", "instance", "job_id"].contains($0.key) }.mapValues(logical))
            case .array(let values): return .array(values.map(logical))
            default: return value
            }
        }
        let data = (try? RelayPaneHealthJSON.data(logical(input))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Internal result envelopes have tool-specific fields. Only the named
    /// outcome vocabulary may become an audit outcome; arbitrary content
    /// cannot introduce an approval or an invented success state.
    static func auditOutcome(_ text: String, isError: Bool) -> String {
        let fallback = isError ? "refused_or_failed" : "returned"
        guard text.utf8.count <= 128_000,
              let object = try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: Data(text.utf8)),
              let outcome = object["outcome"]?.string,
              ["ran", "failed", "partial", "unknown", "refused", "cancelled", "expired", "not_run"].contains(outcome) else { return fallback }
        return outcome
    }
}

/// The production admission ledger, shared across all workspace harnesses.
/// At most 10,000 entries, no unbounded per-target dictionaries. Admission is
/// synchronous on the main actor, so two workspaces cannot spend one slot.
@MainActor final class RelayMikoActionBudget {
    static let shared = RelayMikoActionBudget()
    private struct Entry { let at: TimeInterval; let target: String; let signature: String; let readOnly: Bool }
    private var entries: [Entry] = []
    private var highWater: TimeInterval = 0
    func admit(tool: String, target: String, digest: String, settings: RelayMikoPolicySettings, now: Date, readOnly: Bool = false) -> Bool {
        let settings = settings.bounded
        let time = max(highWater, now.timeIntervalSince1970)
        highWater = time
        entries.removeAll { time - $0.at >= 3600 }
        let minute = entries.filter { time - $0.at < 60 }
        let signature = tool + "|" + target + "|" + digest
        guard entries.count < settings.hour, minute.count < settings.minute else { return false }
        // Fresh observations and idempotent navigation may repeat after a wait or a change.
        // Per-target and repeated-action limits fence mutations, while all reads
        // still consume the shared minute/hour budgets.
        if !readOnly {
            guard minute.filter({ !$0.readOnly && $0.target == target }).count < settings.targetMinute,
                  entries.filter({ !$0.readOnly && $0.signature == signature }).count < settings.repetitions else { return false }
        }
        entries.append(.init(at: time, target: target, signature: signature, readOnly: readOnly))
        return true
    }
}
