import SwiftUI

@MainActor final class RelaySubscriptionQuotaStore: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let hosts: [String]
        let provider: RelaySubscriptionQuota.Provider
        let accountScope: String?
        var quota: RelaySubscriptionQuota?
        var refreshFailed = false
        var host: String { hosts.joined(separator: " · ") }

        struct Glance {
            let value: String
            let detail: String
            var isLow = false
        }

        func glance(now: Date) -> Glance {
            guard !refreshFailed else { return Glance(value: "Last known", detail: "Refresh failed") }
            guard let quota else { return Glance(value: "Unavailable", detail: "Refresh to check") }
            let windows = quota.windows.filter { quota.isCurrent($0, now: now) }
            if let limiting = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                return Glance(value: "\(Int(limiting.remainingPercent))% left",
                              detail: limiting.label, isLow: limiting.remainingPercent <= 10)
            }
            guard quota.observationIsCurrent(now: now) else {
                return Glance(value: "Stale", detail: "Refresh to check")
            }
            if let credit = quota.credits.first {
                return Glance(value: credit.displayBalance, detail: "Credits")
            }
            if let resets = quota.availableResets {
                return Glance(value: String(resets), detail: "Resets available")
            }
            return Glance(value: "See details", detail: "Account usage")
        }
        static func afterFailure(_ previous: [Entry], key: String, host: String) -> [Entry] {
            let known = previous.isEmpty ? [RelaySubscriptionQuota.Provider.codex, .claude].map {
                Entry(id: key + $0.rawValue, hosts: [host], provider: $0, accountScope: nil, quota: nil)
            } : previous
            return known.map { value in
                var historical = value
                historical.refreshFailed = true
                return historical
            }
        }

        static func grouped(_ entries: [Entry]) -> [Entry] {
            var groups: [String: Entry] = [:]
            for entry in entries {
                // A failed host read cannot verify that its previous account is still signed in.
                let key = entry.refreshFailed ? "unverified:" + entry.id :
                    (entry.accountScope.map { entry.provider.rawValue + ":" + $0 } ?? entry.id)
                guard let previous = groups[key] else {
                    groups[key] = Entry(id: key, hosts: entry.hosts, provider: entry.provider,
                                        accountScope: entry.accountScope, quota: entry.quota,
                                        refreshFailed: entry.refreshFailed)
                    continue
                }
                let hosts = Array(Set(previous.hosts + entry.hosts)).sorted { left, right in
                    if left == "This Mac" { return right != "This Mac" }
                    if right == "This Mac" { return false }
                    return left < right
                }
                // One shared allowance: choose an observation, never sum percentages or balances.
                let quota: RelaySubscriptionQuota?
                if let next = entry.quota { quota = .preferred(previous.quota, next) }
                else { quota = previous.quota }
                groups[key] = Entry(id: key, hosts: hosts, provider: entry.provider,
                                    accountScope: entry.accountScope, quota: quota)
            }
            return groups.values.sorted {
                if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
                if $0.host != $1.host { return $0.host < $1.host }
                return $0.id < $1.id
            }
        }
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var refreshing = false
    private(set) var lastRefreshFinishedAt: Date?
    private var lastSuccessfulEntriesByHost: [String: [Entry]] = [:]

    init(lastRefreshFinishedAt: Date? = nil) { self.lastRefreshFinishedAt = lastRefreshFinishedAt }
    static let refreshInterval: TimeInterval = 120

    func refreshIsDue(now: Date = Date(), force: Bool = false) -> Bool {
        guard !refreshing else { return false }
        guard !force, let last = lastRefreshFinishedAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        // A wall-clock correction must not suppress refresh indefinitely.
        return elapsed < 0 || elapsed >= Self.refreshInterval
    }

    func refresh(workspace: WorkspaceModel, force: Bool = false) async {
        guard refreshIsDue(force: force) else { return }
        refreshing = true
        defer {
            refreshing = false
            if !Task.isCancelled { lastRefreshFinishedAt = Date() }
        }
        var profiles: [String: (ConnectionProfile, [String])] = [:]
        for pane in workspace.panes.values where pane.contentKind == .terminal {
            let profile = pane.profile
            let key = ([profile.host] + profile.sshConnectionArguments).joined(separator: "\u{0}")
            if profiles[key] == nil { profiles[key] = (profile, []) }
            profiles[key]?.1.append(pane.id.uuidString.lowercased())
        }
        if profiles.isEmpty { profiles["local"] = (.local, []) }
        guard let url = RelayResources.bundle?.url(forResource: "subscription_quota", withExtension: "py", subdirectory: "Rotation"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { return }
        var observations: [Entry] = []
        var history: [String: [Entry]] = [:]
        for key in profiles.keys.sorted() {
            guard !Task.isCancelled, let (profile, panes) = profiles[key] else { break }
            let host = profile.kind == .local ? "This Mac" : profile.host
            do {
                // Pane context matters for Claude session reports. Do not share different scopes.
                let readKey = (profile.kind == .local ? "local:" : "ssh:") + key +
                    "\u{0}" + panes.sorted().joined(separator: ",")
                let snapshot = try await RelaySubscriptionQuotaReader.shared.read(key: readKey, force: force) {
                    try await Self.read(profile: profile, script: script, panes: panes)
                }
                let rows = try Self.entries(from: snapshot, key: key, host: host)
                history[key] = rows
                observations.append(contentsOf: rows)
            } catch {
                guard !Task.isCancelled else { break }
                let previous = lastSuccessfulEntriesByHost[key] ?? []
                history[key] = previous
                observations.append(contentsOf: Entry.afterFailure(previous, key: key, host: host))
            }
        }
        if !Task.isCancelled {
            lastSuccessfulEntriesByHost = history
            entries = Entry.grouped(observations)
        }
    }

    static func entries(from snapshot: RelaySubscriptionQuotaReader.Snapshot,
                        key: String, host: String) throws -> [Entry] {
        guard let rows = try JSONSerialization.jsonObject(with: snapshot.data) as? [[String: Any]] else {
            throw RelaySubscriptionQuota.ParseError.invalidPayload
        }
        return [RelaySubscriptionQuota.Provider.codex, .claude].map { provider in
            var newest: RelaySubscriptionQuota?
            let identity = rows.first { $0["provider"] as? String == provider.rawValue && $0["identity_only"] as? Bool == true }
            let scope = (identity?["account_scope"] as? String).flatMap {
                $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil ? $0 : nil
            }
            for row in rows where row["provider"] as? String == provider.rawValue {
                guard row["identity_only"] as? Bool != true,
                      row["account_scope"] as? String == scope else { continue }
                guard let observation = row["observation"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: observation) else { continue }
                let quota: RelaySubscriptionQuota?
                if provider == .codex {
                    quota = try? .codex(response: data, now: snapshot.observedAt)
                } else {
                    guard let session = observation["session_id"] as? String,
                          let captured = observation["captured_at"] as? String,
                          let date = Self.date(captured) else { continue }
                    quota = try? .claude(statusLine: data, expectedSessionID: session, now: date)
                }
                if let quota, !quota.windows.isEmpty || !quota.credits.isEmpty || quota.availableResets != nil || quota.extraUsageEnabled != nil {
                    newest = .preferred(newest, quota)
                }
            }
            return Entry(id: key + provider.rawValue, hosts: [host], provider: provider,
                         accountScope: scope, quota: newest)
        }
    }

    private static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: text) { return value }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    nonisolated private static func read(profile: ConnectionProfile, script: String, panes: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            if profile.kind == .local {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "-c", script] + panes
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + profile.sshConnectionArguments +
                    ["python3 -c " + quote(script) + " " + panes.map(quote).joined(separator: " ")]
            }
            process.standardInput = FileHandle.nullDevice
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            let result = try ProcessCapture.run(process, output: output, errors: errors, timeout: 15, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelaySubscriptionQuota.ParseError.invalidPayload }
            return result.standardOutput
        }.value
    }
}


