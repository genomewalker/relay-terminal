import Foundation
import Testing
@testable import Relay

@Suite("Agent accounts")
@MainActor
struct RelayAgentAccountsTests {
    let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
    let work = RelayAgentAccount(provider: "claude", label: "work", dir: "")
    let paneID = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!

    @Test("Launch commands select the account only through its config variable")
    func launchPrefix() {
        // The default account unsets the variable, so an inherited override
        // never selects another account.
        #expect(work.launchCommand("claude") == #"env -u CLAUDE_CONFIG_DIR "$HOME"/.local/share/relay/shims/claude"#)
        #expect(personal.launchCommand("claude") == #"CLAUDE_CONFIG_DIR="$HOME"/.claude-personal "$HOME"/.local/share/relay/shims/claude"#)
        let codex = RelayAgentAccount(provider: "codex", label: "personal", dir: "/srv/codex-personal")
        #expect(codex.launchCommand("codex") == #"CODEX_HOME=/srv/codex-personal "$HOME"/.local/share/relay/shims/codex"#)
        // A login runs the CLI relayd resolved on the host through env, with
        // only the account's variable; it is not an agent launch.
        #expect(codex.loginCommand(executable: "/opt/homebrew/bin/codex", remote: false) ==
                #"env CODEX_HOME=/srv/codex-personal '/opt/homebrew/bin/codex' login"#)
        // Codex's browser callback reaches only the remote host: device code.
        #expect(codex.loginCommand(executable: "/home/u/.local/bin/codex", remote: true) ==
                #"env CODEX_HOME=/srv/codex-personal '/home/u/.local/bin/codex' login --device-auth"#)
        #expect(personal.loginCommand(executable: "/Users/a/.local/bin/claude", remote: true) ==
                #"env CLAUDE_CONFIG_DIR="$HOME"/.claude-personal '/Users/a/.local/bin/claude' auth login"#)
        #expect(RelayAgentAccount(provider: "codex", label: "work", dir: "").loginCommand(executable: "/b/codex", remote: false) ==
                #"env -u CODEX_HOME '/b/codex' login"#)
        // Signing in again runs the provider's own logout first; login only after it succeeds.
        #expect(codex.loginCommand(executable: "/b/codex", remote: true, replacing: true) ==
                #"env CODEX_HOME=/srv/codex-personal '/b/codex' logout && env CODEX_HOME=/srv/codex-personal '/b/codex' login --device-auth"#)
        #expect(work.loginCommand(executable: "/b/claude", remote: false, replacing: true) ==
                #"env -u CLAUDE_CONFIG_DIR '/b/claude' auth logout && env -u CLAUDE_CONFIG_DIR '/b/claude' auth login"#)
        // A relayd that predates the report: the provider's name, through env.
        #expect(work.loginCommand(executable: nil, remote: false) == #"env -u CLAUDE_CONFIG_DIR claude auth login"#)
        // A reported path is typed only when it is absolute and safely quoted.
        for bad in ["claude", "relative/claude", "/a'b/claude", "/a/\nclaude", "/a/\u{7f}"] {
            #expect(work.loginCommand(executable: bad, remote: false) == "", "\(bad)")
        }
        // Only the provider itself is launched, never another program.
        #expect(work.launchCommand("codex") == "" && work.launchCommand("claudex") == "" && work.launchCommand("/bin/sh") == "")
        // Anything that would need shell quoting is refused, never typed.
        for bad in ["~/x y", "~/../x", "relative", "~/a;rm", "/a/", "~/$(id)", "//x"] {
            let account = RelayAgentAccount(provider: "claude", label: "x", dir: bad)
            #expect(!account.isValid)
            #expect(account.launchCommand("claude") == "")
            #expect(account.loginCommand(executable: "/bin/claude", remote: false) == "")
        }
        #expect(!RelayAgentAccount.validLabel("Work"))
        #expect(!RelayAgentAccount.validLabel(""))
        #expect(RelayAgentAccount.validLabel("client-2"))
    }

