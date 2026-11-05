import Foundation
import Testing
@testable import Relay

private let paneID = UUID()
private let keyReference = "26a28707aa9e4522a8a0b822333f0b35"

private func rotation(enabled: Bool = false, state: String = "not_enrolled", observed: UInt64? = 0,
                      lastAt: String? = nil, agent: String? = nil) throws -> RelayHostRotationRPC.Status {
    var object: [String: Any] = ["v": 1, "operation_id": "", "operation": "", "enabled": enabled, "state": state,
                                 "generation": 1, "lifecycle": "unavailable", "refresh_capability": "unverified",
                                 // The host always encodes every enrollment field, zero when unenrolled.
                                 "enrollment": ["pane_id": "", "session_id": "", "client": "", "cwd": "", "agent_pid": 0, "agent_start": 0,
                                                "worker_pid": 0, "worker_start": 0, "node_boot_id": ""],
                                 "updated_at": "2026-10-13T00:00:00Z"]
    if let observed { object["observed_completed_turns"] = observed }
    if let lastAt { object["last_completed_turn_at"] = lastAt }
    if let agent { object["last_completed_turn_agent"] = agent }
    return try JSONDecoder().decode(RelayHostRotationRPC.Status.self, from: JSONSerialization.data(withJSONObject: object))
}

private func text(enabled: Bool = true, provider: String = "anthropic_api", accountEnabled: Bool = true,
                  credential: String? = keyReference) throws -> RelayHostRotationTextRPC.Status {
    var account: [String: Any] = ["id": "1c175f8796a7476f96ff8cd8f1f90241", "name": "Claude API", "provider": provider,
                                  "enabled": accountEnabled, "daily_limit_microusd": 6_000_000,
                                  "monthly_limit_microusd": 200_000_000, "max_requests_per_day": 100]
    if provider == "anthropic_api" { account["billing_group"] = "anthropic" }
    if let credential { account["credential_ref"] = credential }
    let object: [String: Any] = ["v": 1, "status": "ready", "configuration_id": "a3cd337594b141739cdb3c3e28029156",
        "settings": ["enabled": enabled, "providers": ["anthropic_api", "claude_account"], "accounts": [account],
                     "daily_limit_microusd": 6_000_000, "monthly_limit_microusd": 200_000_000, "max_requests_per_day": 100],
        "day": "2026-10-13", "month": "2026-10", "requests_today": 0, "charged_today_microusd": 0,
        "charged_month_microusd": 0, "unresolved": [String](), "credential_support": "v1"]
    return try JSONDecoder().decode(RelayHostRotationTextRPC.Status.self, from: JSONSerialization.data(withJSONObject: object))
}

private func credentials(_ state: String = "saved", reference: String = keyReference) throws -> [RelayHostRotationTextRPC.CredentialRecord] {
    let object: [String: Any] = ["v": 1, "status": "ready", "entries": [
        ["reference": reference, "account_id": "1c175f8796a7476f96ff8cd8f1f90241", "state": state]]]
    return try RelayHostRotationTextRPC.decodeCredentials(JSONSerialization.data(withJSONObject: object))
}

@Test("A saved key on an unenrolled pane explains that Enable is the missing step")
func contextSummaryUnenrolledPaneWithSavedKey() throws {
    let summary = RelayContextManagementSummary(rotation: try rotation(), text: try text(), credentials: try credentials())
    #expect(summary.handoffText == .ok("API key OK"))
    #expect(summary.enrollment == .attention("Pane not enrolled"))
    #expect(summary.completedTurns == .attention("No completed turns observed"))
    #expect(summary.line == "API key OK · Pane not enrolled · No completed turns observed")
    #expect(summary.nextStep?.contains("Enable") == true)
}

@Test("An enrolled pane with observed turns reports everything ready")
func contextSummaryReadyPane() throws {
    let now = try #require(RelayContextManagementSummary.parseTimestamp("2026-10-13T01:00:00Z"))
    let status = try rotation(enabled: true, state: "awaiting_completed_turn", observed: 3,
                              lastAt: "2026-10-13T00:58:00.123456789Z", agent: "codex")
    let summary = RelayContextManagementSummary(rotation: status, text: try text(), credentials: try credentials(), now: now)
    #expect(summary.enrollment == .ok("Pane enrolled"))
    #expect(summary.completedTurns.isOK)
    #expect(summary.completedTurns.text.hasPrefix("3 completed turns observed, last "))
    #expect(summary.nextStep == nil)
}

