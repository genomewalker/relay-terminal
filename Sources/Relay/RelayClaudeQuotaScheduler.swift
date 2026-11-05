import Foundation
import Combine

/// Moves require app-owned terminal renderers, prompt/owner leases and the
/// existing provider exit/resume machinery. relayd cannot safely perform that
/// operation without the app, so this scheduler deliberately lives here.
@MainActor final class RelayClaudeQuotaScheduler: ObservableObject {
    static let shared = RelayClaudeQuotaScheduler()
    @Published private(set) var notices: [UUID: String] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var usageLines: [String: [String]] = [:]
    /// The latest reason each host's failover is waiting, shown in Settings.
    @Published private(set) var deferrals: [String: String] = [:]
    @Published private(set) var hostKeys: Set<String> = ["local"]
    private struct Workspace { weak var value: WorkspaceModel? }
    private var workspaces: [Workspace] = []
    private let journal: RelayClaudeQuotaJournal
    private var engine: RelayClaudeQuotaEngine
    private var lane: Task<Void, Never>?
    private var nextTick = Date.distantPast
    private var quotaPolls = RelayClaudeQuotaPollSchedule()
    private var lastAudit: [UUID: String] = [:]

    init(url: URL = RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/AgentAccounts/quota-failover-v1.json")) {
        journal = RelayClaudeQuotaJournal(url: url)
        do {
            let disk = try journal.load()
            engine = .init(disk: disk)
            for record in disk.records where record.state == .moving || record.state == .returning || record.state == .refused {
                notices[record.pane] = "Quota failover needs attention: " + record.detail + ". This pane will not be retried in this window."
            }
        } catch {
            engine = .init()
            problem = "Quota failover stopped: its durable journal could not be read. " + error.localizedDescription
        }
    }

    var paused: Bool {
        // The base caller pause exists independently of Miko tool parity.
        !RelayCallerControl.shared.permitted(RelayCallerControl.assistantCaller)
    }

