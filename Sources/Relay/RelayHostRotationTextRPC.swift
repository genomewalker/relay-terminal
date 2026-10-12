import Foundation

enum RelayHostRotationTextRPC {
    static let providers = ["anthropic_api", "claude_account", "codex_account"]
    static func providerName(_ value: String) -> String {
        switch value {
        case "anthropic_api": "Claude API"
        case "claude_account": "Claude Code account"
        case "codex_account": "Codex account"
        default: "Unknown provider"
        }
    }

    struct Account: Codable, Equatable, Sendable, Identifiable {
        var id = RelayHostRotationRPC.newOperationID()
        var name = "API account"
        var provider = "anthropic_api"
        var enabled = false
        var dailyLimitMicrousd: Int64 = 0
        var monthlyLimitMicrousd: Int64 = 0
        var maxRequestsPerDay = 0
        var credentialReference: String? = nil
        var authDirectory: String? = nil
        var billingGroup: String? = nil
        var model: String? = nil
        var cliPath: String? = nil
        enum CodingKeys: String, CodingKey {
            case id, name, provider, enabled, model
            case dailyLimitMicrousd = "daily_limit_microusd", monthlyLimitMicrousd = "monthly_limit_microusd"
            case maxRequestsPerDay = "max_requests_per_day", credentialReference = "credential_ref"
            case authDirectory = "auth_directory", billingGroup = "billing_group", cliPath = "cli_path"
        }
        var valid: Bool {
            guard RelayHostRotationRPC.validOperationID(id), (1...64).contains(name.unicodeScalars.count),
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  name.range(of: #"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}"#, options: .regularExpression) == nil,
                  RelayHostRotationTextRPC.providers.contains(provider),
                  (0...200_000_000).contains(dailyLimitMicrousd),
                  (0...200_000_000).contains(monthlyLimitMicrousd),
                  (0...10_000).contains(maxRequestsPerDay), !enabled || maxRequestsPerDay > 0 else { return false }
            if provider == "anthropic_api" {
                guard authDirectory == nil, model == nil, cliPath == nil,
                      credentialReference.map(RelayHostRotationRPC.validOperationID) ?? true,
                      billingGroup.map({ $0.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil }) ?? true
                else { return false }
                return !enabled || credentialReference != nil && billingGroup != nil &&
                    min(dailyLimitMicrousd, monthlyLimitMicrousd) >= 1_000_000
            }
            guard credentialReference == nil, billingGroup == nil,
                  [authDirectory, cliPath].allSatisfy({ $0.map(RelayHostRotationRPC.validDirectory) ?? true }),
                  model.map({ $0.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil }) ?? true
            else { return false }
            return !enabled || authDirectory != nil && model != nil
        }
    }

