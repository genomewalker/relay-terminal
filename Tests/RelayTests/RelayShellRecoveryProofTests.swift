import Foundation
import Testing
@testable import Relay

@Suite struct RelayShellRecoveryProofTests {
    static let pane = UUID(uuidString: "0F0E0D0C-1111-2222-3333-444455556666")!

    static func input(workerPID: Int = 100, workerStart: String = "5000",
                      shellPID: Int = 200, shellStart: String = "6000") -> RelayShellRecoveryInput {
        RelayShellRecoveryInput(instance: UUID(), requestID: UUID(), text: "claude", workerPID: workerPID,
                                workerStart: workerStart, shellPID: shellPID, shellStart: shellStart)
    }

    @Test func builderInterpolatesOnlyValidatedValues() throws {
        let command = try #require(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input()))
        #expect(command.contains("RELAY_PROOF_PANE=0f0e0d0c-1111-2222-3333-444455556666 "))
        #expect(command.contains("RELAY_PROOF_WORKER=100 RELAY_PROOF_WORKER_START=5000 "))
        #expect(command.contains("RELAY_PROOF_SHELL=200 RELAY_PROOF_SHELL_START=6000 "))
        #expect(command.contains("RELAY_PROOF_PROC=/proc\n"))
        #expect(!command.contains("python"))
        // UInt64 accepts these, but they are not canonical /proc start times.
        for start in ["+5", "5;id", "", "5 6", "$(id)", "123456789012345678901"] {
            #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(workerStart: start)) == nil)
            #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(shellStart: start)) == nil)
        }
        #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(workerPID: 1)) == nil)
        #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(shellPID: -5)) == nil)
        #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(), procRoot: "/x y") == nil)
        #expect(RelayShellRecoveryProof.command(paneID: Self.pane, input: Self.input(), procRoot: "proc") == nil)
        #expect(!RelayShellRecoveryProof.awkProgram.contains("'"), "the awk program is single-quoted in sh")
    }

