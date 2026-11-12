import AppKit
import Foundation
import Testing
@testable import Relay

/// Where these tests write fixtures: TMPDIR when the test process has it,
/// otherwise Foundation's temporary folder.
private func fixtureURL(_ prefix: String) -> URL {
    let root = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent(prefix + UUID().uuidString)
}

@Suite("Remote relayd installs")
struct RelayRemoteInstallTests {
    private static let id = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private static let newRelayd = "#!/bin/sh\nif [ \"$1\" = version ]; then echo 'relayd 0.5.4'; else echo \"$*\" >> \"$HOME/calls\"; fi\n"
    private static let oldRelayd = "#!/bin/sh\necho 'relayd 0.5.3'\n"
    /// A relayd whose supervisor and worker upgrades say why on stderr and exit 42.
    static let failingRelayd = "#!/bin/sh\nif [ \"$1\" = version ]; then echo 'relayd 0.5.4'; else echo \"$*\" >> \"$HOME/calls\"; echo \"refused: $*\" >&2; exit 42; fi\n"
    /// A relayd whose upgrade `name` fails only while `$HOME/fail-name` exists, and
    /// which records whether the install's receipt existed when the supervisor step ran.
    static let switchableRelayd = """
        #!/bin/sh
        if [ "$1" = version ]; then echo 'relayd 0.5.4'; exit 0; fi
        name=${1#upgrade-}
        receipts=$(ls "$HOME/.local/state/relay/relayd-installs/"*.json 2>/dev/null | grep -c -v supervisor)
        echo "$* receipts=$receipts" >> "$HOME/calls"
        if [ -f "$HOME/fail-$name" ]; then echo "refused: $*" >&2; exit 42; fi

        """

    private static func sha256(_ text: String) -> String {
        try! RelayRemoteInstallRunner.inspect(write(text, to: fixtureURL("relay-install-hash-")).path).sha256
    }

    @discardableResult
    private static func write(_ text: String, to url: URL, executable: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    private static func install(_ changes: (inout RelayRemoteInstallRequest) -> Void = { _ in }) -> RelayRemoteInstallRequest {
        var request = RelayRemoteInstallRequest(requestID: id, action: .install, host: "dandy-07")
        request.localPath = "/builds/relayd-linux-amd64"
        request.sha256 = sha256(newRelayd)
        request.version = "0.5.4"
        changes(&request)
        return request
    }

    /// A home folder with an installed relayd and stand-ins for the host tools
    /// the scripts read: the machine type, the filesystem type and its mount.
    private struct Host {
        let home: URL
        let tools: URL
        var bin: URL { home.appendingPathComponent(".local/share/relay/bin") }
        var target: URL { bin.appendingPathComponent("relayd-linux-amd64") }

        init(filesystem: String = "xfs") throws {
            let root = fixtureURL("relay-install-")
            home = root.appendingPathComponent("home")
            tools = root.appendingPathComponent("tools")
            try write(oldRelayd, to: home.appendingPathComponent(".local/share/relay/bin/relayd-linux-amd64"), executable: true)
            try write("#!/bin/sh\necho x86_64\n", to: tools.appendingPathComponent("uname"), executable: true)
            try write("#!/bin/sh\necho \(filesystem)\n", to: tools.appendingPathComponent("stat"), executable: true)
            try write("#!/bin/sh\necho isilon:/ifs/home\n", to: tools.appendingPathComponent("findmnt"), executable: true)
        }

        func staged(_ request: RelayRemoteInstallRequest, name: String? = nil) -> URL {
            bin.appendingPathComponent(name ?? RelayRemoteInstallScript.stagedName(request.installJobID))
        }

        func stage(_ request: RelayRemoteInstallRequest, _ text: String = newRelayd, name: String? = nil) throws {
            try write(text, to: staged(request, name: name))
        }

        /// The install script for the upload relayd committed at `staged`.
        func install(_ request: RelayRemoteInstallRequest, staged: URL? = nil) -> String {
            RelayRemoteInstallScript.install(request, staged: (staged ?? self.staged(request)).path)
        }

        /// Makes `mv` fail when its destination ends in `suffix`, as an I/O error would.
        func failMoves(to suffix: String) throws {
            try write("#!/bin/sh\nfor last; do :; done\ncase \"$last\" in *\(suffix)) echo 'injected rename failure' >&2; exit 73;; esac\nexec /bin/mv \"$@\"\n",
                      to: tools.appendingPathComponent("mv"), executable: true)
        }

        func restoreMoves() throws { try FileManager.default.removeItem(at: tools.appendingPathComponent("mv")) }

        func run(_ script: String) throws -> [String: String] { try runWithStatus(script).receipt }

        func runWithStatus(_ script: String) throws -> (status: Int32, receipt: [String: String]) {
            let (status, data, _) = try execute(script)
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            return (status, try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String]))
        }