    struct Settings: Codable, Equatable, Sendable {
        var enabled = false
        var accounts: [Account]? = nil
        var providers = ["anthropic_api"]
        var dailyLimitMicrousd: Int64 = 0
        var monthlyLimitMicrousd: Int64 = 0
        var maxRequestsPerDay = 0
        var codexModel: String? = nil
        var claudePath: String? = nil
        var codexPath: String? = nil
        enum CodingKeys: String, CodingKey {
            case enabled, providers, accounts, dailyLimitMicrousd = "daily_limit_microusd"
            case monthlyLimitMicrousd = "monthly_limit_microusd", maxRequestsPerDay = "max_requests_per_day"
            case codexModel = "codex_model", claudePath = "claude_path", codexPath = "codex_path"
        }
        var valid: Bool {
            guard !providers.isEmpty, providers.count <= 3, Set(providers).count == providers.count,
                  providers.allSatisfy({ RelayHostRotationTextRPC.providers.contains($0) }),
                  (0...200_000_000).contains(dailyLimitMicrousd),
                  (0...200_000_000).contains(monthlyLimitMicrousd),
                  (0...10_000).contains(maxRequestsPerDay) else { return false }
            if enabled && (maxRequestsPerDay == 0 || providers.contains("anthropic_api") &&
                min(dailyLimitMicrousd, monthlyLimitMicrousd) < 1_000_000) { return false }
            if let codexModel, codexModel.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) == nil { return false }
            guard [claudePath, codexPath].allSatisfy({ $0.map(RelayHostRotationRPC.validDirectory) ?? true }) else { return false }
            if let accounts {
                guard accounts.count <= 12, Set(accounts.map(\.id)).count == accounts.count,
                      accounts.allSatisfy(\.valid),
                      Set(accounts.compactMap(\.credentialReference)).count == accounts.compactMap(\.credentialReference).count,
                      Set(accounts.compactMap { account in account.authDirectory.map { account.provider + ":" + $0 } }).count ==
                        accounts.compactMap(\.authDirectory).count,
                      !enabled || accounts.contains(where: { $0.enabled && providers.contains($0.provider) }) else { return false }
            }
            return (try? JSONEncoder().encode(self).count).map { $0 <= 60_000 } ?? false
        }
        // Merge a host account without changing generation, budgets or unrelated
        // profiles. A stale editor cannot overwrite another confirmed edit.
        func mergingAccount(_ account: Account, replacing original: Account?) throws -> Settings {
            guard account.valid else { throw RelayHostRotationRPC.Failure.refused("Complete the account settings before saving.") }
            var value = self
            var rows = accounts ?? []
            if let index = rows.firstIndex(where: { $0.id == account.id }) {
                guard rows[index] == original || rows[index] == account else {
                    throw RelayHostRotationRPC.Failure.refused("This account changed on the host. Reload it before editing again.")
                }
                rows[index] = account
            } else {
                guard original == nil, rows.count < 12 else {
                    throw RelayHostRotationRPC.Failure.refused("The saved account changed. Reload the accounts on this host.")
                }
                rows.append(account)
            }
            value.accounts = rows
            if !value.providers.contains(account.provider) { value.providers.append(account.provider) }
            guard value.valid else {
                throw RelayHostRotationRPC.Failure.refused("The host limits or account details need attention. Set valid host limits and use a different saved key for each account.")
            }
            return value
        }

    }

    struct AccountUsage: Decodable, Equatable, Sendable {
        let accountID: String
        let requestsToday: Int
        let chargedTodayMicrousd: Int64
        let chargedMonthMicrousd: Int64
        let billingGroup: String
        let groupChargedTodayMicrousd: Int64
        let groupChargedMonthMicrousd: Int64
        enum CodingKeys: String, CodingKey {
            case accountID = "account_id", requestsToday = "requests_today"
            case chargedTodayMicrousd = "charged_today_microusd", chargedMonthMicrousd = "charged_month_microusd"
            case billingGroup = "billing_group", groupChargedTodayMicrousd = "group_charged_today_microusd"
            case groupChargedMonthMicrousd = "group_charged_month_microusd"
        }
        var valid: Bool {
            RelayHostRotationRPC.validOperationID(accountID) && requestsToday >= 0 &&
                chargedTodayMicrousd >= 0 && chargedMonthMicrousd >= chargedTodayMicrousd &&
                groupChargedTodayMicrousd >= 0 && groupChargedMonthMicrousd >= groupChargedTodayMicrousd
        }
    }

