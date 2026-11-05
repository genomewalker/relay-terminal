import Foundation
import CryptoKit

/// Typed preferences only. Credentials, grants and arbitrary UserDefaults keys
/// cannot be represented by this API.
enum RelaySettingValue: Codable, Equatable, Sendable {
    case bool(Bool), number(Double), string(String), bindings([String: RelayKeyBinding])
    /// Agent account routing: {"version":1,"global":{provider: label},
    /// "hosts":{host: {provider: label}},"workspaces":{uuid: {provider: label}}}.
    case accountRules(RelayAgentAccountRules)
    case json(RelayPaneHealthJSON)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        // Only rules carry "version"; no key binding is named that.
        else if let v = try? c.decode(RelayAgentAccountRules.Wire.self) { self = .accountRules(v.rules) }
        else if let v = try? c.decode([String: RelayKeyBinding].self) { self = .bindings(v) }
        else { self = .json(try c.decode(RelayPaneHealthJSON.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .bindings(let v): try c.encode(v)
        case .accountRules(let v): try c.encode(v)
        case .json(let v): try c.encode(v)
        }
    }
}

struct RelaySettingsProposal: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let expectedRevision: String
    let changes: [String: RelaySettingValue]
    enum CodingKeys: String, CodingKey {
        case instance, changes
        case requestID = "request_id", expectedRevision = "expected_revision"
    }
}

struct RelaySettingsDefinition: Codable, Sendable {
    let key: String
    let type: String
    var minimum: Double? = nil
    var maximum: Double? = nil
    var choices: [String]? = nil
}

struct RelaySettingsSnapshot: Codable, Sendable {
    let schema: String
    let instance: UUID
    let revision: String
    let values: [String: RelaySettingValue]
    let definitions: [RelaySettingsDefinition]
    var agentMaintenance: RelayAgentMaintenance.Snapshot? = nil
    var receipt: RelaySettingsReceipt? = nil
}

/// A verified observation for this process instance, never a durable claim.
struct RelaySettingsReceipt: Codable, Sendable {
    let requestID: UUID
    let verifiedRevision: String
    let changedKeys: [String]
    let outcome: String
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", verifiedRevision = "verified_revision"
        case changedKeys = "changed_keys", outcome
    }
}

enum RelaySettingsPolicy {
    static let definitions: [RelaySettingsDefinition] = [
        .init(key: "font_family", type: "string"),
        .init(key: "font_size", type: "number", minimum: 9, maximum: 24),
        .init(key: "terminal_padding", type: "number", minimum: 0, maximum: 20),
        .init(key: "cursor_blink", type: "boolean"),
        .init(key: "palette", type: "string", choices: RelayTerminalPalette.allCases.map(\.rawValue)),
        .init(key: "compact_interface", type: "boolean"),
        .init(key: "hide_sidebar_fullscreen", type: "boolean"),
        .init(key: "artifact_previews", type: "boolean"),
        .init(key: "artifact_presentation", type: "string", choices: RelayArtifactPresentation.allCases.map(\.rawValue)),
        .init(key: "intelligence_enabled", type: "boolean"),
        .init(key: "decision_model_path", type: "string"),
        .init(key: "decision_model_sha256", type: "string"),
        .init(key: "intelligence_summaries", type: "boolean"),
        .init(key: "intelligence_search", type: "boolean"),
        .init(key: "relayd_auto_update", type: "boolean"),
        .init(key: "automatic_agent_maintenance", type: "boolean"),
        .init(key: "haiku_pane_health", type: "boolean"),
        .init(key: "key_bindings", type: "object"),
        .init(key: "agent_account_rules", type: "object"),
        .init(key: "miko_host_key", type: "string"),
        .init(key: "miko_autonomy", type: "string", choices: RelayMikoPolicySettings.Autonomy.allCases.map(\.rawValue)),
        .init(key: "miko_actions_per_minute", type: "number", minimum: 1, maximum: 600),
        .init(key: "miko_actions_per_hour", type: "number", minimum: 1, maximum: 10_000),
        .init(key: "miko_target_actions_per_minute", type: "number", minimum: 1, maximum: 100),
        .init(key: "miko_identical_actions_per_hour", type: "number", minimum: 1, maximum: 20),
        .init(key: "miko_paused", type: "boolean"),
        .init(key: "miko_shepherd", type: "object"),
        .init(key: "assistant_hotkey_enabled", type: "boolean"),
        .init(key: "assistant_hotkey", type: "object"),
        .init(key: "claude_quota_failover", type: "object"),
        .init(key: "legacy_context_rotation_enabled", type: "boolean"),
        .init(key: "legacy_context_rotation_budget", type: "number", minimum: 20_000, maximum: 2_000_000)
    ]

