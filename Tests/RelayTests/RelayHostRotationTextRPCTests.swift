import Foundation
import XCTest
@testable import Relay

final class RelayHostRotationTextRPCTests: XCTestCase {
    private let operationID = String(repeating: "a", count: 32)
    private let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func settings() -> RelayHostRotationTextRPC.Settings {
        .init(enabled: true, providers: ["anthropic_api", "codex_account"],
              dailyLimitMicrousd: 1_000_000, monthlyLimitMicrousd: 5_000_000,
              maxRequestsPerDay: 20, codexModel: "fixture-model", codexPath: "/host/bin/codex")
    }
    private func status(_ settings: RelayHostRotationTextRPC.Settings? = nil) throws -> [String: Any] {
        ["v": 1, "status": "ready", "configuration_id": operationID,
         "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings ?? self.settings())),
         "day": "2026-10-11", "month": "2026-10", "requests_today": 1,
         "charged_today_microusd": 100, "charged_month_microusd": 1000, "unresolved": []]
    }
    private func configureRequest() -> RelayHostRotationTextRPC.Request {
        .init(operation: .configure, id: operationID, settings: settings())
    }

    func testExactDollarConversionAndBounds() {
        for (input, amount) in ["0": Int64(0), "1": 1_000_000, "0.000001": 1, "199.999999": 199_999_999, "200": 200_000_000] {
            XCTAssertEqual(RelayHostRotationTextRPC.parseDollars(input), amount)
            XCTAssertEqual(RelayHostRotationTextRPC.parseDollars(RelayHostRotationTextRPC.dollars(amount)), amount)
        }
        for input in ["200.000001", "201", "-1", "1,5", "1e2", "NaN", "1.0000001", ".5", "1."] {
            XCTAssertNil(RelayHostRotationTextRPC.parseDollars(input), input)
        }
    }