    struct Status: Decodable, Equatable, Sendable {
        let version: Int?
        let status: String?
        let configurationID: String?
        let settings: Settings?
        let day: String?
        let month: String?
        let requestsToday: Int?
        let chargedTodayMicrousd: Int64?
        let chargedMonthMicrousd: Int64?
        let unresolved: [String]?
        let state: String?
        let accountUsage: [AccountUsage]?
        let credentialSupport: String?
        var supportsCredentials: Bool { credentialSupport == "v1" }
        enum CodingKeys: String, CodingKey {
            case version = "v", status, configurationID = "configuration_id", settings, day, month
            case requestsToday = "requests_today", chargedTodayMicrousd = "charged_today_microusd"
            case chargedMonthMicrousd = "charged_month_microusd", unresolved, state
            case accountUsage = "account_usage", credentialSupport = "credential_support"
        }
        var isUnsupported: Bool { state == "unsupported" }
        var isNotConfigured: Bool { status == "not_configured" }
        var valid: Bool {
            if isUnsupported { return version == nil && status == nil && settings == nil }
            guard version == 1, credentialSupport == nil || credentialSupport == "v1" else { return false }
            if isNotConfigured { return settings == nil && configurationID == nil }
            guard ["ready", "reconciliation_required"].contains(status ?? ""), let settings, settings.valid,
                  let configurationID, configurationID.isEmpty || RelayHostRotationRPC.validOperationID(configurationID),
                  let requestsToday, requestsToday >= 0,
                  let chargedTodayMicrousd, chargedTodayMicrousd >= 0,
                  let chargedMonthMicrousd, chargedMonthMicrousd >= chargedTodayMicrousd,
                  let unresolved, unresolved.count <= 16, Set(unresolved).count == unresolved.count,
                  unresolved.allSatisfy(RelayHostRotationRPC.validOperationID),
                  (status == "reconciliation_required") == !unresolved.isEmpty,
                  day?.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                  month?.range(of: #"^[0-9]{4}-[0-9]{2}$"#, options: .regularExpression) != nil
            else { return false }
            if let accountUsage {
                guard accountUsage.count <= 12, Set(accountUsage.map(\.accountID)).count == accountUsage.count,
                      accountUsage.allSatisfy(\.valid) else { return false }
            }
            return day?.hasPrefix((month ?? "") + "-") == true
        }
    }

    enum Operation: String, Encodable, Sendable {
        case status = "text_status", configure = "text_configure", abandon = "text_abandon"
        case credentialSave = "text_credential_save", credentialStatus = "text_credential_status"
        case credentialDelete = "text_credential_delete", credentialList = "text_credential_list"
    }
    struct Request: Encodable, Sendable {
        let v = 1
        let operation: Operation
        var id: String? = nil
        var settings: Settings? = nil
        var operationID: String? = nil
        var credentialReference: String? = nil
        var credentialSecret: String? = nil
        var credentialAccountID: String? = nil
        enum CodingKeys: String, CodingKey {
            case v, operation, id, settings = "text_settings", operationID = "text_operation_id"
            case credentialReference = "credential_reference", credentialSecret = "credential_secret"
            case credentialAccountID = "credential_account_id"
        }
        var valid: Bool {
            let credentialOperation = [.credentialSave, .credentialStatus, .credentialDelete].contains(operation)
            if !credentialOperation && (credentialReference != nil || credentialSecret != nil || credentialAccountID != nil) { return false }
            switch operation {
            case .credentialSave:
                return id == nil && settings == nil && operationID == nil &&
                    RelayHostRotationRPC.validOperationID(credentialReference ?? "") &&
                    RelayHostRotationRPC.validOperationID(credentialAccountID ?? "") &&
                    credentialSecret.map({ (16...512).contains($0.utf8.count) && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }) == true
            case .credentialStatus, .credentialDelete:
                return id == nil && settings == nil && operationID == nil && credentialSecret == nil && credentialAccountID == nil &&
                    RelayHostRotationRPC.validOperationID(credentialReference ?? "")
            case .status, .credentialList: return id == nil && settings == nil && operationID == nil
            case .configure: return RelayHostRotationRPC.validOperationID(id ?? "") && settings?.valid == true && operationID == nil
            case .abandon: return id == nil && settings == nil && RelayHostRotationRPC.validOperationID(operationID ?? "")
            }
        }
    }

    struct CredentialRecord: Decodable, Equatable, Sendable, Identifiable {
        let reference: String
        let accountID: String
        let state: String
        var id: String { reference }
        enum CodingKeys: String, CodingKey { case reference, state, accountID = "account_id" }
        var valid: Bool {
            RelayHostRotationRPC.validOperationID(reference) && RelayHostRotationRPC.validOperationID(accountID) &&
                ["pending", "saved", "deleting", "missing_or_locked"].contains(state)
        }
        var stateLabel: String {
            switch state {
            case "saved": "Saved"
            case "deleting": "Removal unconfirmed"
            case "missing_or_locked": "Check keyring"
            default: "Save unconfirmed"
            }
        }
    }
    static func decodeCredentials(_ data: Data) throws -> [CredentialRecord] {
        try checkFailure(data)
        struct Registry: Decodable { let v: Int; let status: String; let entries: [CredentialRecord] }
        let value = try JSONDecoder().decode(Registry.self, from: data)
        guard value.v == 1, value.status == "ready", value.entries.count <= 64,
              Set(value.entries.map(\.reference)).count == value.entries.count,
              value.entries.allSatisfy(\.valid) else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return value.entries
    }