    // CLI configuration is a user capability, not authority for Miko to alter
    // its own autonomy, monitoring, spending/loop policy or pause state.
    static func allows(changes: [String: RelaySettingValue], assistantIdentity: Bool) -> Bool {
        !assistantIdentity || !changes.keys.contains {
            $0.hasPrefix("miko_") || $0 == "claude_quota_failover"
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> RelaySettingValue {
        .json(try JSONDecoder().decode(RelayPaneHealthJSON.self, from: JSONEncoder().encode(value)))
    }

    static func validateObject(_ value: RelayPaneHealthJSON, key: String) throws {
        guard case .object = value else { throw ControlError.invalid("An object is required: " + key) }
        let data = try RelayPaneHealthJSON.data(value)
        switch key {
        case "miko_shepherd": _ = try RelayShepherdSettings.decode(data)
        case "claude_quota_failover": _ = try RelayClaudeQuotaSettings.decode(data)
        case "assistant_hotkey":
            try RelayShepherdWire.keys(data, allowed: ["keyCode", "control", "option", "command", "shift"], limit: 8192)
            guard try JSONDecoder().decode(RelayAssistantHotkey.self, from: data).valid else {
                throw ControlError.invalid("Invalid assistant shortcut")
            }
        default: throw ControlError.invalid("Unknown object setting: " + key)
        }
    }

    static func validate(_ changes: [String: RelaySettingValue]) throws {
        guard !changes.isEmpty, changes.count <= definitions.count else {
            throw ControlError.invalid("Supply known settings from the schema")
        }
        if changes["miko_paused"] != nil && changes.count != 1 {
            throw ControlError.invalid("Change Miko pause separately so a storage failure cannot partially apply other settings")
        }
        for (key, value) in changes {
            guard let definition = definitions.first(where: { $0.key == key }) else {
                throw ControlError.invalid("Unknown setting: \(key)")
            }
            switch (definition.type, value) {
            case ("boolean", .bool): break
            case ("number", .number(let n)):
                if key.hasPrefix("miko_") || key == "legacy_context_rotation_budget" {
                    guard n.rounded() == n else { throw ControlError.invalid("An integer is required: " + key) }
                }
                guard n.isFinite, n >= definition.minimum!, n <= definition.maximum! else {
                    throw ControlError.invalid("Value is outside the allowed range: \(key)")
                }
            case ("string", .string(let s)):
                guard s.utf8.count <= (key == "decision_model_path" ? 4096 : key == "miko_host_key" ? 256 : 160),
                      !s.contains(where: { $0.isNewline || $0 == "\0" }) else {
                    throw ControlError.invalid("Invalid string: \(key)")
                }
                if let choices = definition.choices, !choices.contains(s) {
                    throw ControlError.invalid("Unsupported value: \(key)")
                }
                if key == "miko_host_key", s.isEmpty { throw ControlError.invalid("Miko host key is required") }
                if key == "font_family", s.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ControlError.invalid("Font family is required")
                }
                if key == "decision_model_path", !s.isEmpty, !s.hasPrefix("/") {
                    throw ControlError.invalid("Model path must be absolute")
                }
                if key == "decision_model_sha256", !s.isEmpty,
                   s.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) == nil {
                    throw ControlError.invalid("Trusted model digest must be SHA-256")
                }
            case ("object", .json(let value)):
                try validateObject(value, key: key)
            case ("object", .accountRules(let rules)):
                guard key == "agent_account_rules" else { throw ControlError.invalid("Wrong value type: \(key)") }
                guard rules.version == 1, rules.isValid,
                      rules.hosts.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains(where: { $0.isNewline || $0 == "\0" }) })
                else {
                    throw ControlError.invalid("Account rules map providers (claude, codex) to labels of 1-24 lowercase letters, digits, '-' or '_', per host and per workspace UUID")
                }
            case ("object", .bindings(let bindings)):
                guard key == "key_bindings" else {
                    throw ControlError.invalid("agent_account_rules needs the rules object with \"version\": 1, as relay_get_settings returns it")
                }
                guard bindings.count <= RelayCommand.allCases.count else {
                    throw ControlError.invalid("Too many keyboard bindings")
                }
                for (id, binding) in bindings {
                    guard RelayCommand(rawValue: id) != nil,
                          (binding.command || binding.control || binding.option),
                          binding.key.count == 1 || ["return", "left", "right", "up", "down", "tab", "escape", "space"].contains(binding.key),
                          RelayKeyBindingStorage.reservedConflictName(for: binding) == nil else {
                        throw ControlError.invalid("Invalid or reserved keyboard binding: \(id)")
                    }
                }
                for command in RelayCommand.allCases {
                    let binding = RelayKeyBindingStorage.binding(for: command, overrides: bindings)
                    if let conflict = RelayKeyBindingStorage.conflict(for: binding, command: command, overrides: bindings) {
                        throw ControlError.invalid("Keyboard binding conflict: \(command.rawValue) / \(conflict.rawValue)")
                    }
                }
            default: throw ControlError.invalid("Wrong value type: \(key)")
            }
        }
    }

    enum ControlError: LocalizedError {
        case invalid(String), conflict
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            case .conflict: "Settings changed or request ID was reused; read current settings before retrying"
            }
        }
    }
}

