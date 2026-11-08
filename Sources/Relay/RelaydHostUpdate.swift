import Foundation

/// Runs Manage relayd's "Update relayd" for one configured SSH host on behalf
/// of relay_update_host_relayd. It never reimplements the install: it calls
/// RelaydManager's own check and install, then reports how they ended.
///
/// Every request_id runs at most once. Its receipt is created before the first
/// suspension point, so a concurrent or later replay only reads it. Refusals
/// consume the id too. Receipts live for the life of the app process.
@MainActor
final class RelaydHostUpdateService {
    struct Dependencies {
        var resolve: @MainActor (String) -> ConnectionProfile?
        var check: @MainActor (ConnectionProfile) async -> RelaydHostReport?
        var install: @MainActor (ConnectionProfile, _ retrying: Bool) -> Void
        var report: @MainActor (ConnectionProfile) -> RelaydHostReport
        /// The relayd version this app installs.
        var bundledVersion: String = RelaydRemoteClient.expectedVersion

        static func live(resolve: @escaping @MainActor (String) -> ConnectionProfile?) -> Self {
            .init(
                resolve: resolve,
                check: { await RelaydManager.shared.checkForRequest($0) },
                install: { RelaydManager.shared.install($0, explicitlyAuthorized: true, retrying: $1) },
                report: { RelaydManager.shared.report(for: $0) }
            )
        }
    }

    private struct Receipt {
        let host: String
        var result: [String: String]
        var finished: Bool { result["status"] != Self.inProgress }
        static let inProgress = "in_progress"
    }

    static let receiptCap = 4096

    private let dependencies: Dependencies
    private let pollInterval: Duration
    private let completionLimit: Duration
    private var receipts: [UUID: Receipt] = [:]

    init(dependencies: Dependencies, pollInterval: Duration = .seconds(1), completionLimit: Duration = .seconds(1800)) {
        self.dependencies = dependencies
        self.pollInterval = pollInterval
        self.completionLimit = completionLimit
    }

    func receipt(_ id: UUID) -> [String: String]? { receipts[id]?.result }

    /// Starts the update for a new request_id, or reads the receipt of a known
    /// one, then waits up to `wait` for it to finish.
    func run(host: String, requestID: UUID, wait: Duration) async -> [String: String] {
        if let existing = receipts[requestID] {
            guard existing.host == host else {
                return result(host, requestID, "refused", "This request_id was already used for another host; nothing was run.")
            }
            return await awaitReceipt(requestID, wait: wait)
        }
        guard receipts.count < Self.receiptCap else {
            return result(host, requestID, "refused", "Relay holds the most relayd update receipts it keeps in one run; restart Relay to update again. Nothing was run.")
        }
        receipts[requestID] = Receipt(host: host, result: result(host, requestID, Receipt.inProgress, "Checking relayd on \(host)."))
        await start(host: host, requestID: requestID)
        return await awaitReceipt(requestID, wait: wait)
    }