    struct CredentialReceipt: Decodable, Sendable {
        let v: Int
        let status: String
        let reference: String
        let storage: String
    }
    static func decodeCredential(_ data: Data, reference: String) throws -> CredentialReceipt {
        try checkFailure(data)
        let value = try JSONDecoder().decode(CredentialReceipt.self, from: data)
        guard value.v == 1, value.reference == reference,
              ["saved", "missing", "missing_or_locked", "deleted"].contains(value.status),
              ["macos_keychain", "linux_secret_service"].contains(value.storage)
        else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return value
    }

    struct AbandonReceipt: Decodable, Sendable {
        let v: Int
        let status: String
        let operationID: String
        let chargedMicrousd: Int64
        enum CodingKeys: String, CodingKey { case v, status, operationID = "operation_id", chargedMicrousd = "charged_microusd" }
    }

    static func checkFailure(_ data: Data) throws {
        struct Failure: Decodable { let state: String?; let message: String?; let status: String?; let code: String? }
        guard data.count <= 262_144 else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let failure = try JSONDecoder().decode(Failure.self, from: data)
        if failure.state == "refused" {
            guard (failure.message?.utf8.count ?? 0) <= 8192 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            throw RelayHostRotationRPC.Failure.refused(failure.message ?? "The host refused the change. Check terminal control and read status.")
        }
        if failure.status == "failed" {
            let message: String
            switch failure.code {
            case "invalid_settings", "positive_limits_required": message = "Choose a provider and positive request limits. Claude API also needs daily and monthly budgets of at least $1."
            case "invalid_accounts", "invalid_account", "invalid_account_name", "invalid_billing_group",
                 "api_account_configuration_required", "saved_account_configuration_required", "account_required":
                message = "Complete the named account, its saved credential or login directory, and its request limits."
            case "configuration_changed": message = "The host settings changed in another tab. Reload before saving again."
            case "invalid_cli_path": message = "Use an absolute path to the account CLI on this host."
            case "invalid_model": message = "Enter a valid Codex model name."
            case "operation_identity_conflict": message = "Another configuration owns this request ID. Read the current host settings."
            case "reconciliation_required": message = "An earlier request has an unknown outcome. Review it before continuing."
            default: message = "The host's text service is unavailable. Check its helper and Python installation, then read status."
            }
            throw RelayHostRotationRPC.Failure.refused(message)
        }
    }

    static func decode(_ data: Data, request: Request) throws -> Status {
        try checkFailure(data)
        guard request.valid, [.status, .configure].contains(request.operation) else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.valid else { throw RelayHostRotationRPC.Failure.invalidResponse }
        if request.operation == .configure {
            guard !status.isUnsupported, status.configurationID == request.id, status.settings == request.settings else {
                throw RelayHostRotationRPC.Failure.invalidResponse
            }
        }
        return status
    }

    static func decodeAbandon(_ data: Data, operationID: String) throws {
        try checkFailure(data)
        let receipt = try JSONDecoder().decode(AbandonReceipt.self, from: data)
        guard receipt.v == 1, receipt.operationID == operationID, receipt.status == "abandoned",
              receipt.chargedMicrousd >= 0 else { throw RelayHostRotationRPC.Failure.invalidResponse }
    }

