import Foundation
import Testing
@testable import Relay

/// relay_launch_agent: validation before creation, shell quoting, idempotent
/// replay, and the mapping of observations onto the four receipt stages.
@MainActor @Suite("MCP launch agent")
struct MCPLaunchAgentTests {
    typealias F = MCPTabMoveTests

    static let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
    static let brief = Data("Review the parser and report findings.\n".utf8)

    static func body(_ instance: UUID, _ request: UUID, provider: String = "claude", model: String = "claude-opus-4.1",
                     extra: [String: String] = [:]) -> Data {
        var object = ["instance": instance.uuidString, "requestID": request.uuidString, "host": "This Mac",
                      "cwd": "/tmp/project", "provider": provider, "model": model, "account": "personal",
                      "briefPath": "/tmp/brief.md"]
        object.merge(extra) { $1 }
        return F.body(object)
    }

    /// Records every start; never touches a real host or types anything.
    final class Probe {
        var starts: [(UUID, String)] = []
        var bindingReads = 0
        /// The shell's command markers the handler reads; nil = unreadable.
        var command: (producer: UUID, observation: TerminalSemanticPromptStateTracker.CommandObservation)? =
            (UUID(), .init(executions: 0, completedExecutions: 0, exitStatus: nil, integrationSeen: false))
        var bindNow = false
        var transcript = Data()
    }

    static func environment(_ probe: Probe, host: ConnectionProfile? = .local,
                            account: RelayAgentAccount? = personal, launcher: String? = nil,
                            directory: Bool = true, brief: Result<Data, Error> = .success(brief),
                            startRefusal: String? = nil) -> MCPLaunchAgentRequests.Environment {
        MCPLaunchAgentRequests.Environment(
            resolveHost: { _ in host },
            resolveAccount: { _, provider, label in account.flatMap { $0.provider == provider && $0.label == label ? $0 : nil } },
            launcherRefusal: { _, _ in launcher },
            isDirectory: { _, _ in directory },
            readFile: { _, _, _ in try brief.get() },
            readPrefix: { _, _, _ in probe.transcript },
            start: { pane, command, _, authorized, willSend in
                guard authorized() else { return "not authorized" }
                if startRefusal == nil { willSend() }
                probe.starts.append((pane.id, command))
                return startRefusal
            },
            readBinding: { _, paneID, _ in
                probe.bindingReads += 1
                guard probe.bindNow else { return .unavailable("no verified agent yet") }
                return .bound(["version": 1, "session_id": "sess-1", "transcript_path": "/t/sess-1.jsonl",
                               "producer": ["pane_id": paneID.uuidString.lowercased(), "provider": "claude",
                                            "process_id": 4242, "config_dir": "~/.claude-personal"]])
            },
            screen: { _ in "Error: model not found\n$ " },
            accountLabel: { _, _, directory in directory == "~/.claude-personal" ? "personal" : nil },
            commandState: { _ in probe.command },
            launchBudget: .milliseconds(60), observeBudget: .milliseconds(30), pollInterval: .milliseconds(10))
    }

    static func receipt(_ response: RelaySidePanelHTTPResponse) -> MCPLaunchAgentReceipt? {
        try? JSONDecoder().decode(MCPLaunchAgentReceipt.self, from: response.body)
    }

    // MARK: - Shell quoting