    /// One fixture host: a HOME with the worker manifest and a /proc stand-in.
    final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("proof-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.local/state/relay/workers"),
                                                    withIntermediateDirectories: true)
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("awk").path,
                                                       withDestinationPath: "/usr/bin/awk")
            // GNU readlink prints the raw target plus one newline.
            let readlink = bin.appendingPathComponent("readlink")
            try Data("#!/bin/sh\nexec /usr/bin/perl -e '$t = readlink($ARGV[0]); defined $t or exit 1; print \"$t\\n\"' \"$1\"\n".utf8)
                .write(to: readlink)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readlink.path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        static func stat(pid: Int, comm: String, ppid: Int, tpgid: Int, start: String, fields: Int = 52) -> Data {
            var text = "\(pid) (\(comm)) S \(ppid) \(pid) \(pid) 34816 \(tpgid)"
            for index in 6..<fields { text += index == 19 ? " \(start)" : " \(index)" }
            return Data((text + "\n").utf8)
        }

        func run(manifest: String = #"{"worker_pid": 100, "shell_pid": 200}"#, manifestData: Data? = nil,
                 worker: Data = stat(pid: 100, comm: "relay-worker", ppid: 1, tpgid: -1, start: "5000"),
                 shell: Data = stat(pid: 200, comm: "ba) sh)) x", ppid: 100, tpgid: 200, start: "6000"),
                 executable: String = "/usr/bin/bash") throws -> String {
            let proc = root.appendingPathComponent("proc")
            try? FileManager.default.removeItem(at: proc)
            for (pid, data) in [(100, worker), (200, shell)] {
                let directory = proc.appendingPathComponent(String(pid))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("stat"))
            }
            try FileManager.default.createSymbolicLink(atPath: proc.appendingPathComponent("200/exe").path,
                                                       withDestinationPath: executable)
            try (manifestData ?? Data(manifest.utf8)).write(to: root.appendingPathComponent(
                "home/.local/state/relay/workers/0f0e0d0c-1111-2222-3333-444455556666.json"))
            let command = try #require(RelayShellRecoveryProof.command(paneID: RelayShellRecoveryProofTests.pane,
                input: RelayShellRecoveryProofTests.input(), procRoot: proc.path))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": root.appendingPathComponent("home").path,
                                   "PATH": root.appendingPathComponent("bin").path + ":/bin"]
            // Output goes to a file, never a pipe drained against a wall clock,
            // so a loaded full-suite run cannot fail a correct proof.
            let capture = root.appendingPathComponent("stdout")
            FileManager.default.createFile(atPath: capture.path, contents: nil)
            let output = try FileHandle(forWritingTo: capture)
            defer { try? output.close() }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            // Only a hang trips this generous watchdog; it is not a drain limit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: try Data(contentsOf: capture), as: UTF8.self)
        }
    }

    static let verified = #"{"verified": true, "pane_id": "0f0e0d0c-1111-2222-3333-444455556666"}"# + "\n"
    static let refused = #"{"verified": false, "pane_id": "0f0e0d0c-1111-2222-3333-444455556666"}"# + "\n"

    @Test func provesTheRetainedShellAndItsWorker() throws {
        let fixture = try Fixture()
        #expect(try fixture.run() == Self.verified)
        let output = try fixture.run()
        let proof = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(proof["verified"] as? Bool == true)
        #expect(proof["pane_id"] as? String == "0f0e0d0c-1111-2222-3333-444455556666")
        // Field 19 after the last ')': comm may hold spaces, ')' and a newline.
        #expect(try fixture.run(shell: Fixture.stat(pid: 200, comm: "b\nash) 1 2", ppid: 100, tpgid: 200, start: "6000")) == Self.verified)
        #expect(try fixture.run(shell: Fixture.stat(pid: 200, comm: "bä)sh", ppid: 100, tpgid: 200, start: "6000")) == Self.verified)
        #expect(try fixture.run(shell: Fixture.stat(pid: 200, comm: "bash", ppid: 100, tpgid: 200, start: "6000", fields: 20)) == Self.verified)
        #expect(try fixture.run(manifest: #"{"worker_pid": 1, "shell_pid": 200, "worker_pid": 100}"#) == Self.verified)
        #expect(try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": 200}"#) == Self.verified)
        #expect(try fixture.run(manifest: #" {"a": [1, -2.5e3, NaN, -Infinity, true, null, {"b": "q\"\\\/\b\f\n\r\té"}], "worker_pid": 100, "shell_pid": 200} "#) == Self.verified)
    }

    @Test func refusesEveryMismatch() throws {
        let fixture = try Fixture()
        func stat(_ pid: Int, comm: String = "bash", ppid: Int, tpgid: Int, start: String, fields: Int = 52) -> Data {
            Fixture.stat(pid: pid, comm: comm, ppid: ppid, tpgid: tpgid, start: start, fields: fields)
        }
        let cases: [(String, String)] = [
            ("worker start", try fixture.run(worker: stat(100, ppid: 1, tpgid: -1, start: "5001"))),
            ("shell start", try fixture.run(shell: stat(200, ppid: 100, tpgid: 200, start: "6001"))),
            ("start prefix", try fixture.run(shell: stat(200, ppid: 100, tpgid: 200, start: "06000"))),
            ("shell parent", try fixture.run(shell: stat(200, ppid: 101, tpgid: 200, start: "6000"))),
            ("foreground group", try fixture.run(shell: stat(200, ppid: 100, tpgid: 201, start: "6000"))),
            ("19 fields", try fixture.run(shell: stat(200, ppid: 100, tpgid: 200, start: "6000", fields: 19))),
            ("no paren", try fixture.run(shell: Data("200 bash S 100 200 200 1 200\n".utf8))),
            ("invalid UTF-8", try fixture.run(shell: Data("200 (b".utf8) + Data([0xff]) + stat(200, ppid: 100, tpgid: 200, start: "6000").dropFirst(9))),
            ("zsh", try fixture.run(executable: "/usr/bin/zsh")),
            ("deleted", try fixture.run(executable: "/usr/bin/bash (deleted)")),
            ("trailing newline", try fixture.run(executable: "/usr/bin/bash\n")),
            ("manifest worker", try fixture.run(manifest: #"{"worker_pid": 101, "shell_pid": 200}"#)),
            ("manifest shell", try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": 201}"#)),
            ("missing shell", try fixture.run(manifest: #"{"worker_pid": 100}"#)),
            ("duplicate", try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": 200, "worker_pid": 1}"#)),
            ("string PID", try fixture.run(manifest: #"{"worker_pid": "100", "shell_pid": 200}"#)),
            ("nested only", try fixture.run(manifest: #"{"x": {"worker_pid": 100}, "shell_pid": 200}"#)),
            ("trailing comma", try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": 200,}"#)),
            ("extra data", try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": 200} x"#)),
            ("array", try fixture.run(manifest: #"[{"worker_pid": 100, "shell_pid": 200}]"#)),
            ("raw control", try fixture.run(manifest: "{\"a\": \"\t\", \"worker_pid\": 100, \"shell_pid\": 200}")),
            ("bad escape", try fixture.run(manifest: #"{"a": "\x", "worker_pid": 100, "shell_pid": 200}"#)),
            ("leading zero", try fixture.run(manifest: #"{"a": 01, "worker_pid": 100, "shell_pid": 200}"#)),
            ("BOM", try fixture.run(manifest: "\u{FEFF}" + #"{"worker_pid": 100, "shell_pid": 200}"#)),
            ("list PID", try fixture.run(manifest: #"{"worker_pid": 100, "shell_pid": [200]}"#)),
            ("float PID", try fixture.run(manifest: #"{"worker_pid": 100.0, "shell_pid": 200}"#)),
            ("xbash", try fixture.run(executable: "/usr/bin/xbash")),
            ("manifest invalid UTF-8", try fixture.run(manifestData: Data(#"{"a": ""#.utf8) + Data([0xFF]) +
                Data(#"", "worker_pid": 100, "shell_pid": 200}"#.utf8))),
        ]
        for (name, output) in cases { #expect(output == Self.refused, "\(name)") }
    }
}