        /// Runs `script` with this home and tools and returns its exit status, stdout and stderr.
        func execute(_ script: String) throws -> (status: Int32, output: Data, error: String) {
            let process = Process()
            let output = Pipe()
            let errors = fixtureURL("relay-install-stderr-")
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            let errorHandle = try FileHandle(forWritingTo: errors)
            defer { try? errorHandle.close(); try? FileManager.default.removeItem(at: errors) }
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": home.path, "PATH": tools.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardOutput = output
            process.standardError = errorHandle
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data, (try? String(contentsOf: errors, encoding: .utf8)) ?? "")
        }

        /// The supervisor step Relay runs over its own SSH session after `kind`'s job.
        func supervisor(_ request: RelayRemoteInstallRequest, kind: String = "install", sha256: String? = nil) -> String {
            RelayRemoteInstallScript.supervisor(request, kind: kind, sha256: sha256 ?? request.sha256 ?? "")
        }

        func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    }

    @Test func aVerifiedInstallKeepsABackupAndLeavesWorkersAlone() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request)
        let receipt = try host.run(host.install(request))
        #expect(receipt["ok"] == "true")
        #expect(receipt["sha256"] == request.sha256)
        #expect(receipt["workers"] == "skipped")
        #expect(receipt["supervisor"] == "skipped")
        #expect(receipt["shared_storage"] == "false")
        #expect(host.contents(host.target) == Self.newRelayd)
        let backup = try #require(receipt["backup"])
        #expect(host.contents(URL(fileURLWithPath: backup)) == Self.oldRelayd)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == nil)
    }

    @Test func aStagedFileWithAnotherSHAIsNotInstalled() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request, Self.newRelayd + "# tampered\n")
        let receipt = try host.run(host.install(request))
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("does not match") == true)
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aBuildReportingAnotherVersionIsNotInstalled() throws {
        let host = try Host()
        let request = Self.install { $0.version = "0.5.5" }
        try host.stage(request)
        let receipt = try host.run(host.install(request))
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("not relayd 0.5.5") == true)
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aBuildForAnotherArchitectureIsNotInstalled() throws {
        let host = try Host()
        let request = Self.install { $0.architecture = "arm64" }
        try host.stage(request)
        let receipt = try host.run(host.install(request))
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("does not match relayd-linux-arm64") == true)
    }

    @Test func sharedStorageStopsTheInstallUnlessTheRequestAcceptsIt() throws {
        let host = try Host(filesystem: "nfs")
        let refused = Self.install()
        try host.stage(refused)
        let receipt = try host.run(host.install(refused))
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("shared storage (nfs isilon:/ifs/home)") == true)
        #expect(host.contents(host.target) == Self.oldRelayd)

        let accepted = Self.install { $0.allowSharedHome = true }
        let installed = try host.run(host.install(accepted))
        #expect(installed["ok"] == "true")
        #expect(installed["shared_storage"] == "true")
        #expect(installed["mount_source"] == "isilon:/ifs/home")
    }

    @Test func resendingAnInstallReturnsItsReceiptWithoutActingAgain() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request)
        let first = try host.run(host.install(request))
        try Self.write("changed by someone else", to: host.target, executable: true)
        let second = try host.run(host.install(request))
        #expect(first == second)
        #expect(host.contents(host.target) == "changed by someone else")
    }

    @Test func workersAreUpgradedOnlyWhenAsked() throws {
        let host = try Host()
        let request = Self.install { $0.upgradeWorkers = true }
        try host.stage(request)
        let receipt = try host.run(host.install(request))
        #expect(receipt["workers"] == "upgraded")
        #expect(host.contents(host.home.appendingPathComponent("calls")) == "upgrade-workers\n")
    }

    @Test func aRollbackRestoresTheBackupOnlyWhileItsInstallIsInPlace() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request)
        _ = try host.run(host.install(request))
        var rollback = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        rollback.installID = request.installJobID

        try Self.write("installed later", to: host.target, executable: true)
        let refused = try host.run(RelayRemoteInstallScript.rollback(rollback))
        #expect(refused["ok"] == "false")
        #expect(host.contents(host.target) == "installed later")

        try Self.write(Self.newRelayd, to: host.target, executable: true)
        let restored = try host.run(RelayRemoteInstallScript.rollback(rollback))
        #expect(restored["ok"] == "true")
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func anEnvironmentReceiptWriteFailureDoesNotReportSuccessfulInstall() throws {
        let host = try Host()
        try host.failMoves(to: ".env")
        let request = Self.install()
        try host.stage(request)
        let (status, receipt) = try host.runWithStatus(host.install(request))
        #expect(status == 1)
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("relayd was not changed") == true)
        #expect(receipt["target_changed"] == nil)
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aReceiptWriteFailureAfterTheSwapFailsWithRecoveryMetadata() throws {
        let host = try Host()
        try host.failMoves(to: ".json")
        let request = Self.install()
        try host.stage(request)
        let (status, receipt) = try host.runWithStatus(host.install(request))
        #expect(status == 1)
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("cannot write receipt") == true)
        #expect(receipt["target_changed"] == "true")
        #expect(receipt["install_id"] == request.installJobID)
        #expect(receipt["target"] == host.target.path)
        #expect(host.contents(host.target) == Self.newRelayd)
        let backup = try #require(receipt["backup"])
        #expect(host.contents(URL(fileURLWithPath: backup)) == Self.oldRelayd)
        #expect(receipt["recovery_record"].map { host.contents(URL(fileURLWithPath: $0)) != nil } == true)

        // The metadata is enough for the normal rollback to undo it.
        try host.restoreMoves()
        var rollback = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        rollback.installID = try #require(receipt["install_id"])
        let restored = try host.run(RelayRemoteInstallScript.rollback(rollback))
        #expect(restored["ok"] == "true")
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aRollbackReceiptWriteFailureStillSaysRelaydChanged() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request)
        _ = try host.run(host.install(request))
        try host.failMoves(to: ".json")
        var rollback = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        rollback.installID = request.installJobID
        let (status, receipt) = try host.runWithStatus(RelayRemoteInstallScript.rollback(rollback))
        #expect(status == 1)
        #expect(receipt["ok"] == "false")
        #expect(receipt["target_changed"] == "true")
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aCollidingStageIsInstalledFromItsCommittedName() throws {
        let host = try Host()
        let request = Self.install()
        try host.stage(request, "stale bytes from an earlier attempt")
        let committed = " (1)" + RelayRemoteInstallScript.stagedName(request.installJobID)
        try host.stage(request, name: committed)
        let receipt = try host.run(host.install(request, staged: host.staged(request, name: committed)))
        #expect(receipt["ok"] == "true")
        #expect(host.contents(host.target) == Self.newRelayd)
        #expect(host.contents(host.staged(request)) == "stale bytes from an earlier attempt")
    }

    @Test func anUploadOutsideRelaydsFolderIsNotInstalled() throws {
        let host = try Host()
        let request = Self.install()
        let elsewhere = host.home.appendingPathComponent("elsewhere/" + RelayRemoteInstallScript.stagedName(request.installJobID))
        try Self.write(Self.newRelayd, to: elsewhere)
        let receipt = try host.run(host.install(request, staged: elsewhere))
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("the upload landed in") == true)
        #expect(host.contents(host.target) == Self.oldRelayd)
    }

    @Test func aFailedRequestedUpgradeIsAFailedInstallThatReplaysAsFailed() throws {
        let host = try Host()
        let request = Self.install { $0.sha256 = Self.sha256(Self.failingRelayd); $0.upgradeWorkers = true; $0.upgradeSupervisor = true }
        try host.stage(request, Self.failingRelayd)
        let (status, receipt) = try host.runWithStatus(host.install(request))
        #expect(status == 1)
        #expect(receipt["ok"] == "false")
        // The job never restarts the supervisor it runs under; Relay does that after the receipt.
        #expect(receipt["failed_step"] == "workers" && receipt["supervisor"] == "pending")
        #expect(receipt["workers_exit"] == "42" && receipt["supervisor_exit"] == nil)
        #expect(receipt["workers_stderr"] == "refused: upgrade-workers ")
        #expect(receipt["error"] == "relayd was installed, but the requested upgrade failed: workers (exit 42)")
        #expect(receipt["target_changed"] == "true" && receipt["install_id"] == request.installJobID)
        #expect(host.contents(host.target) == Self.failingRelayd)

        // The failure is the job's durable receipt: a resend reports it again and does nothing.
        let (again, replayed) = try host.runWithStatus(host.install(request))
        #expect(again == 1)
        #expect(replayed == receipt)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == "upgrade-workers\n")
    }

    @Test func theSupervisorStepRunsOnceOnTheInstalledRelaydAndReplaysItsReceipt() throws {
        let host = try Host()
        let request = Self.install { $0.sha256 = Self.sha256(Self.switchableRelayd); $0.upgradeSupervisor = true }
        try host.stage(request, Self.switchableRelayd)
        let job = try host.run(host.install(request))
        #expect(job["ok"] == "true" && job["supervisor"] == "pending")
        #expect(host.contents(host.home.appendingPathComponent("calls")) == nil)
        // A resent job replays its pending receipt and runs nothing.
        let (jobAgain, jobReplayed) = try host.runWithStatus(host.install(request))
        #expect(jobAgain == 0 && jobReplayed == job)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == nil)

        let (status, receipt) = try host.runWithStatus(host.supervisor(request))
        #expect(status == 0)
        #expect(receipt["ok"] == "true" && receipt["supervisor"] == "upgraded" && receipt["sha256"] == request.sha256)
        let (again, replayed) = try host.runWithStatus(host.supervisor(request))
        #expect(again == 0 && replayed == receipt)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == "upgrade-supervisor --force receipts=1\n")
    }

    @Test func theSupervisorStepRefusesARelaydThatChangedAfterTheInstall() throws {
        let host = try Host()
        let request = Self.install { $0.sha256 = Self.sha256(Self.switchableRelayd); $0.upgradeSupervisor = true }
        try host.stage(request, Self.switchableRelayd)
        #expect(try host.run(host.install(request))["ok"] == "true")
        try Self.write(Self.switchableRelayd + "# replaced by another install\n", to: host.target, executable: true)
        let (status, receipt) = try host.runWithStatus(host.supervisor(request))
        #expect(status == 1)
        #expect(receipt["ok"] == "false")
        #expect(receipt["error"]?.contains("relayd changed after the install") == true)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == nil)
    }

    @Test func aRelaydReplacedWhileTheSupervisorRestartsFailsTheStep() throws {
        let host = try Host()
        // Its supervisor upgrade replaces the relayd file it runs from, as a concurrent install could.
        let swapping = Self.switchableRelayd + "cp \"$0\" \"$0.tmp\" && echo '# swapped' >> \"$0.tmp\" && mv -f \"$0.tmp\" \"$0\"\n"
        let request = Self.install { $0.sha256 = Self.sha256(swapping); $0.upgradeSupervisor = true }
        try host.stage(request, swapping)
        #expect(try host.run(host.install(request))["ok"] == "true")
        let (status, receipt) = try host.runWithStatus(host.supervisor(request))
        #expect(status == 1)
        #expect(receipt["ok"] == "false" && receipt["supervisor"] == "unknown")
        #expect(receipt["failed_step"] == "identity")
        #expect(receipt["error"]?.contains("relayd changed while the supervisor restarted") == true)
    }

    /// Deterministic generator for the receipt fuzz test.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Fuzzes what the supervisor session prints: valid, foreign, malformed and
    /// truncated receipts with any exit status. Properties: success only for this
    /// job's exact supervisor receipt with status 0; every refusal is not ok, never
    /// says the supervisor upgraded, keeps the job's sha256 and backup, and keeps
    /// every field bounded. Fixed seeds; the listed regression inputs always run.
    @Test func theSupervisorReceiptIsBoundToThisJobUnderFuzzing() async throws {
        let request = Self.install { $0.upgradeSupervisor = true }
        let job = request.installJobID
        let sha = try #require(request.sha256)
        let installed = ["ok": "true", "job_id": job, "action": "install", "sha256": sha, "backup": "/b", "target": "/t", "supervisor": "pending"]
        let valid = ["ok": "true", "job_id": job, "action": "supervisor", "target": "/t", "sha256": sha, "supervisor": "upgraded"]
        func line(_ object: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let pool = ["true", "false", "upgraded", "unknown", "", "install", "supervisor", job, "install-other", sha,
                    String(repeating: "f", count: 64), String(repeating: "x", count: 9000), "\u{e9}\u{0}\n\"", "{\"ok\":\"true\"}"]
        // Committed regression inputs: each was a way an ok-looking line could be accepted.
        var cases: [(Int32, String)] = [
            (0, line(valid)), (1, line(valid)), (0, String(line(valid).dropLast())),
            (0, line(valid.merging(["job_id": "install-other"]) { $1 })), (0, line(valid.merging(["sha256": String(repeating: "f", count: 64)]) { $1 })),
            (0, line(["ok": "true"])), (0, line(valid.merging(["supervisor": "pending"]) { $1 })),
            (0, line(valid.merging(["action": "install"]) { $1 })), (0, line(valid) + "\n" + line(["ok": "true"])),
            (0, line(["ok": "false", "error": String(repeating: "e", count: 9000), "sha256": String(repeating: "f", count: 64), "backup": ""])),
            (0, "{\"ok\":true,\"supervisor\":\"upgraded\"}"), (0, ""), (0, "\u{0}\u{ff}garbage"),
        ]
        for seed: UInt64 in [1, 42, 20_261_027] {
            var random = SplitMix64(state: seed)
            for _ in 0..<1000 {
                let status: Int32 = [0, 0, 0, 1, 42, 255][random.below(6)]
                var object: [String: Any] = valid
                var text: String
                switch random.below(8) {
                case 0: text = line(object)
                case 1: object.removeValue(forKey: Array(valid.keys).sorted()[random.below(valid.count)]); text = line(object)
                case 2:
                    let keys = Array(valid.keys).sorted() + ["error", "backup", "failed_step", "supervisor_exit"]
                    object[keys[random.below(keys.count)]] = pool[random.below(pool.count)]; text = line(object)
                case 3: let full = line(object); text = String(full.prefix(random.below(full.count + 1)))
                case 4: text = line(object) + "\n" + pool[random.below(pool.count)]
                case 5: object["sha256"] = random.below(2); text = line(object)
                case 6: text = line(object) + "\n" + line(valid.merging(["job_id": "install-other"]) { $1 })
                default: text = String((0..<random.below(64)).map { _ in Character(UnicodeScalar(UInt8(random.below(256)))) })
                }
                cases.append((status, text))
            }
        }
        for (status, output) in cases {
            let last = output.split(separator: "\n").last.map(String.init) ?? ""
            let parsed = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String]
            let shouldSucceed = status == 0 && parsed?["ok"] == "true" && parsed?["supervisor"] == "upgraded"
                && parsed?["action"] == "supervisor" && parsed?["job_id"] == job && parsed?["sha256"] == sha
            var result: [String: String]?
            var refused: [String: String]?
            do {
                result = try await RelayRemoteInstallRunner.upgradeSupervisor(
                    request, after: installed, kind: "install", direct: { _ in (status, output, String(repeating: "s", count: 5000)) })
            } catch RelayRemoteInstallError.refused(_, let receipt) {
                refused = receipt
            }
            let label = "status \(status): \(output.prefix(160))"
            #expect((result != nil) == shouldSucceed, "\(label)")
            let receipt = try #require(result ?? refused, "\(label)")
            #expect(receipt["sha256"] == sha && receipt["backup"] == "/b" && receipt["target"] == "/t", "\(label)")
            #expect(receipt.values.allSatisfy { $0.count <= 4096 }, "\(label)")
            if result != nil {
                #expect(receipt["ok"] == "true" && receipt["supervisor"] == "upgraded", "\(label)")
            } else {
                #expect(receipt["ok"] == "false" && receipt["supervisor"] != "upgraded", "\(label)")
            }
        }
        #expect(cases.count == 13 + 3000)
    }

    @Test func stepLogsNeverFollowALinkPlacedAtTheirOldNames() throws {
        let host = try Host()
        let request = Self.install { $0.sha256 = Self.sha256(Self.failingRelayd); $0.upgradeWorkers = true }
        try host.stage(request, Self.failingRelayd)
        let state = host.home.appendingPathComponent(".local/state/relay/relayd-installs")
        let sentinel = try Self.write("keep me\n", to: host.home.appendingPathComponent("outside/sentinel"))
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for suffix in ["out", "err"] {
            try FileManager.default.createSymbolicLink(
                at: state.appendingPathComponent("\(request.installJobID).workers.\(suffix)"), withDestinationURL: sentinel)
        }
        let receipt = try host.run(host.install(request))
        #expect(receipt["workers_exit"] == "42" && receipt["workers_stderr"] == "refused: upgrade-workers ")
        #expect(host.contents(sentinel) == "keep me\n")
        let logs = try FileManager.default.contentsOfDirectory(atPath: state.path)
            .filter { $0.hasPrefix("\(request.installJobID).workers.") && !$0.hasSuffix(".out") && !$0.hasSuffix(".err") }
        #expect(logs.count == 1)
        let directory = state.appendingPathComponent(try #require(logs.first))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o077 } == 0)
        #expect(host.contents(directory.appendingPathComponent("err")) == "refused: upgrade-workers\n")
    }

    @Test func aStepWithoutAPrivateLogDirectoryDoesNotRun() throws {
        let host = try Host()
        try Self.write("#!/bin/sh\nexit 1\n", to: host.tools.appendingPathComponent("mktemp"), executable: true)
        let request = Self.install { $0.sha256 = Self.sha256(Self.failingRelayd); $0.upgradeWorkers = true }
        try host.stage(request, Self.failingRelayd)
        let receipt = try host.run(host.install(request))
        #expect(receipt["ok"] == "false" && receipt["failed_step"] == "workers" && receipt["workers_exit"] == "125")
        #expect(receipt["workers_stderr"] == "cannot create a private log directory for workers; it was not run")
        #expect(host.contents(host.home.appendingPathComponent("calls")) == nil)
    }

    @Test func aFailedSupervisorStepQuotesABoundedPrintableStderrTail() throws {
        let host = try Host()
        let noisy = Self.failingRelayd.replacingOccurrences(
            of: "echo \"refused: $*\" >&2",
            with: #"head -c 6000 /dev/zero | tr '\000' x >&2; printf '\n"q" \\ \303\251 END' >&2"#)
        let request = Self.install { $0.sha256 = Self.sha256(noisy); $0.upgradeSupervisor = true }
        try host.stage(request, noisy)
        #expect(try host.run(host.install(request))["ok"] == "true")
        let (status, receipt) = try host.runWithStatus(host.supervisor(request))
        #expect(status == 1)
        #expect(receipt["supervisor_exit"] == "42")
        let tail = try #require(receipt["supervisor_stderr"])
        #expect(tail.utf8.count == 2048)
        #expect(tail.hasSuffix(" \"q\" \\    END"))
        #expect(tail.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) })
    }

    /// What the host's relayd had been asked to do when the direct session began.
    private final class CallsSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: String?
        var value: String? { lock.withLock { seen } }
        func set(_ calls: String?) { lock.withLock { seen = calls } }
    }

    /// Answers relayd RPCs for one `Host`: an upload lands in its relayd folder
    /// and an exec runs the actual script there, so Runner and Control see the
    /// script's real exit status and output.
    private final class ScriptHost: @unchecked Sendable {
        let host: Host
        private let lock = NSLock()
        private var name = "", sha = "", bytes = Data(), output = Data()
        private var exit: Int32?
        private var jobs = 0, sessions = 0
        var scriptExit: Int32? { lock.withLock { exit } }
        /// Host jobs run through relayd, and scripts run in their own SSH session.
        var counts: (jobs: Int, sessions: Int) { lock.withLock { (jobs, sessions) } }
        /// Runs before each direct session's script, as another install could.
        var beforeSession: () throws -> Void = {}

        init(_ host: Host) { self.host = host }

        lazy var direct: RelayRemoteInstallRunner.Direct = { [self] script in
            try self.beforeSession()
            let run = try self.host.execute(script)
            self.lock.withLock { self.sessions += 1 }
            return (run.status, String(decoding: run.output, as: UTF8.self), run.error)
        }

        lazy var send: RelayRemoteInstallRunner.Send = { [self] payload in
            let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let folder = self.host.bin.path
            let result: [String: Any] = try self.lock.withLock {
                switch object["operation"] as? String {
                case "file_upload_begin":
                    self.name = object["upload_name"] as? String ?? ""
                    self.sha = object["upload_sha256"] as? String ?? ""
                    return ["state": "receiving", "offset": 0, "directory": folder]
                case "file_upload_chunk":
                    self.bytes.append(Data(base64Encoded: object["data"] as? String ?? "") ?? Data())
                    return ["state": "receiving", "offset": self.bytes.count, "directory": folder]
                case "file_upload_commit":
                    try self.bytes.write(to: self.host.bin.appendingPathComponent(self.name))
                    return ["state": "committed", "offset": self.bytes.count, "sha256": self.sha,
                            "directory": folder, "path": folder + "/" + self.name]
                case "exec":
                    let run = try self.host.execute(object["command"] as? String ?? "")
                    self.exit = run.status
                    self.output = run.output
                    self.jobs += 1
                    return ["state": "running"]
                case "status":
                    return ["stdout": self.output.base64EncodedString(),
                            "job": ["state": "exited", "exit_code": Int(self.exit ?? -1)] as [String: Any]]
                default:
                    return ["state": "running"]
                }
            }
            return try JSONSerialization.data(withJSONObject: ["result": result])
        }
    }

    /// Approves `request` in a Control and waits for its terminal receipt.
    @MainActor private func approve(_ request: RelayRemoteInstallRequest, file: RelayRemoteInstallRunner.LocalFile?,
                                    on host: ScriptHost) async throws -> RelayRemoteInstallReceipt {
        let control = RelayRemoteInstallControl { _, completion in completion(.alertSecondButtonReturn); return true }
        _ = try control.propose(request, file: file, send: host.send, direct: host.direct)
        for _ in 0..<1000 {
            if let status = control.receipt(request.requestID)?.status, status == "completed" || status == "failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(control.receipt(request.requestID))
    }

    /// Installs the failing relayd through Runner and Control with the given upgrades requested.
    @MainActor private func failingInstall(workers: Bool, supervisor: Bool) async throws -> (Host, ScriptHost, RelayRemoteInstallRequest, RelayRemoteInstallReceipt) {
        let host = try Host()
        let local = try Self.write(Self.failingRelayd, to: fixtureURL("relay-install-local-"))
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .install, host: "dandy-07")
        request.localPath = local.path
        request.sha256 = Self.sha256(Self.failingRelayd)
        request.version = "0.5.4"
        request.upgradeWorkers = workers
        request.upgradeSupervisor = supervisor
        let rpc = ScriptHost(host)
        let receipt = try await approve(request, file: try RelayRemoteInstallRunner.inspect(local.path), on: rpc)
        return (host, rpc, request, receipt)
    }

    private func expectFailedStep(_ receipt: RelayRemoteInstallReceipt, _ step: String, scriptExit: Int32?, installID: String,
                                  jobExit: Int32 = 1) {
        #expect(receipt.status == "failed")
        #expect(scriptExit == jobExit)
        #expect(receipt.result?["\(step)_stderr"] == "refused: \(step == "workers" ? "upgrade-workers" : "upgrade-supervisor --force") ")
        #expect(receipt.error?.contains("requested upgrade failed: \(step) (exit 42)") == true)
        #expect(receipt.result?["ok"] == "false")
        #expect(receipt.result?["failed_step"] == step)
        #expect(receipt.result?["\(step)_exit"] == "42")
        #expect(receipt.result?[step] == "failed")
        #expect(receipt.result?["target_changed"] == "true")
        #expect(receipt.result?["install_id"] == installID)
        #expect(receipt.result?["backup"]?.isEmpty == false)
        #expect(receipt.result?["recovery_record"]?.hasSuffix(installID + ".env") == true)
    }

    @MainActor @Test func aFailedRequestedWorkerUpgradeDoesNotCompleteTheInstall() async throws {
        let (host, rpc, request, receipt) = try await failingInstall(workers: true, supervisor: false)
        expectFailedStep(receipt, "workers", scriptExit: rpc.scriptExit, installID: request.installJobID)
        #expect(host.contents(host.target) == Self.failingRelayd)
    }

    @MainActor @Test func aFailedRequestedSupervisorUpgradeDoesNotCompleteTheInstall() async throws {
        let (host, rpc, request, receipt) = try await failingInstall(workers: false, supervisor: true)
        // The job itself succeeded; the supervisor step after it failed.
        expectFailedStep(receipt, "supervisor", scriptExit: rpc.scriptExit, installID: request.installJobID, jobExit: 0)
        #expect(receipt.result?["workers"] == "skipped")
        #expect(rpc.counts.jobs == 1 && rpc.counts.sessions == 1)
        #expect(host.contents(host.target) == Self.failingRelayd)
    }

    @MainActor @Test func aFailedRequestedSupervisorUpgradeDoesNotCompleteTheRollback() async throws {
        let host = try Host()
        // The relayd a rollback restores is the one whose supervisor upgrade fails.
        try Self.write(Self.failingRelayd, to: host.target, executable: true)
        let install = Self.install()
        try host.stage(install)
        #expect(try host.run(host.install(install))["ok"] == "true")
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        request.installID = install.installJobID
        request.upgradeSupervisor = true
        let rpc = ScriptHost(host)
        let receipt = try await approve(request, file: nil, on: rpc)
        expectFailedStep(receipt, "supervisor", scriptExit: rpc.scriptExit, installID: install.installJobID, jobExit: 0)
        #expect(receipt.error?.hasPrefix("relayd was rolled back") == true)
        #expect(rpc.counts.jobs == 1 && rpc.counts.sessions == 1)
        #expect(host.contents(host.target) == Self.failingRelayd)
    }

    @MainActor @Test func aRequestedUpgradeThatSucceedsLeavesTheInstallOk() async throws {
        let host = try Host()
        let local = try Self.write(Self.switchableRelayd, to: fixtureURL("relay-install-local-"))
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .install, host: "dandy-07")
        request.localPath = local.path
        request.sha256 = Self.sha256(Self.switchableRelayd)
        request.version = "0.5.4"
        request.upgradeSupervisor = true
        let rpc = ScriptHost(host)
        let receipt = try await approve(request, file: try RelayRemoteInstallRunner.inspect(local.path), on: rpc)
        #expect(receipt.status == "completed")
        #expect(receipt.result?["ok"] == "true" && receipt.result?["supervisor"] == "upgraded")
        #expect(receipt.result?["failed_step"] == nil && receipt.result?["target_changed"] == nil)
        #expect(receipt.result?["job_id"] == request.installJobID && receipt.result?["action"] == "install")
        // One host job installed relayd; the supervisor restarted after its receipt, in its own session.
        #expect(rpc.counts.jobs == 1 && rpc.counts.sessions == 1)
        #expect(host.contents(host.home.appendingPathComponent("calls")) == "upgrade-supervisor --force receipts=1\n")
    }

    /// Every combination of install job outcome, requested supervisor upgrade,
    /// direct session result and relayd replaced between the two steps.
    /// Safety: the supervisor restarts only after a job that installed relayd and
    /// either succeeded or failed only its worker upgrade, on the relayd that job
    /// installed, never inside the job; any other job failure skips it; an install
    /// completes only if every requested step did; a failed one never reports ok,
    /// and reports the supervisor upgraded only when that step succeeded.
    @MainActor @Test func theSupervisorRestartsOnlyAfterAnOkJobOnItsOwnRelayd() async throws {
        enum Job: CaseIterable { case ok, refusedUnchanged, refusedChanged }
        enum Session: CaseIterable { case ok, fails, noReceipt, unreachable }
        var states = 0
        for job in Job.allCases {
            for requested in [false, true] {
                for session in Session.allCases {
                    for replaced in [false, true] {
                        states += 1
                        let label = "\(job) requested=\(requested) \(session) replaced=\(replaced)"
                        let host = try Host()
                        let local = try Self.write(Self.switchableRelayd, to: fixtureURL("relay-install-local-"))
                        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .install, host: "dandy-07")
                        request.localPath = local.path
                        request.sha256 = Self.sha256(Self.switchableRelayd)
                        request.version = job == .refusedUnchanged ? "0.5.9" : "0.5.4"
                        request.upgradeWorkers = job == .refusedChanged
                        request.upgradeSupervisor = requested
                        if job == .refusedChanged { try Self.write("", to: host.home.appendingPathComponent("fail-workers")) }
                        if session == .fails { try Self.write("", to: host.home.appendingPathComponent("fail-supervisor")) }
                        let rpc = ScriptHost(host)
                        let jobCalls = CallsSeen()
                        let original = rpc.direct
                        rpc.direct = { script in
                            jobCalls.set(host.contents(host.home.appendingPathComponent("calls")))
                            if replaced { try Self.write(Self.switchableRelayd + "# another install\n", to: host.target, executable: true) }
                            switch session {
                            case .ok, .fails: return try await original(script)
                            case .noReceipt: return (255, "", "ssh: connection closed")
                            case .unreachable: throw RelayRemoteInstallError.failed("ssh: host unreachable")
                            }
                        }
                        let file = try RelayRemoteInstallRunner.inspect(local.path)
                        var result: [String: String]?
                        var refused: [String: String]?
                        do { result = try await RelayRemoteInstallRunner.perform(request, file: file, send: rpc.send, direct: rpc.direct) }
                        catch RelayRemoteInstallError.refused(_, let receipt) { refused = receipt }
                        catch {}
                        let calls = host.contents(host.home.appendingPathComponent("calls")) ?? ""
                        let restarted = calls.contains("upgrade-supervisor")
                        let reachesSession = (job == .ok || job == .refusedChanged) && requested
                        let shouldRestart = reachesSession && !replaced && (session == .ok || session == .fails)
                        let shouldComplete = job == .ok && (!requested || (session == .ok && !replaced))
                        #expect(restarted == shouldRestart, "\(label)")
                        #expect(rpc.counts.sessions == (reachesSession && (session == .ok || session == .fails) ? 1 : 0), "\(label)")
                        #expect(!(jobCalls.value ?? "").contains("upgrade-supervisor"), "\(label)")
                        if shouldRestart { #expect(calls.contains("upgrade-supervisor --force receipts=1"), "\(label)") }
                        #expect((result != nil) == shouldComplete, "\(label)")
                        if let result {
                            #expect(result["ok"] == "true" && result["supervisor"] == (requested ? "upgraded" : "skipped"), "\(label)")
                        }
                        if let refused {
                            // Only a workers-only failure followed by a successful supervisor step reports it upgraded.
                            let upgradedAfterWorkers = job == .refusedChanged && requested && session == .ok && !replaced
                            #expect(refused["ok"] != "true" && (refused["supervisor"] != "upgraded" || upgradedAfterWorkers), "\(label)")
                        }
                        // After an ok job, every supervisor failure still reports what was installed and how to undo it.
                        if reachesSession && !shouldComplete {
                            #expect(refused?["sha256"] == request.sha256 && refused?["backup"]?.isEmpty == false, "\(label)")
                            #expect(refused?["target_changed"] == "true" && refused?["install_id"] == request.installJobID, "\(label)")
                            #expect(refused?["recovery_record"]?.hasSuffix(request.installJobID + ".env") == true, "\(label)")
                        }
                        // A job that failed before changing relayd is reported as it was, with no supervisor step.
                        if job == .refusedUnchanged {
                            #expect(refused?["supervisor"] == nil && refused?["failed_step"] == nil, "\(label)")
                            #expect(refused?["error"]?.contains("not relayd 0.5.9") == true, "\(label)")
                        }
                        // A workers-only failure reports both steps' outcomes.
                        if job == .refusedChanged && requested {
                            let supervisorOk = session == .ok && !replaced
                            let expectedSupervisor = supervisorOk ? "upgraded"
                                : (session == .noReceipt || session == .unreachable) ? "unknown" : "failed"
                            #expect(refused?["supervisor"] == expectedSupervisor, "\(label)")
                            #expect(refused?["failed_step"] == (supervisorOk ? "workers" : "workers,supervisor"), "\(label)")
                            #expect(refused?["workers_exit"] == "42" && refused?["error"]?.contains("workers (exit 42)") == true, "\(label)")
                            if session == .fails && !replaced {
                                #expect(refused?["supervisor_exit"] == "42" && refused?["error"]?.contains("supervisor (exit 42)") == true, "\(label)")
                            }
                        }
                    }
                }
            }
        }
        #expect(states == 48)
    }

    /// Every direct session result and relayd replaced after a rollback that asks
    /// for the supervisor upgrade. Safety: the rollback completes only if the step
    /// succeeded on the relayd it restored; every other outcome is refused with
    /// what changed and the install's undo record.
    @MainActor @Test func aRollbackWhoseSupervisorStepFailsKeepsItsUndoRecord() async throws {
        enum Session: CaseIterable { case ok, fails, noReceipt, unreachable }
        var states = 0
        for session in Session.allCases {
            for replaced in [false, true] {
                states += 1
                let label = "rollback \(session) replaced=\(replaced)"
                let host = try Host()
                try Self.write(Self.switchableRelayd, to: host.target, executable: true)
                let install = Self.install()
                try host.stage(install)
                #expect(try host.run(host.install(install))["ok"] == "true", "\(label)")
                if session == .fails { try Self.write("", to: host.home.appendingPathComponent("fail-supervisor")) }
                var request = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
                request.installID = install.installJobID
                request.upgradeSupervisor = true
                let rpc = ScriptHost(host)
                let original = rpc.direct
                rpc.direct = { script in
                    if replaced { try Self.write(Self.switchableRelayd + "# another install\n", to: host.target, executable: true) }
                    switch session {
                    case .ok, .fails: return try await original(script)
                    case .noReceipt: return (255, "", "ssh: connection closed")
                    case .unreachable: throw RelayRemoteInstallError.failed("ssh: host unreachable")
                    }
                }
                var result: [String: String]?
                var refused: [String: String]?
                do { result = try await RelayRemoteInstallRunner.perform(request, file: nil, send: rpc.send, direct: rpc.direct) }
                catch RelayRemoteInstallError.refused(_, let receipt) { refused = receipt }
                catch {}
                let shouldComplete = session == .ok && !replaced
                #expect((result != nil) == shouldComplete, "\(label)")
                #expect(rpc.counts.jobs == 1, "\(label)")
                if let result {
                    #expect(result["ok"] == "true" && result["supervisor"] == "upgraded" && result["action"] == "rollback", "\(label)")
                }
                if !shouldComplete {
                    #expect(refused?["ok"] == "false" && refused?["supervisor"] != "upgraded", "\(label)")
                    #expect(refused?["target_changed"] == "true" && refused?["install_id"] == install.installJobID, "\(label)")
                    #expect(refused?["recovery_record"]?.hasSuffix(install.installJobID + ".env") == true, "\(label)")
                    #expect(refused?["backup"]?.isEmpty == false, "\(label)")
                }
            }
        }
        #expect(states == 8)
    }

    @Test func aRollbackSupervisorRestartIsDisclosedByTheApproval() throws {
        let object: [String: Any] = ["request_id": UUID().uuidString, "host": "dandy-07", "action": "rollback",
                                     "install_id": "install-" + UUID().uuidString.lowercased()]
        let quiet = try RelayRemoteInstallRequest.parse(object)
        #expect(!quiet.approval(size: nil).detail.localizedCaseInsensitiveContains("supervisor"))
        let loud = try RelayRemoteInstallRequest.parse(object.merging(["upgrade_supervisor": true]) { $1 })
        #expect(RelayRemoteInstallScript.rollback(loud).contains("upgrade_supervisor=1"))
        #expect(loud.approval(size: nil).detail.contains("The supervisor restarts on the restored relayd"))
    }

    @Test func requestsAcceptOnlyTheirOwnStrictFields() throws {
        let base: [String: Any] = ["host": "dandy-07", "request_id": Self.id.uuidString, "action": "install",
                                   "local_path": "/builds/relayd", "sha256": String(repeating: "a", count: 64)]
        let parsed = try RelayRemoteInstallRequest.parse(base)
        #expect(parsed.architecture == "amd64")
        #expect(!parsed.upgradeWorkers && !parsed.upgradeSupervisor && !parsed.allowSharedHome)
        #expect(parsed.installJobID == "install-" + Self.id.uuidString.lowercased())
        let invalid: [[String: Any]] = [
            base.merging(["command": "rm"]) { $1 },
            base.merging(["sha256": "ABC"]) { $1 },
            base.merging(["version": "0.5.4'; rm -rf ~; '"]) { $1 },
            base.merging(["architecture": "x86_64"]) { $1 },
            base.merging(["upgrade_workers": "yes"]) { $1 },
            base.merging(["host": "This Mac"]) { $1 },
            base.merging(["remote_directory": "/tmp"]) { $1 },
            base.filter { $0.key != "sha256" },
            ["host": "dandy-07", "request_id": Self.id.uuidString, "action": "rollback"],
            ["host": "dandy-07", "request_id": Self.id.uuidString, "action": "upload", "local_path": "/a", "remote_directory": "relative"],
        ]
        for object in invalid {
            #expect(throws: RelayRemoteInstallError.self) { _ = try RelayRemoteInstallRequest.parse(object) }
        }
    }

    @Test func theApprovalSheetSaysWhatTheInstallWillTouch() {
        let quiet = Self.install().approval(size: 12 << 20)
        #expect(quiet.title == "Install relayd on dandy-07?")
        #expect(quiet.detail.contains("Running workers are not touched"))
        #expect(quiet.detail.contains("the install stops without changing anything"))
        #expect(!quiet.detail.contains("supervisor"))
        let loud = Self.install { $0.upgradeWorkers = true; $0.allowSharedHome = true; $0.upgradeSupervisor = true }.approval(size: nil)
        #expect(loud.detail.contains("Running workers will be upgraded"))
        #expect(loud.detail.contains("The supervisor restarts on the new relayd"))
        #expect(loud.detail.contains("every host that mounts it gets this relayd"))
    }
}

