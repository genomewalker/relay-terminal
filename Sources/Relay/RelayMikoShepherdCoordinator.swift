import Combine
import Foundation

/// The existing maintenance heartbeat supplies workspace membership. Reading
/// the renderer never attaches, focuses, resizes, types, or starts a host job.
@MainActor final class RelayMikoShepherdCoordinator: ObservableObject {
    static let shared = RelayMikoShepherdCoordinator()
    @Published private(set) var reports: [RelayShepherdReport] = []
    private var engine = RelayShepherdEngine()
    private let testingHeartbeat: Bool
    private let readSettings: @MainActor () -> RelayShepherdSettings
    private let readPause: @MainActor () -> Bool
    private let push: RelayShepherdPushController?
    var observationReads: Int { engine.reads }

    init(testingHeartbeat: Bool = false,
         settings: (@MainActor () -> RelayShepherdSettings)? = nil,
         paused: (@MainActor () -> Bool)? = nil,
         push: RelayShepherdPushController? = nil) {
        self.testingHeartbeat = testingHeartbeat
        readSettings = settings ?? { Self.settings }
        readPause = paused ?? { Self.paused }
        self.push = push ?? (RelayLaunchMode.isRunningTests ? nil : .shared)
    }
    private var nextPoll: [ObjectIdentifier: Date] = [:]
    private struct Job {
        let id: String
        let owner: UUID
        let profile: ConnectionProfile
        let workspace: ObjectIdentifier
        var status = "submitted; outcome pending"
        var finished = false
        var stdoutOffset = 0
        var stderrOffset = 0
        var completionKind: String?
        var completionReported = false
    }
    private var jobs: [String: Job] = [:]
    private var polling: Set<String> = []
    private var modelBudget = RelayShepherdModelBudget()
    private var lastCapNotice = Date.distantPast

    static var settings: RelayShepherdSettings { RelayPreferences.shared.shepherd.bounded }
    static var paused: Bool {
        RelayMikoSupervision.shared.isDisabled("*") || !RelayCallerControl.shared.permitted(RelayCallerControl.assistantCaller)
    }
    // One shared rolling-hour cap for interactive Miko steps in shepherd mode.
    // UTF-8 bytes plus 32K for the fixed host prompt/tool schemas is a
    // conservative upper bound on input tokens, not an invoice estimate.
    func reserveModelInput(bytes: Int) -> Bool {
        let settings = Self.settings
        guard settings.enabled else { return true }
        let admitted = modelBudget.admit(tokens: bytes + 32_768, settings: settings, paused: Self.paused,
                                        now: Date().timeIntervalSince1970)
        if !admitted, !Self.paused, Date().timeIntervalSince(lastCapNotice) >= 3600 {
            lastCapNotice = Date()
            reports.append(.init(paneID: UUID(uuidString: RelayAssistantMessaging.inboxID)!, host: "Relay",
                kind: "model_cap", digest: "cap:\(lastCapNotice.timeIntervalSince1970)",
                text: "Miko's hourly model cap reached. Shepherd template reports continue without model calls."))
            trim()
        }
        return admitted
    }
    private func trim() { if reports.count > 200 { reports.removeFirst(reports.count - 200) } }
    var state: [[String: String]] {
        reports.suffix(20).map { ["pane_id": $0.paneID.uuidString.lowercased(), "host": $0.host, "kind": $0.kind,
                       "digest": $0.digest, "text": $0.text] }
    }

    // Called only for workspace-scoped exec: the captured workspace/host and
    // exact single agent owner remain fixed for the lifetime of this job.
    // Ambiguous host-only execs are never guessed from the focused pane.
    func track(id: String, owner: UUID, profile: ConnectionProfile, workspace: WorkspaceModel) {
        guard !RelayLaunchMode.isRunningTests, id.utf8.count <= 128, !id.isEmpty else { return }
        let key = profile.connectionKey + "|" + id
        guard jobs[key] == nil, jobs.count < 512 else { return }
        jobs[key] = Job(id: id, owner: owner, profile: profile, workspace: ObjectIdentifier(workspace))
    }