private struct RelaySubscriptionQuotaRow: View {
    let entry: RelaySubscriptionQuotaStore.Entry
    let now: Date
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let glance = entry.glance(now: now)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: RelayTheme.spacing(10)) {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                        HStack(spacing: RelayTheme.spacing(5)) {
                            Text(entry.provider.rawValue.capitalized).fontWeight(.medium)
                            if let plan = entry.quota?.planType {
                                Text(plan.capitalized).foregroundStyle(.secondary)
                            }
                        }.font(.callout)
                        Text(entry.host).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(entry.host)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: RelayTheme.spacing(3)) {
                        Text(glance.value).font(.callout).fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(glance.isLow ? Color.orange : Color.primary)
                            .lineLimit(1)
                        Text(glance.detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(glance.detail)
                    }.frame(maxWidth: 125, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                }
                .padding(.vertical, RelayTheme.spacing(10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.provider.rawValue.capitalized) \(entry.quota?.planType?.capitalized ?? ""), \(entry.host), \(glance.value), \(glance.detail)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hide account details" : "Show account details")
            .accessibilityIdentifier("relay.quota.account.\(entry.id)")
            if expanded {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
        if entry.hosts.count > 1 {
            Text("Shared allowance across these hosts").font(.caption).foregroundStyle(.secondary)
        }
        if entry.refreshFailed {
            Text(entry.quota == nil ? "Refresh failed. Account could not be checked." :
                 "Refresh failed. Showing last known account and usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let quota = entry.quota, !quota.windows.isEmpty || !quota.credits.isEmpty || quota.availableResets != nil || quota.extraUsageEnabled != nil {
            ForEach(quota.windows) { window in
                let showValue = entry.refreshFailed || quota.isCurrent(window, now: now)
                HStack {
                    Text(window.label)
                    Spacer()
                    Text(showValue ? "\(Int(window.remainingPercent))% left" : "Stale").monospacedDigit()
                }.font(.callout)
                if let reset = window.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(quota.credits) { credit in
                HStack {
                    Text(quota.credits.count > 1 ? "Credits · " + credit.label : "Credits left")
                    Spacer()
                    Text((entry.refreshFailed || quota.observationIsCurrent(now: now)) ? credit.displayBalance : "Stale")
                        .monospacedDigit()
                }.font(.callout)
            }
            if let enabled = quota.extraUsageEnabled {
                HStack {
                    Text("Extra usage")
                    Spacer()
                    Text((entry.refreshFailed || quota.observationIsCurrent(now: now)) ? (enabled ? "Enabled" : "Disabled") : "Stale")
                }.font(.callout)
                if let used = quota.extraUsageUsed {
                    HStack { Text("Extra usage spent"); Spacer(); Text((entry.refreshFailed || quota.observationIsCurrent(now: now)) ? used : "Stale") }.font(.callout)
                }
                if let balance = quota.extraUsageBalance {
                    HStack { Text("Usage credit balance"); Spacer(); Text((entry.refreshFailed || quota.observationIsCurrent(now: now)) ? balance : "Stale") }.font(.callout)
                }
            }
            if let resets = quota.availableResets {
                HStack {
                    Text("Quota resets available")
                    Spacer()
                    Text((entry.refreshFailed || quota.observationIsCurrent(now: now)) ? String(resets) : "Stale")
                }.font(.callout)
            }
            Text(quota.sourceLabel).font(.caption).foregroundStyle(.secondary)
            Text("Reported \(quota.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        } else { Text("Usage is unavailable from this host. Refresh to try again.").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.top, RelayTheme.spacing(2))
                .padding(.bottom, RelayTheme.spacing(12))
                .transition(.opacity)
            }
        }
    }
}

private struct RelaySubscriptionQuotaContentHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RelaySubscriptionQuotaButton: View {
    @ObservedObject var workspace: WorkspaceModel
    @StateObject private var store = RelaySubscriptionQuotaStore()
    @State private var presenting = false
    @State private var observedNow = Date()
    @State private var contentHeight: CGFloat = 180
    private func summary(now: Date) -> String {
        let values = store.entries.compactMap { entry -> String? in
            guard !entry.refreshFailed, let quota = entry.quota,
                  let left = quota.windows.filter({ quota.isCurrent($0, now: now) }).map(\.remainingPercent).min() else { return nil }
            return "\(entry.provider.rawValue.capitalized) \(Int(left))% left — \(entry.host)"
        }
        return values.isEmpty ? "Subscription quotas · click to check" : values.joined(separator: "\n")
    }
    var body: some View {
        let now = max(observedNow, Date())
        return Group {
            let low = store.entries.contains { entry in
                guard !entry.refreshFailed, let quota = entry.quota else { return false }
                return quota.windows.contains { quota.isCurrent($0, now: now) && $0.remainingPercent <= 10 }
            }
            RelayIconAction(summary(now: now), symbol: "gauge.with.dots.needle.33percent") { presenting.toggle() }
                .overlay(alignment: .topTrailing) {
                    if low { Circle().fill(Color.orange).frame(width: 5, height: 5).padding(RelayTheme.spacing(3)).allowsHitTesting(false) }
                }
                .accessibilityLabel("Subscription quotas")
                .accessibilityIdentifier("relay.tools.subscription-quotas")
                .popover(isPresented: $presenting, arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
                        HStack {
                            Text("Account usage").font(.headline)
                            Spacer()
                            Button { Task { await store.refresh(workspace: workspace, force: true) } } label: {
                                ZStack {
                                    Image(systemName: "arrow.clockwise").opacity(store.refreshing ? 0 : 1)
                                    if store.refreshing { ProgressView().controlSize(.small) }
                                }.frame(width: 18, height: 18)
                            }
                                .buttonStyle(.plain).disabled(store.refreshing).help("Refresh quotas")
                                .accessibilityLabel("Refresh quotas")
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if store.entries.isEmpty {
                                    Text(store.refreshing ? "Checking accounts…" : "Refresh to check your accounts.")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .padding(.vertical, RelayTheme.spacing(10))
                                }
                                ForEach(store.entries) { entry in
                                    RelaySubscriptionQuotaRow(entry: entry, now: now)
                                    if entry.id != store.entries.last?.id { Divider() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: RelaySubscriptionQuotaContentHeight.self,
                                                           value: geometry.size.height)
                                }
                            }
                        }
                        .frame(height: min(max(contentHeight, 1), 420))
                        .onPreferenceChange(RelaySubscriptionQuotaContentHeight.self) { contentHeight = $0 }
                        .scrollBounceBehavior(.basedOnSize)

                        Text("Refreshes automatically while Relay is active.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(RelayTheme.spacing(16)).frame(width: 330)
                        .task { await store.refresh(workspace: workspace) }
                }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) {
            observedNow = $0
            if NSApplication.shared.isActive {
                Task { await store.refresh(workspace: workspace) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            observedNow = Date()
            Task { await store.refresh(workspace: workspace) }
        }
        .task { await store.refresh(workspace: workspace) }
    }
}
