import Foundation
import SwiftUI

/// One tool-using Haiku supervisor per captured execution host. Model steps and
/// native actions have separate durable identities; an unknown action is never
/// replayed. Native tools retain their own session/input/lifecycle fences.
@MainActor final class RelayPaneHealthCoordinator: ObservableObject {
    static let shared = RelayPaneHealthCoordinator()
    private final class Reference {
        weak var pane: PaneModel?
        weak var workspace: WorkspaceModel?
        var seenAt: Date
        init(_ pane: PaneModel, _ workspace: WorkspaceModel, _ now: Date) {
            self.pane = pane; self.workspace = workspace; seenAt = now
        }
    }
    private struct Observation: Equatable {
        let proof: RelayAgentMaintenanceProbe
        let at: Date
    }
    struct ToolReceipt: Codable, Equatable, Sendable {
        let id: String
        let operationID: String
        let host: String
        let paneID: String?
        let name: String
        let inputDigest: String
        let before: RelayPaneHealthFacts?
        let createdAt: Date
        var state: String
        var result: RelayPaneHealthJSON?
    }
    private struct Pending: Codable, Equatable {
        let operationID: String
        let snapshotID: String
        let panes: [RelayPaneHealthFacts]
        let messages: [RelayPaneHealthJSON]
        let step: Int
    }
    private struct Host: Codable, Equatable {
        var name: String
        var state = "Waiting for native pane observations"
        var lastAttemptAt: Date?
        var lastModelAt: Date?
        var lastSnapshotID: String?
        var lastFinishedAt: Date?
        var deferredUntil: Date?
        var pending: Pending?
        var report: RelayPaneHealthJSON?
        var modelOperations: [String] = []
        var observedPaneCount = 0
        var checkedBatches: [String: BatchCheck] = [:]
        var daemonCheckOperationID: String?
        var daemonCheckRequestedAt: Date?
        var daemonCheckSubmitted: Bool?
        var controllerCheck: RelayPaneHealthControllerCheck? {
            daemonCheckOperationID.map { RelayPaneHealthControllerCheck(operationID: $0,
                requestedAt: daemonCheckRequestedAt, submitted: daemonCheckSubmitted) }
        }
    }
    private struct BatchCheck: Codable, Equatable {
        let signal: String
        let at: Date
    }
    private struct Journal: Codable, Equatable {
        var hosts: [String: Host] = [:]
        var tools: [String: ToolReceipt] = [:]
        var controllerActionResults: [String: RelayPaneHealthControllerActionReceipt]?
    }
    struct HostSnapshot: Codable, Sendable {
        let host: String
        let name: String
        let state: String
        let panes: Int
        let lastObservedAt: Date?
        let lastHeartbeatAt: Date?
        let freshObservations: Int
        let endedPanes: Int
        let livePanes: [PaneSnapshot]
        let lastModelAt: Date?
        let pendingOperationID: String?
        let modelStepReceipts: Int
        let report: RelayPaneHealthJSON?
        let controller: String
        let controllerProcessID: Int?
        let controllerProcessStart: UInt64?
    }
    struct PaneSnapshot: Codable, Sendable {
        let paneID: String
        let name: String
        let observationState: String
        let observedAt: Date?
        let facts: RelayPaneHealthFacts
        let worker: RelayPaneWorkerObservation?
        let context: RelayPaneContextObservation?
        let unavailable: String?
    }
    struct Snapshot: Codable, Sendable {
        let enabled: Bool
        let model: String
        let effort: String
        let thinking: String
        let hosts: [HostSnapshot]
        let recentTools: [ToolReceipt]
        let journalNeedsAttention: Bool
    }

    @Published private(set) var revision: UInt64 = 0
    /// Everything `snapshot()` and `hostOverviews()` expose from this
    /// coordinator (pane titles and connection state come from the panes).
    /// A sync bumps `revision` only when this changed.
    private struct PublishedState: Equatable {
        struct Controller: Equatable {
            let processID: Int?
            let processStart: UInt64?
            let pendingOperationID: String?
            let lastTickAt: TimeInterval?
            let lastModelAt: TimeInterval?
            let modelOperations: [String]?
            let report: RelayPaneHealthJSON?
        }
        let hosts: [String: Host]
        let tools: [String: ToolReceipt]
        let observations: [UUID: Observation]
        let controllers: [String: Controller]
        let loadFailed: Bool
    }
    /// A routine status sync that changed nothing must not wake observers.
    func bumpingRevisionIfPublishedStateChanges(_ work: () async -> Void) async {
        let before = publishedState
        await work()
        if publishedState != before { revision &+= 1 }
        scheduleFreshnessWake()
    }

    /// snapshot(), hostOverviews() and agentVersions() treat an observation as
    /// fresh for this long. Its expiry changes what they show without any new
    /// event, so one wake at the earliest expiry bumps `revision` and re-arms.
    static let observationLifetime: TimeInterval = 300
    var clock: () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    private var freshnessWake: Task<Void, Never>?
    private(set) var freshnessDeadline: Date?

