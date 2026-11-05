import Foundation
import SwiftUI

/// A user policy edit is bound to the exact pane and complete connection
/// snapshot that supplied the native settings, including changes under one ID.
struct RelayCapacityPolicyOrigin: Equatable {
    let paneID: UUID
    let profile: ConnectionProfile
    @MainActor func matches(_ pane: PaneModel) -> Bool { pane.id == paneID && pane.profile == profile }
}

/// Native policy data. No restart command, provider credential, capability flag
/// or source incarnation is accepted in a client policy/action request.
enum RelayCapacityManagement {
    struct Weight: Codable, Equatable, Sendable {
        var provider: String
        var account: String
        var model: String
        var value: Double
        var asOfMs: Int64
        var expiresMs: Int64
        var provenance = "user_assumption"
        var note = "Explicit native user assumption; not measured capacity or entitlement"
        var valid: Bool {
            ["claude", "codex"].contains(provider) && RelayAgentAccount.validLabel(account) && !model.isEmpty && model.utf8.count <= 256 && !model.contains(where: { $0.isNewline || $0 == "\0" }) &&
            value.isFinite && value > 0 && value <= 1_000_000 && asOfMs > 0 && expiresMs > asOfMs && expiresMs - asOfMs <= 30 * 86_400_000 && provenance == "user_assumption" && note.utf8.count <= 256
        }
    }
    struct Score: Codable, Equatable, Sendable {
        let provider: String
        let account: String
        let model: String
        let known: Bool
        let eligible: Bool
        let value: Double?
        let weight: Weight?
        let unit: String
        let limitingWindow: String
        let reason: String
        let absoluteCapacity: String
        let observedPlan: String
    }
    static func approvedKey(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && ["claude", "codex"].contains(String(parts[0])) && RelayAgentAccount.validLabel(String(parts[1]))
    }
    struct Settings: Codable, Equatable, Sendable {
        var adoptInstalledUpdates = false
        var rebalanceEnabled = true
        var codexLimitThreshold = 90.0
        var weights: [Weight] = []
        var hysteresisPercent = 10.0
        var minimumDwellMs: Int64 = 300_000
        var contextEnabled = true
        var quotaEnabled = false
        var newPaneDefault = true
        var thresholdTokens: Int64 = 100_000
        var fiveHourThreshold = 90.0
        var weeklyThreshold = 90.0
        var targetCeiling = 95.0
        var approvedAccounts: [String] = []
        var valid: Bool {
            (10_000...2_000_000).contains(thresholdTokens) && (1...50).contains(hysteresisPercent) &&
            (60_000...86_400_000).contains(minimumDwellMs) && approvedAccounts.count <= 32 &&
            Set(approvedAccounts).count == approvedAccounts.count && approvedAccounts.allSatisfy(RelayCapacityManagement.approvedKey) && weights.count <= 64 && weights.allSatisfy(\.valid) && Set(weights.map { $0.provider + ":" + $0.account + ":" + $0.model }).count == weights.count &&
            [fiveHourThreshold, weeklyThreshold, targetCeiling, codexLimitThreshold].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 100 }
        }
    }
    struct Capabilities: Codable, Equatable, Sendable {
        let providerVersion: String
        let admission: Bool
        let completeWork: Bool
        let scheduledTasks: Bool
        let preservation: Bool
        let pickup: Bool
        let reason: String
        var ready: Bool { !providerVersion.isEmpty && admission && completeWork && scheduledTasks && preservation && pickup }
    }
    struct Decision: Codable, Equatable, Sendable {
        let v: Int
        let state: String
        let contextDue: Bool
        let quotaDue: Bool
        let ranking: String
        let scores: [Score]?
        let rebalanceDue: Bool
        let returnDue: Bool
        let targetAccount: String
        let targetConfig: String
        let mode: String
        let reasons: [String]
        let limitingWindows: [String]
        let nextObservationMs: Int64
        let measuredTokens: Int64?
        let retirement: String
        let ready: Bool
    }
    struct Window: Codable, Equatable, Sendable {
        let name: String
        let usedPercent: Double
        let resetMs: Int64
        let durationMinutes: Int64
    }
    struct Account: Codable, Equatable, Sendable {
        let provider: String
        let label: String
        let config: String
        let model: String
        let observedPlan: String
        let compatibilityReason: String
        let compatible: Bool
        let scopeKnown: Bool
        let reserved: Bool
        let observedMs: Int64
        let windows: [Window]
    }
    struct Status: Codable, Equatable, Sendable {
        let v: Int
        let revision: UInt64
        let settings: Settings
        let state: String
        let reason: String
        let source: RelayPaneHealthJSON?
        let supported: Bool
        let managed: Bool
        let enabled: Bool
        let ready: Bool
        let capabilities: Capabilities
        let decision: Decision?
        let entry: RelayPaneHealthJSON?
        let operation: RelayPaneHealthJSON?
        let accounts: [Account]
        let registeredAccounts: [String]
        var valid: Bool {
            v == 1 && settings.valid && (!enabled || managed) && !state.isEmpty && state.utf8.count <= 128 && reason.utf8.count <= 4096 &&
            (!ready || capabilities.ready) && registeredAccounts.count <= 64 && accounts.count <= 32 &&
            (decision.map { $0.v == 1 && $0.reasons.count <= 32 && $0.limitingWindows.count <= 64 && (!$0.ready || capabilities.ready) } ?? true)
        }
    }
    struct Request: Encodable, Sendable {
        let v = 1
        let operation: String
        var id: String? = nil
        var expectedRevision: UInt64? = nil
        var paneId: String? = nil
        var settings: Settings? = nil
        var targetAccount: String? = nil
    }
    static let settingKeys: Set<String> = ["adopt_installed_updates", "rebalance_enabled", "codex_limit_threshold", "weights", "hysteresis_percent", "minimum_dwell_ms", "context_enabled", "quota_enabled", "new_pane_default", "threshold_tokens", "five_hour_threshold", "weekly_threshold", "target_ceiling", "approved_accounts"]
    static func decode(_ data: Data, requestID: String) throws -> Status {
        try RelayCapacityJSON.validate(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["request_id", "result", "error"]), root["request_id"] as? String == requestID else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        if let error = root["error"] as? String {
            guard root["result"] == nil, error.utf8.count <= 8192 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            throw RelayHostRotationRPC.Failure.refused(error)
        }
        guard let result = root["result"] as? [String: Any],
              Set(result.keys).isSubset(of: ["v", "revision", "settings", "state", "reason", "source", "supported", "managed", "enabled", "ready", "capabilities", "decision", "entry", "operation", "accounts", "registered_accounts"]),
              let settings = result["settings"] as? [String: Any], Set(settings.keys) == settingKeys,
              let capabilities = result["capabilities"] as? [String: Any],
              Set(capabilities.keys) == ["provider_version", "admission", "complete_work", "scheduled_tasks", "preservation", "pickup", "reason"] else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        try validateFields(result, kind: "result")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(Status.self, from: JSONSerialization.data(withJSONObject: result))
        guard value.valid else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return value
    }
    private static func validateFields(_ object: [String: Any], kind: String) throws {
        let schemas: [String: Set<String>] = [
            "result": ["v", "revision", "settings", "state", "reason", "source", "supported", "managed", "enabled", "ready", "capabilities", "decision", "entry", "operation", "accounts", "registered_accounts"],
            "settings": settingKeys,
            "capabilities": ["provider_version", "admission", "complete_work", "scheduled_tasks", "preservation", "pickup", "reason"],
            "source": ["model", "host", "boot", "pane", "worker_pid", "worker_start", "provider", "session", "pid", "start", "account", "config", "binding", "root"],
            "entry": ["managed", "pinned", "last_move_ms", "user_generation", "source", "enabled", "opt_out", "human_takeover", "manual_owner", "baseline", "baseline_turn", "quota_away"],
            "quota_away": ["original_account", "original_config", "owner", "trigger_resets"],
            "decision": ["ranking", "scores", "v", "state", "context_due", "quota_due", "rebalance_due", "return_due", "target_account", "target_config", "mode", "reasons", "limiting_windows", "next_observation_ms", "measured_tokens", "retirement", "ready"],
            "operation": ["plan", "state", "reason", "effects", "receipt"],
            "plan": ["counters", "accounts", "observed_ms", "source_quota", "target_quota", "trigger_resets", "origin", "settings_sha256", "id", "source", "target", "target_config", "new_session", "mode", "reasons", "user_generation", "policy_revision", "preparation", "source_sha256", "turn", "installed_image", "current_image"],
            "preparation": ["canonical_json", "link_state", "source", "capsule", "jobs", "inventory_complete", "scheduled_tasks_known", "falsifiers"],
            "canonical_json": ["version", "revision", "saved_at", "source", "ledger_seq", "objective", "repository", "project_dir", "session_id", "stream_id", "branch", "code_head", "next_action", "state", "constraints", "dirty_paths", "blockers", "gates", "jobs"],
            "capsule": ["session", "revision", "sha256", "ledger_seq", "source_sha256"],
            "counters": ["session", "turn", "tokens", "window", "observed_ms", "completed_idle"],
            "source_quota": ["reserved", "scope_known", "model", "observed_plan", "compatibility_reason", "label", "config", "provider", "compatible", "observed_ms", "windows"],
            "target_quota": ["reserved", "scope_known", "model", "observed_plan", "compatibility_reason", "label", "config", "provider", "compatible", "observed_ms", "windows"],
            "account": ["reserved", "scope_known", "model", "observed_plan", "compatibility_reason", "label", "config", "provider", "compatible", "observed_ms", "windows"],
            "window": ["duration_minutes", "name", "used_percent", "reset_ms"],
            "canonical_job": ["id", "result_path"],
            "gate": ["status", "number"],
            "job": ["id", "host", "boot", "pid", "start", "state", "evidence_sha256", "log", "brief", "output", "next_action"],
            "weight": ["provider", "account", "model", "value", "as_of_ms", "expires_ms", "provenance", "note"],
            "score": ["provider", "account", "model", "known", "eligible", "value", "weight", "unit", "limiting_window", "reason", "absolute_capacity", "observed_plan"],
            "effects": ["notice", "retire", "launch", "pickup"],
            "trigger_resets": ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette"]
        ]
        if kind == "gates" {
            guard object.count <= 6 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            for (name, value) in object {
                guard name.utf8.count <= 48, let gate = value as? [String: Any], Set(gate.keys) == ["status", "number"],
                      let status = gate["status"] as? String, ["pass", "fail"].contains(status),
                      let number = gate["number"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw RelayHostRotationRPC.Failure.invalidResponse }
            }
            return
        }
        if kind == "trigger_resets" {
            guard object.count <= 64, object.keys.allSatisfy({ $0.utf8.count <= 256 && !$0.contains(where: { $0.isNewline }) }) else { throw RelayHostRotationRPC.Failure.invalidResponse }
            return
        }
        guard let keys = schemas[kind], Set(object.keys).isSubset(of: keys) else { throw RelayHostRotationRPC.Failure.invalidResponse }
        for (key, value) in object {
            if let child = value as? [String: Any] { try validateFields(child, kind: key) }
            else if let rows = value as? [[String: Any]], let childKind = ["weights": "weight", "scores": "score", "accounts": "account", "windows": "window", "jobs": kind == "canonical_json" ? "canonical_job" : "job"][key] {
                guard rows.count <= (["jobs": 128, "weights": 64, "windows": 64][key] ?? 32) else { throw RelayHostRotationRPC.Failure.invalidResponse }
                for row in rows { try validateFields(row, kind: childKind) }
            }
        }
    }
    static func formatWeights(_ weights: [Weight]) -> String {
        weights.map { "\($0.provider):\($0.account):\($0.model)=\($0.value)" }.sorted().joined(separator: ", ")
    }
    static func parseWeights(_ text: String, existing: [Weight], nowMs: Int64, reconfirm: Bool = false) -> [Weight]? {
        if !reconfirm && text.trimmingCharacters(in: .whitespaces) == formatWeights(existing) { return existing }
        guard text.utf8.count <= 8192, nowMs > 0, nowMs < Int64.max - 30 * 86_400_000 else { return nil }
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var result: [Weight] = []; var seen = Set<String>()
        for row in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = row.trimmingCharacters(in: .whitespaces).split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, let value = Double(pair[1]) else { return nil }
            let key = pair[0].split(separator: ":", omittingEmptySubsequences: false)
            guard key.count == 3, seen.insert(String(pair[0])).inserted, result.count < 64 else { return nil }
            let weight = Weight(provider: String(key[0]), account: String(key[1]), model: String(key[2]), value: value, asOfMs: nowMs, expiresMs: nowMs + 30 * 86_400_000)
            guard weight.valid else { return nil }
            if !reconfirm, let old = existing.first(where: { $0.provider == weight.provider && $0.account == weight.account && $0.model == weight.model && $0.value == weight.value }) { result.append(old) }
            else { result.append(weight) }
        }
        return result
    }
    @MainActor static func sendBound(_ request: Request, origin: RelayCapacityPolicyOrigin, pane: PaneModel,
                                     isCurrent: () -> Bool, exchange: ((Data) async throws -> Data)? = nil) async throws -> Status {
        guard origin.matches(pane), isCurrent(), request.paneId == nil || request.paneId == origin.paneID.uuidString.lowercased() else { throw RelayHostRotationRPC.Failure.changedConnection }
        let value = try await send(request, profile: origin.profile, exchange: exchange)
        guard origin.matches(pane), isCurrent() else { throw RelayHostRotationRPC.Failure.changedConnection }
        return value
    }
    @MainActor static func send(_ request: Request, profile: ConnectionProfile,
                                exchange: ((Data) async throws -> Data)? = nil) async throws -> Status {
        guard profile.backend == .relay else { throw RelayHostRotationRPC.Failure.unavailable }
        struct Forward: Encodable { let request: Request }
        struct Envelope: Encodable {
            let requestId: String
            let operation = "host_accounts"
            let hostAccounts: Forward
        }
        let requestID = "capacity-" + UUID().uuidString.lowercased()
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = try encoder.encode(Envelope(requestId: requestID, hostAccounts: Forward(request: request)))
        let raw: Data
        if let exchange { raw = try await exchange(payload) }
        else { raw = try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload, requiredCapability: "host_accounts_v1") }
        try Task.checkCancellation()
        return try decode(raw, requestID: requestID)
    }
}