    static func sh(_ command: String, environment: [String: String] = [:]) throws -> (status: Int32, out: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let hostile = ["plain", "with space", "it's", "'", "''", "a\"b", "$(touch /tmp/relay-pwned)", "`id`",
                          "$HOME", "back\\slash", "bang!x", "!!", "!$", "*", "line\nbreak", "tab\there", "-n", "; rm -rf ~", "trailing\n"]

    @Test func quoteRoundTripsHostileValuesThroughPOSIXShell() throws {
        for value in Self.hostile {
            let result = try Self.sh("printf '%s' " + MCPLaunchAgentCommand.quote(value))
            #expect(result.status == 0)
            #expect(result.out == value, "quoted \(value.debugDescription) came back as \(result.out.debugDescription)")
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/relay-pwned"))
    }

    /// The whole typed command, run by /bin/sh against a stub launcher in a
    /// private HOME: the exact cwd, account variable, model flag and brief
    /// reach the provider as separate arguments, whatever the paths contain.
    @Test func launchCommandPassesHostileValuesExactly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shims = root.appendingPathComponent(".local/share/relay/shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        let out = root.appendingPathComponent("out")
        for provider in ["claude", "codex"] {
            let stub = shims.appendingPathComponent(provider)
            try ("#!/bin/sh\n{ pwd; printf '%s\\n' \"${CLAUDE_CONFIG_DIR-unset}\" \"${CODEX_HOME-unset}\"; " +
                 "for a in \"$@\"; do printf '<%s>\\n' \"$a\"; done; } > \"$RELAY_TEST_OUT\"\n").write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        }
        let cwd = root.appendingPathComponent("dir with 'quote' $(x) `y` \"z\" !! !-1")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let briefURL = root.appendingPathComponent("brief $(rm -rf ~) 'q' !x.md")
        let content = "Fix \"it\"; then $(id) `id` and 'quotes'\nsecond line \\ end"
        try (content + "\n\n").write(to: briefURL, atomically: true, encoding: .utf8)
        let environment = ["HOME": root.path, "RELAY_TEST_OUT": out.path, "CODEX_HOME": "/should/be/unset"]

        let claude = try #require(MCPLaunchAgentCommand.build(account: Self.personal, model: "claude-opus-4.1",
                                                              cwd: cwd.path, briefPath: briefURL.path))
        // No path sits inside double quotes, where interactive history expansion acts on `!`.
        #expect(claude.contains("relay_brief=$(cat -- '") && !claude.contains("\"$(cat"))
        var result = try Self.sh(claude, environment: environment)
        #expect(result.status == 0)
        var lines = try String(contentsOf: out, encoding: .utf8)
        let resolvedCwd = cwd.resolvingSymlinksInPath().path
        #expect(lines.hasPrefix(resolvedCwd + "\n") || lines.hasPrefix(cwd.path + "\n"))
        #expect(lines.contains("\n" + root.path + "/.claude-personal\n"))
        #expect(lines.hasSuffix("<--model>\n<claude-opus-4.1>\n<" + content + ">\n"))

        // Codex default account: CODEX_HOME is unset, never inherited.
        let codex = RelayAgentAccount(provider: "codex", label: "work", dir: "")
        let codexCommand = try #require(MCPLaunchAgentCommand.build(account: codex, model: "gpt-5.1-codex",
                                                                    cwd: cwd.path, briefPath: briefURL.path))
        #expect(codexCommand.contains("exec env -u CODEX_HOME \"$HOME\"/.local/share/relay/shims/codex -m 'gpt-5.1-codex' \"$relay_brief\""))
        result = try Self.sh(codexCommand, environment: environment)
        #expect(result.status == 0)
        lines = try String(contentsOf: out, encoding: .utf8)
        #expect(lines.contains("\nunset\n<-m>\n<gpt-5.1-codex>\n<" + content + ">\n"))

        // A brief changed into an option, emptied, or unreadable never launches.
        for (name, bytes) in [("dash", "--dangerously-skip-permissions"), ("empty", "")] {
            try? FileManager.default.removeItem(at: out)
            let bad = root.appendingPathComponent(name)
            try bytes.write(to: bad, atomically: true, encoding: .utf8)
            let command = try #require(MCPLaunchAgentCommand.build(account: Self.personal, model: "opus", cwd: cwd.path, briefPath: bad.path))
            #expect(try Self.sh(command, environment: environment).status == Int32(MCPLaunchAgentCommand.launchFailureExitCode))
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(name) brief launched the provider")
        }
        for (dir, brief) in [(root.appendingPathComponent("missing").path, briefURL.path), (cwd.path, root.path + "/missing.md")] {
            let command = try #require(MCPLaunchAgentCommand.build(account: Self.personal, model: "opus", cwd: dir, briefPath: brief))
            #expect(try Self.sh(command, environment: environment).status == Int32(MCPLaunchAgentCommand.launchFailureExitCode))
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func commandBuilderRefusesUnsafeValues() {
        for (model, cwd, brief) in [("op us", "/p", "/b"), ("$(id)", "/p", "/b"), ("opus", "p", "/b"), ("opus", "/p\nx", "/b"),
                                    ("opus", "/p", "/b\r"), ("Opus", "/p", "/b")] {
            #expect(MCPLaunchAgentCommand.build(account: Self.personal, model: model, cwd: cwd, briefPath: brief) == nil)
        }
        #expect(MCPLaunchAgentCommand.build(account: Self.personal, model: "opus", cwd: "/" + String(repeating: "a", count: 4000),
                                            briefPath: "/" + String(repeating: "b", count: 4000)) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data("-p do it".utf8)) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data("  \n".utf8)) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data("resume\n".utf8)) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data([0x61, 0x00, 0x62])) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data([0xff, 0xfe])) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Data(repeating: 0x61, count: (64 << 10) + 1)) != nil)
        #expect(MCPLaunchAgentCommand.briefRefusal(Self.brief) == nil)
    }

    // MARK: - Validation and refusal with nothing created

    @Test func proposalDecodingIsExact() {
        let instance = UUID(), request = UUID()
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request)) != nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["command": "claude"])) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, provider: "gemini")) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, model: "a b")) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["cwd": "/a\nb"])) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["briefPath": "~/b.md"])) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request,
            extra: ["targetPaneID": UUID().uuidString, "anchorTabID": UUID().uuidString])) == nil)
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["anchorPaneID": UUID().uuidString])) != nil)
    }

    @Test func everyRefusalCreatesNothingAndLeavesRequestIDUnused() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let instance = UUID(), request = UUID()
        let refusals: [(String, MCPLaunchAgentRequests.Environment, Int)] = {
            let p = Probe()
            struct Unreadable: Error {}
            return [
                ("unknown host", Self.environment(p, host: nil), 400),
                ("unknown account", Self.environment(p, account: RelayAgentAccount(provider: "claude", label: "work", dir: "")), 409),
                ("other provider's account", Self.environment(p, account: RelayAgentAccount(provider: "codex", label: "personal", dir: "")), 409),
                ("launcher missing", Self.environment(p, launcher: "Relay's claude launcher is not installed. Nothing was typed."), 409),
                ("cwd not a directory", Self.environment(p, directory: false), 409),
                ("brief unreadable", Self.environment(p, brief: .failure(Unreadable())), 409),
                ("brief is an option", Self.environment(p, brief: .success(Data("--help".utf8))), 409),
                ("brief empty", Self.environment(p, brief: .success(Data())), 409),
            ]
        }()
        let before = F.Layout(f.workspace)
        for (name, environment, status) in refusals {
            let probe = Probe()
            var env = environment
            env.start = { pane, command, _, _, _ in probe.starts.append((pane.id, command)); return nil }
            let response = await MCPLaunchAgentRequests().launch(Self.body(instance, request), instance: instance,
                permits: F.all, workspace: f.workspace, environment: env)
            #expect(response.status == status, "\(name)")
            #expect(String(decoding: response.body, as: UTF8.self).contains("Nothing was created"), "\(name)")
            #expect(probe.starts.isEmpty, "\(name)")
            #expect(F.Layout(f.workspace) == before, "\(name) changed the workspace")
        }
        // Grants, a stale instance and malformed bodies are refused before any I/O.
        let probe = Probe()
        let handler = MCPLaunchAgentRequests()
        let noInput = await handler.launch(Self.body(instance, request), instance: instance,
            permits: { $0 != .input }, workspace: f.workspace, environment: Self.environment(probe))
        #expect(noInput.status == 403)
        let noLayout = await handler.launch(Self.body(instance, request, extra: ["targetPaneID": UUID().uuidString]),
            instance: instance, permits: { $0 != .layout }, workspace: f.workspace, environment: Self.environment(probe))
        #expect(noLayout.status == 403)
        let stale = await handler.launch(Self.body(UUID(), request), instance: instance,
            permits: F.all, workspace: f.workspace, environment: Self.environment(probe))
        #expect(stale.status == 400)
        #expect(probe.starts.isEmpty && F.Layout(f.workspace) == before)
        // The refused request_id was not consumed.
        let ok = await handler.launch(Self.body(instance, request), instance: instance,
            permits: F.all, workspace: f.workspace, environment: Self.environment(probe))
        #expect(ok.status == 200 && probe.starts.count == 1)
    }

    // MARK: - Idempotency and stages

    @Test func identicalRequestReplaysWithoutCreatingOrTypingAndConflictIs409() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let instance = UUID(), request = UUID(), probe = Probe()
        let handler = MCPLaunchAgentRequests()
        let env = Self.environment(probe)
        let before = Set(f.workspace.panes.keys)

        let first = await handler.launch(Self.body(instance, request), instance: instance, permits: F.all,
                                         workspace: f.workspace, environment: env)
        #expect(first.status == 200)
        let one = try #require(Self.receipt(first))
        let created = Set(f.workspace.panes.keys).subtracting(before)
        #expect(created.count == 1)
        let paneID = try #require(created.first)
        #expect(one.status == "launched" && one.created.status == "created" && one.created.paneID == paneID.uuidString.lowercased())
        #expect(one.started.status == "submitted")
        #expect(one.bound.status == "pending" && one.provider.status == "pending")
        #expect(one.request.configDir == "~/.claude-personal" && one.request.configVariable == "CLAUDE_CONFIG_DIR")
        #expect(one.request.briefBytes == Self.brief.count && one.request.briefSHA256.count == 64)
        #expect(probe.starts.count == 1 && probe.starts[0].0 == paneID)
        #expect(probe.starts[0].1.contains("CLAUDE_CONFIG_DIR=\"$HOME\"/.claude-personal"))
        #expect(f.workspace.panes[paneID]?.agentAccount?.recorded == Self.personal)

        // The agent binds and answers; a repeat observes it and creates nothing.
        probe.bindNow = true
        probe.transcript = Data(#"""
        {"type":"user","message":{"role":"user","content":"Review the parser"}}
        {"type":"assistant","message":{"model":"claude-opus-4-1","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"On it."}]}}

        """#.utf8)
        let second = await handler.launch(Self.body(instance, request), instance: instance, permits: F.all,
                                          workspace: f.workspace, environment: env)
        let two = try #require(Self.receipt(second))
        #expect(Set(f.workspace.panes.keys).subtracting(before) == created)
        #expect(probe.starts.count == 1)
        #expect(two.created == one.created && two.started == one.started)
        #expect(two.bound.status == "bound" && two.bound.pid == 4242 && two.bound.sessionID == "sess-1")
        #expect(two.bound.account == "personal" && two.bound.accountMatches == true && two.bound.provider == "claude")
        #expect(two.provider.status == "admitted" && two.provider.admitted == true && two.provider.observedModel == "claude-opus-4-1")

        // Same request_id, different arguments: 409, nothing created or typed.
        for changed in [Self.body(instance, request, model: "sonnet"), Self.body(instance, request, provider: "codex"),
                        Self.body(instance, request, extra: ["cwd": "/tmp/other"])] {
            let conflict = await handler.launch(changed, instance: instance, permits: F.all,
                                                workspace: f.workspace, environment: env)
            #expect(conflict.status == 409)
        }
        #expect(probe.starts.count == 1 && Set(f.workspace.panes.keys).subtracting(before) == created)
    }

    @Test func shellNotReadyIsAStartFailureNotAProviderOutcome() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let instance = UUID(), probe = Probe()
        let response = await MCPLaunchAgentRequests().launch(Self.body(instance, UUID()), instance: instance, permits: F.all,
            workspace: f.workspace, environment: Self.environment(probe, startRefusal: "prompt not verified empty. Nothing was typed."))
        let receipt = try #require(Self.receipt(response))
        #expect(receipt.status == "launch_failed" && receipt.created.status == "created")
        #expect(receipt.started.status == "failed" && receipt.bound.status == "not_attempted")
        #expect(receipt.provider.status == "unknown" && probe.bindingReads == 0)
    }

    @Test func paneExitMapsToProviderStageNotLaunchFailure() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let instance = UUID(), request = UUID(), probe = Probe()
        let handler = MCPLaunchAgentRequests(), env = Self.environment(probe)
        let first = try #require(Self.receipt(await handler.launch(Self.body(instance, request), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        let firstID = try #require(UUID(uuidString: first.created.paneID ?? ""))
        let pane = try #require(f.workspace.panes[firstID])
        // The provider bound, then exited 1 without any assistant output.
        probe.bindNow = true
        pane.remoteExitCode = 1
        let after = try #require(Self.receipt(await handler.launch(Self.body(instance, request), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        #expect(after.status == "launched" && after.started.status == "submitted")
        #expect(after.bound.status == "bound")
        #expect(after.provider.status == "refused" && after.provider.evidence == "exit" && after.provider.exitCode == 1)
        #expect(after.provider.excerpt?.contains("model not found") == true)

        // Exit 97 before any binding is the launch command failing in the shell.
        probe.bindNow = false
        let other = UUID()
        let second = try #require(Self.receipt(await handler.launch(Self.body(instance, other), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        let secondID = try #require(UUID(uuidString: second.created.paneID ?? ""))
        let pane2 = try #require(f.workspace.panes[secondID])
        pane2.remoteExitCode = MCPLaunchAgentCommand.launchFailureExitCode
        let failed = try #require(Self.receipt(await handler.launch(Self.body(instance, other), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        #expect(failed.status == "launch_failed" && failed.started.status == "failed")
        #expect(failed.provider.status == "unknown")

        // 127 (launcher not executable) is a launch failure too; another
        // unbound non-zero exit is unknown, never attributed to the provider.
        for (code, status, started) in [(127, "launch_failed", "failed"), (1, "launched", "submitted")] {
            let id = UUID()
            let made = try #require(Self.receipt(await handler.launch(Self.body(instance, id), instance: instance,
                permits: F.all, workspace: f.workspace, environment: env)))
            let madeID = try #require(UUID(uuidString: made.created.paneID ?? ""))
            try #require(f.workspace.panes[madeID]).remoteExitCode = code
            let seen = try #require(Self.receipt(await handler.launch(Self.body(instance, id), instance: instance,
                permits: F.all, workspace: f.workspace, environment: env)))
            #expect(seen.status == status && seen.started.status == started && seen.provider.status == "unknown")
            #expect(seen.bound.status == "failed" && seen.provider.exitCode == code)
        }

        // A pane closed before binding settles as unknown, not pending forever.
        let closing = UUID()
        let made = try #require(Self.receipt(await handler.launch(Self.body(instance, closing), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        let closingID = try #require(UUID(uuidString: made.created.paneID ?? ""))
        let tab = try #require(f.workspace.tabID(containingPane: closingID))
        f.workspace.closeTab(tab)
        #expect(f.workspace.panes[closingID] == nil)
        let closed = try #require(Self.receipt(await handler.launch(Self.body(instance, closing), instance: instance,
            permits: F.all, workspace: f.workspace, environment: env)))
        #expect(closed.bound.status == "failed" && closed.provider.status == "unknown")
    }

    @Test func providerStageMapping() {
        typealias O = MCPLaunchAgentObservation
        let start = MCPLaunchAgentReceipt.Provider()
        func stage(_ evidence: O.TranscriptEvidence?, exit: Int?, bound: Bool = true, previous: MCPLaunchAgentReceipt.Provider = start) -> MCPLaunchAgentReceipt.Provider {
            O.provider(previous, evidence: evidence, exitCode: exit, everBound: bound, hasTranscriptPath: true,
                       transcriptReadable: evidence != nil, screen: "boom")
        }
        let claudeRefusal = O.scan(Data(#"{"type":"assistant","message":{"role":"assistant","stop_reason":"refusal","content":[{"type":"text","text":"I can't help with that."}]}}"#.utf8), provider: "claude")
        #expect(stage(claudeRefusal, exit: nil).status == "refused")
        #expect(stage(claudeRefusal, exit: nil).excerpt?.contains("can't help") == true)
        let apiError = O.scan(Data(#"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: 400 invalid model"}]}}"#.utf8), provider: "claude")
        #expect(stage(apiError, exit: nil).status == "refused" && apiError.model == nil)
        // An API error after an admitted turn is not the launch's refusal.
        let later = O.scan(Data(("{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":\"ok\"}}\n" +
            "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"message\":{\"role\":\"assistant\",\"content\":\"API Error\"}}").utf8), provider: "claude")
        #expect(later.admitted && later.refusal == nil && stage(later, exit: nil).status == "admitted")
        // Exits: non-zero before output is a provider refusal; after admission, exited.
        #expect(stage(nil, exit: 2).status == "refused" && stage(nil, exit: 2).evidence == "exit")
        #expect(stage(nil, exit: 2, bound: false).status == "unknown")
        #expect(stage(nil, exit: 127, bound: false).status == "unknown")
        #expect(stage(nil, exit: 0).status == "exited")
        #expect(O.provider(start, evidence: nil, exitCode: nil, everBound: false, hasTranscriptPath: false,
                           transcriptReadable: false, screen: nil, paneClosed: true).status == "unknown")
        let admitted = stage(later, exit: nil)
        #expect(stage(nil, exit: 1, previous: admitted).status == "exited" && stage(nil, exit: 1, previous: admitted).admitted == true)
        #expect(stage(nil, exit: 97, bound: false).status == "unknown")
        #expect(stage(nil, exit: nil, bound: false).status == "pending")
        // Refusal latches.
        let refused = stage(claudeRefusal, exit: nil)
        #expect(stage(later, exit: 0, previous: refused) == refused)
        // Codex rollout rows.
        let codex = O.scan(Data(("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.1-codex\"}}\n" +
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Looking.\"}}").utf8), provider: "codex")
        #expect(codex.admitted && codex.model == "gpt-5.1-codex")
        let codexError = O.scan(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"error\",\"message\":\"model is not supported\"}}".utf8), provider: "codex")
        #expect(stage(codexError, exit: nil).status == "unknown" && stage(codexError, exit: nil).excerpt?.contains("not supported") == true)
        #expect(O.scan(Data("not json\n{}".utf8), provider: "claude") == O.TranscriptEvidence())
    }

    // MARK: 0.5.108 gaps: home-relative accounts, derived Claude transcript, trust prompt

    @Test func accountMatchesAResolvedHomePath() {
        typealias O = MCPLaunchAgentObservation
        #expect(O.tildeForm("/home/u/.claude-team", home: "/home/u") == "~/.claude-team")
        #expect(O.tildeForm("/home/u/.claude-team/", home: "/home/u/") == "~/.claude-team")
        #expect(O.tildeForm("/home/uu/.claude-team", home: "/home/u") == "/home/uu/.claude-team")
        #expect(O.tildeForm("/opt/x", home: nil) == "/opt/x")
        let team = RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-team")
        let binding: [String: Any] = ["session_id": "0088ed42-5a5b-49e5-b025-4fb565300b9c",
            "producer": ["provider": "claude", "process_id": 7, "config_dir": "/home/u/.claude-team"]]
        let bound = O.bound(.init(), binding: binding, unavailable: nil, exitCode: nil, paneClosed: false,
                            target: team, home: "/home/u", label: { $0 == "~/.claude-team" ? "business" : nil })
        #expect(bound.accountMatches == true)
        #expect(bound.account == "business")
        #expect(bound.configDir == "/home/u/.claude-team")
        let other = O.bound(.init(), binding: binding, unavailable: nil, exitCode: nil, paneClosed: false,
                            target: Self.personal, home: "/home/u", label: { _ in nil })
        #expect(other.accountMatches == false)
    }

    @Test func claudeTranscriptPathFollowsConfigCwdAndSession() {
        typealias O = MCPLaunchAgentObservation
        let session = "0088ed42-5a5b-49e5-b025-4fb565300b9c"
        #expect(O.claudeTranscriptPath(configDir: "/home/u/.claude-team",
                                       cwd: "/maps/projects/caeg/people/kbd606/projects/faro-platform", sessionID: session)
                == "/home/u/.claude-team/projects/-maps-projects-caeg-people-kbd606-projects-faro-platform/\(session).jsonl")
        #expect(O.claudeTranscriptPath(configDir: "/c/", cwd: "/a b/c.d_e", sessionID: session) == "/c/projects/-a-b-c-d-e/\(session).jsonl")
        #expect(O.claudeTranscriptPath(configDir: "~/.claude", cwd: "/a", sessionID: session) == nil)
        #expect(O.claudeTranscriptPath(configDir: "/c", cwd: "/a", sessionID: "../x") == nil)
        #expect(O.claudeTranscriptPath(configDir: "/c", cwd: "/" + String(repeating: "a", count: 240), sessionID: session) == nil)
        #expect(O.absolute("~/.claude-team", home: "/home/u") == "/home/u/.claude-team")
        #expect(O.absolute("~/.claude-team", home: nil) == nil)
    }

    @Test func trustPromptIsReportedAsBlockedNotPending() {
        typealias O = MCPLaunchAgentObservation
        let claude = " Accessing workspace:\n Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder"
        #expect(O.trustPrompt(claude))
        #expect(O.trustPrompt("Do you trust the contents of this directory? Working with untrusted contents"))
        #expect(!O.trustPrompt("❯ launch smoke test OK"))
        #expect(!O.trustPrompt(nil))
        let blocked = O.provider(.init(), evidence: nil, exitCode: nil, everBound: false, hasTranscriptPath: false,
                                 transcriptReadable: false, screen: nil, trustPrompt: true)
        #expect(blocked.status == "blocked")
        #expect(blocked.evidence == "screen")
        // Admission, an exit or a closed pane decide over a stale trust screen.
        var admitted = MCPLaunchAgentReceipt.Provider(); admitted.admitted = true
        #expect(O.provider(admitted, evidence: nil, exitCode: nil, everBound: true, hasTranscriptPath: true,
                           transcriptReadable: true, screen: nil, trustPrompt: true).status == "admitted")
        #expect(O.provider(.init(), evidence: nil, exitCode: 1, everBound: false, hasTranscriptPath: false,
                           transcriptReadable: false, screen: nil, trustPrompt: true).status != "blocked")
    }

    @Test func permissionModeAddsOnlyTheProvidersOwnFlags() throws {
        typealias C = MCPLaunchAgentCommand
        #expect(C.permissionFlags(provider: "claude", mode: "account") == [])
        #expect(C.permissionFlags(provider: "claude", mode: "ask") == ["--permission-mode", "manual"])
        #expect(C.permissionFlags(provider: "claude", mode: "yolo") == ["--permission-mode", "bypassPermissions"])
        #expect(C.permissionFlags(provider: "codex", mode: "ask") == ["-a", "on-request", "-s", "workspace-write"])
        #expect(C.permissionFlags(provider: "codex", mode: "read_only") == ["-a", "on-request", "-s", "read-only"])
        #expect(C.permissionFlags(provider: "codex", mode: "yolo") == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(C.permissionFlags(provider: "claude", mode: "bypassPermissions") == nil)
        let plain = try #require(C.build(account: Self.personal, model: "opus", cwd: "/w", briefPath: "/b"))
        #expect(!plain.contains("--permission-mode"))
        let ask = try #require(C.build(account: Self.personal, model: "opus", cwd: "/w", briefPath: "/b", permissionMode: "ask"))
        #expect(ask.contains(" --model 'opus' --permission-mode manual \"$relay_brief\""))
        #expect(C.build(account: Self.personal, model: "opus", cwd: "/w", briefPath: "/b", permissionMode: "nope") == nil)
        // The wire field is optional and checked.
        let instance = UUID(), request = UUID()
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request))?.mode == "account")
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["permissionMode": "ask"]))?.mode == "ask")
        #expect(MCPLaunchAgentProposal.decode(Self.body(instance, request, extra: ["permissionMode": "root"])) == nil)
    }

    // MARK: - No exec: the pane's shell outlives the provider

    static func run(_ shell: String, _ command: String, environment: [String: String]) throws -> (status: Int32, out: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", command] : ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The launch command runs the provider as a child: after a stub provider
    /// exits 3 the same shell carries on, in cwd, with the provider's status
    /// and no relay_brief variable. A bad brief or cwd returns 97 without
    /// running the provider, and the shell carries on too.
    @Test func launchCommandLeavesTheShellAliveAfterTheProviderExits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-noexec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shims = root.appendingPathComponent(".local/share/relay/shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        let ran = root.appendingPathComponent("ran")
        let stub = shims.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$RELAY_TEST_OUT\"\nexit 3\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let cwd = root.appendingPathComponent("work dir 'q'")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let brief = root.appendingPathComponent("brief.md")
        try "Review the parser and report.\n".write(to: brief, atomically: true, encoding: .utf8)
        let bad = root.appendingPathComponent("bad.md")
        try "--dangerously-skip-permissions".write(to: bad, atomically: true, encoding: .utf8)
        let environment = ["HOME": root.path, "RELAY_TEST_OUT": ran.path]
        // What the pane's shell shows next: the command's status, its cwd,
        // whether relay_brief exists, and that it is still the same shell.
        let after = "; printf 'status=%s\\n' \"$?\"; printf 'pwd=%s\\n' \"$(pwd -P)\"; " +
            "printf 'brief=%s\\n' \"${relay_brief-unset}\"; printf 'shell=%s\\n' \"$$\""
        // pwd -P names /private/var where Foundation's resolution says /var.
        let physical = try #require(cwd.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let start = FileManager.default.currentDirectoryPath
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            try? FileManager.default.removeItem(at: ran)
            let command = try #require(MCPLaunchAgentCommand.build(account: Self.personal, model: "opus",
                                                                   cwd: cwd.path, briefPath: brief.path))
            #expect(!command.contains("exec env") || command.contains("&& (relay_brief="), "exec only inside the subshell")
            let result = try Self.run(shell, command + after, environment: environment)
            #expect(result.status == 0, "\(shell): the shell itself must not exit")
            #expect(result.out.contains("status=3\n"), "\(shell): \(result.out)")
            #expect(result.out.contains("pwd=" + physical + "\n"), "\(shell): \(result.out)")
            #expect(result.out.contains("brief=unset\n"), "\(shell): relay_brief leaked into the shell")
            let providerPID = try String(contentsOf: ran, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!result.out.contains("shell=" + providerPID + "\n"), "\(shell): the provider replaced the shell")

            for (dir, briefPath) in [(cwd.path, bad.path), (cwd.path, root.path + "/missing.md"),
                                     (root.appendingPathComponent("missing").path, brief.path)] {
                try? FileManager.default.removeItem(at: ran)
                let failing = try #require(MCPLaunchAgentCommand.build(account: Self.personal, model: "opus",
                                                                       cwd: dir, briefPath: briefPath))
                let failed = try Self.run(shell, failing + after, environment: environment)
                #expect(failed.status == 0, "\(shell): the shell itself must not exit")
                #expect(failed.out.contains("status=\(MCPLaunchAgentCommand.launchFailureExitCode)\n"), "\(shell): \(failed.out)")
                #expect(failed.out.contains("brief=unset\n"))
                #expect(!FileManager.default.fileExists(atPath: ran.path), "\(shell): the provider ran")
                if dir != cwd.path { #expect(!failed.out.contains("pwd=" + physical + "\n")) }
            }
        }
        #expect(FileManager.default.currentDirectoryPath == start)
    }

    // MARK: - The provider's exit is the launch command's shell-reported status

    @Test func commandReportMapsOnlyTheLaunchCommandsOwnStatus() {
        typealias O = MCPLaunchAgentObservation
        typealias C = TerminalSemanticPromptStateTracker.CommandObservation
        #expect(O.commandReport(C(executions: 6, completedExecutions: 5, exitStatus: 0, integrationSeen: true),
                                after: 5, producerChanged: false) == .running)
        #expect(O.commandReport(C(executions: 6, completedExecutions: 6, exitStatus: 97, integrationSeen: true),
                                after: 5, producerChanged: false) == .returned(97))
        // A later command returned too: the status is not the launch command's.
        #expect(O.commandReport(C(executions: 7, completedExecutions: 7, exitStatus: 0, integrationSeen: true),
                                after: 5, producerChanged: false) == .returned(nil))
        #expect(O.commandReport(C(executions: 6, completedExecutions: 6, exitStatus: nil, integrationSeen: true),
                                after: 5, producerChanged: false) == .returned(nil))
        if case .unavailable = O.commandReport(C(executions: 0, completedExecutions: 0, exitStatus: nil, integrationSeen: false),
                                               after: 0, producerChanged: false) {} else { Issue.record("no integration") }
        if case .unavailable = O.commandReport(C(executions: 6, completedExecutions: 6, exitStatus: 1, integrationSeen: true),
                                               after: 5, producerChanged: true) {} else { Issue.record("reconnected") }

        let command = { (code: Int?) in O.Ending(source: .command, code: code) }
        func stage(_ ending: O.Ending?, bound: Bool, admitted: Bool = false, unobservable: String? = nil) -> MCPLaunchAgentReceipt.Provider {
            var previous = MCPLaunchAgentReceipt.Provider()
            if admitted { previous.admitted = true }
            return O.provider(previous, evidence: nil, ending: ending, everBound: bound, hasTranscriptPath: true,
                              transcriptReadable: true, screen: "$ ", exitUnobservable: unobservable)
        }
        // 97/126/127 before a binding: Relay's launch failed, not the provider.
        for code in [97, 126, 127] {
            #expect(stage(command(code), bound: false).status == "unknown")
            #expect(stage(command(code), bound: false).detail?.contains("launch command returned \(code)") == true)
        }
        // Non-zero after a binding with no output: refused. After output: exited.
        #expect(stage(command(1), bound: true).status == "refused" && stage(command(1), bound: true).exitCode == 1)
        #expect(stage(command(1), bound: true).evidence == "exit")
        #expect(stage(command(0), bound: true, admitted: true).status == "exited")
        #expect(stage(command(1), bound: true, admitted: true).status == "exited")
        #expect(stage(command(0), bound: true).status == "exited")
        // Unattributable status: exited after output, otherwise unknown; never 0.
        #expect(stage(command(nil), bound: true, admitted: true).status == "exited")
        #expect(stage(command(nil), bound: true).status == "unknown" && stage(command(nil), bound: true).exitCode == nil)
        // No shell integration: a bound agent's exit cannot be seen.
        #expect(stage(nil, bound: true, unobservable: "no OSC 133").status == "unknown")
        #expect(stage(nil, bound: true).status == "pending")
        #expect(stage(nil, bound: false, unobservable: "no OSC 133").status == "pending")
        let failed = O.bound(.init(), binding: nil, unavailable: nil, ending: command(97), paneClosed: false,
                             target: Self.personal, label: { _ in nil })
        #expect(failed.status == "failed" && failed.reason == "The launch command returned (97) before a verified binding")
    }

    /// Through the handler: the handle is read just before typing, and the
    /// shell's report of the launch command returning decides the stages
    /// while the pane itself never exits.
    @Test func commandCompletionMapsToStagesWithoutAPaneExit() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        typealias C = TerminalSemanticPromptStateTracker.CommandObservation
        let producer = UUID()
        func launched(_ probe: Probe) async throws -> (UUID, MCPLaunchAgentRequests, Data) {
            let instance = UUID(), request = UUID(), handler = MCPLaunchAgentRequests()
            probe.command = (producer, C(executions: 4, completedExecutions: 4, exitStatus: 0, integrationSeen: true))
            let body = Self.body(instance, request)
            let first = try #require(Self.receipt(await handler.launch(body, instance: instance, permits: F.all,
                workspace: f.workspace, environment: Self.environment(probe))))
            #expect(first.started.status == "submitted" && first.provider.status == "pending")
            return (instance, handler, body)
        }
        func observe(_ probe: Probe, _ launch: (UUID, MCPLaunchAgentRequests, Data)) async throws -> MCPLaunchAgentReceipt {
            try #require(Self.receipt(await launch.1.launch(launch.2, instance: launch.0, permits: F.all,
                workspace: f.workspace, environment: Self.environment(probe))))
        }

        // A bad brief: the command returned 97 before any binding.
        let badBrief = Probe()
        let one = try await launched(badBrief)
        badBrief.command = (producer, C(executions: 5, completedExecutions: 5, exitStatus: 97, integrationSeen: true))
        let failed = try await observe(badBrief, one)
        #expect(failed.status == "launch_failed" && failed.started.status == "failed")
        #expect(failed.started.reason?.contains("launch command returned 97") == true)
        #expect(failed.bound.status == "failed" && failed.provider.status == "unknown")

        // Bound, then the provider exited 1 with no assistant output: refused.
        let refusing = Probe()
        let two = try await launched(refusing)
        refusing.bindNow = true
        let running = try await observe(refusing, two)
        #expect(running.bound.status == "bound" && running.provider.status == "pending")
        refusing.command = (producer, C(executions: 5, completedExecutions: 5, exitStatus: 1, integrationSeen: true))
        let refused = try await observe(refusing, two)
        #expect(refused.status == "launched" && refused.provider.status == "refused")
        #expect(refused.provider.exitCode == 1 && refused.provider.evidence == "exit")

        // Admitted, then returned 0: exited, and later commands do not change it.
        let exiting = Probe()
        let three = try await launched(exiting)
        exiting.bindNow = true
        exiting.transcript = Data((#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":"Done."}}"# + "\n").utf8)
        exiting.command = (producer, C(executions: 5, completedExecutions: 5, exitStatus: 0, integrationSeen: true))
        let exited = try await observe(exiting, three)
        #expect(exited.provider.status == "exited" && exited.provider.admitted == true && exited.provider.exitCode == 0)
        exiting.command = (producer, C(executions: 6, completedExecutions: 6, exitStatus: 1, integrationSeen: true))
        let later = try await observe(exiting, three)
        #expect(later.provider.status == "exited" && later.provider.exitCode == 0)

        // No shell integration: bound with no output is reported unknown.
        let blind = Probe()
        let four = try await launched(blind)
        blind.command = (producer, C(executions: 0, completedExecutions: 0, exitStatus: nil, integrationSeen: false))
        blind.bindNow = true
        let unknown = try await observe(blind, four)
        #expect(unknown.bound.status == "bound" && unknown.provider.status == "unknown")
        #expect(unknown.provider.detail?.contains("cannot be observed") == true)
    }

    /// relay_launch_agent's default placement creates its tab in the background.
    @Test func launchLeavesTheUsersSelectionAlone() async throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        var started: [UUID] = []
        f.workspace.createdPaneBackgroundStart = { pane, _ in started.append(pane.id) }
        f.workspace.selectTab(f.a1.id)
        let before = (f.workspace.selectedTabID, f.workspace.activePaneID, f.workspace.selectedWorkspaceID)
        let instance = UUID(), probe = Probe()
        let stackTarget = try #require(f.b2.allPaneIDs.first)
        let placements: [[String: String]] = [[:], ["anchorTabID": f.b1.id.uuidString], ["targetPaneID": stackTarget.uuidString]]
        for extra in placements {
            let receipt = try #require(Self.receipt(await MCPLaunchAgentRequests().launch(Self.body(instance, UUID(), extra: extra),
                instance: instance, permits: F.all, workspace: f.workspace, environment: Self.environment(probe))))
            #expect(receipt.created.status == "created", "\(extra)")
            let paneID = try #require(receipt.created.paneID.flatMap(UUID.init(uuidString:)))
            #expect(f.workspace.selectedTabID == before.0 && f.workspace.activePaneID == before.1, "\(extra)")
            #expect(f.workspace.selectedWorkspaceID == before.2, "\(extra)")
            #expect(started.last == paneID && probe.starts.last?.0 == paneID, "\(extra)")
        }
    }
}
