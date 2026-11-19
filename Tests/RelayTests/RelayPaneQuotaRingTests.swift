import Foundation
import Testing
@testable import Relay

/// Each Claude or Codex pane shows its own account's 5-hour usage; on
/// dandy-07 a personal and a business Claude account share one host.
@MainActor
@Suite("A pane's quota ring shows its own account's usage")
struct RelayPaneQuotaRingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let personal = String(repeating: "a", count: 64)
    static let business = String(repeating: "b", count: 64)

    static func entry(_ scope: String?, provider: RelaySubscriptionQuota.Provider = .claude,
                      fiveHour: Double = 42, sevenDay: Double = 18, observedAgo: TimeInterval = 30,
                      fiveHourResetIn: TimeInterval = 3_600, label: String? = nil, failed: Bool = false) -> RelaySubscriptionQuotaStore.Entry {
        let quota = RelaySubscriptionQuota(provider: provider, observedAt: now.addingTimeInterval(-observedAgo), windows: [
            .init(id: "seven_day", label: "7 days", usedPercent: sevenDay, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400 * 3)),
            .init(id: "five_hour", label: "5 hours", usedPercent: fiveHour, durationMinutes: 300, resetsAt: now.addingTimeInterval(fiveHourResetIn)),
        ])
        var entry = RelaySubscriptionQuotaStore.Entry(id: "host" + provider.rawValue + (scope ?? ""), hosts: ["dandy-07"],
            provider: provider, accountScope: scope, quota: quota, refreshFailed: failed, accountLabel: label)
        entry.refreshFailed = failed
        return entry
    }

    @Test func theRingShowsFiveHourUsedWithSevenDayAndResetsOnHover() {
        let glance = RelayPaneQuotaGlance.make(entry: Self.entry(Self.personal, label: "personal"), now: Self.now)
        #expect(glance.usedFraction == 0.42)
        #expect(!glance.stale && glance.level == .normal)
        #expect(glance.help.hasPrefix("Claude · personal\n5 hours: 42% used · resets "))
        #expect(glance.help.contains("\n7 days: 18% used · resets "))
        #expect(glance.help.hasSuffix("As of just now"))
    }

    @Test func nearTheLimitTheRingWarnsThenTurnsCritical() {
        #expect(RelayPaneQuotaGlance.make(entry: Self.entry(nil, fiveHour: 80), now: Self.now).level == .warning)
        #expect(RelayPaneQuotaGlance.make(entry: Self.entry(nil, fiveHour: 95), now: Self.now).level == .critical)
    }

    @Test func anOldReadingIsShownAsLastKnownUntilItsWindowResets() {
        let old = RelayPaneQuotaGlance.make(entry: Self.entry(nil, observedAgo: 12 * 60), now: Self.now)
        #expect(old.stale && old.usedFraction == 0.42)
        #expect(old.help.hasSuffix("Last known, 12 min ago"))
        // After the 5-hour reset the next open window is shown, never a fresh 0%.
        let reset = RelayPaneQuotaGlance.make(entry: Self.entry(nil, observedAgo: 12 * 60, fiveHourResetIn: -1), now: Self.now)
        #expect(reset.usedFraction == 0.18)
        #expect(!reset.help.contains("5 hours"))
    }

    @Test func noReadingOrAFailedRefreshDrawsAHollowRing() {
        #expect(RelayPaneQuotaGlance.make(entry: nil, now: Self.now).usedFraction == nil)
        var failed = Self.entry(nil, failed: true)
        failed.quota = nil
        let glance = RelayPaneQuotaGlance.make(entry: failed, now: Self.now)
        #expect(glance.usedFraction == nil && glance.help == "Usage refresh failed")
        #expect(RelayPaneQuotaGlance.make(entry: Self.entry(nil, failed: true), now: Self.now).stale)
    }

    @Test func eachPaneMapsToTheAccountItsHostReported() {
        let rows = [Self.entry(Self.personal), Self.entry(Self.business), Self.entry(nil, provider: .codex)]
        let (claudePersonal, claudeBusiness, codex, shell, unreported) = ("p1", "p2", "p3", "p4", "p5")
        let kinds: [String: RelaySubscriptionQuota.Provider] = [claudePersonal: .claude, claudeBusiness: .claude,
                                                                codex: .codex, unreported: .claude]
        let accounts = RelaySubscriptionQuotaStore.paneAccounts(
            panes: [claudePersonal, claudeBusiness, codex, shell, unreported], rows: rows,
            reported: [claudePersonal: Self.personal, claudeBusiness: Self.business], provider: { kinds[$0] })
        #expect(accounts[claudePersonal] == "claude:" + Self.personal)
        #expect(accounts[claudeBusiness] == "claude:" + Self.business)
        #expect(accounts[codex] == rows[2].groupKey, "one Codex account on the host")
        #expect(accounts[shell] == nil)
        #expect(accounts[unreported] == nil, "two Claude accounts: never guess")
    }

    @Test func aSingleClaudeAccountCoversPanesWithoutAReport() {
        let rows = [Self.entry(Self.personal)]
        let accounts = RelaySubscriptionQuotaStore.paneAccounts(panes: ["p"], rows: rows, reported: [:],
                                                               provider: { _ in .claude })
        #expect(accounts["p"] == "claude:" + Self.personal)
    }

    @Test func relaydPaneRowsNameOnlyValidPanesAndScopes() throws {
        let pane = "07fa914c-6df8-45db-9757-3078bd97d2d2"
        let rows: [[String: Any]] = [
            ["provider": "claude", "pane_id": pane.uppercased(), "account_scope": Self.business],
            ["provider": "claude", "pane_id": "../x", "account_scope": Self.personal],
            ["provider": "claude", "pane_id": "0325f764-b5f0-4137-ab2c-14b518b233a5", "account_scope": "short"],
            ["provider": "codex", "pane_id": "0cbaecb0-0450-43e9-b97c-f5a649a9540f", "account_scope": Self.personal],
        ]
        let snapshot = RelaySubscriptionQuotaReader.Snapshot(data: try JSONSerialization.data(withJSONObject: rows), observedAt: Self.now)
        #expect(try RelaySubscriptionQuotaStore.paneScopes(from: snapshot) == [pane: Self.business])
    }
}