@MainActor
final class RelaySettingsControl {
    /// The routing store the account rules read and write (tests use their own).
    let routing: RelayAgentAccountRouting
    private var receipts: [UUID: (RelaySettingsProposal, RelaySettingsSnapshot)] = [:]
    private let receiptLimit = 1024
    private var uncertainRequests: Set<UUID> = []

    init(routing: RelayAgentAccountRouting = .shared) {
        self.routing = routing
    }

    func snapshot(instance: UUID) throws -> RelaySettingsSnapshot {
        let p = RelayPreferences.shared
        let values: [String: RelaySettingValue] = [
            "font_family": .string(p.fontFamily), "font_size": .number(p.fontSize),
            "terminal_padding": .number(p.terminalPadding), "cursor_blink": .bool(p.cursorBlink),
            "palette": .string(p.palette.rawValue), "compact_interface": .bool(p.compactInterface),
            "hide_sidebar_fullscreen": .bool(p.hideSidebarInFullScreen),
            "artifact_previews": .bool(p.showArtifactPreviews),
            "artifact_presentation": .string(p.artifactPresentation.rawValue),
            "intelligence_enabled": .bool(p.intelligenceEnabled),
            "automatic_agent_maintenance": .bool(p.automaticAgentMaintenance),
            "haiku_pane_health": .bool(p.haikuPaneHealth),
            "decision_model_path": .string(p.decisionModelPath),
            "decision_model_sha256": .string(p.decisionModelSHA256),
            "intelligence_summaries": .bool(p.automaticAgentSummaries),
            "intelligence_search": .bool(p.semanticAgentSearch),
            "relayd_auto_update": .bool(p.automaticallyUpdateRelayd),
            "key_bindings": .bindings(p.keyBindings),
            "agent_account_rules": .accountRules(routing.rules),
            "miko_host_key": .string(p.mikoHostKey),
            "miko_autonomy": .string(p.mikoAutonomy.rawValue),
            "miko_actions_per_minute": .number(Double(p.mikoMinute)),
            "miko_actions_per_hour": .number(Double(p.mikoHour)),
            "miko_target_actions_per_minute": .number(Double(p.mikoTargetMinute)),
            "miko_identical_actions_per_hour": .number(Double(p.mikoRepetitions)),
            "miko_paused": .bool(RelayMikoSupervision.shared.current.disabledTools.contains("*")),
            "miko_shepherd": try RelaySettingsPolicy.json(p.shepherd),
            "assistant_hotkey_enabled": .bool(p.assistantHotkeyEnabled),
            "assistant_hotkey": try RelaySettingsPolicy.json(p.assistantHotkey),
            "claude_quota_failover": try RelaySettingsPolicy.json(p.claudeQuotaFailover),
            "legacy_context_rotation_enabled": .bool(p.automaticContextRotation),
            "legacy_context_rotation_budget": .number(Double(p.contextRotationBudget))
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(values)).map { String(format: "%02x", $0) }.joined()
        return .init(schema: "relay.settings/1", instance: instance, revision: digest,
                     values: values, definitions: RelaySettingsPolicy.definitions,
                     agentMaintenance: RelayAgentMaintenance.shared.snapshot())
    }