    func scheduleFreshnessWake() {
        let now = clock()
        guard let deadline = observations.values.map({ $0.at.addingTimeInterval(Self.observationLifetime) })
            .filter({ $0 > now }).min() else {
            freshnessWake?.cancel(); freshnessWake = nil; freshnessDeadline = nil
            return
        }
        if freshnessWake != nil, freshnessDeadline == deadline { return }
        freshnessWake?.cancel()
        freshnessDeadline = deadline
        let sleep = self.sleep
        freshnessWake = Task { @MainActor [weak self] in
            do { try await sleep(deadline.timeIntervalSince(now)) } catch { return }
            guard let self, !Task.isCancelled, self.freshnessDeadline == deadline else { return }
            self.freshnessWake = nil; self.freshnessDeadline = nil
            self.revision &+= 1
            self.scheduleFreshnessWake()
        }
    }
    private var publishedState: PublishedState {
        PublishedState(hosts: journal.hosts, tools: journal.tools, observations: observations,
            controllers: controllers.mapValues { status in
                let state = status.currentState
                return .init(processID: status.supervisorPid, processStart: status.supervisorStartTime,
                    pendingOperationID: state?.pending?.operationId, lastTickAt: state?.lastTickAt,
                    lastModelAt: state?.lastModelAt, modelOperations: state?.modelOperations, report: state?.report)
            }, loadFailed: loadFailed)
    }
    private var references: [UUID: Reference] = [:]
    private var observations: [UUID: Observation] = [:]
    private let controllerTasks = RelayPaneHealthControllerTasks()
    private var controllers: [String: RelayPaneHealthHostControllerStatus] = [:]
    private var controllerProfiles: [String: ConnectionProfile] = [:]
    private var controllerConfigurations: [String: String] = [:]
    private var controllerRegisteredPanes: [String: [String]] = [:]
    private var controllerLastSynced: [String: Date] = [:]
    private var journal = Journal()
    /// The journal as the file holds it (loaded or last written). `save()`
    /// skips only when the in-memory journal equals it and the file exists,
    /// so every changed journal, including each pre-dispatch fence, is written.
    private var persistedJournal: Journal?
    private var loadFailed = false
    private let startedAt = Date()
    private let url: URL
    private var reconnectCompletions: [UUID: (RelayPaneHealthJSON) -> Void] = [:]
    private var reconnectTimeouts: [UUID: Task<Void, Never>] = [:]

