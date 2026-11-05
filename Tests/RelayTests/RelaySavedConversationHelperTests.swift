import Foundation
import Testing
@testable import Relay

// The recovery helper runs a saved conversation only when it is at least as
// new as the installed relayd. On dandy-07 (2026-10-30) a 0.5.3 helper from
// Oct 8 refused every ~/.claude-team transcript the installed 0.5.6 accepts.

@Suite("RelaySavedConversationHelper")
struct RelaySavedConversationHelperTests {
    static let remote = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07")

    @Test("The helper is used only when both versions are known and it is not older")
    func decision() {
        let cases: [(String, Bool)] = [
            ("helper:relayd 0.5.3\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6\ninstalled:relayd 0.5.6\n", true),
            ("helper:relayd 0.6.0\ninstalled:relayd 0.5.6\n", true),
            ("helper:relayd 0.10.0\ninstalled:relayd 0.9.9\n", true),
            ("helper:relayd 0.9.9\ninstalled:relayd 0.10.0\n", false),
            ("helper:relayd 1.0.0\ninstalled:relayd 0.99.99\n", true),
            ("helper:\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6\ninstalled:\n", false),
            ("helper:relayd reexec-next\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6-dev\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.6\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6.1\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6\nhelper:relayd 0.5.6\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 0.5.6\ninstalled:relayd 0.5.6\ninstalled:relayd 0.5.6\n", false),
            ("installed:relayd 0.5.6\nhelper:relayd 0.5.6\n", true),
            ("", false),
            ("helper: relayd 0.5.6\ninstalled:relayd 0.5.6\n", false),
            ("helper:relayd 00.5.6\ninstalled:relayd 0.5.6\n", true),
            ("helper:relayd 1234567.0.0\ninstalled:relayd 0.5.6\n", false),
        ]
        for (probe, expected) in cases {
            #expect(RelaySavedConversationRecovery.helperIsCurrent(probe: probe) == expected, "\(probe.debugDescription)")
        }
    }