    private func start(host: String, requestID: UUID) async {
        guard host == host.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              let profile = dependencies.resolve(host), profile.kind == .ssh, profile.backend == .relay else {
            return finish(requestID, "refused", "Exact configured Relay SSH host required; nothing was run.")
        }
        guard let report = await dependencies.check(profile) else {
            return finish(requestID, "refused", "Another relayd check or install is already running for \(host); nothing was run. Try again with a new request_id after it ends.")
        }
        let retrying: Bool
        switch report.state {
        case .outdated, .missing: retrying = false
        case .failed where report.architecture != "—": retrying = true
        case .ready:
            return finish(requestID, "refused", "relayd on \(host) is already current\(report.version.map { " (\($0))" } ?? ""); nothing was run.", version: report.version)
        default:
            let detail = report.message.map { ": \($0)" } ?? ""
            return finish(requestID, "refused", "relayd on \(host) is \(report.state.rawValue)\(detail); only an outdated, missing or failed host with a known architecture is updated. Nothing was run.", version: report.version)
        }
        dependencies.install(profile, retrying)
        guard dependencies.report(profile).state == .installing else {
            return finish(requestID, "refused", "Relay did not start the update for \(host); nothing was run.")
        }
        update(requestID, "Updating relayd on \(host): installing the bundled relayd, replacing the supervisor with workers preserved.")
        // The manager's operation continues on its own; this only records how
        // it ends, and stops if the service goes away.
        Task { [weak self, pollInterval, completionLimit] in
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: completionLimit)
            while clock.now < deadline {
                if await self?.settle(profile: profile, requestID: requestID, before: report) != false { return }
                try? await Task.sleep(for: pollInterval)
            }
            self?.update(requestID, "The relayd update on \(profile.host) is still running after \(completionLimit); check Manage relayd.")
        }
    }

    /// The install ends in .failed, or in the manager's recheck (.checking,
    /// then .ready or another state). Returns whether the receipt is final.
    private func settle(profile: ConnectionProfile, requestID: UUID, before: RelaydHostReport) async -> Bool {
        let report = dependencies.report(profile)
        switch report.state {
        case .installing, .checking:
            return false
        case .ready:
            finish(requestID, "installed", "relayd on \(profile.host) is updated and its supervisor restarted\(report.version.map { " at \($0)" } ?? "").", version: report.version)
        default:
            let detail = report.message.map { ": \($0)" } ?? ""
            await settleByRecheck(profile: profile, requestID: requestID, before: before,
                                  ended: "The relayd update on \(profile.host) ended \(report.state.rawValue)\(detail)")
        }
        return true
    }

    /// A non-ready end can hide a completed swap: the install job's outcome is
    /// lost when the supervisor it ran under is replaced. A fresh check decides
    /// by evidence bound to this request: "installed" only if the supervisor
    /// differs from the one the pre-install check saw (so it was replaced after
    /// this request's check and dispatch) and runs the bundled relayd. The
    /// manager's .ready already requires the installed payload hash to match
    /// the bundled one for an equal version.
    private func settleByRecheck(profile: ConnectionProfile, requestID: UUID, before: RelaydHostReport, ended: String) async {
        let bundled = dependencies.bundledVersion
        guard let after = await dependencies.check(profile) else {
            return finish(requestID, "failed", ended + ". A recheck could not run (another relayd check or install is running); check Manage relayd.")
        }
        let wasPID = before.supervisorPID.map(String.init) ?? "none"
        if after.state == .ready, after.version == bundled, after.liveVersion == bundled, let pid = after.supervisorPID {
            if pid != before.supervisorPID {
                return finish(requestID, "installed", "relayd on \(profile.host) is updated and its supervisor restarted at \(bundled): a recheck found a new supervisor (pid \(pid), was \(wasPID)) running the bundled relayd. The install itself reported: \(ended).", version: after.version)
            }
            return finish(requestID, "already_current", "relayd on \(profile.host) runs the bundled relayd \(bundled) under the same supervisor (pid \(pid)) as before this request, so this request did not update it. The install reported: \(ended).", version: after.version)
        }
        let seen = "state \(after.state.rawValue), installed \(after.version ?? "unknown"), running \(after.liveVersion ?? "none"), supervisor pid \(after.supervisorPID.map(String.init) ?? "none") (was \(wasPID))"
        let detail = after.message.map { ": \($0)" } ?? ""
        finish(requestID, "failed", ended + ". A recheck found \(seen)\(detail); Relay includes \(bundled).", version: after.version)
    }

    private func awaitReceipt(_ id: UUID, wait: Duration) async -> [String: String] {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: wait)
        while let receipt = receipts[id], !receipt.finished, clock.now < deadline {
            // A cancelled sleep throws at once; looping on it would spin on the
            // main actor until the deadline (Stop cancels Miko's turn task).
            do { try await Task.sleep(for: pollInterval) } catch { break }
        }
        return receipts[id]?.result ?? [:]
    }

    private func result(_ host: String, _ id: UUID, _ status: String, _ message: String, version: String? = nil) -> [String: String] {
        var value = ["status": status, "message": message, "host": host, "request_id": id.uuidString.lowercased()]
        if let version { value["version"] = version }
        return value
    }

    private func finish(_ id: UUID, _ status: String, _ message: String, version: String? = nil) {
        guard let host = receipts[id]?.host else { return }
        receipts[id]?.result = result(host, id, status, message, version: version)
    }

    private func update(_ id: UUID, _ message: String) {
        receipts[id]?.result["message"] = message
    }
}
