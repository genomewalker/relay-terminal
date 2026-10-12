import Foundation
import Testing
@testable import Relay

@Test func subscriptionQuotaSeparatesWindowsAndExpiresAtReset() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let value = try RelaySubscriptionQuota.claude(statusLine: Data(#"{"session_id":"exact","rate_limits":{"five_hour":{"used_percentage":32.5,"resets_at":1100},"seven_day":{"used_percentage":91,"resets_at":2000}},"context_window":{"remaining_percentage":1},"cost":{"total_cost_usd":100}}"#.utf8), expectedSessionID: "exact", now: now)
    #expect(value.windows.count == 2)
    #expect(value.windows[0].remainingPercent == 67.5)
    #expect(value.isCurrent(value.windows[0], now: now))
    #expect(!value.isCurrent(value.windows[0], now: Date(timeIntervalSince1970: 1100)))
    #expect(!value.isCurrent(value.windows[1], now: Date(timeIntervalSince1970: 1301)))
    #expect(throws: RelaySubscriptionQuota.ParseError.self) {
        try RelaySubscriptionQuota.claude(statusLine: Data(#"{"session_id":"wrong"}"#.utf8), expectedSessionID: "exact")
    }
}

@Test func subscriptionQuotaMissingNeverMeansFullAndRejectsBoolean() throws {
    let value = try RelaySubscriptionQuota.claude(statusLine: Data(#"{"session_id":"exact","rate_limits":{"five_hour":{"used_percentage":true},"seven_day":{"used_percentage":-1}}}"#.utf8), expectedSessionID: "exact")
    #expect(value.windows.isEmpty)
    let missing = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":null}"#.utf8))
    #expect(missing.windows.isEmpty)
}

@Test func subscriptionQuotaCodexPreservesDistinctBuckets() throws {
    let value = try RelaySubscriptionQuota.codex(response: Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000},"secondary":null},"other":{"primary":{"usedPercent":100,"windowDurationMins":60}}}}}"#.utf8))
    #expect(value.windows.map(\.id) == ["codex:primary", "other:primary"])
    #expect(value.windows.map(\.remainingPercent) == [75, 0])
    let empty = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":1}}}"#.utf8))
    #expect(empty.windows.isEmpty)
}

@Test func subscriptionQuotaCodexProWeeklyCreditsAndMissingBalance() throws {
    let value = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":10,"windowDurationMins":10080},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"62500"}},"rateLimitResetCredits":{"availableCount":2,"credits":[]}}"#.utf8))
    #expect(value.planType == "pro")
    #expect(value.windows.count == 1)
    #expect(value.windows[0].durationMinutes == 10080)
    #expect(value.credits[0].balance == "62500")
    #expect(value.availableResets == 2)
    let missing = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":null}}}"#.utf8))
    #expect(missing.credits[0].balance == nil)
    #expect(missing.credits[0].displayBalance == "Available · balance unknown")
    let malformed = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"credits":{"hasCredits":1,"unlimited":false,"balance":"62500"}}}"#.utf8))
    #expect(malformed.credits.isEmpty)
}

@MainActor @Test func subscriptionQuotaGroupsExactAccountAcrossHostsWithoutAddingBalances() throws {
    typealias Entry = RelaySubscriptionQuotaStore.Entry
    let old = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"primary":{"usedPercent":10},"credits":{"hasCredits":true,"unlimited":false,"balance":"62500"}}}"#.utf8), now: Date(timeIntervalSince1970: 1000))
    let new = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"primary":{"usedPercent":11},"credits":{"hasCredits":true,"unlimited":false,"balance":"62000"}}}"#.utf8), now: Date(timeIntervalSince1970: 1100))
    let values = Entry.grouped([
        Entry(id: "local", hosts: ["This Mac"], provider: .codex, accountScope: "same", quota: old),
        Entry(id: "remote", hosts: ["dandy-07"], provider: .codex, accountScope: "same", quota: new)])
    #expect(values.count == 1)
    #expect(values[0].hosts == ["This Mac", "dandy-07"])
    #expect(values[0].quota?.credits[0].balance == "62000")
    #expect(values[0].quota?.windows[0].remainingPercent == 89)
    #expect(Entry.grouped([
        Entry(id: "one", hosts: ["This Mac"], provider: .codex, accountScope: nil, quota: old),
        Entry(id: "two", hosts: ["dandy-07"], provider: .codex, accountScope: nil, quota: old)]).count == 2)
    #expect(Entry.grouped([
        Entry(id: "one", hosts: ["This Mac"], provider: .codex, accountScope: "one", quota: old),
        Entry(id: "two", hosts: ["dandy-07"], provider: .codex, accountScope: "two", quota: old)]).count == 2)
}