    func apply(_ proposal: RelaySettingsProposal) throws -> RelaySettingsSnapshot {
        if let (old, result) = receipts[proposal.requestID] {
            guard old == proposal else { throw RelaySettingsPolicy.ControlError.conflict }
            // A lost-reply retry may arrive after a native settings change.
            // Never replay the old snapshot as a current verified result.
            guard try snapshot(instance: proposal.instance).revision == result.revision else {
                throw RelaySettingsPolicy.ControlError.conflict
            }
            return result
        }
        guard !uncertainRequests.contains(proposal.requestID) else {
            throw RelaySettingsPolicy.ControlError.invalid("This settings request has an uncertain outcome; read current settings before a new operation")
        }
        guard receipts.count + uncertainRequests.count < receiptLimit else {
            throw RelaySettingsPolicy.ControlError.invalid("Settings receipt capacity reached; read current settings and restart Relay before another write")
        }
        guard try snapshot(instance: proposal.instance).revision == proposal.expectedRevision else {
            throw RelaySettingsPolicy.ControlError.conflict
        }
        try RelaySettingsPolicy.validate(proposal.changes)
        uncertainRequests.insert(proposal.requestID)
        // Every value is validated before any setter runs. There are no awaits
        // in this transaction, so native UI writes cannot interleave.
        let p = RelayPreferences.shared
        for (key, value) in proposal.changes {
            switch (key, value) {
            case ("font_family", .string(let v)): p.fontFamily = v
            case ("font_size", .number(let v)): p.fontSize = v
            case ("terminal_padding", .number(let v)): p.terminalPadding = v
            case ("cursor_blink", .bool(let v)): p.cursorBlink = v
            case ("palette", .string(let v)): p.palette = RelayTerminalPalette(rawValue: v)!
            case ("compact_interface", .bool(let v)): p.compactInterface = v
            case ("hide_sidebar_fullscreen", .bool(let v)): p.hideSidebarInFullScreen = v
            case ("artifact_previews", .bool(let v)): p.showArtifactPreviews = v
            case ("artifact_presentation", .string(let v)): p.artifactPresentation = RelayArtifactPresentation(rawValue: v)!
            case ("intelligence_enabled", .bool(let v)): p.intelligenceEnabled = v
            case ("decision_model_path", .string(let v)): p.decisionModelPath = v
            case ("decision_model_sha256", .string(let v)): p.decisionModelSHA256 = v
            case ("intelligence_summaries", .bool(let v)): p.automaticAgentSummaries = v
            case ("intelligence_search", .bool(let v)): p.semanticAgentSearch = v
            case ("relayd_auto_update", .bool(let v)): p.automaticallyUpdateRelayd = v
            case ("automatic_agent_maintenance", .bool(let v)): p.automaticAgentMaintenance = v
            case ("haiku_pane_health", .bool(let v)): p.haikuPaneHealth = v
            case ("miko_host_key", .string(let v)): p.mikoHostKey = v
            case ("miko_autonomy", .string(let v)): p.mikoAutonomy = RelayMikoPolicySettings.Autonomy(rawValue: v)!
            case ("miko_actions_per_minute", .number(let v)): p.mikoMinute = Int(v)
            case ("miko_actions_per_hour", .number(let v)): p.mikoHour = Int(v)
            case ("miko_target_actions_per_minute", .number(let v)): p.mikoTargetMinute = Int(v)
            case ("miko_identical_actions_per_hour", .number(let v)): p.mikoRepetitions = Int(v)
            case ("miko_paused", .bool(let v)): try RelayMikoSupervision.shared.setMikoPaused(v)
            case ("miko_shepherd", .json(let v)):
                p.shepherd = try RelayShepherdSettings.decode(RelayPaneHealthJSON.data(v))
            case ("assistant_hotkey_enabled", .bool(let v)): p.assistantHotkeyEnabled = v
            case ("assistant_hotkey", .json(let v)):
                p.assistantHotkey = try JSONDecoder().decode(RelayAssistantHotkey.self, from: RelayPaneHealthJSON.data(v))
            case ("claude_quota_failover", .json(let v)):
                p.claudeQuotaFailover = try RelayClaudeQuotaSettings.decode(RelayPaneHealthJSON.data(v))
            case ("legacy_context_rotation_enabled", .bool(let v)): p.automaticContextRotation = v
            case ("legacy_context_rotation_budget", .number(let v)): p.contextRotationBudget = Int(v)
            case ("key_bindings", .bindings(let v)): p.replaceValidatedKeyBindings(v)
            case ("agent_account_rules", .accountRules(let v)):
                routing.update { $0 = v }
                RelayAgentAccountDirectory.shared.objectWillChange.send()
            default: preconditionFailure("Unvalidated setting")
            }
        }
        var result = try snapshot(instance: proposal.instance)
        guard proposal.changes.allSatisfy({ result.values[$0.key] == $0.value }) else {
            throw RelaySettingsPolicy.ControlError.invalid("Settings write could not be verified; read current settings before any retry")
        }
        result.receipt = RelaySettingsReceipt(requestID: proposal.requestID,
            verifiedRevision: result.revision, changedKeys: proposal.changes.keys.sorted(), outcome: "verified")
        // Do not evict IDs and later execute them as new operations.
        receipts[proposal.requestID] = (proposal, result)
        uncertainRequests.remove(proposal.requestID)
        return result
    }
}