    func tick(_ workspace: WorkspaceModel, now: Date) {
        guard !RelayLaunchMode.isRunningTests else { return }
        workspaces.removeAll { $0.value == nil }
        if !workspaces.contains(where: { $0.value === workspace }) { workspaces.append(.init(value: workspace)) }
        guard problem == nil else { return }
        let settings = RelayPreferences.shared.claudeQuotaFailover
        // This happens even while lane is awaiting an in-flight move.
        if settings.enabled, settings.valid, !paused {
            for workspace in workspaces.compactMap(\.value) {
                for pane in workspace.panes.values where pane.contentKind == .terminal && pane.kind == .claude && pane.profile.backend == .relay {
                    let host = RelayAgentAccountDirectory.hostKey(pane.profile)
                    guard settings.hosts[host] != false, quotaPolls.begin(host: host, now: now) else { continue }
                    let profile = pane.profile
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.quotaPolls.finish(host: host) }
                        do { _ = try await RelayAgentAccountDirectory.shared.refreshUsage(profile, provider: "claude") }
                        catch {
                            self.deferrals[host] = "Claude usage could not be read: " + String(error.localizedDescription.prefix(160))
                            do { try self.audit(pane.id, "deferred_usage_read_failed") }
                            catch { self.problem = "Quota failover stopped: its audit could not be saved." }
                        }
                    }
                }
            }
        }
        guard lane == nil, now >= nextTick else { return }
        nextTick = now.addingTimeInterval(5)
        lane = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.lane = nil }
            do { try await self.run(now: now) }
            catch { self.problem = "Quota failover stopped: " + error.localizedDescription }
        }
    }

    /// This is only authority for the exact durable operation in the serial
    /// lane. MCP callers always use .mcp, never this internal origin.
    func authorizes(_ pane: UUID, target: RelayAgentAccount, proof: RelayAgentMaintenanceProbe? = nil) -> Bool {
        guard problem == nil, let move = engine.inFlight,
              let record = engine.disk.records.first(where: { $0.operation == move.operation }),
              record.state == (move.returning ? .returning : .moving),
              target.dir == (move.returning ? record.sourceDir : record.targetDir) else { return false }
        if let proof {
            guard proof.valid(for: pane), proof.provider == "claude", move.pane.session == proof.sessionID,
                  move.pane.process == Self.process(proof) else { return false }
        }
        return move.pane.id == pane && target.provider == "claude" && move.target == target.label
    }

    func userClaimed(_ pane: PaneModel) {
        guard !RelayLaunchMode.isRunningTests, pane.kind == .claude, problem == nil else { return }
        let settings = RelayPreferences.shared.claudeQuotaFailover
        guard settings.valid else { return }
        do {
            try engine.userMoved(.init(id: pane.id, host: RelayAgentAccountDirectory.hostKey(pane.profile),
                label: pane.agentAccount?.recorded?.label ?? "", session: "user-claimed", process: "user-claimed", idle: false),
                source: settings.source, target: settings.target, save: journal.save)
        } catch { problem = "Quota failover stopped after a manual move: its ownership fence could not be saved." }
    }

    private func audit(_ pane: UUID, _ event: String) throws {
        // Repeated polls of the same held pane are one deferral, not a retry.
        if event.hasPrefix("deferred"), lastAudit[pane] == event { return }
        try journal.appendAudit(pane, event)
        try RelayCallerControl.shared.recordAssistantAction(operation: "claude_quota_failover", requestID: UUID().uuidString,
            request: event, tabID: nil, paneID: pane, outcome: event.hasPrefix("deferred") ? "deferred" : event,
            path: "in-process/claude-quota-failover")
        lastAudit[pane] = event
    }

    /// Both the 5-hour window and at least one weekly window must be reported.
    /// A missing 5-hour window means its usage is unknown, not that none is
    /// running. Missing, duplicate, stale, unparseable or unrecognized windows
    /// cannot authorize a move or a return.
    static func quota(_ usage: RelayAgentAccountUsage?, now: Date, targetCeiling: Double? = nil) -> RelayClaudeQuotaEngine.Quota? {
        try? reading(usage, now: now, targetCeiling: targetCeiling).get()
    }

    /// Why a reading is not a usable quota. The code is the audit event's
    /// suffix (bounded, fixed vocabulary); `text` is for Settings.
    struct Unusable: Error, Equatable {
        let code: String
        let text: String
    }

    /// `displayingUnreportedFiveHour` is for Settings text only: it shows the
    /// weekly figures of a reading whose 5-hour usage is unknown. Failover
    /// always uses the default, which rejects that reading as `no_five_hour`.
    static func reading(_ usage: RelayAgentAccountUsage?, now: Date, targetCeiling: Double? = nil,
                        displayingUnreportedFiveHour: Bool = false) -> Result<RelayClaudeQuotaEngine.Quota, Unusable> {
        typealias E = RelayClaudeQuotaEngine
        guard let usage, usage.provider == "claude" else { return .failure(.init(code: "none", text: "no usage reading yet")) }
        guard usage.status == "ok" else {
            let reason = usage.reason.map { ": " + String($0.prefix(120)) } ?? ""
            return .failure(.init(code: "status", text: "Claude usage " + String(usage.status.prefix(24)) + reason))
        }
        guard let observed = usage.readDate, let windows = usage.windows, windows.count <= 7,
              Set(windows.map(\.name)).count == windows.count else {
            return .failure(.init(code: "invalid", text: "the usage reading is malformed"))
        }
        guard Set(windows.map(\.name)).isSubset(of: E.weeklyNames.union(["five_hour"])) else {
            return .failure(.init(code: "unknown_window", text: "Claude reported an unrecognized usage window"))
        }
        var weekly: [String: E.Window] = [:]
        for window in windows where window.name != "five_hour" {
            guard let raw = window.resetsAt, let reset = date(raw) else {
                return .failure(.init(code: "invalid", text: "a weekly window has no valid reset time"))
            }
            weekly[window.name] = .init(used: window.usedPercent, reset: reset, observed: observed)
        }
        guard !weekly.isEmpty else { return .failure(.init(code: "no_weekly", text: "Claude reported no weekly window")) }
        var quota = E.Quota(used: 0, reset: observed, observed: observed, weekly: weekly, fiveHourReported: false)
        if let five = windows.first(where: { $0.name == "five_hour" }) {
            // A reported 5-hour window must be complete; it is never dropped.
            guard let raw = five.resetsAt, let reset = date(raw) else {
                return .failure(.init(code: "invalid", text: "the 5-hour window has no valid reset time"))
            }
            quota = E.Quota(used: five.usedPercent, reset: reset, observed: observed, weekly: weekly)
        } else if !displayingUnreportedFiveHour {
            return .failure(.init(code: "no_five_hour",
                text: "Claude did not report the 5-hour window, so its usage is unknown"))
        }
        guard quota.current(now) else { // QF17 QW3
            return .failure(.init(code: "stale", text: "the usage reading is not current"))
        }
        if let targetCeiling, !quota.under(targetCeiling) {
            return .failure(.init(code: "ceiling", text: "a window is at or above the target ceiling"))
        }
        return .success(quota)
    }

    static func usageText(_ usage: RelayAgentAccountUsage?, label: String, now: Date) -> [String] {
        let quota: RelayClaudeQuotaEngine.Quota
        switch reading(usage, now: now, displayingUnreportedFiveHour: true) {
        case .failure(let unusable): return ["\(label): usage unavailable (\(unusable.text))"]
        case .success(let value): quota = value
        }
        return (quota.fiveHourReported ? [] : ["\(label) 5-hour: not reported (usage unknown; failover waits)"]) + quota.windows.keys.sorted().map { name in
            let window = quota.windows[name]!
            let title = name == "five_hour" ? "5-hour" : name.replacingOccurrences(of: "seven_day", with: "weekly")
            return "\(label) \(title): \(Int(window.used))%; resets \(window.reset.formatted(date: .abbreviated, time: .shortened))"
        }
    }
    static func date(_ raw: String) -> Date? {
        guard raw.utf8.count <= 80 else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    private func run(now: Date) async throws {
        let directory = RelayAgentAccountDirectory.shared
        let snapshot = workspaces.compactMap(\.value).flatMap { workspace in workspace.panes.values.map { (workspace, $0) } }
        var seen = Set<String>()
        for (_, pane) in snapshot where pane.contentKind == .terminal && pane.kind == .claude && pane.profile.backend == .relay {
            let host = RelayAgentAccountDirectory.hostKey(pane.profile)
            hostKeys.insert(host)
            guard seen.insert(host).inserted else { continue }
            let settings = RelayPreferences.shared.claudeQuotaFailover
            guard settings.enabled, settings.valid, settings.hosts[host] != false, !paused else { continue }
            // Account registry and quota are re-read after awaits. Neither a
            // cached pane label nor a source/target guess is move authority:
            // only the host's own registry names accounts, never the defaults.
            guard let registry = directory.registeredAccounts(for: pane.profile, provider: "claude") else {
                deferrals[host] = "waiting for this host's account list"
                try audit(pane.id, "deferred_registry_loading"); continue
            }
            guard let sourceAccount = registry.first(where: { $0.label == settings.source }),
                  let targetAccount = registry.first(where: { $0.label == settings.target }),
                  sourceAccount.dir != targetAccount.dir else {
                deferrals[host] = "this host has no distinct Claude accounts named \(settings.source) and \(settings.target)"
                try audit(pane.id, "deferred_account_mapping"); continue
            }
            let observedNow = Date()
            usageLines[host] = Self.usageText(directory.usage(for: pane.profile, account: sourceAccount),
                label: settings.source, now: observedNow) + Self.usageText(directory.usage(for: pane.profile, account: targetAccount),
                label: settings.target, now: observedNow)
            let sourceNow: RelayClaudeQuotaEngine.Quota
            switch Self.reading(directory.usage(for: pane.profile, account: sourceAccount), now: observedNow) {
            case .failure(let unusable):
                deferrals[host] = settings.source + ": " + unusable.text
                try audit(pane.id, "deferred_quota_" + unusable.code); continue
            case .success(let value): sourceNow = value
            }
            deferrals[host] = nil
            if sourceNow.below(settings) {
                // Below the threshold, inspect only when a recorded return
                // can actually be due. Ordinary polling needs no pane RPCs.
                guard engine.disk.records.contains(where: { $0.host == host && $0.state == .away &&
                    sourceNow.canReturn($0, now: observedNow) }) else { continue }
            } else if case .failure(let unusable) = Self.reading(directory.usage(for: pane.profile, account: targetAccount),
                                                                 now: observedNow, targetCeiling: settings.targetCeiling) {
                deferrals[host] = settings.target + ": " + unusable.text
                try audit(pane.id, "deferred_target_" + unusable.code); continue
            }
            for (workspace, candidate) in snapshot where candidate.kind == .claude &&
                RelayAgentAccountDirectory.hostKey(candidate.profile) == host {
                guard workspace.panes[candidate.id] === candidate, candidate.connectionState == .connected else { continue }
                if await RelayCapacityManagementCoordinator.shared.shouldUseCombined(candidate) {
                    // The existing QF2 ownership/reset journal stays intact.
                    // A combined intent never bypasses it via the legacy mover.
                    try audit(candidate.id, "deferred_combined_native_lane")
                    notices[candidate.id] = "Combined context/quota policy owns this pane; native preservation capabilities remain held. Existing quota-away reset/ownership records are retained."
                    continue
                }
                // The first read is strictly observational; it never closes an
                // overlay or captures/clears a typed draft for an automatic move.
                let proof: RelayAgentMaintenanceProbe
                do { proof = try await RelayAgentMaintenanceReader.inspect(candidate) }
                catch { try audit(candidate.id, "deferred_native_identity"); continue }
                guard proof.valid(for: candidate.id), proof.provider == "claude", let dir = proof.configDir,
                      let label = directory.label(for: candidate.profile, provider: "claude", observedDirectory: dir),
                      let session = proof.sessionID else { try audit(candidate.id, "deferred_native_identity"); continue }
                let mover = RelayAgentAccountMove.shared
                if RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: true, hasDraft: false),
                   !(await Self.ensureReadable(candidate, in: workspace, mover: mover)) {
                    try audit(candidate.id, "deferred_screen_unavailable"); continue
                }
                let prompt = await mover.readPrompt(candidate, proof)
                let held = RelayAgentMaintenancePolicy.deferral(proof, paneID: candidate.id,
                    emptyPrompt: prompt.empty, hasDraft: prompt.typed || prompt.delivering,
                    pendingApprovals: candidate.pendingAgentApprovals, inputAge: Date().timeIntervalSince(candidate.agentLastInputAt),
                    recordedAccount: candidate.agentAccount?.recorded)
                let evidence = RelayClaudeQuotaEngine.Pane(id: candidate.id, host: host, label: label, session: session,
                    process: Self.process(proof), idle: held == nil && prompt.empty)
                let current = Date()
                let source = Self.quota(directory.usage(for: candidate.profile, account: sourceAccount), now: current)
                let target = Self.quota(directory.usage(for: candidate.profile, account: targetAccount), now: current, targetCeiling: settings.targetCeiling)
                guard RelayPreferences.shared.claudeQuotaFailover == settings else { return }
                guard let move = try engine.next(settings: settings, host: host, source: source, target: target,
                    panes: [evidence], paused: paused, now: current, sourceDir: sourceAccount.dir, targetDir: targetAccount.dir,
                    save: journal.save, audit: audit) else { continue }
                let destination = move.returning ? sourceAccount : targetAccount
                // A single awaited move holds the app-wide lane until the
                // existing native machinery completes or refuses it.
                let outcome = await mover.move(candidate, in: workspace, to: destination, origin: .quotaFailover, inputGranted: false)
                var after: RelayAgentMaintenanceProbe?
                if outcome.state == "verified" { after = try? await RelayAgentMaintenanceReader.inspect(candidate, expectAccount: destination) }
                let success = outcome.state == "verified" && after?.valid(for: candidate.id) == true &&
                    after?.accountMatches == true && after?.sessionID == evidence.session
                try engine.finish(move, success: success, process: after.map(Self.process) ?? evidence.process,
                    detail: outcome.message, deferred: outcome.state == "deferred", save: journal.save, audit: audit)
                if !success && outcome.state != "deferred" {
                    notices[candidate.id] = "Quota failover refused: " + outcome.message + ". This pane will not be retried in this window."
                    AgentIntelligenceStore.shared.record(.init(paneID: candidate.id, host: host, provider: .claude,
                        kind: .failure, title: "Claude quota failover refused", detail: outcome.message,
                        sourceID: "quota-failover:" + move.operation.uuidString, alert: .needsInput))
                }
                // Any subsequent pane is re-inspected, with quotas and pause
                // checked again. There is never a task per pane.
            }
        }
    }
    /// Observation only. An unopened pane must first produce a complete
    /// native screen; no prompt input is sent and a user's new selection wins.
    static func ensureReadable(_ pane: PaneModel, in workspace: WorkspaceModel, mover: RelayAgentAccountMove) async -> Bool {
        guard mover.screenRefusal(pane) != nil else { return true }
        let previous = workspace.activePaneID
        let tab = workspace.selectedTabID
        let profile = pane.profile
        defer {
            if workspace.activePaneID == pane.id, previous != pane.id {
                if let previous, workspace.panes[previous] != nil { workspace.revealPane(previous) }
                else if let tab, workspace.tabs.contains(where: { $0.id == tab }) { workspace.selectTab(tab) }
            }
        }
        mover.presentPane(pane, workspace)
        let deadline = Date().addingTimeInterval(mover.screenTimeout)
        while mover.screenRefusal(pane) != nil {
            guard workspace.panes[pane.id] === pane, pane.profile == profile, pane.connectionState == .connected,
                  Date() < deadline else { return false }
            try? await Task.sleep(for: .seconds(mover.screenInterval))
        }
        return workspace.panes[pane.id] === pane && pane.profile == profile && pane.connectionState == .connected
    }
    static func process(_ proof: RelayAgentMaintenanceProbe) -> String {
        "\(proof.owner?.nodeBootId ?? "unknown"):\(proof.processID ?? 0):\(proof.processStart ?? 0)"
    }
}