@MainActor @Test func subscriptionQuotaRefreshesAfterExpiryAndClockCorrection() {
    let start = Date(timeIntervalSince1970: 1_000)
    let store = RelaySubscriptionQuotaStore(lastRefreshFinishedAt: start)
    #expect(!store.refreshIsDue(now: start.addingTimeInterval(119)))
    #expect(store.refreshIsDue(now: start.addingTimeInterval(120)))
    #expect(store.refreshIsDue(now: start.addingTimeInterval(-1)))
    #expect(store.refreshIsDue(now: start, force: true))
    #expect(RelaySubscriptionQuotaStore().refreshIsDue(now: start))
}

@Test func subscriptionQuotaUsesReadableWindowsWithoutLosingBuckets() throws {
    let value = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}},"review":{"limitName":"Code review","primary":{"usedPercent":10,"windowDurationMins":30}}}}"#.utf8))
    #expect(value.windows.map(\.label) == ["5 hours", "7 days", "Code review · 30 min"])
    #expect(value.windows.map(\.remainingPercent) == [75, 40, 90])
}

@MainActor @Test func subscriptionQuotaKeepsAccountOrderStableOnTheSameHost() {
    typealias Entry = RelaySubscriptionQuotaStore.Entry
    let a = Entry(id: "a", hosts: ["This Mac"], provider: .codex, accountScope: "a", quota: nil)
    let b = Entry(id: "b", hosts: ["This Mac"], provider: .codex, accountScope: "b", quota: nil)
    #expect(Entry.grouped([b, a]).map(\.id) == Entry.grouped([a, b]).map(\.id))
}

@Test func subscriptionQuotaFreshAccountDataWinsOverNewerPartialSessionReport() throws {
    let now = Date(timeIntervalSince1970: 2000)
    let account = try RelaySubscriptionQuota.claude(statusLine: Data(#"{"session_id":"account-usage","rate_limits":{"five_hour":{"used_percentage":25},"seven_day":{"used_percentage":60}}}"#.utf8), expectedSessionID: "account-usage", now: now.addingTimeInterval(-10))
    let partial = try RelaySubscriptionQuota.claude(statusLine: Data(#"{"session_id":"session","rate_limits":{"five_hour":{"used_percentage":20}}}"#.utf8), expectedSessionID: "session", now: now)
    let chosen = RelaySubscriptionQuota.preferred(account, partial, now: now)
    #expect(chosen == account)
    #expect(chosen.windows.count == 2)
    #expect(RelaySubscriptionQuota.preferred(partial, account, now: now) == account)
    #expect(RelaySubscriptionQuota.preferred(account, partial, now: now.addingTimeInterval(295)) == partial)
}

@Test func subscriptionQuotaFutureHostClockCannotHideCurrentObservation() throws {
    let now = Date(timeIntervalSince1970: 2000)
    let bytes = Data(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8)
    let current = try RelaySubscriptionQuota.codex(response: bytes, now: now)
    let future = try RelaySubscriptionQuota.codex(response: bytes, now: now.addingTimeInterval(60))
    #expect(RelaySubscriptionQuota.preferred(current, future, now: now) == current)
    #expect(RelaySubscriptionQuota.preferred(future, current, now: now) == current)
}


private actor SubscriptionQuotaReadCounter {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var peak = 0
    enum Failure: Error { case unavailable }

    func read(fail: Bool = false) async throws -> Data {
        calls += 1
        active += 1
        peak = max(peak, active)
        await Task.yield()
        active -= 1
        if fail { throw Failure.unavailable }
        return Data("[]".utf8)
    }
}

@Test func subscriptionQuotaSharesReadsAndPreservesCapturedTime() async throws {
    let reader = RelaySubscriptionQuotaReader()
    let counter = SubscriptionQuotaReadCounter()
    let snapshots = try await withThrowingTaskGroup(of: RelaySubscriptionQuotaReader.Snapshot.self) { group in
        for _ in 0..<20 {
            group.addTask { try await reader.read(key: "same") { try await counter.read() } }
        }
        var values: [RelaySubscriptionQuotaReader.Snapshot] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(await counter.calls == 1)
    #expect(snapshots.count == 20)
    #expect(Set(snapshots.map(\.observedAt)).count == 1)
    let cached = try await reader.read(key: "same") { try await counter.read() }
    #expect(cached.observedAt == snapshots.first?.observedAt)
    _ = try await reader.read(key: "same", force: true) { try await counter.read() }
    #expect(await counter.calls == 2)
}

@Test func subscriptionQuotaBoundsConcurrentReadsAcrossHosts() async throws {
    let reader = RelaySubscriptionQuotaReader(maximumConcurrentReads: 2)
    let counter = SubscriptionQuotaReadCounter()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                _ = try await reader.read(key: "host-\(index)") { try await counter.read() }
            }
        }
        try await group.waitForAll()
    }
    #expect(await counter.calls == 20)
    #expect(await counter.peak <= 2)
}

@Test func subscriptionQuotaFailedReadCanRetryAndContextsStaySeparate() async throws {
    let reader = RelaySubscriptionQuotaReader()
    let counter = SubscriptionQuotaReadCounter()
    do {
        _ = try await reader.read(key: "host:panes-a") { try await counter.read(fail: true) }
        Issue.record("Expected the read to fail")
    } catch SubscriptionQuotaReadCounter.Failure.unavailable {}
    _ = try await reader.read(key: "host:panes-a") { try await counter.read() }
    _ = try await reader.read(key: "host:panes-b") { try await counter.read() }
    #expect(await counter.calls == 3)
}

@MainActor @Test func subscriptionQuotaHostFailureRetainsHistoryWithoutClaimingSharedAccount() throws {
    typealias Entry = RelaySubscriptionQuotaStore.Entry
    let quota = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8))
    let previous = Entry(id: "remote", hosts: ["dandy-07"], provider: .codex, accountScope: "same", quota: quota)
    let historical = Entry.afterFailure([previous], key: "remote", host: "dandy-07")
    #expect(historical.count == 1)
    #expect(historical[0].refreshFailed)
    #expect(historical[0].quota == quota)
    #expect(historical[0].accountScope == "same")
    let verified = Entry(id: "local", hosts: ["This Mac"], provider: .codex, accountScope: "same", quota: quota)
    let grouped = Entry.grouped(historical + [verified])
    #expect(grouped.count == 2)
    #expect(grouped.filter(\.refreshFailed).count == 1)
    #expect(grouped.allSatisfy { $0.hosts.count == 1 })
    #expect(Entry.afterFailure([], key: "new", host: "new").allSatisfy { $0.refreshFailed && $0.quota == nil })
}