    @Test("Commands name the helper only when the plan came from it")
    func commands() throws {
        let pane = "4b3c6f80-bdbb-493c-8c18-089cd64d67b6", session = "f849a11d-46d9-456a-9886-b9511ae73e88"
        var plan = RelaySavedConversationPlan(paneID: pane, provider: "claude", sessionID: session,
            directory: "/maps/projects/caeg/people/kbd606/rice", bindingSHA: String(repeating: "b", count: 64))
        let installed = try plan.command(profile: Self.remote)
        #expect(!installed.contains("relayd-recovery"))
        #expect(installed.hasPrefix("\"$HOME/.local/bin/relayd\" 'resume-saved' '\(pane)' '\(session)'"))
        plan.useRecoveryHelper = true
        let helper = try plan.command(profile: Self.remote)
        #expect(helper.contains("\"$HOME/.local/share/relay/bin/relayd-recovery\" 'resume-saved' '\(pane)'"))
        #expect(helper.contains("else \"$HOME/.local/bin/relayd\" 'resume-saved'"))
        let decoded = try JSONDecoder().decode(RelaySavedConversationPlan.self, from: Data(
            #"{"pane_id":"\#(pane)","provider":"claude","session_id":"\#(session)","directory":"/","binding_sha":"\#(String(repeating: "c", count: 64))","useRecoveryHelper":true}"#.utf8))
        #expect(decoded.useRecoveryHelper == false)
    }

    /// The plan is read by the binary the probe chose, and its start command
    /// uses that same binary.
    @Test("A plan comes from, and starts through, the binary the probe chose")
    func planFollowsTheProbe() async throws {
        let pane = UUID(uuidString: "4b3c6f80-bdbb-493c-8c18-089cd64d67b6")!
        let json = #"{"pane_id":"4b3c6f80-bdbb-493c-8c18-089cd64d67b6","provider":"claude","session_id":"f849a11d-46d9-456a-9886-b9511ae73e88","directory":"/maps/projects/caeg/people/kbd606/rice","binding_sha":"\#(String(repeating: "d", count: 64))"}"#
        final class Log: @unchecked Sendable { var commands: [String] = [] }
        for (probe, helper) in [("helper:relayd 0.5.3\ninstalled:relayd 0.5.6\n", false),
                                ("helper:relayd 0.5.6\ninstalled:relayd 0.5.6\n", true),
                                ("helper:\ninstalled:relayd 0.5.6\n", false)] {
            let log = Log()
            let plan = try await RelaySavedConversationRecovery.plan(profile: Self.remote, paneID: pane) { _, command in
                log.commands.append(command)
                let out = log.commands.count == 1 ? probe : json
                return RelayHostExecution.Output(stdout: Data(out.utf8), stderr: Data(), exitCode: 0, jobID: "job")
            }
            #expect(log.commands.count == 2)
            #expect(log.commands.first == RelaySavedConversationRecovery.versionProbeCommand(profile: Self.remote))
            #expect(log.commands.last?.contains("relayd-recovery\" 'resume-plan'") == helper)
            #expect(plan.useRecoveryHelper == helper)
            #expect(try plan.command(profile: Self.remote).contains("relayd-recovery") == helper)
        }
        // A failed probe falls back to the installed relayd.
        let log = Log()
        let plan = try await RelaySavedConversationRecovery.plan(profile: Self.remote, paneID: pane) { _, command in
            log.commands.append(command)
            if log.commands.count == 1 { throw RemoteCatalogError.invalidResponse }
            return RelayHostExecution.Output(stdout: Data(json.utf8), stderr: Data(), exitCode: 0, jobID: "job")
        }
        #expect(!plan.useRecoveryHelper && log.commands.last?.contains("relayd-recovery") == false)
    }

    /// Runs the real probe through /bin/sh against fake binaries in a fake HOME.
    @Test("The probe reports each binary's first version line, or nothing")
    func probeShell() throws {
        func run(helper: String?, installed: String?) throws -> String {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            func install(_ relative: String, _ script: String) throws {
                let url = home.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            if let helper { try install(".local/share/relay/bin/relayd-recovery", helper) }
            if let installed { try install(".local/bin/relayd", installed) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", RelaySavedConversationRecovery.versionProbeCommand(profile: Self.remote)]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let stale = try run(helper: "echo 'relayd 0.5.3'", installed: "echo 'relayd 0.5.6'")
        #expect(stale == "helper:relayd 0.5.3\ninstalled:relayd 0.5.6\n")
        #expect(!RelaySavedConversationRecovery.helperIsCurrent(probe: stale))
        let current = try run(helper: "printf 'relayd 0.5.7\\nextra\\n'", installed: "echo 'relayd 0.5.6'")
        #expect(current == "helper:relayd 0.5.7\ninstalled:relayd 0.5.6\n")
        #expect(RelaySavedConversationRecovery.helperIsCurrent(probe: current))
        let absent = try run(helper: nil, installed: "echo 'relayd 0.5.6'")
        #expect(absent == "helper:\ninstalled:relayd 0.5.6\n")
        let failing = try run(helper: "exit 3", installed: "echo 'relayd 0.5.6'")
        #expect(failing == "helper:\ninstalled:relayd 0.5.6\n")
        let injected = try run(helper: "printf 'relayd 9.9.9\\ninstalled:relayd 0.0.1\\n'", installed: "echo 'relayd 0.5.6'")
        #expect(injected == "helper:relayd 9.9.9\ninstalled:relayd 0.5.6\n")
    }
}

/// Seeded fuzz target for the probe parser (output of another host's
/// binaries). Properties: the decision equals an independent oracle; a
/// rendered version parses back to itself; every accepted version line is
/// canonical up to leading zeros; truncated version lines never parse to the
/// original version. Seeds are fixed; add found crashers to `regressions`.
@Suite("RelaySavedConversationProbeFuzz")
struct RelaySavedConversationProbeFuzzTests {
    static let seeds: [UInt64] = [1, 0x5eed_0030_1031, 0xdead_beef, 0x31be_9c00_0093_fa42]
    static let regressions = [
        "", "\n", "helper:", "installed:", "helper:relayd ..\ninstalled:relayd ..",
        "helper:relayd 0.0.0\ninstalled:relayd 0.0.0", "helper:relayd 999999.999999.999999\ninstalled:relayd 0.0.0",
        "helper:relayd +1.0.0\ninstalled:relayd 0.0.0", "helper:relayd ٣.0.0\ninstalled:relayd 0.0.0",
        "helper:relayd 1.0.0\r\ninstalled:relayd 0.0.0", "helper:relayd 1.0.0 \ninstalled:relayd 0.0.0",
        "helper:relayd 0.5.6\u{0}\ninstalled:relayd 0.5.6", String(repeating: "helper:relayd 1.1.1\n", count: 2000),
        // Mutant H4 (2026-10-30): two or four components must not parse.
        "helper:relayd 1.2\ninstalled:relayd 0.0.0", "helper:relayd 1.2.3.4\ninstalled:relayd 0.0.0",
    ]

    static func oracleVersion<S: StringProtocol>(_ text: S) -> [Int]? {
        let bytes = Array(text.utf8)
        let prefix = Array("relayd ".utf8)
        guard bytes.count <= 64, bytes.count > prefix.count, Array(bytes.prefix(prefix.count)) == prefix else { return nil }
        var parts: [[UInt8]] = [[]]
        for b in bytes.dropFirst(prefix.count) {
            if b == UInt8(ascii: ".") { parts.append([]) } else { parts[parts.count - 1].append(b) }
        }
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            out.append(p.reduce(0) { $0 * 10 + Int($1 - 48) })
        }
        return out
    }

    static func oracle(_ probe: String) -> Bool {
        var helpers: [Substring] = [], installs: [Substring] = []
        for line in probe.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("helper:") { helpers.append(line.dropFirst(7)) }
            else if line.hasPrefix("installed:") { installs.append(line.dropFirst(10)) }
        }
        guard helpers.count == 1, installs.count == 1,
              let h = oracleVersion(helpers[0]), let i = oracleVersion(installs[0]) else { return false }
        for k in 0..<3 where h[k] != i[k] { return h[k] > i[k] }
        return true
    }

    @Test("Decision matches the oracle; versions round trip; truncation refused")
    func probe() {
        let alphabet = Array("relayd helper:installed:0123456789.\n -x\r٣".unicodeScalars)
        var cases = 0
        for seed in Self.seeds {
            var rng = SplitMix64(state: seed)
            for _ in 0..<2000 {
                let v = (0..<3).map { _ in rng.below(1_000_000) }
                let line = "relayd " + v.map(String.init).joined(separator: ".")
                #expect(RelaySavedConversationRecovery.version(Substring(line)) == v)
                let cut = line.unicodeScalars.count - 1 - rng.below(line.unicodeScalars.count - 1)
                let truncated = String(String.UnicodeScalarView(line.unicodeScalars.prefix(cut)))
                #expect(RelaySavedConversationRecovery.version(Substring(truncated)) != v)
                let w = (0..<3).map { _ in rng.below(20) }
                let pair = "helper:relayd \(v.map(String.init).joined(separator: "."))\ninstalled:relayd \(w.map(String.init).joined(separator: "."))\n"
                #expect(RelaySavedConversationRecovery.helperIsCurrent(probe: pair) == Self.oracle(pair))
                var junk = ""
                for _ in 0..<rng.below(80) { junk.unicodeScalars.append(alphabet[rng.below(alphabet.count)]) }
                // Well-formed digit groups with 1-5 components: only three parse.
                let groups = (0..<(1 + rng.below(5))).map { _ in String(rng.below(1000)) }
                Self.check("helper:relayd \(groups.joined(separator: "."))\ninstalled:relayd 0.0.0\n")
                Self.check(junk)
                Self.check(pair + junk)
                cases += 1
            }
        }
        Self.regressions.forEach(Self.check)
        #expect(cases == Self.seeds.count * 2000)
    }

    static func check(_ probe: String) {
        #expect(RelaySavedConversationRecovery.helperIsCurrent(probe: probe) == oracle(probe), "\(probe.debugDescription)")
        for line in probe.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(RelaySavedConversationRecovery.version(line) == oracleVersion(line))
        }
    }
}