/// Answers relayd host RPCs from memory and records each operation. Like
/// relayd it resolves `~/` to a home folder, names that folder when an upload
/// begins, and commits a colliding name as `stem (N)ext`.
private final class FakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var advance = true
    var stdout = Data()
    var exitCode: Int? = 0
    var collisions = 0
    var resolved: ((String) -> String)?
    var committedPath: String?

    var operations: [String] { lock.withLock { log.compactMap { $0["operation"] as? String } } }
    func request(_ operation: String) -> [String: Any]? { lock.withLock { log.last { $0["operation"] as? String == operation } } }

    private func directory(_ path: String) -> String {
        resolved?(path) ?? (path.hasPrefix("~/") ? "/home/fixture" + path.dropFirst(1) : path)
    }

    /// This fixture has no SSH session; a supervisor step would fail visibly.
    let direct: RelayRemoteInstallRunner.Direct = { _ in throw RelayRemoteInstallError.failed("no direct session in this fixture") }

    // Strong capture: a run that outlives its test must not touch a freed host.
    lazy var send: RelayRemoteInstallRunner.Send = { [self] payload in
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let result: [String: Any] = self.lock.withLock {
            self.log.append(object)
            let offset = self.log.filter { $0["operation"] as? String == "file_upload_chunk" }
                .compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0)?.count } }.reduce(0, +)
            let begin = self.log.first { $0["operation"] as? String == "file_upload_begin" } ?? [:]
            let folder = self.directory(begin["path"] as? String ?? "")
            switch object["operation"] as? String {
            case "file_upload_begin", "file_upload_chunk":
                return ["state": "receiving", "offset": self.advance ? offset : 0, "directory": folder]
            case "file_upload_commit":
                var name = begin["upload_name"] as? String ?? ""
                if self.collisions > 0 {
                    let ext = name.lastIndex(of: ".").map { String(name[$0...]) } ?? ""
                    name = "\(name.dropLast(ext.count)) (\(self.collisions))\(ext)"
                }
                return ["state": "committed", "offset": offset, "sha256": begin["upload_sha256"] ?? "",
                        "directory": folder, "path": self.committedPath ?? "\(folder)/\(name)"]
            case "file_upload_cancel":
                return ["state": "cancelled"]
            case "status":
                let from = (object["stdout_offset"] as? Int) ?? 0
                let half = min(self.stdout.count, from + 20)
                var job: [String: Any] = ["state": half == self.stdout.count ? "exited" : "running"]
                if half == self.stdout.count, let code = self.exitCode { job["exit_code"] = code }
                return ["stdout": self.stdout[from..<half].base64EncodedString(), "job": job]
            default:
                return ["state": "running"]
            }
        }
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }
}