@MainActor @Test func subscriptionQuotaCachedPayloadNeverAcquiresANewerReportTime() throws {
    let captured = Date(timeIntervalSince1970: 1_000)
    let scope = String(repeating: "a", count: 64)
    let rows: [[String: Any]] = [
        ["provider": "codex", "identity_only": true, "account_scope": scope],
        ["provider": "codex", "account_scope": scope,
         "observation": ["rateLimits": ["primary": ["usedPercent": 25]]]]
    ]
    let snapshot = RelaySubscriptionQuotaReader.Snapshot(data: try JSONSerialization.data(withJSONObject: rows), observedAt: captured)
    let parsed = try RelaySubscriptionQuotaStore.entries(from: snapshot, key: "local", host: "This Mac")
    #expect(parsed.first?.quota?.observedAt == captured)
    #expect(parsed.first?.accountScope == scope)
    #expect(parsed.allSatisfy { !$0.refreshFailed })
    let empty = try RelaySubscriptionQuotaStore.entries(
        from: .init(data: Data("[]".utf8), observedAt: captured), key: "local", host: "This Mac")
    #expect(empty.count == 2)
    #expect(empty.allSatisfy { $0.quota == nil && $0.accountScope == nil && !$0.refreshFailed })
    #expect(throws: RelaySubscriptionQuota.ParseError.self) {
        try RelaySubscriptionQuotaStore.entries(
            from: .init(data: Data("{}".utf8), observedAt: captured), key: "local", host: "This Mac")
    }
}


@MainActor @Test func subscriptionQuotaGlanceShowsTheLimitingCurrentWindow() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let quota = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":95,"windowDurationMins":10080}}}"#.utf8), now: now)
    let entry = RelaySubscriptionQuotaStore.Entry(id: "local", hosts: ["This Mac"], provider: .codex, accountScope: nil, quota: quota)
    let glance = entry.glance(now: now)
    #expect(glance.value == "5% left")
    #expect(glance.detail == "7 days")
    #expect(glance.isLow)
    #expect(entry.glance(now: now.addingTimeInterval(301)).value == "Stale")
    var historical = entry
    historical.refreshFailed = true
    #expect(historical.glance(now: now).value == "Last known")
    #expect(!historical.glance(now: now).isLow)
}

@MainActor @Test func subscriptionQuotaGlanceHandlesCreditsAndUnavailableAccounts() throws {
    let now = Date()
    let quota = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true}}}"#.utf8), now: now)
    let credit = RelaySubscriptionQuotaStore.Entry(id: "local", hosts: ["This Mac"], provider: .codex, accountScope: nil, quota: quota)
    #expect(credit.glance(now: now).value == "Unlimited")
    #expect(credit.glance(now: now).detail == "Credits")
    let missing = RelaySubscriptionQuotaStore.Entry(id: "missing", hosts: ["remote"], provider: .claude, accountScope: nil, quota: nil)
    #expect(missing.glance(now: now).value == "Unavailable")
}