    @Test("A running agent's account is compared in the recorded form")
    func mismatch() {
        #expect(personal.matches(observedDirectory: "~/.claude-personal"))
        #expect(!personal.matches(observedDirectory: ""))
        #expect(work.matches(observedDirectory: ""))
        #expect(!work.matches(observedDirectory: "~/.claude-personal"))
        var state = RelayPaneAgentAccountState(recorded: personal)
        #expect(!state.mismatch && state.label == "personal")
        state.observedProvider = "claude"
        state.observedDirectory = ""
        #expect(state.mismatch)
        #expect(state.mismatchDescription?.contains("will not restart or switch") == true)
        state.observedDirectory = "~/.claude-personal"
        #expect(!state.mismatch && state.mismatchDescription == nil)
        // Only an observation of the same provider is comparable.
        state.observedProvider = "codex"
        state.observedDirectory = ""
        #expect(!state.mismatch)
    }

    @Test("Pane accounts persist by pane ID and are removed when cleared")
    func paneStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RelayPaneAccountStore(directory: root)
        #expect(store.load(paneID: paneID) == nil)
        var state = RelayPaneAgentAccountState(recorded: personal)
        state.observedProvider = "claude"
        state.observedDirectory = "~/.claude-personal"
        store.save(state, paneID: paneID)
        #expect(RelayPaneAccountStore(directory: root).load(paneID: paneID) == state)
        let file = root.appendingPathComponent(paneID.uuidString.lowercased() + ".json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // A tampered record with an unsafe directory is not loaded.
        try Data(#"{"recorded":{"provider":"claude","label":"x","dir":"~/a b"}}"#.utf8).write(to: file)
        #expect(store.load(paneID: paneID) == nil)
        store.save(nil, paneID: paneID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Routing rules: explicit, then workspace, then host, then global, then the default directory")
    func rulePrecedence() throws {
        let accounts = RelayAgentAccount.defaults + [.init(provider: "claude", label: "client", dir: "/srv/claude-client")]
        let first = UUID(), second = UUID()
        var rules = RelayAgentAccountRules()
        func chosen(_ workspace: UUID? = nil, host: String = "dandy-07", explicit: String? = nil) -> (String?, RelayAgentAccountChoiceSource?) {
            let choice = rules.choose(provider: "claude", host: host, workspace: workspace, explicit: explicit, accounts: accounts)
            return (choice?.account.label, choice?.source)
        }
        #expect(chosen(first) == ("work", .standard))
        rules.global["claude"] = "client"
        #expect(chosen(first) == ("client", .global))
        rules.hosts["dandy-07"] = ["claude": "personal"]
        #expect(chosen(first) == ("personal", .host))
        #expect(chosen(first, host: "local") == ("client", .global))
        rules.workspaces[RelayAgentAccountRules.workspaceKey(first)] = ["claude": "work"]
        #expect(chosen(first) == ("work", .workspace))
        #expect(chosen(second) == ("personal", .host))
        #expect(chosen(first, explicit: "client") == ("client", .explicit))
        // An explicit label the host lacks is refused, never replaced.
        #expect(chosen(first, explicit: "gone").0 == nil)
        // A rule naming a missing label falls through to the next rule.
        rules.workspaces[RelayAgentAccountRules.workspaceKey(second)] = ["claude": "gone"]
        #expect(chosen(second) == ("personal", .host))
        // Codex is routed independently.
        #expect(rules.choose(provider: "codex", host: "dandy-07", workspace: first, accounts: accounts)?.source == .standard)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-routing-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RelayAgentAccountRouting(url: url)
        store.setWorkspace(first, provider: "claude", label: "personal")
        store.setHost("dandy-07", provider: "codex", label: "personal")
        store.setGlobal(provider: "claude", label: "work")
        let reloaded = RelayAgentAccountRouting(url: url).rules
        #expect(reloaded.workspaces[RelayAgentAccountRules.workspaceKey(first)]?["claude"] == "personal")
        #expect(reloaded.hosts["dandy-07"]?["codex"] == "personal" && reloaded.global["claude"] == "work")
        #expect(!store.update { $0.global["claude"] = "Not A Label" })
        store.setWorkspace(first, provider: "claude", label: nil)
        #expect(RelayAgentAccountRouting(url: url).rules.workspaces.isEmpty)
    }

    func reading(_ label: String, _ used: [Double], provider: String = "claude", status: String = "ok",
                 age: TimeInterval = 60, now: Date) -> RelayAgentAccountUsage {
        let windows = used.enumerated().map { #"{"name":"w\#($0.offset)","used_percent":\#($0.element),"window_minutes":300}"# }
        let json = #"{"provider":"\#(provider)","label":"\#(label)","status":"\#(status)","read_at":"\#(ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)))","windows":[\#(windows.joined(separator: ","))]}"#
        return try! JSONDecoder().decode(RelayAgentAccountUsage.self, from: Data(json.utf8))
    }

    @Test("Usage without a provider reading is unknown, never estimated")
    func unknownUsage() throws {
        let now = Date()
        let unknown = try JSONDecoder().decode(RelayAgentAccountUsage.self, from: Data(#"""
        {"provider":"codex","label":"personal","status":"unknown","reason":"not logged in","read_at":"2026-10-17T08:00:00Z"}
        """#.utf8))
        #expect(unknown.headroom == nil && unknown.summary(now: now) == "usage unknown")
        #expect(reading("work", [], now: now).headroom == nil)
        #expect(reading("work", [120], now: now).headroom == nil)
        let known = reading("work", [28, 36], now: now)
        #expect(known.headroom == 64)
        #expect(known.summary(now: now).contains("5-hour 28%") && known.summary(now: now).contains("read 1 min ago"))
        #expect(RelayAgentAccountUsage.age(now.addingTimeInterval(-7200), now: now) == "2 h ago")
    }

    @Test("A usage suggestion is shown only with readings for every account and never applied")
    func suggestionIsNeverApplied() {
        let now = Date()
        let accounts = RelayAgentAccount.defaults.filter { $0.provider == "claude" }
        var usage = ["claude:work": reading("work", [90, 40], now: now), "claude:personal": reading("personal", [10, 20], now: now)]
        #expect(RelayAgentAccountUsage.suggestion(accounts: accounts, usage: usage, now: now) == "personal")
        // The rule default stays the selection whatever usage says.
        #expect(RelayAgentAccountRules().choose(provider: "claude", host: "local", workspace: nil, accounts: accounts)?.account.label == "work")
        usage["claude:work"] = reading("work", [10], now: now)
        usage["claude:personal"] = reading("personal", [10], now: now)
        #expect(RelayAgentAccountUsage.suggestion(accounts: accounts, usage: usage, now: now) == nil)
        usage["claude:work"] = reading("work", [90], status: "unknown", now: now)
        #expect(RelayAgentAccountUsage.suggestion(accounts: accounts, usage: usage, now: now) == nil)
        usage["claude:work"] = reading("work", [90], age: 7200, now: now)
        #expect(RelayAgentAccountUsage.suggestion(accounts: accounts, usage: usage, now: now) == nil)
        usage.removeValue(forKey: "claude:work")
        #expect(RelayAgentAccountUsage.suggestion(accounts: accounts, usage: usage, now: now) == nil)
        // Miko's launch account comes from the rules, never the suggestion.
        let directory = RelayAgentAccountDirectory.shared
        #expect(directory.defaultAccount(for: .local, provider: "claude", workspace: UUID()) == work)
    }

    @Test("Maintenance holds a restart whose running account differs from the pane's")
    func maintenanceHold() throws {
        func proof(_ configDir: String?) throws -> RelayAgentMaintenanceProbe {
            var json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":false,"lifecycle":"quiet","background_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"CLAUDE_CONFIG_DIR=/home/u/.claude-personal relayd agent claude --resume exact-session""#
            if let configDir { json += #","config_dir":"# + "\"\(configDir)\"" }
            json += "}"
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        }
        func held(_ value: RelayAgentMaintenanceProbe, _ account: RelayAgentAccount?) -> String? {
            RelayAgentMaintenancePolicy.deferral(value, paneID: paneID, emptyPrompt: true, hasDraft: false,
                pendingApprovals: 0, inputAge: 60, recordedAccount: account)
        }
        #expect(try proof("~/.claude-personal").configDir == "~/.claude-personal")
        #expect(held(try proof("~/.claude-personal"), personal) == nil)
        #expect(held(try proof(""), work) == nil)
        #expect(held(try proof(""), personal)?.contains("will not restart or switch") == true)
        #expect(held(try proof("~/.claude-personal"), work)?.contains("different claude account") == true)
        // Legacy panes without a recorded account, and older readers without
        // config_dir, keep their previous behaviour.
        #expect(held(try proof(""), nil) == nil)
        #expect(held(try proof(nil), personal) == nil)
    }

    func moveProof(lifecycle: String = "quiet", session: String = "exact-session", pid: Int = 42, start: Int = 99,
                   extra: String = #","move_command":"CLAUDE_CONFIG_DIR=/home/u/.claude-personal relayd agent claude --resume exact-session""#) throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"claude","process_id":\#(pid),"process_start":\#(start),"session_id":"\#(session)","bound":true,"lifecycle":"\#(lifecycle)","background_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":\#(pid),"process_start":\#(start),"session_id":"\#(session)","transcript_identity":"1:2"},"installed_update":false,"resume_command":"relayd agent claude --resume exact-session""#
            + extra + "}"
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    @Test("Moving a pane is user-initiated only and needs an idle agent, an empty prompt and visible history")
    func moveRefusals() throws {
        #expect(RelayAgentAccountMovePolicy.originRefusal(.user, inputGranted: false) == nil)
        #expect(RelayAgentAccountMovePolicy.originRefusal(.mcp, inputGranted: true) == nil)
        #expect(RelayAgentAccountMovePolicy.originRefusal(.mcp, inputGranted: false)?.contains("terminal input grant") == true)
        #expect(RelayAgentAccountMovePolicy.originRefusal(.assistant, inputGranted: true)?.contains("user-initiated only") == true)
        #expect(RelayAgentAccountMovePolicy.originRefusal(.maintenance, inputGranted: true)?.contains("user-initiated only") == true)
        func refusal(_ proof: RelayAgentMaintenanceProbe, target: RelayAgentAccount? = nil, empty: Bool = true,
                     draft: Bool = false, approvals: Int = 0, inputAge: TimeInterval = 60) -> String? {
            RelayAgentAccountMovePolicy.refusal(proof, paneID: paneID, target: target ?? personal, emptyPrompt: empty,
                hasDraft: draft, pendingApprovals: approvals, inputAge: inputAge)
        }
        #expect(refusal(try moveProof()) == nil)
        #expect(refusal(try moveProof(lifecycle: "busy")) != nil)
        #expect(refusal(try moveProof(), draft: true)?.contains("empty prompt") == true)
        #expect(refusal(try moveProof(), empty: false) != nil)
        #expect(refusal(try moveProof(), approvals: 1) != nil)
        #expect(refusal(try moveProof(), inputAge: 1) != nil)
        #expect(refusal(try moveProof(), target: RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")) != nil)
        let hidden = try moveProof(extra: #","move_error":"This conversation is not visible from the target account.""#)
        #expect(refusal(hidden)?.contains("not visible from the target account") == true)
        #expect(refusal(try moveProof(extra: "")) != nil)
    }

    @Test("Miko, maintenance and a busy pane cannot start a move; refusals are audited")
    func moveOriginsAreRefusedBeforeInput() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        let mover = RelayAgentAccountMove()
        mover.audit = RelayAgentAccountMoveAudit()
        let revision = pane.agentInputRevision
        for origin in [RelayAgentAccountMoveOrigin.assistant, .maintenance] {
            let outcome = await mover.move(pane, in: workspace, to: personal, origin: origin, inputGranted: true)
            #expect(outcome.state == "refused" && outcome.message.contains("user-initiated only"))
        }
        #expect(await mover.move(pane, in: workspace, to: personal, origin: .mcp, inputGranted: false).state == "refused")
        // Maintenance holds the pane: a move does not interleave with it.
        #expect(RelayAgentMaintenance.shared.hold(pane.id))
        defer { RelayAgentMaintenance.shared.release(pane.id) }
        #expect(!RelayAgentMaintenance.shared.hold(pane.id))
        #expect(pane.agentInputRevision == revision)
        // Miko's executor cannot reach the move route, and no plan op moves accounts.
        #expect(!RelaySidePanelServer.assistantMayRequest("/api/agent-accounts/move"))
        #expect(RelaySidePanelServer.assistantMayRequest("/api/workspace/apply"))
        let snapshot = RelayAssistantSnapshot.capture(workspace)
        for op in ["move_account", "move_pane_account"] {
            if case .success = RelayAssistantPlan.validate(["steps": .array([.object(["op": .string(op)])])], snapshot: snapshot) {
                Issue.record("A plan op moved an account")
            }
        }
        #expect(mover.audit.memory.count == 3 && mover.audit.memory.allSatisfy { $0.state == "refused" && $0.to == personal })
    }

    @Test("The header and sidebar menus mark the workspace default from the tab's current owner")
    func workspaceDefaultFollowsTheTabOwner() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let tabID = try #require(workspace.tabID(containingPane: pane.id))
        let owner = workspace.createWorkspace(named: "Accounts")
        try workspace.moveTab(tabID, toWorkspace: owner)
        let routing = RelayAgentAccountRouting.shared
        routing.setWorkspace(owner, provider: "claude", label: "personal")
        defer { routing.setWorkspace(owner, provider: "claude", label: nil) }
        // Both menus are RelayAgentAccountMenus; Miko asks the model directly.
        func marked() -> RelayAgentAccountChoice? {
            let menu = RelayAgentAccountMenus.choice("claude", pane: pane.id, in: workspace)
            #expect(menu == workspace.agentAccountChoice("claude", forPane: pane.id))
            return menu
        }
        // The session field (restored from the legacy tab when a snapshot
        // lacks it) names the legacy session, not the owner; it is not used.
        #expect(pane.remoteWorkspaceSessionID != owner.uuidString.lowercased())
        #expect(workspace.accountWorkspaceID(containingPane: pane.id) == owner)
        #expect(marked() == RelayAgentAccountChoice(account: personal, source: .workspace))
        // A birth session naming another container does not change it.
        pane.assignRemoteHierarchy(workspaceSessionID: UUID(), tabID: UUID())
        #expect(marked() == RelayAgentAccountChoice(account: personal, source: .workspace))
        // Moving the tab moves the pane to the other workspace's default.
        try workspace.moveTab(tabID, toWorkspace: workspace.createWorkspace(named: "Other"))
        #expect(marked()?.account == work && marked()?.source != .workspace)
        // Without the workspace model no default is marked.
        #expect(RelayAgentAccountMenus.choice("claude", pane: pane.id, in: nil) == nil)
    }

    @Test("A verified move keeps the conversation and changes only the account")
    func moveVerification() throws {
        let before = try moveProof()
        let after = try moveProof(pid: 77, start: 120, extra: #","account_matches":true,"config_dir":"~/.claude-personal""#)
        #expect(RelayAgentAccountMovePolicy.verified(before: before, after: after, paneID: paneID))
        #expect(!RelayAgentAccountMovePolicy.verified(before: before, after: try moveProof(pid: 77, start: 120), paneID: paneID))
        #expect(!RelayAgentAccountMovePolicy.verified(before: before,
            after: try moveProof(pid: 77, start: 120, extra: #","account_matches":false"#), paneID: paneID))
        #expect(!RelayAgentAccountMovePolicy.verified(before: before,
            after: try moveProof(session: "other-session", pid: 77, start: 120, extra: #","account_matches":true"#), paneID: paneID))
        #expect(!RelayAgentAccountMovePolicy.verified(before: before,
            after: try moveProof(extra: #","account_matches":true"#), paneID: paneID))
        // The move command differs from the restart only by the account variable.
        let move = try #require(before.moveCommand), resume = try #require(before.resumeCommand)
        #expect(move == "CLAUDE_CONFIG_DIR=/home/u/.claude-personal " + resume)
    }

    @Test("CODEX_HOME=~/.codex is the default account; Claude's explicit ~/.claude is a mismatch with its reason")
    func explicitDefaultIsDefault() throws {
        // Codex: CODEX_HOME=~/.codex is the default account.
        let codexWork = RelayAgentAccount(provider: "codex", label: "work", dir: "")
        #expect(codexWork.matches(observedDirectory: "~/.codex"))
        #expect(RelayAgentAccount(provider: "codex", label: "main", dir: "~/.codex").matches(observedDirectory: ""))
        // Claude: an explicit ~/.claude reads another .claude.json, so it is a
        // mismatch with that reason.
        #expect(!work.matches(observedDirectory: "~/.claude"))
        var claude = RelayPaneAgentAccountState(recorded: work)
        claude.observedProvider = "claude"
        claude.observedDirectory = "~/.claude"
        #expect(claude.mismatch)
        #expect(claude.mismatchDescription?.contains("explicit ~/.claude uses a different .claude.json") == true)
        claude.observedDirectory = "~/.claude-personal"
        #expect(claude.mismatchDescription?.contains(".claude.json") == false)
        var state = RelayPaneAgentAccountState(recorded: work)
        state.observedProvider = "claude"
        state.observedDirectory = "/home/u/aliases/main-claude"
        state.observedMatches = true
        #expect(!state.mismatch)
        state.observedMatches = false
        #expect(state.mismatch)
        // relayd's real-path verdict decides over the textual comparison.
        let held = RelayAgentMaintenancePolicy.deferral(try moveProof(extra: #","config_dir":"/alias","account_matches":true"#),
            paneID: paneID, emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60, recordedAccount: work)
        #expect(held == nil)
    }

    @Test("Miko's start_agent accepts an account label and shows it in the launch")
    func assistantStartAgent() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let snapshot = RelayAssistantSnapshot.capture(workspace)
        func validate(_ step: [String: RelayPaneHealthJSON]) -> [RelayAssistantPlanStep]? {
            let steps: [RelayPaneHealthJSON] = [.object(["op": .string("new_tab")]), .object(step)]
            if case .success(let parsed) = RelayAssistantPlan.validate(["steps": .array(steps)], snapshot: snapshot) { return parsed }
            return nil
        }
        let base: [String: RelayPaneHealthJSON] = ["op": .string("start_agent"), "pane": .string("step:1"), "agent": .string("claude")]
        #expect(validate(base)?.last?.account == nil)
        #expect(validate(base.merging(["account": .string("personal")]) { $1 })?.last?.account == "personal")
        #expect(validate(base.merging(["account": .string("Personal Account")]) { $1 }) == nil)
        #expect(validate(base.merging(["account": .integer(1)]) { $1 }) == nil)
        #expect(validate(["op": .string("send_command"), "pane": .string("step:1"), "text": .string("ls"), "account": .string("work")]) == nil)

        final class Paths { var values: [String] = [] }
        let statted = Paths()
        let stat: (String) async -> [String: Any]? = { path in
            statted.values.append(path)
            return path.hasSuffix("relay-launch-defaults.json") ? ["version": "v1", "size": 80] : ["directory": false, "version": "shim1"]
        }
        let read: (String, String, Int) async -> Data? = { _, _, _ in
            Data(#"{"version":1,"sandbox_mode":"workspace-write","approval_policy":"on-request"}"#.utf8)
        }
        let plain = await RelayAssistantLaunch.resolve(agent: "claude", account: nil, stat: stat, read: read)
        let standard = await RelayAssistantLaunch.resolve(agent: "claude", account: work, stat: stat, read: read)
        let chosen = await RelayAssistantLaunch.resolve(agent: "claude", account: personal, stat: stat, read: read)
        #expect(plain.typed == "claude")
        // The default account unsets the variable rather than inheriting it.
        #expect(standard.typed == #"env -u CLAUDE_CONFIG_DIR "$HOME"/.local/share/relay/shims/claude"#)
        #expect(chosen.typed == #"CLAUDE_CONFIG_DIR="$HOME"/.claude-personal "$HOME"/.local/share/relay/shims/claude"#)
        #expect(chosen.fingerprint != plain.fingerprint && chosen.fingerprint.hasPrefix(plain.fingerprint))
        #expect(standard.fingerprint != chosen.fingerprint && standard.fingerprint.hasPrefix(plain.fingerprint))
        let codexAccount = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        let codex = await RelayAssistantLaunch.resolve(agent: "codex", account: codexAccount, stat: stat, read: read)
        #expect(codex.blockedReason == nil)
        #expect(codex.typed == #"CODEX_HOME="$HOME"/.codex-personal "$HOME"/.local/share/relay/shims/codex --sandbox workspace-write --ask-for-approval on-request"#)
        // The frozen description and the fingerprint name the pinned launcher too.
        #expect(codex.resolved.hasPrefix(#"CODEX_HOME="$HOME"/.codex-personal "$HOME"/.local/share/relay/shims/codex --sandbox"#))
        #expect(codex.fingerprint.hasSuffix(#"|launcher:"$HOME"/.local/share/relay/shims/codex"#))
        // Codex's launch defaults are read from that account's CODEX_HOME, as relayd applies them.
        #expect(statted.values.contains("~/.codex-personal/relay-launch-defaults.json"))
        // An account for the other provider is ignored rather than mixed in.
        #expect(await RelayAssistantLaunch.resolve(agent: "codex", account: personal, stat: stat, read: read).typed.hasPrefix("codex "))
    }

    @Test("relayd's account and sync responses decode without paths in the MCP pane state")
    func wireFormat() throws {
        let status = try JSONDecoder().decode(RelayAgentAccountStatus.self, from: Data(#"""
        {"provider":"claude","label":"work","dir":"~/.claude","root":"/Users/u/.claude","default":true,"exists":true,"logged_in":"yes","method":"keychain","email":"a@b.org"}
        """#.utf8))
        #expect(status.account == work && status.loggedIn == "yes")
        let sync = try JSONDecoder().decode(RelayAgentAccountSyncResult.self, from: Data(#"""
        {"provider":"claude","label":"personal","links":[{"name":"CLAUDE.md","state":"linked"},{"name":"skills","state":"foreign_link"}],"mcp":"updated","mcp_backup":".claude.json.mcpServers.relay-backup-x.json","mcp_servers":3}
        """#.utf8))
        #expect(sync.summary.contains("Linked: CLAUDE.md") && sync.summary.contains("Left unchanged: skills"))
        // On a file system without atomic exchange (NFS) relayd skips the merge
        // and says what the user must do by hand; both reach the summary.
        let skipped = try JSONDecoder().decode(RelayAgentAccountSyncResult.self, from: Data(#"""
        {"provider":"claude","label":"max","links":[],"mcp":"skipped_no_atomic_exchange","mcp_servers":2,"notes":[".claude.json was not changed: skipped: atomic exchange unsupported on this filesystem; merge skipped. add them by hand (claude mcp add)"]}
        """#.utf8))
        #expect(skipped.summary.contains("MCP servers: not synced") && skipped.summary.contains("claude mcp add")
            && !skipped.summary.contains("skipped_no_atomic_exchange (2)"))
        let pane = RelaySidePanelState.Pane(id: "p", name: "n", host: "This Mac", directory: nil, contentKind: "terminal",
            terminalAvailable: true, agent: "claude", phase: "idle", connection: "Connected", selected: false, summary: "",
            account: "personal", accountMismatch: nil)
        let encoded = String(decoding: try JSONEncoder().encode(pane), as: UTF8.self)
        #expect(encoded.contains(#""account":"personal""#) && !encoded.contains(".claude"))
    }
}
