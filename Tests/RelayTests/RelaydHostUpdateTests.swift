import Foundation
import Testing
@testable import Relay

/// A fake RelaydManager: `install` mirrors the manager's own guard and only
/// moves the report to .installing; the test decides how it ends.
@MainActor private final class FakeRelaydHost {
    var profiles: [String: ConnectionProfile] = [:]
    var report = RelaydHostReport(state: .outdated, architecture: "amd64", version: "old")
    var busy = false
    var installGuardRefuses = false
    var checks = 0
    var installs: [Bool] = []
    var finish: ((inout RelaydHostReport) -> Void)?
    /// What a fresh check sees once an install has run (nil: the current report).
    var recheck: RelaydHostReport?
    var recheckBusy = false

    init() {
        profiles["dandy-07"] = ConnectionProfile(host: "dandy-07")
        profiles["direct-host"] = ConnectionProfile(host: "direct-host", backend: .direct)
        profiles["This Mac"] = .local
    }

    var dependencies: RelaydHostUpdateService.Dependencies {
        .init(
            // Weak: a service's watcher may outlive this fake after a test.
            resolve: { [weak self] in self?.profiles[$0] },
            check: { [weak self] _ in
                guard let self else { return nil }
                self.checks += 1
                if !self.installs.isEmpty {
                    if self.recheckBusy { return nil }
                    if let recheck = self.recheck { self.report = recheck }
                }
                return self.busy ? nil : self.report
            },
            install: { [weak self] _, retrying in
                guard let self else { return }
                self.installs.append(retrying)
                guard !self.installGuardRefuses else { return }
                self.report.state = .installing
                if let finish = self.finish {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(20))
                        if let self { finish(&self.report) }
                    }
                }
            },
            report: { [weak self] _ in self?.report ?? RelaydHostReport(state: .unknown) },
            bundledVersion: "new"
        )
    }
}

@Suite("Relayd host update service", .serialized)
@MainActor struct RelaydHostUpdateTests {
    private func service(_ host: FakeRelaydHost) -> RelaydHostUpdateService {
        RelaydHostUpdateService(dependencies: host.dependencies, pollInterval: .milliseconds(5))
    }

    @Test func refusesUnknownLocalAndDirectHostsWithoutChecking() async {
        let host = FakeRelaydHost(), updates = service(host)
        for name in ["nowhere", "This Mac", "direct-host", " dandy-07", ""] {
            let result = await updates.run(host: name, requestID: UUID(), wait: .seconds(1))
            #expect(result["status"] == "refused", "host \(name)")
        }
        #expect(host.checks == 0 && host.installs.isEmpty)
    }

    @Test func refusesCurrentUnreachableAndBusyHosts() async {
        for state in [RelaydHostState.ready, .unreachable, .unknown] {
            let host = FakeRelaydHost(), updates = service(host)
            host.report.state = state
            let result = await updates.run(host: "dandy-07", requestID: UUID(), wait: .seconds(1))
            #expect(result["status"] == "refused" && host.installs.isEmpty, "state \(state)")
        }
        let host = FakeRelaydHost(), updates = service(host)
        host.busy = true
        let busy = await updates.run(host: "dandy-07", requestID: UUID(), wait: .seconds(1))
        #expect(busy["status"] == "refused" && host.installs.isEmpty)
    }

    @Test func failedHostRetriesOnlyWithKnownArchitecture() async {
        let unknown = FakeRelaydHost(), first = service(unknown)
        unknown.report = RelaydHostReport(state: .failed, architecture: "—")
        let refused = await first.run(host: "dandy-07", requestID: UUID(), wait: .seconds(1))
        #expect(refused["status"] == "refused" && unknown.installs.isEmpty)

        let known = FakeRelaydHost(), second = service(known)
        known.report = RelaydHostReport(state: .failed, architecture: "arm64")
        known.finish = { $0.state = .ready; $0.version = "new" }
        let retried = await second.run(host: "dandy-07", requestID: UUID(), wait: .seconds(5))
        #expect(retried["status"] == "installed" && known.installs == [true])
    }

    @Test func outdatedHostInstallsOnceAndReplayReturnsTheSameReceipt() async {
        let host = FakeRelaydHost(), updates = service(host)
        let id = UUID()
        // Stepped by hand, not by timers: installing, then the manager's
        // post-install recheck (.checking), then .ready.
        let pending = await updates.run(host: "dandy-07", requestID: id, wait: .milliseconds(30))
        #expect(pending["status"] == "in_progress" && host.installs == [false])
        host.report.state = .checking; host.report.version = "new"
        let rechecking = await updates.run(host: "dandy-07", requestID: id, wait: .milliseconds(30))
        #expect(rechecking["status"] == "in_progress")
        host.report.state = .ready
        let done = await updates.run(host: "dandy-07", requestID: id, wait: .seconds(5))
        #expect(done["status"] == "installed" && done["version"] == "new", "\(done)")
        let replay = await updates.run(host: "dandy-07", requestID: id, wait: .seconds(1))
        #expect(replay == done && host.installs.count == 1 && host.checks == 1)
        #expect(updates.receipt(id) == done)
        let otherHost = await updates.run(host: "elsewhere", requestID: id, wait: .seconds(1))
        #expect(otherHost["status"] == "refused" && host.installs.count == 1)
    }

