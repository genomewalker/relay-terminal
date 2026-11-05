import Foundation
import Testing
@testable import Relay

@Suite("Agent accounts: workspaces, expectations, removal and routing settings")
@MainActor
struct AgentAccountsUXTests {
    func status(_ label: String, provider: String = "claude", loggedIn: String = "yes", email: String? = nil,
                plan: String? = nil, workspace: String? = nil, workspaceKey: String? = nil,
                expect: (String, String, String)? = nil, probe: String? = nil, reason: String? = nil,
                isDefault: Bool = false) throws -> RelayAgentAccountStatus {
        var object: [String: Any] = ["provider": provider, "label": label, "dir": isDefault ? "~/.\(provider)" : "~/.\(provider)-\(label)",
                                     "root": "/h/.\(provider)-\(label)", "default": isDefault, "exists": true, "logged_in": loggedIn]
        object["email"] = email
        object["plan"] = plan
        object["workspace"] = workspace
        object["workspace_key"] = workspaceKey
        object["probe"] = probe
        object["probe_reason"] = reason
        if let expect {
            object["expect_workspace"] = expect.0
            object["expect_plan"] = expect.1
            object["expect_key"] = expect.2
        }
        return try JSONDecoder().decode(RelayAgentAccountStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func codexUsage(_ label: String, email: String, plan: String, workspaceKey: String) throws -> RelayAgentAccountUsage {
        let json = #"{"provider":"codex","label":"\#(label)","status":"ok","read_at":"\#(ISO8601DateFormatter().string(from: Date()))","windows":[],"email":"\#(email)","plan":"\#(plan)","workspace_key":"\#(workspaceKey)"}"#
        return try JSONDecoder().decode(RelayAgentAccountUsage.self, from: Data(json.utf8))
    }

    @Test("The same email in another organization is a different workspace; the same organization is a duplicate")
    func identityComparison() throws {
        let business = try status("business", email: "ana@example.org", plan: "team", workspace: "AEGIS-micro", workspaceKey: "1111aaaa1111aaaa")
        let personal = try status("personal", email: "ana@example.org", plan: "max", workspace: "Ana's Organization", workspaceKey: "2222bbbb2222bbbb")
        let colleague = try status("shared", email: "bo@example.org", plan: "team", workspace: "AEGIS-micro", workspaceKey: "1111aaaa1111aaaa")
        func slot(_ status: RelayAgentAccountStatus) -> (label: String, expected: RelayAgentAccountExpectation, current: RelayAgentAccountWorkspace?) {
            (status.label, status.expectation, RelayAgentAccountIdentity.current(status: status, usage: nil))
        }
        let distinct = RelayAgentAccountIdentity.findings([slot(business), slot(personal)])
        #expect(distinct.isEmpty)
        let duplicate = RelayAgentAccountIdentity.findings([slot(business), slot(personal), slot(colleague)])
        #expect(duplicate["shared"] == [.duplicate(of: "business", title: "AEGIS-micro · Team")])
        #expect(duplicate["business"] == nil && duplicate["personal"] == nil)
        // The row leads with workspace and plan; the email is secondary.
        #expect(RelayAgentAccountSummary.identity(status: business, usage: nil) == "AEGIS-micro · Team (ana@example.org)")

        // Codex: same email, two workspaces (team and personal Pro) are distinct.
        let codexWork = try status("business", provider: "codex"), codexPersonal = try status("personal", provider: "codex")
        let team = try codexUsage("business", email: "ana@example.org", plan: "team", workspaceKey: "3333cccc3333cccc")
        let pro = try codexUsage("personal", email: "ana@example.org", plan: "pro", workspaceKey: "4444dddd4444dddd")
        let samePro = try codexUsage("personal", email: "ana@example.org", plan: "pro", workspaceKey: "3333cccc3333cccc")
        let codexCurrent = RelayAgentAccountIdentity.current(status: codexPersonal, usage: pro)
        #expect(codexCurrent?.title == "Pro · workspace #4444")
        #expect(RelayAgentAccountIdentity.findings([
            ("business", .init(), RelayAgentAccountIdentity.current(status: codexWork, usage: team)),
            ("personal", .init(), codexCurrent)]).isEmpty)
        #expect(RelayAgentAccountIdentity.findings([
            ("business", .init(), RelayAgentAccountIdentity.current(status: codexWork, usage: team)),
            ("personal", .init(), RelayAgentAccountIdentity.current(status: codexPersonal, usage: samePro))])["personal"]?.count == 1)
    }

    @Test("A sign-in to another workspace or plan than the slot expects is reported, with what to choose")
    func expectationMismatch() throws {
        let expected = RelayAgentAccountExpectation(workspace: "AEGIS-micro", plan: "team")
        let wrong = try status("business", email: "ana@example.org", plan: "max", workspace: "Ana's Organization",
                               workspaceKey: "2222bbbb2222bbbb", expect: ("AEGIS-micro", "team", ""))
        let right = try status("business", email: "other@example.org", plan: "team", workspace: "aegis-micro",
                               workspaceKey: "1111aaaa1111aaaa", expect: ("AEGIS-micro", "Team", ""))
        let mismatch = RelayAgentAccountIdentity.mismatch(wrong.expectation, current: .current(wrong))
        #expect(mismatch == "Signed in to Ana's Organization · Max; expected workspace AEGIS-micro, expected plan Team")
        #expect(RelayAgentAccountIdentity.mismatch(right.expectation, current: .current(right)) == nil)
        // A pinned key decides even when the names agree.
        let pinned = RelayAgentAccountExpectation(workspace: "", plan: "", key: "9999eeee9999eeee")
        #expect(RelayAgentAccountIdentity.mismatch(pinned, current: .current(right)) != nil)
        #expect(RelayAgentAccountIdentity.findings([("business", wrong.expectation, .current(wrong))])["business"]?.count == 1)

        // The login outcome reports the resulting workspace and refuses a mismatch or a duplicate.
        let started = Date()
        func checked(_ status: RelayAgentAccountStatus) -> RelayAgentAccountStatus { status.probed(at: started.addingTimeInterval(1)) }
        let failed = RelayAgentLoginMonitor.outcome(status: checked(try status("business", email: "ana@example.org", plan: "max",
            workspace: "Ana's Organization", workspaceKey: "2222bbbb2222bbbb", probe: "ok")), checkStarted: started, freshUsage: nil,
            provider: "claude", replacing: false, replacedKey: nil, paneClosed: false, expected: expected)
        #expect(failed == .failed("Signed in to Ana's Organization · Max; expected workspace AEGIS-micro, expected plan Team. Sign in again and choose AEGIS-micro on the page."))
        let duplicate = RelayAgentLoginMonitor.outcome(status: checked(try status("personal", email: "bo@example.org", plan: "team",
            workspace: "AEGIS-micro", workspaceKey: "1111aaaa1111aaaa", probe: "ok")), checkStarted: started, freshUsage: nil,
            provider: "claude", replacing: false, replacedKey: nil, paneClosed: false, others: ["business": "1111aaaa1111aaaa"])
        #expect(duplicate == .failed("Signed in to AEGIS-micro · Team, the same workspace as business. Sign in again and choose another workspace."))
        let fine = RelayAgentLoginMonitor.outcome(status: checked(try status("business", email: "ana@example.org", plan: "team",
            workspace: "AEGIS-micro", workspaceKey: "1111aaaa1111aaaa", probe: "ok")), checkStarted: started, freshUsage: nil,
            provider: "claude", replacing: false, replacedKey: nil, paneClosed: false, expected: expected,
            others: ["personal": "2222bbbb2222bbbb"])
        #expect(fine == .finished("Signed in to AEGIS-micro · Team as ana@example.org."))
    }

    @Test("The sign-in checklist names the expected workspace and a device code from the pane")
    func guidedSignIn() {
        let steps = RelayAgentAccountIdentity.checklist(provider: "codex", expected: .init(workspace: "AEGIS-micro", plan: "team"),
                                                        deviceCode: "ABCD-12345")
        #expect(steps == ["Enter the code ABCD-12345 on the page.", "Choose the workspace AEGIS-micro (Team).",
                          "Approve, then come back: Relay checks which workspace signed in."])
        let pane = "Follow these steps\n1. Open https://auth.openai.com/codex/device\n2. Enter this one-time code\n   WXYZ-9K7Q2\n(expires in 15 minutes)"
        #expect(RelayAgentAccountIdentity.deviceCode(in: pane) == "WXYZ-9K7Q2")
        #expect(RelayAgentAccountIdentity.deviceCode(in: "date 2026-10-18 and uuid 1234-5678-9abc") == nil)
    }

    @Test("A failed check says why; its earlier workspace is never shown as current")
    func probeReason() throws {
        let failed = try status("personal", provider: "codex", loggedIn: "unknown", workspace: nil, probe: "failed",
                                reason: "codex did not answer in 12 s; its tmp/arg0 folder holds 80053 entries")
            .probed(at: Date())
        #expect(failed.checkFailed && failed.probeReason?.contains("did not answer in 12 s") == true)
        let earlier = try status("personal", email: "a@example.org", plan: "max", workspace: "Org", workspaceKey: "5555ffff5555ffff",
                                 probe: "failed").probed(at: Date())
        #expect(earlier.workspace == nil && earlier.workspaceKey == nil)
        #expect(RelayAgentAccountIdentity.current(status: earlier, usage: nil) == nil)
    }

    @Test("Removing an account updates only this host's rule and reports rules that apply elsewhere; a rename follows the label")
    func removeAndRenameRules() {
        let workspace = UUID()
        var rules = RelayAgentAccountRules()
        rules.global["codex"] = "personal"
        rules.hosts["dandy-07"] = ["codex": "personal", "claude": "business"]
        rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)] = ["codex": "personal"]
        let (removed, stale) = rules.removing(provider: "codex", label: "personal", host: "dandy-07")
        #expect(removed.hosts["dandy-07"] == ["claude": "business"])
        #expect(removed.global["codex"] == "personal")
        #expect(stale == ["all hosts", "workspace " + String(RelayAgentAccountRules.workspaceKey(workspace).prefix(8))])
        let (renamed, staleRename) = rules.renaming(provider: "codex", from: "personal", to: "pro", host: "dandy-07")
        #expect(renamed.hosts["dandy-07"]?["codex"] == "pro" && renamed.global["codex"] == "personal")
        #expect(staleRename.count == 2)
        #expect(rules.effectiveSummary(provider: "codex", hostKey: "local", hostName: "This Mac",
            accounts: [.init(provider: "codex", label: "business", dir: "~/.codex-business"), .init(provider: "codex", label: "personal", dir: "")],
            title: { $0.label == "personal" ? "Pro" : nil }) == "New Codex agents use: personal (Pro) on all hosts; 1 workspace uses its own rule")
    }

    @Test("Remove is refused while an agent pane on that host uses the account")
    func removeRefusesInUse() {
        let account = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
        let other = RelayAgentAccount(provider: "claude", label: "business", dir: "")
        let refusal = RelayAgentAccountsSettingsView.inUseRefusal(account, hostKey: "dandy-07", hostName: "dandy-07",
            agents: [("dandy-07", account), ("dandy-07", other), ("local", account)])
        #expect(refusal == "personal is in use by 1 agent pane on dandy-07. Stop it before removing the account; nothing was changed.")
        // The same label on another host, or another account here, does not block.
        #expect(RelayAgentAccountsSettingsView.inUseRefusal(account, hostKey: "dandy-07", hostName: "dandy-07",
            agents: [("local", account), ("dandy-07", other), ("dandy-07", nil)]) == nil)
    }

    @Test("Routing rules are read and replaced through the settings tools, validated before any write")
    func routingThroughSettings() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("relay-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let routing = RelayAgentAccountRouting(url: file)
        let control = RelaySettingsControl(routing: routing), instance = UUID()
        let before = try control.snapshot(instance: instance)
        #expect(before.values["agent_account_rules"] == .accountRules(RelayAgentAccountRules()))
        #expect(before.definitions.contains { $0.key == "agent_account_rules" && $0.type == "object" })

        let workspace = UUID()
        let body = #"{"instance":"\#(instance.uuidString)","request_id":"\#(UUID().uuidString)","expected_revision":"\#(before.revision)","changes":{"agent_account_rules":{"version":1,"global":{"codex":"personal"},"hosts":{"dandy-07":{"claude":"business"}},"workspaces":{"\#(workspace.uuidString)":{"codex":"business"}}}}}"#
        let proposal = try JSONDecoder().decode(RelaySettingsProposal.self, from: Data(body.utf8))
        let after = try control.apply(proposal)
        #expect(routing.rules.global == ["codex": "personal"])
        #expect(routing.rules.hosts["dandy-07"] == ["claude": "business"])
        #expect(routing.rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)] == ["codex": "business"])
        #expect(after.revision != before.revision)
        // The snapshot encodes the rules the same way they are sent.
        let encoded = try JSONEncoder().encode(after.values["agent_account_rules"])
        let decoded = try JSONDecoder().decode(RelaySettingValue.self, from: encoded)
        #expect(decoded == after.values["agent_account_rules"])

        for bad in [#"{"version":1,"global":{"gemini":"x"}}"#, #"{"version":1,"global":{"codex":"Bad Label"}}"#,
                    #"{"version":1,"workspaces":{"not-a-uuid":{"codex":"x"}}}"#, #"{"version":2}"#, #"{}"#] {
            let value = try JSONDecoder().decode(RelaySettingValue.self, from: Data(bad.utf8))
            #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["agent_account_rules": value]) }
        }
        // Rules never land in key bindings or the reverse.
        #expect(throws: (any Error).self) { try RelaySettingsPolicy.validate(["key_bindings": .accountRules(.init())]) }
        let stale = RelaySettingsProposal(instance: instance, requestID: UUID(), expectedRevision: before.revision,
                                          changes: ["agent_account_rules": .accountRules(.init())])
        #expect(throws: (any Error).self) { try control.apply(stale) }
        #expect(routing.rules.global == ["codex": "personal"])
    }

    @Test("Edits validate label, expectation and model before anything is sent")
    func editDraft() throws {
        let status = try status("business", provider: "codex", expect: ("AEGIS-micro", "team", ""))
        var draft = RelayAgentAccountEditDraft(account: status.account, status: status)
        #expect(draft.expected.workspace == "AEGIS-micro" && draft.problem == nil)
        draft.label = "Bad Label"
        #expect(draft.problem != nil)
        draft.label = "work"; draft.model = "gpt-rosalind-5.5"; draft.effort = "xhigh"
        #expect(draft.problem == nil)
        draft.model = "two words"
        #expect(draft.problem != nil)
        draft.model = ""; draft.expected.workspace = String(repeating: "x", count: 65)
        #expect(draft.problem != nil)
        #expect(RelayAgentAccountEditDraft.efforts("claude").contains("max") && !RelayAgentAccountEditDraft.efforts("codex").contains("max"))
    }

    @Test("An expectation the provider does not report is unverified, never a verified sign-in")
    func unverifiedExpectation() throws {
        let started = Date()
        let signedIn = try status("personal", provider: "codex", probe: "ok").probed(at: started.addingTimeInterval(1))
        let noKey = try JSONDecoder().decode(RelayAgentAccountUsage.self, from: Data(#"{"provider":"codex","label":"personal","status":"ok","read_at":"2026-10-18T07:00:00Z","windows":[],"email":"ana@example.org","plan":"pro"}"#.utf8))
        let pinned = RelayAgentAccountExpectation(workspace: "", plan: "pro", key: "2222bbbb2222bbbb")
        let current = RelayAgentAccountIdentity.current(status: signedIn, usage: noKey)
        #expect(RelayAgentAccountIdentity.mismatch(pinned, current: current) == nil)
        #expect(RelayAgentAccountIdentity.unverified(pinned, current: current) != nil)
        let outcome = RelayAgentLoginMonitor.outcome(status: signedIn, checkStarted: started, freshUsage: noKey, provider: "codex",
            replacing: false, replacedKey: nil, paneClosed: false, expected: pinned)
        #expect(outcome == .failed("Signed in to Pro, but the provider did not report enough to verify the workspace pinned for this slot. Refresh status to check again."))
        let finding = RelayAgentAccountIdentity.findings([("personal", pinned, current)])["personal"]
        #expect(finding?.count == 1 && finding?.first?.isUnverified == true)

        // Codex reports no workspace name: only a matching pinned key confirms one.
        let keyed = try codexUsage("personal", email: "ana@example.org", plan: "pro", workspaceKey: "2222bbbb2222bbbb")
        let named = RelayAgentAccountExpectation(workspace: "Personal", plan: "pro", key: "")
        let keyedCurrent = RelayAgentAccountIdentity.current(status: signedIn, usage: keyed)
        #expect(RelayAgentAccountIdentity.unverified(named, current: keyedCurrent)?.contains("pin the workspace") == true)
        #expect(RelayAgentAccountIdentity.unverified(.init(workspace: "Personal", plan: "pro", key: "2222bbbb2222bbbb"), current: keyedCurrent) == nil)
        #expect(RelayAgentLoginMonitor.outcome(status: signedIn, checkStarted: started, freshUsage: keyed, provider: "codex",
            replacing: false, replacedKey: nil, paneClosed: false, expected: .init(workspace: "Personal", plan: "pro", key: "2222bbbb2222bbbb"))
            == .finished("Signed in to Pro · workspace #2222 as ana@example.org."))

        // Claude without a reported plan cannot confirm an expected plan.
        let noPlan = try status("business", workspace: "AEGIS-micro", workspaceKey: "1111aaaa1111aaaa")
        #expect(RelayAgentAccountIdentity.unverified(.init(workspace: "AEGIS-micro", plan: "team"), current: .current(noPlan)) != nil)
        #expect(RelayAgentAccountIdentity.unverified(.init(workspace: "AEGIS-micro"), current: .current(noPlan)) == nil)
        // Nothing expected, nothing to verify.
        #expect(RelayAgentAccountIdentity.unverified(.init(), current: current) == nil)
    }

    @Test("Only the user's own Settings action removes an account; tool routes never carry account operations")
    func removalOrigin() async throws {
        #expect(RelayAgentAccountMovePolicy.removalRefusal(.user) == nil)
        for origin in [RelayAgentAccountMoveOrigin.mcp, .assistant, .maintenance] {
            #expect(RelayAgentAccountMovePolicy.removalRefusal(origin) != nil)
        }
        #expect(!RelaySidePanelServer.toolHostOperations.contains("agent_accounts"))
        #expect(RelaySidePanelServer.toolHostOperations.isSuperset(of: ["exec", "status", "file_read", "file_write"]))
    }
}

private extension RelayAgentAccountWorkspace {
    static func current(_ status: RelayAgentAccountStatus) -> RelayAgentAccountWorkspace? {
        RelayAgentAccountIdentity.current(status: status, usage: nil)
    }
}