/// A bounded JSON recognizer that preserves duplicate-key rejection before
/// Foundation decoding. No regex or decoded dictionary can hide duplicate keys.
enum RelayCapacityJSON {
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 256 << 10 else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let b = Array(data); var i = 0
        func fail() throws -> Never { throw RelayHostRotationRPC.Failure.invalidResponse }
        func space() { while i < b.count && [UInt8(32), 9, 10, 13].contains(b[i]) { i += 1 } }
        func string() throws -> String {
            guard i < b.count, b[i] == 34 else { try fail() }; let start = i; i += 1
            var escaped = false
            while i < b.count {
                let c = b[i]; i += 1
                if !escaped && c == 34 {
                    guard i - start <= 8194 else { try fail() }
                    return try JSONDecoder().decode(String.self, from: Data(b[start..<i]))
                }
                if !escaped && c == 92 { escaped = true } else { escaped = false }
            }
            try fail()
        }
        func value(_ depth: Int) throws {
            guard depth <= 16 else { try fail() }; space(); guard i < b.count else { try fail() }
            if b[i] == 123 {
                i += 1; space(); var keys = Set<String>()
                if i < b.count && b[i] == 125 { i += 1; return }
                while true {
                    space(); let key = try string(); guard key.utf8.count <= 256, keys.insert(key).inserted, keys.count <= 4096 else { try fail() }
                    space(); guard i < b.count, b[i] == 58 else { try fail() }; i += 1; try value(depth + 1); space()
                    guard i < b.count else { try fail() }; let next = b[i]; i += 1
                    if next == 125 { return }; guard next == 44 else { try fail() }
                }
            } else if b[i] == 91 {
                i += 1; space(); var count = 0
                if i < b.count && b[i] == 93 { i += 1; return }
                while true {
                    count += 1; guard count <= 4096 else { try fail() }; try value(depth + 1); space()
                    guard i < b.count else { try fail() }; let next = b[i]; i += 1
                    if next == 93 { return }; guard next == 44 else { try fail() }
                }
            } else if b[i] == 34 { _ = try string() }
            else {
                let start = i
                while i < b.count && ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(b[i]) { i += 1 }
                guard i > start else { try fail() }
                _ = try JSONSerialization.jsonObject(with: Data(b[start..<i]), options: .fragmentsAllowed)
            }
        }
        try value(0); space(); guard i == b.count else { try fail() }
    }
}