    init(url: URL = RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/pane-health/journal.json")) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                    throw RelayHostRotationRPC.Failure.invalidResponse
                }
                let data = try Data(contentsOf: url)
                guard data.count <= 4 << 20 else { throw RelayHostRotationRPC.Failure.invalidResponse }
                journal = try JSONDecoder().decode(Journal.self, from: data)
                persistedJournal = journal
            }
        } catch { loadFailed = true }
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        Snapshot(enabled: !RelayPreferences.shared.shepherd.enabled && RelayPreferences.shared.haikuPaneHealth, model: "claude-haiku-5-5",
            effort: "low", thinking: "disabled",
            hosts: journal.hosts.keys.sorted().compactMap { key in
                guard let host = journal.hosts[key] else { return nil }
                let refs = references.values.filter { $0.pane?.profile.connectionKey == key }
                guard !refs.isEmpty else { return nil }
                let live = refs.compactMap(\.pane).sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
                    let observation = observations[pane.id]
                    let (state, fresh) = observationState(pane, now: now)
                    return PaneSnapshot(paneID: pane.id.uuidString.lowercased(), name: pane.title,
                        observationState: state, observedAt: observation?.at, facts: facts(pane, now: now),
                        worker: fresh ? observation?.proof.worker : nil,
                        context: fresh ? observation?.proof.context : nil,
                        unavailable: fresh ? observation?.proof.unavailable : nil)
                }
                let controller = controllers[key]
                let daemonState = controller?.currentState
                let modelDate = daemonState?.lastModelAt.map(Date.init(timeIntervalSince1970:)) ?? host.lastModelAt
                let modelOperations = Set(host.modelOperations + (daemonState?.modelOperations ?? []))
                return HostSnapshot(host: key, name: host.name, state: host.state,
                    panes: refs.count, lastObservedAt: live.compactMap(\.observedAt).max(),
                    lastHeartbeatAt: daemonState?.lastTickAt.map(Date.init(timeIntervalSince1970:)) ?? refs.map(\.seenAt).max(),
                    freshObservations: live.filter { ["observed", "unavailable"].contains($0.observationState) }.count,
                    endedPanes: live.filter { $0.observationState == "exited" }.count,
                    livePanes: live, lastModelAt: modelDate,
                    pendingOperationID: RelayPaneHealthHostControllerStatus.pendingOperation(controller: controller,
                        check: host.daemonCheckOperationID, legacy: host.pending?.operationID),
                    modelStepReceipts: modelOperations.count, report: daemonState?.report ?? host.report,
                    controller: controller == nil ? "desktop_native_observation" : "relayd",
                    controllerProcessID: controller?.supervisorPid, controllerProcessStart: controller?.supervisorStartTime)
            }, recentTools: Array(journal.tools.values.sorted { $0.createdAt > $1.createdAt }.prefix(32)),
            journalNeedsAttention: loadFailed)
    }

    private func observationState(_ pane: PaneModel, now: Date) -> (state: String, fresh: Bool) {
        let observation = observations[pane.id]
        let fresh = pane.connectionState == .connected && pane.phase != .exited && pane.remoteExitCode == nil &&
            (observation.map { now.timeIntervalSince($0.at) < 300 } ?? false)
        let state = pane.programExited ? "exited" : pane.connectionState != .connected || pane.phase == .exited ? "connection_unavailable" :
            observation == nil ? "not_checked" : !fresh ? "stale" :
            observation?.proof.unavailable != nil ? "unavailable" : "observed"
        return (state, fresh)
    }

    /// The Settings rows: the same host counts as `snapshot()`, without
    /// per-pane facts. Facts read each pane's screen; display needs none.
    struct HostSummary: Equatable, Sendable {
        let host: String
        let name: String
        let state: String
        let panes: Int
        let freshObservations: Int
        let endedPanes: Int
    }

    func hostSummaries(now: Date = Date()) -> [HostSummary] {
        journal.hosts.keys.sorted().compactMap { key in
            guard let host = journal.hosts[key] else { return nil }
            let refs = references.values.filter { $0.pane?.profile.connectionKey == key }
            guard !refs.isEmpty else { return nil }
            let states = refs.compactMap(\.pane).map { observationState($0, now: now).state }
            return HostSummary(host: key, name: host.name, state: host.state, panes: refs.count,
                freshObservations: states.filter { ["observed", "unavailable"].contains($0) }.count,
                endedPanes: states.filter { $0 == "exited" }.count)
        }
    }

    /// The Performance panel's Agents rows: `snapshot()` hosts and panes
    /// without facts, plus whether a host check runs. Facts read each pane's
    /// screen; display needs none.
    struct PaneOverview: Equatable, Sendable {
        let paneID: String
        let name: String
        let observationState: String
        let worker: RelayPaneWorkerObservation?
        let context: RelayPaneContextObservation?
    }
    struct HostOverview: Equatable, Sendable {
        let summary: HostSummary
        let controller: String
        let checkRunning: Bool
        let livePanes: [PaneOverview]
    }

    func hostOverviews(now: Date = Date()) -> [HostOverview] {
        hostSummaries(now: now).map { summary in
            let panes = references.values.compactMap(\.pane).filter { $0.profile.connectionKey == summary.host }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
                    let (state, fresh) = observationState(pane, now: now)
                    let proof = fresh ? observations[pane.id]?.proof : nil
                    return PaneOverview(paneID: pane.id.uuidString.lowercased(), name: pane.title,
                        observationState: state, worker: proof?.worker, context: proof?.context)
                }
            return HostOverview(summary: summary, controller: controllers[summary.host] == nil ? "desktop_native_observation" : "relayd",
                checkRunning: checkIsRunning(host: summary.host), livePanes: panes)
        }
    }

    func observe(_ pane: PaneModel, proof: RelayAgentMaintenanceProbe, now: Date = Date()) {
        observations[pane.id] = Observation(proof: proof, at: now)
        revision &+= 1
        scheduleFreshnessWake()
    }

    /// Last native versions per pane; read-only evidence, never an action input.
    func agentVersions(now: Date = Date()) -> [String: RelayAgentMaintenance.AgentVersion] {
        Dictionary(uniqueKeysWithValues: observations.compactMap { id, observation in
            guard now.timeIntervalSince(observation.at) < 300 else { return nil }
            return RelayAgentMaintenance.AgentVersion(observation.proof, paneID: id).map { (id.uuidString.lowercased(), $0) }
        })
    }

    func monitoredContexts() -> [UUID: (PaneModel, WorkspaceModel)] {
        Dictionary(uniqueKeysWithValues: references.keys.compactMap { id in
            context(for: id).map { (id, $0) }
        })
    }

    func context(for id: UUID) -> (PaneModel, WorkspaceModel)? {
        guard let reference = references[id], let pane = reference.pane, let workspace = reference.workspace,
              workspace.panes[id] === pane else { return nil }
        return (pane, workspace)
    }

    func facts(_ pane: PaneModel, now: Date = Date(), forScheduling: Bool = false) -> RelayPaneHealthFacts {
        let observation = observations[pane.id]
        let proof = observation.flatMap {
            pane.connectionState == .connected && pane.phase != .exited && pane.remoteExitCode == nil &&
                (forScheduling || now.timeIntervalSince($0.at) < 300) ? $0.proof : nil
        }
        return RelayPaneHealthFacts.read(pane, proof: proof)
    }

    private func schedulingSignal(_ panes: [RelayPaneHealthFacts], host: String) -> String {
        // Expiring read evidence still requires a fresh inspection before any
        // action. It is not itself a new fault that should spend an API call.
        let current = panes.map { original -> RelayPaneHealthFacts in
            guard let id = UUID(uuidString: original.paneID), let pane = references[id]?.pane,
                  pane.profile.connectionKey == host else { return original }
            return facts(pane, forScheduling: true)
        }
        return Self.healthSignal(current)
    }

    func heartbeat(_ workspace: WorkspaceModel, now: Date = Date()) {
        for pane in workspace.panes.values where pane.contentKind == .terminal && pane.profile.backend == .relay {
            if let ref = references[pane.id] { ref.pane = pane; ref.workspace = workspace; ref.seenAt = now }
            else { references[pane.id] = Reference(pane, workspace, now) }
            let key = pane.profile.connectionKey
            if journal.hosts[key] == nil {
                journal.hosts[key] = Host(name: pane.profile.kind == .local ? "This Mac" : pane.profile.host)
            }
            if pane.connectionState == .connected, let completion = reconnectCompletions.removeValue(forKey: pane.id) {
                reconnectTimeouts.removeValue(forKey: pane.id)?.cancel()
                completion(.object(["state": .string("verified"),
                    "message": .string("The viewer reconnected to its retained worker."), "pane": facts(pane).value]))
            }
        }
        references = references.filter { _, ref in
            guard let pane = ref.pane, let workspace = ref.workspace else { return false }
            return workspace.panes[pane.id] === pane && now.timeIntervalSince(ref.seenAt) < 30
        }
        guard !RelayLaunchMode.isRunningTests, !loadFailed,
              now.timeIntervalSince(startedAt) >= 20 else { return }
        var profiles = controllerProfiles
        for (key, profile) in Dictionary(references.values.compactMap { ref -> (String, ConnectionProfile)? in
            guard let pane = ref.pane else { return nil }; return (pane.profile.connectionKey, pane.profile)
        }, uniquingKeysWith: { first, _ in first }) { profiles[key] = profile }
        controllerProfiles = profiles
        for (key, profile) in profiles {
            guard let desired = desiredController(profile: profile) else { continue }
            controllerTasks.cancelIfStale(host: key, scope: desired.digest)
            guard controllerTasks[key] == nil else { continue }
            let interval: TimeInterval = controllerConfigurations[key] != desired.digest ? 5 : 15
            guard now.timeIntervalSince(controllerLastSynced[key] ?? .distantPast) >= interval else { continue }
            controllerLastSynced[key] = now
            _ = startControllerSync(profile: profile)
        }
    }

    func checkIsRunning(host: String) -> Bool {
        controllerTasks[host] != nil || journal.hosts[host]?.daemonCheckOperationID != nil ||
            controllers[host]?.currentState?.pending != nil
    }

    func checkNow(host: String) async {
        guard let profile = references.values.compactMap(\.pane).first(where: { $0.profile.connectionKey == host })?.profile ??
                controllerProfiles[host] else { return }
        await requestControllerCheck(profile: profile)
    }

    func accountConfigurationChanged(profile: ConnectionProfile) {
        let key = profile.connectionKey
        guard var host = journal.hosts[key] else { return }
        host.deferredUntil = nil; host.lastAttemptAt = nil
        host.state = "Account settings changed; waiting for a fresh check"
        journal.hosts[key] = host; revision &+= 1
        try? save()
        Task { @MainActor [weak self] in await self?.requestControllerCheck(profile: profile) }
    }

    func checkNow(_ workspace: WorkspaceModel, profile: ConnectionProfile) async {
        heartbeat(workspace)
        await requestControllerCheck(profile: profile)
    }

    private func desiredController(profile: ConnectionProfile) -> RelayPaneHealthControllerScope? {
        guard let installation = Bundle.main.object(forInfoDictionaryKey: "RelayInstallationID") as? String,
              let owner = UUID(uuidString: installation)?.uuidString.lowercased() else { return nil }
        let all = references.values.compactMap(\.pane).filter { $0.profile.connectionKey == profile.connectionKey }
        let live = all.filter { $0.phase != .exited && $0.remoteExitCode == nil }
        let panes = (live.isEmpty ? (controllerRegisteredPanes[profile.connectionKey] ?? all.map { $0.id.uuidString.lowercased() }) :
                     live.map { $0.id.uuidString.lowercased() }).sorted()
        guard !panes.isEmpty, panes.count <= 128 else { return nil }
        let enabled = !live.isEmpty && RelayPreferences.shared.shepherd.permitsLegacyMonitoring(maintenance: RelayPreferences.shared.automaticAgentMaintenance, haiku: RelayPreferences.shared.haikuPaneHealth)
        let haiku = enabled && RelayPreferences.shared.haikuPaneHealth
        let host = Self.rpcHostID(profile.connectionKey)
        return RelayPaneHealthControllerScope(host: host, owner: owner, panes: panes, enabled: enabled, haiku: haiku)
    }

    private func requestControllerCheck(profile: ConnectionProfile) async {
        let key = profile.connectionKey
        guard !RelayPreferences.shared.shepherd.enabled, RelayPreferences.shared.haikuPaneHealth, !loadFailed,
              var host = journal.hosts[key] else { return }
        if host.daemonCheckOperationID == nil {
            host.daemonCheckOperationID = RelayHostRotationRPC.newOperationID()
            host.daemonCheckRequestedAt = Date()
            host.daemonCheckSubmitted = false
            journal.hosts[key] = host
            do { try save() } catch { return }
        }
        // Queue the explicit request even if a normal sync is in flight. Its
        // original ID is saved first and is never replaced after uncertainty.
        if let desired = desiredController(profile: profile) {
            controllerTasks.cancelIfStale(host: key, scope: desired.digest)
        }
        if let existing = controllerTasks[key] { await existing.value }
        guard !Task.isCancelled, !loadFailed else { return }
        if let task = startControllerSync(profile: profile) { await task.value }
    }

    @discardableResult private func startControllerSync(profile: ConnectionProfile) -> Task<Void, Never>? {
        let key = profile.connectionKey
        guard let desired = desiredController(profile: profile) else { return nil }
        return controllerTasks.start(host: key, scope: desired.digest) { @MainActor [weak self] in
            guard let self else { return }
            await self.bumpingRevisionIfPublishedStateChanges { await self.syncController(profile: profile) }
        }
    }

    private func syncController(profile: ConnectionProfile) async {
        let key = profile.connectionKey
        guard !Task.isCancelled, let desired = desiredController(profile: profile) else { return }
        let placements = references.values.compactMap { reference -> (PaneModel, WorkspaceModel, ConnectionProfile)? in
            guard let pane = reference.pane, let workspace = reference.workspace,
                  pane.profile.connectionKey == key, desired.panes.contains(pane.id.uuidString.lowercased()) else { return nil }
            return (pane, workspace, pane.profile)
        }
        func accepts(_ reply: RelayPaneHealthHostControllerStatus,
            admitted: RelayPaneHealthHostControllerStatus? = nil) -> Bool {
            !loadFailed && desired.accepts(reply, currentDigest: desiredController(profile: profile)?.digest,
                cancelled: Task.isCancelled, admitted: admitted, placementsCurrent: placements.allSatisfy { pane, workspace, captured in
                    workspace.panes[pane.id] === pane && references[pane.id]?.pane === pane &&
                    references[pane.id]?.workspace === workspace && pane.profile == captured
                })
        }
        do {
            var result: RelayPaneHealthHostControllerStatus
            if controllerConfigurations[key] != desired.digest {
                result = try await RelayPaneHealthHostControllerRPC.send(profile: profile, action: "configure",
                    operationID: String(desired.digest.prefix(32)), host: desired.host, owner: desired.owner,
                    enabled: desired.enabled, haikuEnabled: desired.haiku, panes: desired.panes)
            } else {
                result = try await RelayPaneHealthHostControllerRPC.send(profile: profile, action: "status",
                    operationID: RelayHostRotationRPC.newOperationID())
            }
            guard accepts(result) else {
                throw RelayHostRotationRPC.Failure.refused(result.code ?? "The exact host controller configuration could not be verified")
            }
            let admitted = result
            controllerConfigurations[key] = desired.digest
            controllerRegisteredPanes[key] = desired.panes
            if var host = journal.hosts[key], let check = host.controllerCheck,
               check.disposition(recorded: result.configuration?.checks ?? []) == .queued {
                // Durable before dispatch. Old journal entries without this
                // field are uncertain and may only query their original receipt.
                host.daemonCheckSubmitted = true; journal.hosts[key] = host
                try save()
                result = try await RelayPaneHealthHostControllerRPC.send(profile: profile, action: "check", operationID: check.operationID)
                guard accepts(result, admitted: admitted) else {
                    throw RelayHostRotationRPC.Failure.invalidResponse
                }
            }
            controllers[key] = result
            controllerProfiles[key] = profile
            if var host = journal.hosts[key] {
                host.state = result.currentState?.status ?? "The host daemon owns monitoring; waiting for its first native check"
                if let at = result.currentState?.lastModelAt { host.lastModelAt = Date(timeIntervalSince1970: at) }
                host.report = result.currentState?.report
                for operation in result.currentState?.modelOperations ?? [] where !host.modelOperations.contains(operation) {
                    host.modelOperations.append(operation)
                }
                host.modelOperations = Array(host.modelOperations.suffix(128))
                if let check = host.controllerCheck {
                    if check.disposition(recorded: result.configuration?.checks ?? []) == .recorded {
                        host.daemonCheckOperationID = nil; host.daemonCheckRequestedAt = nil
                        host.daemonCheckSubmitted = nil
                    } else if check.disposition(recorded: result.configuration?.checks ?? []) == .unknown {
                        // The bounded read/check RPC has ended. An absent native
                        // receipt is a failed check request, never an API ACK.
                        host.daemonCheckOperationID = nil; host.daemonCheckRequestedAt = nil
                        host.daemonCheckSubmitted = nil
                        host.state = "The explicit check was not recorded; native host monitoring continues"
                    }
                }
                journal.hosts[key] = host
            }
            if let state = result.currentState {
                for (id, observation) in state.observations ?? [:] {
                    guard desired.panes.contains(id), observation.paneId == id, let paneID = UUID(uuidString: id),
                          let pane = references[paneID]?.pane, pane.profile.connectionKey == key,
                          observation.valid(paneID: paneID) else { continue }
                    let at = Date(timeIntervalSince1970: observation.observedAt)
                    guard observations[paneID].map({ $0.at < at }) ?? true else { continue }
                    observations[paneID] = Observation(proof: observation.proof, at: at)
                }
            }
            if desired.enabled, let generation = result.configuration?.generation {
                let inputFacts = references.values.compactMap(\.pane).filter {
                    $0.profile.connectionKey == key && desired.panes.contains($0.id.uuidString.lowercased())
                }.sorted { $0.id.uuidString < $1.id.uuidString }.map { facts($0) }
                for start in stride(from: 0, to: inputFacts.count, by: 64) {
                    result = try await RelayPaneHealthHostControllerRPC.send(profile: profile, action: "desktop_facts",
                        operationID: RelayHostRotationRPC.newOperationID(), owner: desired.owner, generation: generation,
                        facts: Array(inputFacts[start..<min(start + 64, inputFacts.count)]))
                    guard accepts(result, admitted: admitted) else {
                        throw RelayHostRotationRPC.Failure.invalidResponse
                    }
                }
                controllers[key] = result
            }
            if let state = result.currentState, let generation = result.configuration?.generation,
               let saved = journal.controllerActionResults {
                let requests = Array((state.actionRequests ?? [:]).values)
                journal.controllerActionResults = saved.filter { _, receipt in
                    receipt.host != key || receipt.owner != desired.owner ||
                    !receipt.canForget(currentGeneration: generation, requests: requests)
                }
            }
            for request in (result.currentState?.actionRequests ?? [:]).values.sorted(by: { $0.id < $1.id })
                where request.state == "pending_native" && request.generation == result.configuration?.generation {
                guard accepts(result, admitted: admitted) else { throw RelayHostRotationRPC.Failure.changedConnection }
                let receiptKey = key + ":" + String(request.generation) + ":" + request.id
                let value: RelayPaneHealthJSON
                if let saved = journal.controllerActionResults?[receiptKey] {
                    guard saved.matches(request, host: key, owner: desired.owner) else {
                        throw RelayHostRotationRPC.Failure.invalidResponse
                    }
                    value = saved.result
                } else {
                    guard (journal.controllerActionResults?.count ?? 0) < 1024 else {
                        throw RelayHostRotationRPC.Failure.invalidResponse
                    }
                    value = await executeControllerAction(request, profile: profile, knownPaneIDs: Set(desired.panes),
                        scopeIsCurrent: { accepts(result, admitted: admitted) })
                    guard accepts(result, admitted: admitted) else { throw RelayHostRotationRPC.Failure.changedConnection }
                    var results = journal.controllerActionResults ?? [:]
                    // Do not evict an uncertain acknowledgement to admit new
                    // work. Bounded journal exhaustion requires reconciliation.
                    guard results.count < 1024 else { throw RelayHostRotationRPC.Failure.invalidResponse }
                    results[receiptKey] = RelayPaneHealthControllerActionReceipt(request: request, host: key,
                        owner: desired.owner, result: value)
                    journal.controllerActionResults = results
                    try save()
                }
                guard accepts(result, admitted: admitted) else { throw RelayHostRotationRPC.Failure.changedConnection }
                let acknowledgement = String(RelayPaneHealthJSON.digest(RelayPaneHealthJSON.object([
                    "action_id": .string(request.id), "result": value])).prefix(32))
                let receipt = try await RelayPaneHealthHostControllerRPC.send(profile: profile, action: "complete_action",
                    operationID: acknowledgement, owner: desired.owner, actionID: request.id, result: value)
                guard accepts(receipt, admitted: admitted),
                      receipt.acknowledgedActionId == request.id else { throw RelayHostRotationRPC.Failure.invalidResponse }
                controllers[key] = receipt
                journal.controllerActionResults?[receiptKey]?.acknowledged = true
            }
            try save()
        } catch {
            // A superseded task may finish after its replacement has already
            // configured the host. Its cancellation is not a new host failure.
            guard !Task.isCancelled else { return }
            controllerConfigurations.removeValue(forKey: key)
            controllers.removeValue(forKey: key)
            if var host = journal.hosts[key] {
                host.state = "Host monitoring could not be verified: " + String(error.localizedDescription.prefix(180))
                journal.hosts[key] = host
                try? save()
            }
        }
    }

    /// Once the host daemon supplies a fresh observation, the GUI only repeats
    /// the expensive native probe for a repair that could actually proceed.
    func hostObservationAllowsMaintenanceInspection(_ pane: PaneModel, now: Date = Date()) -> Bool {
        let key = pane.profile.connectionKey
        guard controllers[key] != nil, let observation = observations[pane.id], now.timeIntervalSince(observation.at) < 300 else { return true }
        let proof = observation.proof
        return proof.valid(for: pane.id) && proof.lifecycle == "quiet" && proof.backgroundWork != true &&
            (proof.provider != "claude" || proof.backgroundWork == false) &&
            RelayAgentMaintenancePolicy.reason(proof, updateBanner: false) != nil
    }

    static func controllerNativeSourceMatches(_ before: RelayPaneHealthFacts, _ current: RelayPaneHealthFacts) -> Bool {
        before.paneID == current.paneID && ["kind", "connection", "binding", "identity_verified",
            "session_id", "process_id", "process_start"].allSatisfy { before.value[$0] == current.value[$0] }
    }

    static func controllerReconnectIsAdmissible(_ before: RelayPaneHealthFacts, _ current: RelayPaneHealthFacts) -> Bool {
        controllerNativeSourceMatches(before, current) &&
        before.value["connection"]?.string == "disconnected" &&
        before.allowedActions.contains("reconnect") && current.allowedActions.contains("reconnect")
    }

    private func executeControllerAction(_ request: RelayPaneHealthHostControllerStatus.ActionRequest,
        profile: ConnectionProfile, knownPaneIDs: Set<String>, scopeIsCurrent: () -> Bool) async -> RelayPaneHealthJSON {
        let held: (String) -> RelayPaneHealthJSON = { .object(["state": .string("held"), "message": .string($0)]) }
        let expectedID = String(RelayPaneHealthJSON.digest(RelayPaneHealthJSON.object([
            "operation_id": .string(request.operationId), "tool_id": .string(request.call.id)])).prefix(32))
        let before = RelayPaneHealthFacts(value: request.before)
        guard !Task.isCancelled, scopeIsCurrent(), request.call.type == "tool_use",
              RelayHostRotationRPC.validOperationID(request.operationId), request.id == expectedID,
              let id = request.call.paneID, before.paneID == id.uuidString.lowercased(),
              knownPaneIDs.contains(before.paneID), let reference = references[id], let pane = reference.pane,
              let workspace = reference.workspace, workspace.panes[id] === pane,
              pane.profile.connectionKey == profile.connectionKey,
              case .object(let fields) = before.value, RelayPaneHealthFacts.seal(fields).evidenceID == before.evidenceID,
              request.call.input["evidence_id"]?.string == before.evidenceID,
              let allowed = ["repair_agent_link": "repair_link", "apply_installed_update": "apply_update", "reconnect_pane": "reconnect"][request.call.name],
              before.allowedActions.contains(allowed) else { return held("The journaled request does not match this exact pane and native evidence.") }
        let key = profile.connectionKey + ":" + request.call.id
        if let old = journal.tools[key] {
            guard old.operationID == request.operationId, old.inputDigest == RelayPaneHealthJSON.digest(request.call.input) else {
                return held("The request conflicts with its durable native receipt.")
            }
            return old.result ?? .object(["state": .string("verification_unknown"),
                "message": .string("The original native action outcome is unknown; no action was repeated.")])
        }
        guard RelayPreferences.shared.haikuPaneHealth, RelayPreferences.shared.automaticAgentMaintenance else {
            return held("The operator's current settings hold native repairs.")
        }
        let capturedProfile = pane.profile
        do {
            if request.call.name == "reconnect_pane" {
                // A disconnected viewer cannot provide a fresh agent probe.
                // Reattachment has its own exact retained-worker admission and
                // never creates or restarts a provider.
                let current = facts(pane)
                guard Self.controllerReconnectIsAdmissible(before, current),
                      scopeIsCurrent(), !Task.isCancelled else { return held("The retained viewer or request scope changed.") }
                var inspected = [id: before]
                return await execute(request.call, operationID: request.operationId, host: profile.connectionKey,
                    profile: profile, knownPaneIDs: knownPaneIDs, inspected: &inspected,
                    nativeAdmissionEvidence: [id: current.evidenceID])
            }
            let proof = try await RelayAgentMaintenanceReader.inspect(pane)
            await pane.runtime.prepareAgentMaintenancePromptProof()
            guard !Task.isCancelled, scopeIsCurrent(), workspace.panes[id] === pane, pane.profile == capturedProfile else {
                return held("The captured execution host changed during native admission.")
            }
            observe(pane, proof: proof)
            let current = RelayPaneHealthFacts.read(pane, proof: proof)
            if current.value["session_id"] == before.value["session_id"], proof.bound == true,
               (request.call.name == "apply_installed_update" && proof.installedImageCurrent == true ||
                request.call.name == "repair_agent_link" && current.value["binding"]?.string == "bound") {
                return .object(["state": .string("already_healthy"), "pane": current.value,
                    "message": .string("Fresh native evidence already confirms the original conversation's requested postcondition.")])
            }
            guard Self.controllerNativeSourceMatches(before, current), current.allowedActions.contains(allowed) else {
                return .object(["state": .string("held"), "pane": current.value,
                    "message": .string("The pane or prompt changed after the model request; native input was not submitted.")])
            }
            var inspected = [id: before]
            return await execute(request.call, operationID: request.operationId, host: profile.connectionKey,
                profile: profile, knownPaneIDs: knownPaneIDs, inspected: &inspected,
                nativeAdmissionEvidence: [id: current.evidenceID])
        } catch { return held("Fresh native identity and prompt admission could not be verified.") }
    }

    static func snapshotID(host: String, panes: [RelayPaneHealthFacts]) -> String {
        RelayPaneHealthJSON.digest(RelayPaneHealthJSON.object([
            "host_id": .string(host), "panes": .array(panes.map(\.value)),
        ]))
    }

    /// Keep a serial inspect for every pane and a final report within one pass.
    static func assessmentBatches(_ panes: [RelayPaneHealthFacts]) -> [[RelayPaneHealthFacts]] {
        stride(from: 0, to: panes.count, by: 8).map { Array(panes[$0..<min($0 + 8, panes.count)]) }
    }

    static func mergingReport(_ previous: RelayPaneHealthJSON?, batch: RelayPaneHealthJSON,
                              activePaneIDs: Set<String>) -> RelayPaneHealthJSON {
        var rows: [String: RelayPaneHealthJSON] = [:]
        for value in (previous?["panes"]?.array ?? []) + (batch["panes"]?.array ?? []) {
            if let id = value["pane_id"]?.string, activePaneIDs.contains(id) { rows[id] = value }
        }
        return .object(["panes": .array(rows.keys.sorted().compactMap { rows[$0] })])
    }

    /// Connection keys may contain display spaces, user names or IPv6 syntax.
    /// Bind model receipts to an opaque identifier accepted on both hosts.
    static func rpcHostID(_ connectionKey: String) -> String {
        "host-" + RelayPaneHealthJSON.digest(connectionKey)
    }

    static func batchID(_ panes: [RelayPaneHealthFacts]) -> String {
        RelayPaneHealthJSON.digest(panes.map(\.paneID))
    }

    /// Normal typing and quiet/working transitions of a healthy agent do not
    /// spend another model request. A fault, update, identity change or a fault
    /// becoming safe to repair does trigger a new pass.
    static func healthSignal(_ panes: [RelayPaneHealthFacts]) -> String {
        let stable = panes.map { pane -> RelayPaneHealthJSON in
            guard case .object(var fields) = pane.value else { return pane.value }
            fields.removeValue(forKey: "evidence_id")
            // Explanatory text (it can quote the footer); prompt_empty carries the decision.
            fields.removeValue(forKey: "prompt_blocker")
            fields.removeValue(forKey: "footer_agent_facts")
            if fields["binding"]?.string == "bound", fields["installed_update"]?.boolean == false {
                for key in ["activity", "prompt_empty", "has_draft", "pending_approvals", "input_idle", "allowed_actions"] {
                    fields.removeValue(forKey: key)
                }
            }
            return .object(fields)
        }
        return RelayPaneHealthJSON.digest(stable)
    }

    private func save() throws {
        guard !loadFailed else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            loadFailed = true; throw RelayHostRotationRPC.Failure.invalidResponse
        }
        if journal.tools.count > 384 {
            let completed = journal.tools.values.filter { $0.result != nil }.sorted { $0.createdAt < $1.createdAt }
            for entry in completed.prefix(journal.tools.count - 384) { journal.tools.removeValue(forKey: entry.id) }
        }
        // A routine sync rewrote an unchanged journal every 15 s per host.
        if journal == persistedJournal, FileManager.default.fileExists(atPath: url.path) { return }
        let data = try RelayPaneHealthJSON.data(journal)
        guard data.count <= 4 << 20 else { loadFailed = true; throw RelayHostRotationRPC.Failure.invalidResponse }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        persistedJournal = journal
        revision &+= 1
    }

    static func preflightRefusal(_ receipt: RelayPaneHealthStep, operationID: String) -> String? {
        guard receipt.v == 1, receipt.operationID == operationID, receipt.status == "refused", receipt.result == nil else { return nil }
        switch receipt.code {
        case "spending_limit": return "The configured spending limit holds automatic checks; retrying later"
        case "text_backend_disabled": return "The host's model service is disabled; retrying later"
        case "reconciliation_required": return "A previous host model request needs reconciliation; actions are held"
        case "health_api_account_required": return "An API account is required for automatic checks; retrying later"
        case "no_ready_account": return "No configured API account is ready; automatic checks are held until the next retry"
        default: return nil
        }
    }

    static func validReport(_ value: RelayPaneHealthJSON, original: [RelayPaneHealthFacts],
                            inspected: [UUID: RelayPaneHealthFacts]) -> Bool {
        guard let rows = value["panes"]?.array, rows.count == original.count,
              Set(rows.compactMap { $0["pane_id"]?.string }) == Set(original.map(\.paneID)) else { return false }
        let expected = Dictionary(uniqueKeysWithValues: original.map { ($0.paneID, $0) })
        for row in rows {
            guard case .object(let fields) = row,
                  Set(fields.keys) == ["pane_id", "evidence_id", "health", "action", "reason"],
                  let id = row["pane_id"]?.string, let uuid = UUID(uuidString: id),
                  let fact = inspected[uuid] ?? expected[id], row["evidence_id"]?.string == fact.evidenceID,
                  let action = row["action"]?.string, fact.allowedActions.contains(action),
                  let state = row["health"]?.string,
                  ["healthy", "working", "held", "attention", "unknown"].contains(state),
                  let reason = row["reason"]?.string, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.utf8.count <= 240, !reason.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
            if state == "healthy" || state == "working" {
                let kind = fact.value["kind"]?.string, binding = fact.value["binding"]?.string
                let agent = ["claude", "codex"].contains(kind ?? "") && binding == "bound"
                let shell = kind == "shell" && binding == "not_applicable"
                guard fact.value["connection"]?.string == "connected", fact.value["identity_verified"]?.boolean == true,
                      agent || shell, state != "working" || agent && fact.value["activity"]?.string == "working" else { return false }
            }
        }
        return true
    }

    private func execute(_ call: RelayPaneHealthToolCall, operationID: String, host: String,
                         profile: ConnectionProfile, knownPaneIDs: Set<String>,
                         inspected: inout [UUID: RelayPaneHealthFacts],
                         nativeAdmissionEvidence: [UUID: String] = [:]) async -> RelayPaneHealthJSON {
        guard !Task.isCancelled, !RelayPreferences.shared.shepherd.enabled, RelayPreferences.shared.haikuPaneHealth,
              let id = call.paneID, knownPaneIDs.contains(id.uuidString.lowercased()),
              let reference = references[id], let pane = reference.pane, let workspace = reference.workspace,
              workspace.panes[id] === pane, pane.profile.connectionKey == profile.connectionKey else {
            return .object(["state": .string("held"), "message": .string("The pane or captured execution host changed.")])
        }
        let capturedProfile = pane.profile
        let readOnly = call.name == "inspect_pane" || call.name == "verify_pane"
        let inputDigest = RelayPaneHealthJSON.digest(call.input)
        let receiptKey = host + ":" + call.id
        if !readOnly, let old = journal.tools[receiptKey] {
            guard old.operationID == operationID, old.inputDigest == inputDigest else {
                return .object(["state": .string("held"), "message": .string("The tool identity conflicts with its durable receipt.")])
            }
            return old.result ?? .object(["state": .string("verification_unknown"),
                "message": .string("The previous tool outcome is unknown; the action was not repeated.")])
        }
        if !readOnly, journal.tools.values.contains(where: {
            $0.host == host && $0.paneID == id.uuidString.lowercased() &&
            ["repair_agent_link", "apply_installed_update", "reconnect_pane"].contains($0.name) &&
            ["dispatched", "verification_unknown"].contains($0.state)
        }) {
            return .object(["state": .string("held"),
                "message": .string("A previous action has an unknown outcome. Verify this pane before considering another action.")])
        }
        journal.tools[receiptKey] = ToolReceipt(id: receiptKey, operationID: operationID, host: host,
            paneID: id.uuidString.lowercased(), name: call.name, inputDigest: inputDigest,
            before: inspected[id],
            createdAt: Date(), state: "dispatched", result: nil)
        do { try save() } catch {
            return .object(["state": .string("held"), "message": .string("The action receipt could not be saved.")])
        }
        let result: RelayPaneHealthJSON
        if readOnly {
            do {
                let proof = try await RelayAgentMaintenanceReader.inspect(pane)
                guard workspace.panes[id] === pane, pane.profile == capturedProfile else {
                    throw RelayHostRotationRPC.Failure.changedConnection
                }
                observe(pane, proof: proof)
                let value = RelayPaneHealthFacts.read(pane, proof: proof)
                inspected[id] = value
                var state = proof.valid(for: id) || proof.validShell(for: id) ? "observed" : "identity_unavailable"
                if call.name == "verify_pane" {
                    let unresolved = journal.tools.values.filter {
                        $0.host == host && $0.paneID == id.uuidString.lowercased() &&
                        ["repair_agent_link", "apply_installed_update", "reconnect_pane"].contains($0.name) &&
                        ["dispatched", "verification_unknown"].contains($0.state)
                    }
                    for old in unresolved where Self.postcondition(old, current: value,
                        imageVerified: RelayAgentMaintenancePolicy.installedImageVerified(proof)) {
                        let reconciled = old.name == "reconnect_pane" || RelayAgentMaintenance.shared.reconcileHaikuTool(
                            operationID: old.operationID, toolID: old.id.components(separatedBy: ":").last ?? "",
                            pane: pane, proof: proof, updateApplied: old.name == "apply_installed_update")
                        if reconciled {
                            let verified = RelayPaneHealthJSON.object(["state": .string("verified"), "pane": value.value,
                                "message": .string("Fresh native evidence confirms the previous action's postcondition; no action was repeated.")])
                            journal.tools[old.id]?.state = "verified"; journal.tools[old.id]?.result = verified
                            state = "verified"
                        }
                    }
                }
                result = .object(["state": .string(state), "pane": value.value])
            } catch {
                result = .object(["state": .string("unavailable"),
                    "message": .string("Native health inspection is unavailable; the pane was not changed.")])
            }
        } else if let fact = inspected[id], fact.evidenceID == call.input["evidence_id"]?.string,
                  RelayPreferences.shared.automaticAgentMaintenance, !RelayPreferences.shared.shepherd.enabled, !Task.isCancelled {
            switch call.name {
            case "repair_agent_link", "apply_installed_update":
                let allowed = call.name == "repair_agent_link" ? "repair_link" : "apply_update"
                if fact.allowedActions.contains(allowed) {
                    result = await RelayAgentMaintenance.shared.performHaikuTool(call.name, pane: pane, workspace: workspace,
                        evidenceID: nativeAdmissionEvidence[id] ?? fact.evidenceID, operationID: operationID, toolID: call.id)
                } else { result = .object(["state": .string("held"), "message": .string("Fresh native evidence does not allow this repair.")]) }
            case "reconnect_pane":
                result = await reconnect(pane, workspace: workspace, expected: fact,
                    admissionEvidence: nativeAdmissionEvidence[id])
            default:
                result = .object(["state": .string("held"), "message": .string("This tool is not supported.")])
            }
        } else {
            result = .object(["state": .string("held"),
                "message": .string("Inspect this pane first; its current native evidence must allow the exact action.")])
        }
        if let row = result["pane"], let paneID = row["pane_id"]?.string, paneID == id.uuidString.lowercased() {
            inspected[id] = RelayPaneHealthFacts(value: row)
        }
        journal.tools[receiptKey]?.state = result["state"]?.string ?? "unavailable"
        journal.tools[receiptKey]?.result = result
        do { try save() } catch { loadFailed = true }
        return result
    }

    /// An update also needs the native image proof, which stays outside the
    /// model-facing facts: the resumed process must run the installed image.
    static func postcondition(_ receipt: ToolReceipt, current: RelayPaneHealthFacts, imageVerified: Bool) -> Bool {
        guard let before = receipt.before, before.paneID == current.paneID else { return false }
        if receipt.name == "reconnect_pane" {
            return current.value["connection"]?.string == "connected"
        }
        guard current.value["identity_verified"]?.boolean == true,
              current.value["binding"]?.string == "bound",
              let session = before.value["session_id"]?.string,
              current.value["session_id"]?.string == session else { return false }
        if receipt.name == "repair_agent_link" { return true }
        return receipt.name == "apply_installed_update" && current.value["installed_update"]?.boolean == false &&
            imageVerified
    }

    private func reconnect(_ pane: PaneModel, workspace: WorkspaceModel,
                           expected: RelayPaneHealthFacts, admissionEvidence: String? = nil) async -> RelayPaneHealthJSON {
        guard !Task.isCancelled, workspace.panes[pane.id] === pane,
              (admissionEvidence ?? expected.evidenceID) == facts(pane).evidenceID,
              expected.allowedActions.contains("reconnect"), pane.remoteExitCode == nil,
              reconnectCompletions[pane.id] == nil else {
            return .object(["state": .string("held"), "message": .string("The retained connection changed or cannot be safely reattached.")])
        }
        guard case .disconnected = pane.connectionState else {
            return .object(["state": .string("held"), "message": .string("This pane is no longer disconnected.")])
        }
        return await withCheckedContinuation { continuation in
            reconnectCompletions[pane.id] = { continuation.resume(returning: $0) }
            reconnectTimeouts[pane.id] = Task { @MainActor [weak self, pane] in
                try? await Task.sleep(for: .seconds(75))
                guard !Task.isCancelled, let self,
                      let completion = self.reconnectCompletions.removeValue(forKey: pane.id) else { return }
                self.reconnectTimeouts.removeValue(forKey: pane.id)
                completion(.object(["state": .string("verification_unknown"),
                    "message": .string("Retained-worker reconnection was not verified; it was not retried."), "pane": self.facts(pane).value]))
            }
            pane.runtime.reconnectRetainedPane()
        }
    }
}