    // bc08 review of 0.5.28: Stop cancels Miko's turn task, and a cancelled
    // Task.sleep throws at once, so the wait spun on the main actor until its
    // deadline. A cancelled wait now returns the current receipt.
    @Test func cancelledWaitReturnsTheCurrentReceiptPromptly() async {
        let host = FakeRelaydHost(), updates = service(host)
        let id = UUID()
        let started = await updates.run(host: "dandy-07", requestID: id, wait: .milliseconds(10))
        #expect(started["status"] == "in_progress")
        let waiting = Task { @MainActor in
            await updates.run(host: "dandy-07", requestID: id, wait: .seconds(30))
        }
        waiting.cancel()
        let clock = ContinuousClock(), begun = clock.now
        let result = await waiting.value
        #expect(result["status"] == "in_progress" && clock.now - begun < .seconds(2))
        #expect(host.installs.count == 1)
    }

    @Test func concurrentReplayDoesNotStartASecondInstall() async {
        let host = FakeRelaydHost(), updates = service(host)
        let id = UUID()
        async let a = updates.run(host: "dandy-07", requestID: id, wait: .milliseconds(50))
        async let b = updates.run(host: "dandy-07", requestID: id, wait: .milliseconds(50))
        let results = await [a, b]
        #expect(results.allSatisfy { $0["status"] == "in_progress" })
        #expect(host.installs.count == 1 && host.checks == 1)
    }

    @Test func installThatDoesNotStartOrFailsIsReported() async {
        let silent = FakeRelaydHost(), first = service(silent)
        silent.installGuardRefuses = true
        let refused = await first.run(host: "dandy-07", requestID: UUID(), wait: .seconds(1))
        #expect(refused["status"] == "refused" && silent.installs.count == 1)

        let failing = FakeRelaydHost(), second = service(failing)
        failing.finish = { $0.state = .failed; $0.message = "checksum mismatch" }
        let failed = await second.run(host: "dandy-07", requestID: UUID(), wait: .seconds(5))
        #expect(failed["status"] == "failed" && failed["message"]?.contains("checksum mismatch") == true)
    }

    // 0.5.30 on dandy-07: the update swapped the supervisor, but the Mac lost
    // the install job's outcome with the supervisor it ran under, and the
    // receipt said "failed". A non-ready end now settles by a fresh check
    // bound to this request: the supervisor must differ from the one seen
    // before dispatch and run the bundled relayd.
    private let lostOutcome = "Host exec outcome unavailable; job job-1; Do not replay execution."

    private func swapRace(recheck: RelaydHostReport?, busy: Bool = false) async -> (FakeRelaydHost, [String: String]) {
        let host = FakeRelaydHost(), updates = service(host)
        host.report = RelaydHostReport(state: .outdated, architecture: "amd64", version: "old", liveVersion: "old", supervisorPID: 100)
        host.finish = { [lostOutcome] in $0.state = .failed; $0.message = lostOutcome }
        host.recheck = recheck
        host.recheckBusy = busy
        let result = await updates.run(host: "dandy-07", requestID: UUID(), wait: .seconds(5))
        return (host, result)
    }

    @Test func aLostInstallOutcomeIsInstalledWhenANewSupervisorRunsTheBundledRelayd() async {
        let (host, result) = await swapRace(recheck: RelaydHostReport(state: .ready, architecture: "amd64",
            version: "new", liveVersion: "new", supervisorPID: 200))
        #expect(result["status"] == "installed" && result["version"] == "new", "\(result)")
        #expect(result["message"]?.contains("Host exec outcome unavailable") == true)
        #expect(host.installs.count == 1 && host.checks == 2)
    }

    @Test func aLostInstallOutcomeUnderTheSameSupervisorIsAlreadyCurrent() async {
        let (host, result) = await swapRace(recheck: RelaydHostReport(state: .ready, architecture: "amd64",
            version: "new", liveVersion: "new", supervisorPID: 100))
        #expect(result["status"] == "already_current", "\(result)")
        #expect(host.installs.count == 1 && host.checks == 2)
    }

    @Test func aLostInstallOutcomeWithoutEvidenceStaysFailed() async {
        let cases: [(String, RelaydHostReport?, Bool)] = [
            ("outdated", RelaydHostReport(state: .outdated, architecture: "amd64", version: "old", liveVersion: "old", supervisorPID: 300), false),
            ("unreachable", RelaydHostReport(state: .unreachable, message: "no route"), false),
            ("no supervisor", RelaydHostReport(state: .ready, architecture: "amd64", version: "new", supervisorPID: nil), false),
            ("other running version", RelaydHostReport(state: .ready, architecture: "amd64", version: "new", liveVersion: "newer", supervisorPID: 300), false),
            ("recheck busy", nil, true),
        ]
        for (name, recheck, busy) in cases {
            let (host, result) = await swapRace(recheck: recheck, busy: busy)
            #expect(result["status"] == "failed", "\(name): \(result)")
            #expect(result["message"]?.contains("Host exec outcome unavailable") == true, "\(name)")
            #expect(result["message"]?.contains("recheck") == true, "\(name): \(result)")
            #expect(host.installs.count == 1, "\(name)")
        }
    }
}