@MainActor struct RelayCapacitySettingsView: View {
    let pane: PaneModel?
    @State private var status: RelayCapacityManagement.Status?
    @State private var statusOrigin: RelayCapacityPolicyOrigin?
    @State private var settings = RelayCapacityManagement.Settings()
    @State private var approved = ""
    @State private var weightText = ""
    @State private var reconfirmWeights = false
    @State private var manualTarget = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 9) {
            Text("Miko context and capacity policy").font(.headline)
            Toggle("Context planning for newly eligible panes", isOn: $settings.newPaneDefault)
                .accessibilityIdentifier("relay.capacity.new-pane-default")
            Toggle("Measured context policy", isOn: $settings.contextEnabled)
            Stepper("Context threshold: \(settings.thresholdTokens) measured tokens", value: $settings.thresholdTokens, in: 10_000...2_000_000, step: 10_000)
            Toggle("Quota policy (5-hour and weekly)", isOn: $settings.quotaEnabled)
            Toggle("Use installed app updates during a checked restart", isOn: $settings.adoptInstalledUpdates)
            Toggle("Rebalance across approved accounts", isOn: $settings.rebalanceEnabled)
                .accessibilityIdentifier("relay.capacity.rebalance")
            TextField("Approved provider:account keys, comma separated", text: $approved)
            TextField(text: $weightText) { Text(verbatim: "Assumptions: claude:personal:*=5, codex:work:*=1") }
            Text("Weights are optional, dated user assumptions for the same provider/model workload. Missing or stale weights stay unknown; scores are normalized capacity-weighted headroom ESTIMATES, not measured tokens or a global optimum.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(settings.weights.enumerated()), id: \.offset) { _, weight in
                Text("\(weight.provider):\(weight.account) / \(weight.model): \(weight.value) assumed; as of \(dateText(weight.asOfMs)), expires \(dateText(weight.expiresMs))").font(.caption)
            }
            Button("Reconfirm dated weight assumptions on next Save") { reconfirmWeights = true }
            Stepper("Codex reported-limit trigger: \(Int(settings.codexLimitThreshold))%", value: $settings.codexLimitThreshold, in: 1...100)
            Stepper("Rebalance score improvement: \(Int(settings.hysteresisPercent))%", value: $settings.hysteresisPercent, in: 1...50)
            Text("Minimum dwell: \(settings.minimumDwellMs / 60_000) minutes. A 10% context reserve and 10,000 tokens of useful growth above the fresh baseline are required. Percentages are not remaining token counts.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Actual Codex/Claude retirement is unavailable: complete scheduled-work, admission, preservation and pickup evidence is required. Existing panes are not enrolled by this default. Quota failover uses its separate policy setting.")
                .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("relay.capacity.capability-held")
            if let status {
                Text(status.state + ": " + status.reason).font(.caption).textSelection(.enabled)
                ForEach(Array(status.accounts.enumerated()), id: \.offset) { _, account in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(account.provider):\(account.label) / \(account.model) — \(account.compatible && account.scopeKnown ? "usage scope eligible" : "compatibility or usage scope unknown"); observed \(dateText(account.observedMs)); \(account.reserved ? "reserved by a pending or recently completed move" : "no pending reservation")").font(.caption)
                        Text(account.compatibilityReason).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                            Text("\(window.name): \(window.usedPercent, specifier: "%.1f")% used; resets \(dateText(window.resetMs))").font(.caption)
                        }
                    }
                }
                if let decision = status.decision {
                    Text("Ranking: " + decision.ranking).font(.caption)
                    ForEach(Array((decision.scores ?? []).enumerated()), id: \.offset) { _, score in
                        Text("\(score.provider):\(score.account) — \(score.value.map { String(format: "%.3f", $0) } ?? "unknown") estimate; \(score.limitingWindow); \(score.reason)").font(.caption)
                    }
                    Text("Selected account: \(decision.targetAccount.isEmpty ? "held" : decision.targetAccount); limiting windows: \(decision.limitingWindows.joined(separator: ", "))")
                        .font(.caption)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Button("Refresh") { Task { await refresh() } }
                Button("Save policy") { Task { await save() } }.disabled(status == nil || !settings.valid) }
                if status?.supported == true || status?.managed == true {
                    HStack { Button("Enroll this pane for planning") { Task { await action("capacity_enroll") } }
                    Button("Pause planning") { Task { await action("capacity_pause") } }
                    Button("Resume planning") { Task { await action("capacity_resume") } }
                    Button("Pin account") { Task { await action("capacity_pin") } }
                    Button("Unpin") { Task { await action("capacity_unpin") } } }
                    HStack {
                    Button("Clear human takeover") { Task { await action("capacity_user_release") } }
                    Button("Checked context refresh") { Task { await action("capacity_manual_refresh") } } }
                }
            }.disabled(busy || pane == nil)
            HStack { TextField("Approved target label on this pane's provider", text: $manualTarget)
                Button("Request checked account move") { Task { await action("capacity_manual_move", target: manualTarget) } }.disabled(manualTarget.isEmpty || busy || status?.supported != true)
            }
        }.padding(.vertical, 10) }.task(id: pane.map { RelayCapacityPolicyOrigin(paneID: $0.id, profile: $0.profile) }) { await refresh() }
    }
    private func dateText(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "unknown" }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
    private func refresh() async {
        guard let pane else { return }; busy = true; defer { busy = false }
        do {
            let origin = RelayCapacityPolicyOrigin(paneID: pane.id, profile: pane.profile)
            let received = try await RelayCapacityManagement.send(.init(operation: "capacity_status", paneId: pane.id.uuidString.lowercased()), profile: origin.profile)
            guard origin.matches(pane) else { throw RelayHostRotationRPC.Failure.changedConnection }
            status = received; statusOrigin = origin
            settings = received.settings; approved = settings.approvedAccounts.joined(separator: ", "); weightText = RelayCapacityManagement.formatWeights(settings.weights); reconfirmWeights = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let pane, let status, let origin = statusOrigin, origin.matches(pane) else { error = "Refresh this pane and connection before changing policy"; return }; busy = true; defer { busy = false }
        settings.approvedAccounts = approved.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let weights = RelayCapacityManagement.parseWeights(weightText, existing: settings.weights, nowMs: Int64(Date().timeIntervalSince1970 * 1000), reconfirm: reconfirmWeights) else { error = "Invalid dated capacity assumptions"; return }
        settings.weights = weights
        guard settings.valid else { error = "Invalid capacity settings"; return }
        do {
            let saved = try await RelayCapacityManagement.sendBound(.init(operation: "capacity_configure", id: RelayHostRotationRPC.newOperationID(), expectedRevision: status.revision, settings: settings), origin: origin, pane: pane, isCurrent: { statusOrigin == origin })
            self.status = saved; settings = saved.settings; weightText = RelayCapacityManagement.formatWeights(settings.weights); reconfirmWeights = false; error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    private func action(_ name: String, target: String? = nil) async {
        guard let pane, let status, let origin = statusOrigin, origin.matches(pane) else { error = "Refresh this pane and connection before changing policy"; return }; busy = true; defer { busy = false }
        do { self.status = try await RelayCapacityManagement.sendBound(.init(operation: name, id: RelayHostRotationRPC.newOperationID(), expectedRevision: status.revision, paneId: pane.id.uuidString.lowercased(), targetAccount: target), origin: origin, pane: pane, isCurrent: { statusOrigin == origin }); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct RelayCapacityActionRequest: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let action: String
    var targetAccount: String? = nil
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw RelayHostRotationRPC.Failure.invalidResponse }
        try RelayCapacityJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["instance", "requestID", "action", "targetAccount"]) else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard ["pause", "resume", "manual_refresh", "manual_move"].contains(value.action),
              (value.action == "manual_move" ? value.targetAccount.map(RelayAgentAccount.validLabel) == true : value.targetAccount == nil)
        else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return value
    }
}

/// Cheap native status/decision observations share one cache and task per pane.
/// No model call, terminal input or physical effect is performed by this loop.
/// Native request receipts are claimed synchronously before any async host RPC.
/// An unknown/in-flight result is a stored result, never permission to replay.
struct RelayCapacityActionReceipts {
    enum Admission: Equatable {
        case admitted
        case result([String: String])
        case refused(String)
    }
    private struct Entry {
        let pane: UUID
        let request: RelayCapacityActionRequest
        var result: [String: String]
    }
    private var entries: [UUID: Entry] = [:]
    var count: Int { entries.count }
    mutating func begin(pane: UUID, request: RelayCapacityActionRequest, expectedInstance: UUID, inputGranted: Bool) -> Admission {
        guard inputGranted, request.instance == expectedInstance else { return .refused("Native input grant or instance changed") }
        if let old = entries[request.requestID] {
            guard old.pane == pane, old.request == request else { return .refused("Conflicting capacity request ID") }
            return .result(old.result)
        }
        guard entries.count < 256 else { return .refused("Capacity receipt limit reached") }
        entries[request.requestID] = Entry(pane: pane, request: request, result: ["status": "outcome_unknown", "paneID": pane.uuidString.lowercased()])
        return .admitted
    }
    mutating func finish(pane: UUID, requestID: UUID, result: [String: String]) {
        guard var old = entries[requestID], old.pane == pane else { return }
        old.result = result
        entries[requestID] = old
    }
    func result(for requestID: UUID) -> [String: String]? { entries[requestID]?.result }
}

@MainActor final class RelayCapacityManagementCoordinator {
    static let shared = RelayCapacityManagementCoordinator()
    private(set) var statuses: [UUID: RelayCapacityManagement.Status] = [:]
    private var due: [UUID: Date] = [:]
    private var observedAt: [UUID: Date] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var newPanes = Set<UUID>()
    private var submitted = Set<UUID>()
    private let readExchange: ((Data) async throws -> Data)?
    /// CC-S2: the Miko-owned supervisor that observes each pane natively and may hold a submission.
    let budget: RelayBudgetSupervisor
    init(readExchange: ((Data) async throws -> Data)? = nil, budget: RelayBudgetSupervisor = .shared) {
        self.readExchange = readExchange
        self.budget = budget
    }
    func didCreate(_ pane: PaneModel) { newPanes.insert(pane.id) }
    func tick(_ workspace: WorkspaceModel, now: Date) {
        guard !RelayLaunchMode.isRunningTests else { return }
        for pane in workspace.panes.values where pane.contentKind == .terminal && pane.profile.backend == .relay && pane.connectionState == .connected {
            guard tasks[pane.id] == nil, now >= due[pane.id, default: .distantPast] else { continue }
            let id = pane.id; due[id] = now.addingTimeInterval(60)
            tasks[id] = Task { @MainActor [weak self, weak pane, weak workspace] in
                guard let self, let pane else { return }; defer { self.tasks.removeValue(forKey: id) }
                await self.evaluate(pane, workspace: workspace, now: now)
            }
        }
    }
    /// One pane's native observation, exactly as `tick` runs it (tests call this directly,
    /// because `tick` is off while tests run). Supervision only observes, notifies and
    /// verifies; it neither gates nor adds a submission.
    func evaluate(_ pane: PaneModel, workspace: WorkspaceModel?, now: Date) async {
        let id = pane.id
        do {
            var status = try await self.read(pane)
            if self.newPanes.contains(id), status.entry == nil, status.supported {
                self.newPanes.remove(id)
                status = try await RelayCapacityManagement.send(.init(operation: "capacity_register_new", id: RelayHostRotationRPC.newOperationID(), expectedRevision: status.revision, paneId: id.uuidString.lowercased()), profile: pane.profile, exchange: readExchange)
                self.statuses[id] = status
            }
            _ = self.budget.observe(pane: pane, workspace: workspace, status: status, now: now)
            if status.enabled, status.operation == nil, let decision = status.decision,
               decision.contextDue || decision.quotaDue || decision.returnDue || decision.rebalanceDue,
               !self.submitted.contains(id) {
                // Exactly the M12 submission: Miko's holds are notices and never gate it.
                // Submission is sticky before the write. A lost response
                // gets status-only reconciliation, never another request.
                self.submitted.insert(id)
                let operationID = RelayHostRotationRPC.newOperationID()
                let after = try await RelayCapacityManagement.send(.init(operation: "capacity_observe", id: operationID, expectedRevision: status.revision, paneId: id.uuidString.lowercased()), profile: pane.profile, exchange: readExchange)
                self.statuses[id] = after
                self.budget.recordRoll(pane: pane, before: status, after: after, operationID: operationID, now: now)
            }
        } catch { /* Existing state remains descriptive; a failed read grants nothing. */ }
    }
    /// A user-initiated native action on one exact pane, from the Control section: the same
    /// operations and the same bound send as the Context and capacity panel's buttons.
    /// Returns the native receipt (`state: reason`) or the refusal.
    static let userOperations: Set<String> = ["capacity_enroll", "capacity_pause", "capacity_resume", "capacity_manual_refresh"]
    func userAction(_ operation: String, pane: PaneModel, exchange: ((Data) async throws -> Data)? = nil) async -> String {
        guard Self.userOperations.contains(operation) else { return "Refused: not a user action on this pane." }
        do {
            let current = try await read(pane, exchange: exchange)
            let origin = RelayCapacityPolicyOrigin(paneID: pane.id, profile: pane.profile)
            let value = try await RelayCapacityManagement.sendBound(.init(operation: operation, id: RelayHostRotationRPC.newOperationID(), expectedRevision: current.revision, paneId: pane.id.uuidString.lowercased()), origin: origin, pane: pane, isCurrent: { true }, exchange: exchange ?? readExchange)
            statuses[pane.id] = value; observedAt[pane.id] = Date()
            return value.state + ": " + value.reason
        } catch { return "Native operation held or outcome unknown: " + error.localizedDescription }
    }
    /// The host's native context policy (on/off and token threshold), edited from the Control
    /// section through the same `capacity_configure` write as the panel's Save.
    func userContextPolicy(pane: PaneModel, contextEnabled: Bool, thresholdTokens: Int64,
                           exchange: ((Data) async throws -> Data)? = nil) async -> String {
        do {
            let current = try await read(pane, exchange: exchange)
            var settings = current.settings
            settings.contextEnabled = contextEnabled
            settings.thresholdTokens = thresholdTokens
            guard settings.valid else { return "Refused: invalid capacity settings." }
            let origin = RelayCapacityPolicyOrigin(paneID: pane.id, profile: pane.profile)
            let value = try await RelayCapacityManagement.sendBound(.init(operation: "capacity_configure", id: RelayHostRotationRPC.newOperationID(), expectedRevision: current.revision, settings: settings), origin: origin, pane: pane, isCurrent: { true }, exchange: exchange ?? readExchange)
            statuses[pane.id] = value; observedAt[pane.id] = Date()
            return value.state + ": " + value.reason
        } catch { return "Native policy write held or outcome unknown: " + error.localizedDescription }
    }
    func read(_ pane: PaneModel, exchange: ((Data) async throws -> Data)? = nil) async throws -> RelayCapacityManagement.Status {
        let profile = pane.profile
        let value = try await RelayCapacityManagement.send(.init(operation: "capacity_status", paneId: pane.id.uuidString.lowercased()), profile: profile, exchange: exchange ?? readExchange)
        guard pane.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        statuses[pane.id] = value
        observedAt[pane.id] = Date()
        return value
    }
    /// New combined enrollment owns this pane's automatic/manual/update lane.
    /// Existing panes without that explicit enrollment retain legacy behavior.
    func shouldUseCombined(_ pane: PaneModel, exchange: ((Data) async throws -> Data)? = nil) async -> Bool {
        guard pane.profile.backend == .relay, pane.contentKind == .terminal else { return false }
        do { return try await read(pane, exchange: exchange).managed }
        // A fresh app may have no cache while the host still owns a paused or
        // uncertain operation. Missing ownership evidence must hold the move,
        // never grant the legacy executor permission to exit that source.
        catch { return true }
    }
    func requestManual(_ pane: PaneModel, target: RelayAgentAccount) async -> String {
        do {
            let current = try await read(pane)
            let value = try await RelayCapacityManagement.send(.init(operation: "capacity_manual_move", id: RelayHostRotationRPC.newOperationID(), expectedRevision: current.revision, paneId: pane.id.uuidString.lowercased(), targetAccount: target.label), profile: pane.profile)
            statuses[pane.id] = value
            return value.state + ": " + value.reason
        } catch { return "Native combined operation held or outcome unknown: " + error.localizedDescription }
    }
    func snapshotForMiko(_ pane: PaneModel) -> RelayPaneHealthJSON {
        guard let value = statuses[pane.id], Date().timeIntervalSince(observedAt[pane.id] ?? .distantPast) <= 120 else {
            return .object(["state": .string("native_observation_pending_or_stale"), "ready": .bool(false), "reason": .string("Use native Refresh; no model poll is scheduled.")])
        }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: encoder.encode(value))) ?? .null
    }
    func statusForMiko(_ pane: PaneModel) async -> RelayPaneHealthJSON {
        do {
            let value: RelayCapacityManagement.Status
            if let cached = statuses[pane.id], Date() < due[pane.id, default: .distantPast] { value = cached }
            else { value = try await read(pane) }
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            return try JSONDecoder().decode(RelayPaneHealthJSON.self, from: encoder.encode(value))
        } catch { return .object(["state": .string("unavailable"), "ready": .bool(false), "reason": .string(String(error.localizedDescription.prefix(240)))]) }
    }
}
