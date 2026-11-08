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
    private let progress: RelaydHostUpdateProgress
    private var receipts: [UUID: Receipt] = [:]

    init(dependencies: Dependencies, pollInterval: Duration = .seconds(1), completionLimit: Duration = .seconds(1800),
         progress: RelaydHostUpdateProgress = .shared) {
        self.dependencies = dependencies
        self.pollInterval = pollInterval
        self.completionLimit = completionLimit
        self.progress = progress
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
        progress.began(key: profile.connectionKey, host: host, requestID: requestID)
        // The manager's operation continues on its own; this only records how
        // it ends, and stops if the service goes away.
        Task { [weak self, pollInterval, completionLimit] in
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: completionLimit)
            while clock.now < deadline {
                if await self?.settle(profile: profile, requestID: requestID, before: report) != false { return }
                try? await Task.sleep(for: pollInterval)
            }
            self?.update(requestID, "The relayd update on \(profile.host) is still running after \(completionLimit); check Manage relayd.")
            self?.progress.ended(requestID: requestID, phase: .stillRunning(after: completionLimit))
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
    ///
    /// Known limits of pid evidence (accepted in bc08's 0.5.31 review): a
    /// reused supervisor pid, or another actor replacing the supervisor in the
    /// seconds between the pre-install check and dispatch, reads as
    /// "installed"; with no supervisor before, any supervisor after counts as
    /// replaced. A supervisor start time later than dispatch would close these;
    /// the report does not carry one yet (a check-script change).
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
        // Only an update that started has a row; refusals ran nothing.
        switch status {
        case "installed": progress.ended(requestID: id, phase: .installed(version: version ?? dependencies.bundledVersion))
        case "already_current": progress.ended(requestID: id, phase: .alreadyCurrent(version: version ?? dependencies.bundledVersion))
        default: progress.ended(requestID: id, phase: .failed(message: message))
        }
    }

    private func update(_ id: UUID, _ message: String) {
        receipts[id]?.result["message"] = message
    }
}

/// The in-flight and last relayd update per host, observed by the Manage
/// relayd host rail. Written by RelaydHostUpdateService; RelaydManager
/// reports completed checks and install starts. A finished row stays for
/// `finishedLifetime`, or until a newer check completes or an install starts;
/// an update still running (or past the service's limit) stays.
@MainActor
final class RelaydHostUpdateProgress: ObservableObject {
    static let shared = RelaydHostUpdateProgress()
    static let finishedLifetime: TimeInterval = 600

    struct Entry: Equatable {
        enum Phase: Equatable {
            case updating
            case stillRunning(after: Duration)
            case installed(version: String)
            case alreadyCurrent(version: String)
            case failed(message: String)

            var finished: Bool {
                switch self {
                case .installed, .alreadyCurrent, .failed: true
                case .updating, .stillRunning: false
                }
            }
        }
        let host: String
        let requestID: UUID
        let startedAt: Date
        var phase: Phase
        var finishedAt: Date? = nil
    }

    /// Keyed by ConnectionProfile.connectionKey.
    @Published private(set) var entries: [String: Entry] = [:]
    private let now: () -> Date
    private var expiry: Task<Void, Never>?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func entry(forKey key: String) -> Entry? {
        guard let entry = entries[key], !expired(entry) else { return nil }
        return entry
    }

    func began(key: String, host: String, requestID: UUID) {
        prune()
        entries[key] = Entry(host: host, requestID: requestID, startedAt: now(), phase: .updating)
    }

    /// Updates the row of this request; a newer update on the host owns it.
    func ended(requestID: UUID, phase: Entry.Phase) {
        guard let key = entries.first(where: { $0.value.requestID == requestID })?.key else { return }
        entries[key]?.phase = phase
        entries[key]?.finishedAt = phase.finished ? now() : nil
        prune()
        scheduleExpiry()
    }

    /// A check of the host completed with a fresh report. It supersedes the
    /// finished row only if it started after the update finished: the
    /// update's own recheck, or one still running when it ended, does not.
    /// Starting a check (opening Manage relayd) never clears the row.
    func checkCompleted(key: String, startedAt: Date) {
        guard let finished = entries[key]?.finishedAt, startedAt >= finished else { return }
        entries[key] = nil
    }

    /// An explicit install of the host starts: its finished row is stale.
    func installStarted(key: String) {
        guard entries[key]?.phase.finished == true else { return }
        entries[key] = nil
    }

    private func expired(_ entry: Entry) -> Bool {
        entry.finishedAt.map { now().timeIntervalSince($0) >= Self.finishedLifetime } ?? false
    }

    private func prune() {
        let stale = entries.filter { expired($0.value) }.map(\.key)
        for key in stale { entries[key] = nil }
    }

    /// Removes rows as they expire, so the rail redraws without them.
    private func scheduleExpiry() {
        expiry?.cancel()
        let ends = entries.values.compactMap(\.finishedAt).map { $0.addingTimeInterval(Self.finishedLifetime) }
        guard let next = ends.min() else { expiry = nil; return }
        let delay = max(0, next.timeIntervalSince(now()))
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.prune()
            self.scheduleExpiry()
        }
    }
}

/// What the host rail shows for an update: text, tone and whether Details
/// (the host's Manage relayd detail) is offered.
struct RelaydHostUpdateRow: Equatable {
    enum Tone: Equatable { case muted, success, failure }
    let text: String
    let tone: Tone
    let showsDetails: Bool

    init(entry: RelaydHostUpdateProgress.Entry, now: Date) {
        switch entry.phase {
        case .updating:
            text = "Updating relayd… " + Self.elapsed(now.timeIntervalSince(entry.startedAt))
            tone = .muted; showsDetails = false
        case .stillRunning(let limit):
            text = "Updating relayd… still running after " + Self.elapsed(Double(limit.components.seconds))
            tone = .muted; showsDetails = true
        case .installed(let version):
            text = "Updated to " + version
            tone = .success; showsDetails = false
        case .alreadyCurrent(let version):
            text = "Already current at " + version
            tone = .success; showsDetails = false
        case .failed(let message):
            text = message
            tone = .failure; showsDetails = true
        }
    }

    /// m:ss, or h:mm:ss from an hour.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