    func testDisabledDefaultsAndProviderOrderArePreserved() throws {
        let defaults = RelayHostRotationTextRPC.Settings()
        XCTAssertTrue(defaults.valid); XCTAssertFalse(defaults.enabled)
        let request = configureRequest(); XCTAssertTrue(request.valid)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "operation", "id", "text_settings"])
        let decoded = try JSONDecoder().decode(RelayHostRotationTextRPC.Settings.self,
            from: JSONEncoder().encode(settings()))
        XCTAssertEqual(decoded.providers, ["anthropic_api", "codex_account"])
        XCTAssertEqual(decoded.codexPath, "/host/bin/codex")
        XCTAssertEqual(decoded.codexModel, "fixture-model")
    }

    func testConfigurationReceiptRequiresCurrentIDAndExactSettings() throws {
        let request = configureRequest()
        let response = try RelayHostRotationTextRPC.decode(data(status()), request: request)
        XCTAssertEqual(response.configurationID, operationID)
        XCTAssertEqual(response.settings, settings())
        var body = try status(); body["configuration_id"] = String(repeating: "b", count: 32)
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(body), request: request))
        body = try status(); body["configuration_id"] = nil
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(body), request: request))
        var changed = settings(); changed.maxRequestsPerDay = 21
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(status(changed)), request: request))
    }

    func testReadStatusSupportsNewAndOlderHostStates() throws {
        let request = RelayHostRotationTextRPC.Request(operation: .status)
        XCTAssertTrue(request.valid)
        let initial = try RelayHostRotationTextRPC.decode(data(["v": 1, "status": "not_configured", "enabled": false]), request: request)
        XCTAssertTrue(initial.isNotConfigured); XCTAssertNil(initial.settings)
        XCTAssertTrue(try RelayHostRotationTextRPC.decode(data(["state": "unsupported"]), request: request).isUnsupported)
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(["state": "unsupported"]), request: configureRequest()))
    }

    func testUnresolvedStatusAndAcknowledgementKeepExactIdentity() throws {
        let id = String(repeating: "c", count: 32)
        var body = try status(); body["status"] = "reconciliation_required"; body["unresolved"] = [id]
        let request = RelayHostRotationTextRPC.Request(operation: .status)
        XCTAssertEqual(try RelayHostRotationTextRPC.decode(data(body), request: request).unresolved, [id])
        body["unresolved"] = [id, id]
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(body), request: request))
        let receipt: [String: Any] = ["v": 1, "status": "abandoned", "operation_id": id, "charged_microusd": 1_000_000]
        XCTAssertNoThrow(try RelayHostRotationTextRPC.decodeAbandon(data(receipt), operationID: id))
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decodeAbandon(data(receipt), operationID: operationID))
        var pending = receipt; pending["status"] = "pending"
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decodeAbandon(data(pending), operationID: id))
    }

    func testAPIOnlyRequestCapCanBeDisabledWithoutDisablingSpendingLimits() {
        var value = settings()
        value.providers = ["anthropic_api"]
        value.maxRequestsPerDay = 0
        XCTAssertTrue(value.valid)
        value.dailyLimitMicrousd = 999_999
        XCTAssertFalse(value.valid)
        value.dailyLimitMicrousd = 1_000_000
        value.monthlyLimitMicrousd = 999_999
        XCTAssertFalse(value.valid)
        var account = RelayHostRotationTextRPC.Account()
        account.enabled = true
        account.credentialReference = operationID
        account.billingGroup = "test"
        account.dailyLimitMicrousd = 1_000_000
        account.monthlyLimitMicrousd = 1_000_000
        XCTAssertTrue(account.valid)
        account.provider = "codex_account"
        account.credentialReference = nil
        account.billingGroup = nil
        account.authDirectory = "/test/login"
        account.model = "test-model"
        XCTAssertFalse(account.valid)
        account.maxRequestsPerDay = 10
        XCTAssertTrue(account.valid)
    }

    func testInvalidSettingsAndRequestShapesAreRefused() {
        var value = settings(); value.providers = ["anthropic_api", "anthropic_api"]; XCTAssertFalse(value.valid)
        value = settings(); value.dailyLimitMicrousd = 999_999; XCTAssertFalse(value.valid)
        value = settings(); value.monthlyLimitMicrousd = 200_000_001; XCTAssertFalse(value.valid)
        value = settings(); value.maxRequestsPerDay = 0; XCTAssertFalse(value.valid)
        value = settings(); value.codexPath = "relative"; XCTAssertFalse(value.valid)
        value = settings(); value.codexModel = "untrusted model"; XCTAssertFalse(value.valid)
        var request = RelayHostRotationTextRPC.Request(operation: .status); request.id = operationID; XCTAssertFalse(request.valid)
        request = .init(operation: .abandon, operationID: operationID); XCTAssertTrue(request.valid)
        request.settings = settings(); XCTAssertFalse(request.valid)
    }

    func testRefusalAndBudgetErrorsAreActionable() throws {
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(["state": "refused", "message": "input lease changed"]),
            request: configureRequest())) { XCTAssertEqual($0.localizedDescription, "input lease changed") }
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(["v": 1, "status": "failed", "code": "positive_limits_required"]),
            request: configureRequest())) { XCTAssertTrue($0.localizedDescription.contains("at least $1")) }
        var body = try status(); body["charged_today_microusd"] = -1
        XCTAssertThrowsError(try RelayHostRotationTextRPC.decode(data(body), request: .init(operation: .status)))
    }

    func testNativeCandidateUsesProjectDirectoryAndExactProcessIncarnation() throws {
        let body: [String: Any] = ["v": 1, "state": "ready", "cwd": "/native/project",
            "binding": ["version": 1, "session_id": "fixture-session", "transcript_path": "/private/source.jsonl",
                        "revision": "native-revision", "producer": ["pane_id": pane.uuidString.lowercased(),
                        "provider": "codex", "process_id": 101, "process_start": 102]]]
        let wire = String(decoding: try data(body), as: UTF8.self)
            .replacingOccurrences(of: "\"process_start\":102", with: "\"process_start\":18446744073709551615")
        let candidate = try JSONDecoder().decode(RelayHostRotationRPC.NativeCandidate.self, from: Data(wire.utf8))
        XCTAssertTrue(candidate.valid(for: pane)); XCTAssertFalse(candidate.valid(for: UUID()))
        XCTAssertEqual(candidate.cwd, "/native/project")
        XCTAssertEqual(candidate.binding.producer.processStart, UInt64.max)
    }
    func testPreparationHintsPointToTheRequiredAction() throws {
        let budget = try JSONDecoder().decode(RelayHostRotationRPC.Preparation.self,
            from: data(["state": "budget_limited", "code": "spending_limit"]))
        XCTAssertTrue(budget.hint?.contains("Handoff text settings") == true)
        let disabled = try JSONDecoder().decode(RelayHostRotationRPC.Preparation.self,
            from: data(["state": "disabled", "code": "text_backend_disabled"]))
        XCTAssertTrue(disabled.hint?.hasPrefix("Enable Handoff text") == true)
        let recovery = try JSONDecoder().decode(RelayHostRotationRPC.Preparation.self,
            from: data(["state": "reconciliation_required", "code": "reconciliation_required"]))
        XCTAssertTrue(recovery.hint?.contains("unresolved") == true)
        let complete = try JSONDecoder().decode(RelayHostRotationRPC.Preparation.self,
            from: data(["state": "complete"]))
        XCTAssertNil(complete.hint)
    }

}
