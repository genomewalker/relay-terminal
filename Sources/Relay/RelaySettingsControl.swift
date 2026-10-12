import Foundation
import CryptoKit

/// Typed preferences only. Credentials, grants and arbitrary UserDefaults keys
/// cannot be represented by this API.
enum RelaySettingValue: Codable, Equatable, Sendable {
    case bool(Bool), number(Double), string(String), bindings([String: RelayKeyBinding])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .bindings(try c.decode([String: RelayKeyBinding].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .bindings(let v): try c.encode(v)
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
        .init(key: "key_bindings", type: "object")
    ]

    static func validate(_ changes: [String: RelaySettingValue]) throws {
        guard !changes.isEmpty, changes.count <= definitions.count else {
            throw ControlError.invalid("Supply 1 to 16 known settings")
        }
        for (key, value) in changes {
            guard let definition = definitions.first(where: { $0.key == key }) else {
                throw ControlError.invalid("Unknown setting: \(key)")
            }
            switch (definition.type, value) {
            case ("boolean", .bool): break
            case ("number", .number(let n)):
                guard n.isFinite, n >= definition.minimum!, n <= definition.maximum! else {
                    throw ControlError.invalid("Value is outside the allowed range: \(key)")
                }
            case ("string", .string(let s)):
                guard s.utf8.count <= (key == "decision_model_path" ? 4096 : 160),
                      !s.contains(where: { $0.isNewline || $0 == "\0" }) else {
                    throw ControlError.invalid("Invalid string: \(key)")
                }
                if let choices = definition.choices, !choices.contains(s) {
                    throw ControlError.invalid("Unsupported value: \(key)")
                }
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
            case ("object", .bindings(let bindings)):
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
    private var receipts: [UUID: (RelaySettingsProposal, RelaySettingsSnapshot)] = [:]
    private var order: [UUID] = []

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
            "decision_model_path": .string(p.decisionModelPath),
            "decision_model_sha256": .string(p.decisionModelSHA256),
            "intelligence_summaries": .bool(p.automaticAgentSummaries),
            "intelligence_search": .bool(p.semanticAgentSearch),
            "relayd_auto_update": .bool(p.automaticallyUpdateRelayd),
            "key_bindings": .bindings(p.keyBindings)
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(values)).map { String(format: "%02x", $0) }.joined()
        return .init(schema: "relay.settings/1", instance: instance, revision: digest,
                     values: values, definitions: RelaySettingsPolicy.definitions)
    }

    func apply(_ proposal: RelaySettingsProposal) throws -> RelaySettingsSnapshot {
        if let (old, result) = receipts[proposal.requestID] {
            guard old == proposal else { throw RelaySettingsPolicy.ControlError.conflict }
            return result
        }
        guard try snapshot(instance: proposal.instance).revision == proposal.expectedRevision else {
            throw RelaySettingsPolicy.ControlError.conflict
        }
        try RelaySettingsPolicy.validate(proposal.changes)
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
            case ("key_bindings", .bindings(let v)): p.replaceValidatedKeyBindings(v)
            default: preconditionFailure("Unvalidated setting")
            }
        }
        let result = try snapshot(instance: proposal.instance)
        receipts[proposal.requestID] = (proposal, result); order.append(proposal.requestID)
        if order.count > 128 { receipts.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
