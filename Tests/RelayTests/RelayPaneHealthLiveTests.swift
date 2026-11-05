import AppKit
import Combine
import Foundation
import Testing
@testable import Relay

private enum HealthLiveFailure: Error { case connection(String), proof(String) }

private struct HealthLiveReport: Encodable {
    let passed: Bool
    let results: [RelayPaneHealthJSON]
    let cleanup: [RelayPaneHealthJSON]
    let supervisor: RelayPaneHealthCoordinator.Snapshot
    let diagnostics: [RelayDiagnosticEvent]
    let error: String
}

@MainActor
private func connectHealthWorker(_ pane: PaneModel) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        var observation: AnyCancellable?
        var timeout: Task<Void, Never>?
        var finished = false
        func finish(_ error: Error?) {
            guard !finished else { return }; finished = true
            observation?.cancel(); timeout?.cancel()
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
        observation = pane.$connectionState.dropFirst().sink { state in
            print("Health proof connection \(pane.id): \(state)")
            if state == .connected { finish(nil) }
            else if case .disconnected(let reason) = state { finish(HealthLiveFailure.connection(reason)) }
        }
        timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { finish(HealthLiveFailure.connection("Owned worker did not connect")) }
        }
        pane.runtime.startIfNeeded()
    }
}

@MainActor
private func healthWorkerIdentity(_ pane: PaneModel) async throws -> [String: RelayPaneHealthJSON] {
    let catalog = try await RemoteCatalogService.load(profile: pane.profile)
    guard let row = catalog.panes.first(where: { $0.paneID == pane.id.uuidString.lowercased() }),
          let worker = row.workerPID, let shell = row.shellPID, worker > 1, shell > 1,
          row.recoverable else { throw HealthLiveFailure.proof("Exact owned worker is not recoverable") }
    let result = try await RelayHostExecution.capture(profile: pane.profile,
        command: "ps -p \(worker),\(shell) -o pid=,ppid=,lstart=,comm=")
    guard result.exitCode == 0 else { throw HealthLiveFailure.proof("Worker process identity is unavailable") }
    return ["pane_id": .string(row.paneID), "worker_pid": .integer(Int64(worker)),
            "shell_pid": .integer(Int64(shell)), "process_identity": .string(String(decoding: result.stdout, as: UTF8.self))]
}

/// Opt-in integration proof against saved, budgeted API accounts. The runner
/// supplies a private UI profile and an explicit relayd shim to the reviewed
/// helper; only fresh shell UUIDs created here are detached or terminated.
@MainActor
@Test("Real Haiku tools reconnect owned Mac and dandy workers",
      .enabled(if: ProcessInfo.processInfo.environment["RELAY_PANE_HEALTH_LIVE_TEST"] == "1"))
func paneHealthLiveReconnectsOwnedWorkers() async throws {
    guard RelayStateProfile.isIsolated,
          let output = ProcessInfo.processInfo.environment["RELAY_PANE_HEALTH_LIVE_REPORT"] else {
        throw HealthLiveFailure.proof("An isolated profile and an explicit report path are required")
    }
    _ = NSApplication.shared
    print("Health proof test bundle: \(Bundle.main.bundleURL.path)")
    try #require(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/relayd").path))
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let local = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    local.directory = "/private/tmp"
    let remoteProfile = ConnectionProfile(name: "dandy-07 health proof", kind: .ssh,
        host: "dandy-07", command: "", usesSSHConfig: true)
    workspace.newTab(profile: remoteProfile)
    let remote = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    remote.directory = "/tmp"
    let owned = [local, remote]
    let oldHealth = RelayPreferences.shared.haikuPaneHealth
    let oldMaintenance = RelayPreferences.shared.automaticAgentMaintenance
    RelayPreferences.shared.haikuPaneHealth = true
    RelayPreferences.shared.automaticAgentMaintenance = true
    defer {
        workspace.shutdown()
        RelayPreferences.shared.haikuPaneHealth = oldHealth
        RelayPreferences.shared.automaticAgentMaintenance = oldMaintenance
    }
    let coordinator = RelayPaneHealthCoordinator(url: RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("live-health/journal.json"))
    var observations: [AnyCancellable] = []
    for pane in owned {
        observations.append(pane.$connectionState.sink { _ in
            Task { @MainActor in coordinator.heartbeat(workspace) }
        })
    }
    defer { observations.forEach { $0.cancel() } }
    var results: [RelayPaneHealthJSON] = []
    var failure: Error?
    do {
        for pane in owned {
            try await connectHealthWorker(pane)
            let before = try await healthWorkerIdentity(pane)
            pane.runtime.stop()
            pane.disconnected("Owned pane-health integration proof")
            coordinator.heartbeat(workspace)
            try #require(RelayPaneHealthFacts.read(pane, proof: nil).allowedActions.contains("reconnect"))
            await coordinator.checkNow(workspace, profile: pane.profile)
            let after = try await healthWorkerIdentity(pane)
            let receipt = coordinator.snapshot().recentTools.first {
                $0.paneID == pane.id.uuidString.lowercased() && $0.name == "reconnect_pane"
            }
            let host = coordinator.snapshot().hosts.first { $0.host == pane.profile.connectionKey }
            let passed = pane.connectionState == .connected && before == after && receipt?.state == "verified" &&
                host?.report != nil && host?.state == "Haiku assessment complete; monitoring continues"
            results.append(.object(["host": .string(pane.profile.kind == .local ? "This Mac" : pane.profile.host),
                "before": .object(before), "after": .object(after), "passed": .bool(passed)]))
            guard passed else { throw HealthLiveFailure.proof("Haiku reconnect was not natively verified") }
        }
    } catch { failure = error }
    var cleaned: [RelayPaneHealthJSON] = []
    for pane in owned {
        pane.runtime.stop()
        do {
            let previous = try await RemoteCatalogService.load(profile: pane.profile)
            if previous.panes.contains(where: { $0.paneID == pane.id.uuidString.lowercased() }) {
                try await RemotePaneControlService.terminate(profile: pane.profile, paneID: pane.id)
            }
            let catalog = try await RemoteCatalogService.load(profile: pane.profile)
            let absent = !catalog.panes.contains { $0.paneID == pane.id.uuidString.lowercased() }
            cleaned.append(.object(["pane_id": .string(pane.id.uuidString.lowercased()), "absent": .bool(absent)]))
            if !absent && failure == nil { failure = HealthLiveFailure.proof("Owned worker cleanup was not verified") }
        } catch {
            cleaned.append(.object(["pane_id": .string(pane.id.uuidString.lowercased()), "absent": .bool(false)]))
            if failure == nil { failure = error }
        }
    }
    let report = HealthLiveReport(passed: failure == nil, results: results,
        cleanup: cleaned, supervisor: coordinator.snapshot(), diagnostics: RelayDiagnostics.shared.snapshot().events,
        error: failure.map { String(describing: $0) } ?? "")
    let reportURL = URL(fileURLWithPath: output)
    try RelayPaneHealthJSON.data(report).write(to: reportURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
    if let failure { throw failure }
}