    @MainActor static func send(_ request: Request, profile: ConnectionProfile, paneID: UUID,
        lease: RelayPromptEditorControlLease? = nil,
        currentLease: () -> RelayPromptEditorControlLease? = { nil }) async throws -> Data {
        guard request.valid, profile.backend == .relay else { throw RelayHostRotationRPC.Failure.unavailable }
        if request.operation != .status && request.operation != .credentialStatus && request.operation != .credentialList {
            guard let lease, lease.paneID == paneID, lease.hostID == profile.id, currentLease() == lease else {
                throw RelayHostRotationRPC.Failure.changedConnection
            }
        }
        struct Envelope: Encodable {
            let requestID = "rpc-" + UUID().uuidString.lowercased()
            let operation = "host_rotation"
            let hostRotation: Forward
            enum CodingKeys: String, CodingKey { case requestID = "request_id", operation, hostRotation = "host_rotation" }
        }
        struct Forward: Encodable {
            let paneID: String
            let clientID: String
            let request: Request
            enum CodingKeys: String, CodingKey { case paneID = "pane_id", clientID = "client_id", request }
        }
        let input = try JSONEncoder().encode(Envelope(hostRotation: Forward(
            paneID: paneID.uuidString.lowercased(),
            clientID: (lease?.clientID ?? RelayClientIdentity.id).uuidString.lowercased(), request: request)))
        let output = try await RelayNodeTransportPool.shared.request(profile: profile, payload: input)
        try Task.checkCancellation()
        if let lease, currentLease() != lease { throw RelayHostRotationRPC.Failure.changedConnection }
        guard output.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        if let error = object["error"] as? String {
            guard error.utf8.count <= 8192 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            throw RelayHostRotationRPC.Failure.refused(error)
        }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }


    // Settings are host wide. This route is authenticated by the node's local
    // process or SSH connection and deliberately contains no pane or lease.
    static func hostEnvelope(_ request: Request, expectedConfigurationID: String? = nil) throws -> Data {
        guard request.valid else { throw RelayHostRotationRPC.Failure.invalidResponse }
        if request.operation == .configure {
            guard let expectedConfigurationID,
                  expectedConfigurationID.isEmpty || RelayHostRotationRPC.validOperationID(expectedConfigurationID) else {
                throw RelayHostRotationRPC.Failure.refused("Read the saved host settings before saving.")
            }
        } else if expectedConfigurationID != nil {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        struct Envelope: Encodable {
            let requestID = "rpc-" + UUID().uuidString.lowercased()
            let operation = "host_accounts"
            let hostAccounts: Forward
            enum CodingKeys: String, CodingKey { case requestID = "request_id", operation, hostAccounts = "host_accounts" }
        }
        struct Forward: Encodable {
            let request: Request
            let expectedConfigurationID: String?
            enum CodingKeys: String, CodingKey { case request, expectedConfigurationID = "expected_configuration_id" }
        }
        return try JSONEncoder().encode(Envelope(hostAccounts: Forward(
            request: request, expectedConfigurationID: expectedConfigurationID)))
    }

    @MainActor static func sendHost(_ request: Request, profile: ConnectionProfile,
                                   expectedConfigurationID: String? = nil) async throws -> Data {
        guard profile.backend == .relay else { throw RelayHostRotationRPC.Failure.unavailable }
        let input = try hostEnvelope(request, expectedConfigurationID: expectedConfigurationID)
        let output: Data
        do {
            output = try await RelayNodeTransportPool.shared.request(profile: profile, payload: input,
                requiredCapability: "host_accounts_v1")
        } catch RelayHostRPCError.unsupported {
            throw RelayHostRotationRPC.Failure.refused("Update Relay on this host to manage accounts in Settings.")
        }
        try Task.checkCancellation()
        guard output.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        if let error = object["error"] as? String {
            guard error.utf8.count <= 8192 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            throw RelayHostRotationRPC.Failure.refused(error)
        }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    // Decimal entry is converted with integer arithmetic. No rounding or
    // floating-point conversion can silently change a spending ceiling.
    static func parseDollars(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[0-9]{1,3}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]) else { return nil }
        let fractional = parts.count > 1 ? String(parts[1]) : ""
        guard let micro = Int64(fractional + String(repeating: "0", count: 6-fractional.count)) else { return nil }
        let amount = whole * 1_000_000 + micro
        return amount <= 200_000_000 ? amount : nil
    }
    static func dollars(_ amount: Int64) -> String {
        guard amount >= 0 else { return "0" }
        let fraction = String(format: "%06lld", amount % 1_000_000)
        let trimmed = fraction.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        return String(amount / 1_000_000) + (trimmed.isEmpty ? "" : "." + trimmed)
    }
}