@Test("An enrolled pane that never sees a completed turn names the observation gap")
func contextSummaryEnrolledWithoutTurns() throws {
    let summary = RelayContextManagementSummary(rotation: try rotation(enabled: true, state: "awaiting_completed_turn"),
                                                text: try text(), credentials: try credentials())
    #expect(summary.completedTurns == .attention("No completed turns observed"))
    #expect(summary.nextStep?.contains("completed turn") == true)
}

@Test("Key problems are reported before enrollment")
func contextSummaryKeyProblems() throws {
    let locked = RelayContextManagementSummary(rotation: try rotation(), text: try text(), credentials: try credentials("missing_or_locked"))
    #expect(locked.handoffText == .attention("API key: Check keyring"))
    #expect(locked.nextStep?.contains("Settings") == true)
    let absent = RelayContextManagementSummary(rotation: try rotation(), text: try text(),
                                               credentials: try credentials(reference: "3b4abf6b642841d1b7c9cf7074007c2d"))
    #expect(absent.handoffText == .attention("API key not saved"))
    let noReference = RelayContextManagementSummary(rotation: try rotation(), text: try text(credential: nil), credentials: try credentials())
    #expect(noReference.handoffText == .attention("API key not saved"))
    let unread = RelayContextManagementSummary(rotation: try rotation(), text: try text(), credentials: nil)
    #expect(unread.handoffText == .unknown("API key status unavailable"))
}

@Test("Handoff text configuration states are distinguished")
func contextSummaryHandoffConfiguration() throws {
    #expect(RelayContextManagementSummary(rotation: nil, text: try text(enabled: false), credentials: nil).handoffText
        == .attention("Handoff text off"))
    #expect(RelayContextManagementSummary(rotation: nil, text: try text(accountEnabled: false), credentials: nil).handoffText
        == .attention("No enabled handoff account"))
    #expect(RelayContextManagementSummary(rotation: nil, text: try text(provider: "claude_account", credential: nil), credentials: nil).handoffText
        == .ok("Handoff account OK"))
    let notConfigured = try JSONDecoder().decode(RelayHostRotationTextRPC.Status.self,
                                                 from: Data(#"{"v":1,"status":"not_configured","enabled":false}"#.utf8))
    #expect(RelayContextManagementSummary(rotation: nil, text: notConfigured, credentials: nil).handoffText
        == .attention("Handoff text not set up"))
    #expect(RelayContextManagementSummary(rotation: nil, text: nil, credentials: nil).handoffText.isUnknown)
}

@Test("Older helpers without the observation stay unknown, not zero")
func contextSummaryOlderHelper() throws {
    let summary = RelayContextManagementSummary(rotation: try rotation(observed: nil), text: try text(), credentials: try credentials())
    #expect(summary.completedTurns == .unknown("Completed turns not reported by this host"))
    let unsupported = try JSONDecoder().decode(RelayHostRotationRPC.Status.self, from: Data(#"{"state":"unsupported"}"#.utf8))
    let old = RelayContextManagementSummary(rotation: unsupported, text: nil, credentials: nil)
    #expect(old.enrollment == .attention("Host update required"))
    #expect(old.completedTurns.isUnknown)
}

@Test("Status decoding accepts and bounds the observation fields")
func contextSummaryStatusDecoding() throws {
    let status = try rotation(observed: 2, lastAt: "2026-10-13T00:58:00.5Z", agent: "claude")
    #expect(status.valid(for: paneID))
    #expect(status.observedCompletedTurns == 2 && status.lastCompletedTurnAgent == "claude")
    #expect(!(try rotation(observed: 1, agent: "other")).valid(for: paneID))
    #expect(!(try rotation(observed: 1, lastAt: String(repeating: "9", count: 65))).valid(for: paneID))
}

@Test("Go timestamps with nanosecond fractions parse")
func contextSummaryTimestampParsing() throws {
    let base = try #require(RelayContextManagementSummary.parseTimestamp("2026-10-13T00:58:00Z"))
    let nanos = try #require(RelayContextManagementSummary.parseTimestamp("2026-10-13T00:58:00.123456789Z"))
    #expect(abs(nanos.timeIntervalSince(base) - 0.123) < 0.001)
    let offset = try #require(RelayContextManagementSummary.parseTimestamp("2026-10-13T02:58:00.5+02:00"))
    #expect(abs(offset.timeIntervalSince(base) - 0.5) < 0.001)
    #expect(RelayContextManagementSummary.parseTimestamp("not a date") == nil)
}