@Suite("Remote relayd install runner")
struct RelayRemoteInstallRunnerTests {
    private func localFile(_ text: String) throws -> (String, RelayRemoteInstallRunner.LocalFile) {
        let url = fixtureURL("relay-runner-")
        try Data(text.utf8).write(to: url)
        return (url.path, try RelayRemoteInstallRunner.inspect(url.path))
    }

    private func upload(_ path: String, _ sha256: String? = nil) -> RelayRemoteInstallRequest {
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .upload, host: "dandy-07")
        request.localPath = path
        request.remoteDirectory = "/approved-directory"
        request.sha256 = sha256
        return request
    }

    @Test func anUploadNamesItsFolderAndCommitsTheVerifiedBytes() async throws {
        let host = FakeHost()
        let (path, file) = try localFile("relayd bytes")
        let remote = try await RelayRemoteInstallRunner.upload(path: path, name: "relayd", directory: "~/.local/share/relay/bin",
                                                               expected: file, jobID: "upload-x", send: host.send)
        #expect(remote == "/home/fixture/.local/share/relay/bin/relayd")
        #expect(host.operations == ["file_upload_begin", "file_upload_chunk", "file_upload_commit"])
        #expect(host.request("file_upload_begin")?["path"] as? String == "~/.local/share/relay/bin")
        #expect(host.request("file_upload_begin")?["upload_sha256"] as? String == file.sha256)
    }

    @Test func anUploadThatDoesNotAdvanceStopsInsteadOfLooping() async throws {
        let host = FakeHost()
        host.advance = false
        let (path, file) = try localFile("relayd bytes")
        await #expect(throws: RelayRemoteInstallError.failed("Upload upload-x did not advance; query it before resending")) {
            _ = try await RelayRemoteInstallRunner.upload(path: path, name: "relayd", directory: "/x",
                                                          expected: file, jobID: "upload-x", send: host.send)
        }
        #expect(host.operations.filter { $0 == "file_upload_chunk" }.count == 1)
        #expect(!host.operations.contains("file_upload_commit"))
    }

    @Test func aCommittedUploadPathOutsideTheApprovedFolderIsRejected() async throws {
        let host = FakeHost()
        host.committedPath = "/unapproved-directory/payload"
        let (path, file) = try localFile("approved upload bytes")
        await #expect(throws: RelayRemoteInstallError.self) {
            _ = try await RelayRemoteInstallRunner.upload(path: path, name: "payload", directory: "/approved-directory",
                                                          expected: file, jobID: "upload-x", send: host.send)
        }
        // The right folder with another file's name is outside the approval too.
        host.committedPath = "/approved-directory/other"
        await #expect(throws: RelayRemoteInstallError.self) {
            _ = try await RelayRemoteInstallRunner.upload(path: path, name: "payload", directory: "/approved-directory",
                                                          expected: file, jobID: "upload-y", send: host.send)
        }
    }

    @Test func aFolderRelaydResolvesElsewhereIsCancelledBeforeAnyByte() async throws {
        let host = FakeHost()
        host.resolved = { _ in "/maps/projects/elsewhere" }
        let (path, file) = try localFile("approved upload bytes")
        await #expect(throws: RelayRemoteInstallError.self) {
            _ = try await RelayRemoteInstallRunner.upload(path: path, name: "payload", directory: "/approved-directory",
                                                          expected: file, jobID: "upload-x", send: host.send)
        }
        #expect(host.operations == ["file_upload_begin", "file_upload_cancel"])
    }

    @Test func approvedFoldersAndCommittedNamesFollowRelayd() {
        #expect(RelayRemoteInstallRunner.isApproved("/home/u/.local/share/relay/bin", "~/.local/share/relay/bin"))
        #expect(RelayRemoteInstallRunner.isApproved("/data/x", "/data/x/"))
        #expect(!RelayRemoteInstallRunner.isApproved("/home/u/evil.local/share/relay/bin", "~/.local/share/relay/bin"))
        #expect(!RelayRemoteInstallRunner.isApproved("/home/u/.local/share/relay/bin/../../x/.local/share/relay/bin", "~/.local/share/relay/bin"))
        #expect(!RelayRemoteInstallRunner.isApproved("/data/x/y", "/data/x"))
        #expect(!RelayRemoteInstallRunner.isApproved("data/x", "data/x"))
        #expect(RelayRemoteInstallRunner.isCommittedName(" (1).relayd-install-a", for: ".relayd-install-a"))
        #expect(RelayRemoteInstallRunner.isCommittedName("relayd.tar (12).gz", for: "relayd.tar.gz"))
        #expect(RelayRemoteInstallRunner.isCommittedName("relayd", for: "relayd"))
        #expect(!RelayRemoteInstallRunner.isCommittedName("relayd (1000)", for: "relayd"))
        #expect(!RelayRemoteInstallRunner.isCommittedName("other", for: "relayd"))
    }

    @Test func anInstallRunsTheStageRelaydActuallyCommitted() async throws {
        let host = FakeHost()
        host.collisions = 1
        host.stdout = Data("{\"ok\":\"true\",\"job_id\":\"install-x\"}\n".utf8)
        let (path, file) = try localFile("relayd bytes")
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .install, host: "dandy-07")
        request.localPath = path
        request.sha256 = file.sha256
        _ = try await RelayRemoteInstallRunner.perform(request, file: file, send: host.send, direct: host.direct)
        let command = try #require(host.request("exec")?["command"] as? String)
        let committed = "/home/fixture/.local/share/relay/bin/ (1)" + RelayRemoteInstallScript.stagedName(request.installJobID)
        #expect(command.contains("staged='\(committed)'"))
    }

    @Test func aScriptReceiptIsReadAcrossStatusPages() async throws {
        let host = FakeHost()
        host.stdout = Data("noise\n{\"ok\":\"true\",\"job_id\":\"install-x\",\"workers\":\"skipped\"}\n".utf8)
        let receipt = try await RelayRemoteInstallRunner.run(script: "true", jobID: "install-x", send: host.send, sleep: { _ in })
        #expect(receipt == ["ok": "true", "job_id": "install-x", "workers": "skipped"])
        #expect(host.request("exec")?["job_id"] as? String == "install-x")
    }

    @Test func aScriptThatExitsNonZeroFailsWhateverItsReceiptSays() async throws {
        let ok = "{\"ok\":\"true\",\"job_id\":\"install-x\"}\n"
        for code in [1, nil] as [Int?] {
            let host = FakeHost()
            host.stdout = Data(ok.utf8)
            host.exitCode = code
            await #expect(throws: RelayRemoteInstallError.refused("install-x exited with status \(code.map(String.init) ?? "unknown")",
                                                                  receipt: ["ok": "true", "job_id": "install-x"])) {
                _ = try await RelayRemoteInstallRunner.run(script: "true", jobID: "install-x", send: host.send, sleep: { _ in })
            }
        }
        let host = FakeHost()
        host.stdout = Data("{\"ok\":\"false\",\"job_id\":\"install-x\",\"error\":\"refused\"}\n".utf8)
        await #expect(throws: RelayRemoteInstallError.refused("refused", receipt: ["ok": "false", "job_id": "install-x", "error": "refused"])) {
            _ = try await RelayRemoteInstallRunner.run(script: "true", jobID: "install-x", send: host.send, sleep: { _ in })
        }
    }

    @Test func aLocalBuildWithAnotherSHAIsNeverUploaded() async throws {
        let host = FakeHost()
        let (path, file) = try localFile("not the reviewed build")
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .install, host: "dandy-07")
        request.localPath = path
        request.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: RelayRemoteInstallError.self) {
            _ = try await RelayRemoteInstallRunner.perform(request, file: file, send: host.send, direct: host.direct)
        }
        #expect(host.operations.isEmpty)
    }

    @Test func anExplicitUploadSHAIsEnforcedBeforeAnyRPC() async throws {
        let host = FakeHost()
        let (path, file) = try localFile("approved upload bytes")
        await #expect(throws: RelayRemoteInstallError.self) {
            _ = try await RelayRemoteInstallRunner.perform(upload(path, String(repeating: "0", count: 64)), file: file, send: host.send, direct: host.direct)
        }
        #expect(host.operations.isEmpty)
        let receipt = try await RelayRemoteInstallRunner.perform(upload(path, file.sha256), file: file, send: host.send, direct: host.direct)
        #expect(receipt["path"] == "/approved-directory/" + (path as NSString).lastPathComponent)
        #expect(host.operations == ["file_upload_begin", "file_upload_chunk", "file_upload_commit"])
    }

    @MainActor @Test func aMismatchedSHAIsRefusedBeforeTheApprovalSheet() throws {
        let host = FakeHost()
        let (path, file) = try localFile("approved upload bytes")
        let request = upload(path, String(repeating: "0", count: 64))
        var shown = false
        let control = RelayRemoteInstallControl { _, _ in shown = true; return true }
        #expect(throws: RelayRemoteInstallError.self) { _ = try control.propose(request, file: file, send: host.send, direct: host.direct) }
        #expect(!shown)
        #expect(control.receipt(request.requestID) == nil)
        #expect(host.operations.isEmpty)
    }

    @MainActor @Test func nothingRunsUntilTheUserApproves() throws {
        let host = FakeHost()
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        request.installID = "install-" + UUID().uuidString.lowercased()
        let control = RelayRemoteInstallControl { _, completion in completion(.alertFirstButtonReturn); return true }
        let receipt = try control.propose(request, file: nil, send: host.send, direct: host.direct)
        #expect(receipt.status == "awaiting_approval")
        #expect(control.receipt(request.requestID)?.status == "cancelled")
        #expect(host.operations.isEmpty)
    }

    @MainActor @Test func anUnansweredApprovalClosesItselfAndFreesTheNextRequest() async throws {
        let host = FakeHost()
        var answers: [(NSApplication.ModalResponse) -> Void] = []
        var dismissed = 0
        let control = RelayRemoteInstallControl(present: { _, completion in answers.append(completion); return true },
                                                dismiss: { _ in dismissed += 1; answers.last?(.abort) },
                                                approvalWindow: 0.05)
        var first = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        first.installID = "install-" + UUID().uuidString.lowercased()
        _ = try control.propose(first, file: nil, send: host.send, direct: host.direct)
        for _ in 0..<200 where control.receipt(first.requestID)?.status == "awaiting_approval" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let expired = try #require(control.receipt(first.requestID))
        #expect(expired.status == "expired")
        #expect(expired.error?.contains("nothing was run") == true)
        #expect(dismissed == 1)
        // Approving the stale dialog afterwards runs nothing.
        answers[0](.alertSecondButtonReturn)
        #expect(control.receipt(first.requestID)?.status == "expired")
        // The next request is shown instead of being refused as blocked.
        var second = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        second.installID = "install-" + UUID().uuidString.lowercased()
        #expect(try control.propose(second, file: nil, send: host.send, direct: host.direct).status == "awaiting_approval")
        #expect(answers.count == 2)
        #expect(host.operations.isEmpty)
    }

    @MainActor @Test func theApprovalDialogSaysWhenApprovalEnds() {
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        request.installID = "install-" + UUID().uuidString.lowercased()
        let deadline = Date().addingTimeInterval(RelayRemoteInstallControl.approvalWindow)
        let time = DateFormatter.localizedString(from: deadline, dateStyle: .none, timeStyle: .short)
        let detail = request.approval(size: nil, deadline: deadline).detail
        #expect(detail.contains("Approve by \(time)."))
        #expect(!detail.contains("two minutes"))
        #expect(RelayRemoteInstallControl.approvalWindow >= 600)
    }

    @MainActor @Test func aFailedScriptDoesNotBecomeACompletedControlReceipt() async throws {
        let host = FakeHost()
        host.stdout = Data("{\"ok\":\"false\",\"job_id\":\"fixture\",\"error\":\"blocked by fixture shared-storage gate\"}\n".utf8)
        host.exitCode = 1
        var request = RelayRemoteInstallRequest(requestID: UUID(), action: .rollback, host: "dandy-07")
        request.installID = "install-" + UUID().uuidString.lowercased()
        let control = RelayRemoteInstallControl { _, completion in completion(.alertSecondButtonReturn); return true }
        _ = try control.propose(request, file: nil, send: host.send, direct: host.direct)
        // The runner polls the job every 500 ms, so wait in time, not in yields.
        for _ in 0..<1000 {
            if let status = control.receipt(request.requestID)?.status, status == "completed" || status == "failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receipt = try #require(control.receipt(request.requestID))
        #expect(receipt.status == "failed")
        #expect(receipt.error == "blocked by fixture shared-storage gate")
        #expect(receipt.result?["ok"] == "false")
        #expect(receipt.result?["error"] == "blocked by fixture shared-storage gate")
    }
}