    func heartbeat(_ workspace: WorkspaceModel, now: Date = Date()) {
        guard !RelayLaunchMode.isRunningTests || testingHeartbeat else { return }
        push?.remember(workspace)
        let settings = readSettings()
        guard settings.enabled, !readPause() else { return }
        let key = ObjectIdentifier(workspace)
        guard now >= (nextPoll[key] ?? .distantPast) else { return }
        nextPoll[key] = now.addingTimeInterval(Double(settings.interval))
        for pane in workspace.panes.values {
            let host = pane.profile.kind == .local ? "This Mac" : pane.profile.host
            // Opt-out precedes viewport, activity and exec reads.
            guard settings.watches(pane.id, host: host), pane.contentKind == .terminal,
                  pane.kind == .claude || pane.kind == .codex else { continue }
            let updates = engine.poll(id: pane.id, host: host, settings: settings, paused: readPause(),
                                      now: now.timeIntervalSince1970) {
                let state: RelayShepherdSnapshot.State
                if pane.phase == .needsInput || pane.pendingAgentApprovals > 0 { state = .waitingForUser }
                else if let code = pane.remoteExitCode { state = code == 0 ? .ended : .failed }
                else if pane.phase == .exited { state = .ended }
                else if pane.phase == .active { state = .busy }
                else if pane.lastCompletedAgentTurn != nil { state = .finishedOK }
                else { state = .idle }
                let jobStates = Dictionary(jobs.values.filter {
                    $0.owner == pane.id && $0.profile == pane.profile && $0.workspace == key
                }.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
                return .init(paneID: pane.id, host: host, state: state,
                    output: "Connection: \(pane.connectionState)\n" + RelayAssistantRedaction.redact(pane.runtime.sidePanelViewportText() ?? pane.activitySummary),
                    promptID: state == .waitingForUser ? (pane.waitIdentity ?? "waiting") : "", jobs: jobStates)
            }
            let completedKeys = jobs.keys.filter { key in
                jobs[key]?.owner == pane.id && jobs[key]?.finished == true && jobs[key]?.completionReported == false
            }
            for rawReport in updates {
                let completions = completedKeys.compactMap { jobs[$0]?.completionKind }
                let kind = completions.contains("jobFailed") ? "jobFailed" : completions.contains("jobNeedsReview") ? "jobNeedsReview" : completions.contains("jobFinished") ? "jobFinished" : rawReport.kind
                let report = RelayShepherdReport(paneID: rawReport.paneID, host: rawReport.host, kind: kind, digest: rawReport.digest, text: rawReport.text, occurrenceID: rawReport.occurrenceID)
                for key in completedKeys { jobs[key]?.completionReported = true }
                reports.append(report)
                push?.observe(report, now: now)
                let alert: RelayAttentionAlert? = ["waitingForUser", "stall", "jobNeedsReview"].contains(report.kind) ? .needsInput
                    : ["failed", "jobFailed"].contains(report.kind) ? .error : ["finishedOK", "ended", "jobFinished"].contains(report.kind) ? .done : nil
                AgentIntelligenceStore.shared.record(.init(paneID: pane.id, host: host, provider: pane.kind,
                    kind: ["failed", "jobFailed"].contains(report.kind) ? .failure : ["waitingForUser", "stall", "jobNeedsReview"].contains(report.kind) ? .attention : alert == .done ? .completion : .session,
                    title: "Miko · \(report.kind)", detail: report.text, occurredAt: now,
                    sourceID: "shepherd:" + report.occurrenceID, isProgramReported: true, alert: alert))
            }
        }
        trim()
        for (jobKey, job) in jobs where !job.finished && job.workspace == key && !polling.contains(jobKey) {
            let host = job.profile.kind == .local ? "This Mac" : job.profile.host
            guard settings.watches(job.owner, host: host), let pane = workspace.panes[job.owner],
                  pane.profile == job.profile else { continue }
            polling.insert(jobKey)
            Task { [weak self, weak workspace] in
                defer { self?.polling.remove(jobKey) }
                guard let self, let workspace, !Self.paused, Self.settings.watches(job.owner, host: host),
                      RelayShepherdToolPolicy.allows("relay_exec_status", enabled: true, origin: .shepherd),
                      !RelayMikoSupervision.shared.isDisabled("relay_exec_status"),
                      workspace.panes[job.owner]?.profile == job.profile else { return }
                let request: [String: Any] = ["operation": "status", "job_id": job.id,
                    "stdout_offset": job.stdoutOffset, "stderr_offset": job.stderrOffset,
                    "request_id": "rpc-" + UUID().uuidString.lowercased()]
                // Status is a read. Never exec, poll by replay, cancel or signal.
                guard let payload = try? JSONSerialization.data(withJSONObject: request),
                      let raw = try? await RelayNodeTransportPool.shared.request(profile: job.profile, payload: payload),
                      let status = try? RelayShepherdExecSnapshot.decode(raw), status.id == job.id,
                      !Self.paused, Self.settings.watches(job.owner, host: host),
                      workspace.panes[job.owner]?.profile == job.profile else { return }
                self.jobs[jobKey]?.stdoutOffset = status.stdoutOffset
                self.jobs[jobKey]?.stderrOffset = status.stderrOffset
                self.jobs[jobKey]?.status = status.summary
                self.jobs[jobKey]?.finished = status.finished
                self.jobs[jobKey]?.completionKind = status.completionKind
            }
        }
    }
}
