import Foundation
import Testing
@testable import Relay

/// "← N agent" in Claude's footer counts the user's Claude background agent
/// jobs on the host as well as the pane's own subagents. A move goes ahead
/// only when relayd's evidence accounts for every footer agent: the pane's
/// subagents all finished (main-transcript lifecycle and relayd's live event
/// state), Claude reports the bound process idle, and the host has at least
/// that many background agent jobs outside the pane.
@Suite("Account move footer agent count")
struct RelayAgentMoveFooterTests {
    private let paneID = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
    private let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
    /// The footer seen on idle dandy-07 panes on 2026-10-18 while one
    /// background agent job (fqdup 5577ee9d) was working.
    private let idleWithAgentFooter = "❯ \n────────────────\n  ~ | [Opus 5.5] | 2h10m\n" +
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent\n"

    private func proof(backgroundWork: Bool? = false, subagentWork: Bool? = false, harness: String? = "idle",
                       hostJobs: Int? = 1) throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"relayd agent claude --resume exact-session","move_command":"CLAUDE_CONFIG_DIR=/home/u/.claude-personal relayd agent claude --resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var value = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        value.backgroundWork = backgroundWork
        value.subagentWork = subagentWork
        value.harnessStatus = harness
        value.backgroundAgentJobs = hostJobs
        return value
    }

    /// The move's admission: the screen is read with the agents relayd accounts for.
    private func refusal(_ proof: RelayAgentMaintenanceProbe, screen: String, activeSubagents: Int = 0) -> String? {
        let explained = RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: activeSubagents)
        let empty = RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude", explainedAgents: explained)
        let work = RelayAgentMaintenancePrompt.backgroundWork(screen, provider: "claude", explainedAgents: explained)
        return RelayAgentAccountMovePolicy.refusal(proof, paneID: paneID, target: personal,
            emptyPrompt: empty, hasDraft: false, pendingApprovals: 0, inputAge: 60,
            promptBlocker: empty ? nil : work.map { "the footer shows background work (\($0))" } ?? "unrecognised")
    }

    @Test("The proof decodes relayd's subagent, harness and host-job fields")
    func harnessFieldsDecode() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(
            #"{"version":1,"subagent_work":false,"harness_status":"idle","background_agent_jobs":3}"#.utf8))
        #expect(value.subagentWork == false && value.harnessStatus == "idle" && value.backgroundAgentJobs == 3)
        #expect(try proof(subagentWork: true).sameSource(as: proof()) == false)
        #expect(try proof(harness: "shell").sameSource(as: proof()) == false)
        #expect(try proof(hostJobs: 2).sameSource(as: proof()) == false)
    }

    @Test("'← 1 agent' accounted for by a host background job, with the pane idle, allows the move")
    func hostJobExplainsTheFooter() throws {
        #expect(refusal(try proof(), screen: idleWithAgentFooter) == nil)
        let two = idleWithAgentFooter.replacingOccurrences(of: "← 1 agent", with: "← 2 agents")
        #expect(refusal(try proof(hostJobs: 2), screen: two) == nil)
        #expect(refusal(try proof(hostJobs: 1), screen: two)?.contains("← 2 agents") == true)
        // No agent count: nothing to account for, whatever the evidence.
        let plain = idleWithAgentFooter.replacingOccurrences(of: " · ← 1 agent", with: "")
        #expect(refusal(try proof(subagentWork: nil, harness: nil, hostJobs: nil), screen: plain) == nil)
    }

    @Test("A pane subagent without a terminal record, or active in relayd's events, holds the move")
    func paneSubagentsHold() throws {
        #expect(refusal(try proof(subagentWork: true), screen: idleWithAgentFooter) != nil)
        #expect(refusal(try proof(subagentWork: nil), screen: idleWithAgentFooter) != nil)
        #expect(refusal(try proof(), screen: idleWithAgentFooter, activeSubagents: 1) != nil)
    }

    @Test("Root's probe (bffad733): a running subagent holds even on a footerless screen")
    func runningSubagentHoldsWithoutFooter() throws {
        let plain = idleWithAgentFooter.replacingOccurrences(of: " · ← 1 agent", with: "")
        let reason = refusal(try proof(subagentWork: true), screen: plain)
        #expect(reason?.contains("subagents to finish") == true)
        let held = RelayAgentMaintenancePolicy.deferral(try proof(subagentWork: true), paneID: paneID, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60)
        #expect(held?.contains("subagents to finish") == true)
        // Without positive evidence a footerless screen does not hold on subagents.
        #expect(refusal(try proof(subagentWork: nil), screen: plain) == nil)
        #expect(refusal(try proof(subagentWork: false), screen: plain) == nil)
    }

    @Test("Claude's own status must be idle, matched to the bound process")
    func harnessStatusMustBeIdle() throws {
        #expect(refusal(try proof(harness: "shell"), screen: idleWithAgentFooter) != nil)
        #expect(refusal(try proof(harness: nil), screen: idleWithAgentFooter) != nil)
    }

    @Test("Without host background jobs to account for it, the footer agent count holds")
    func noHostJobsHold() throws {
        #expect(refusal(try proof(hostJobs: 0), screen: idleWithAgentFooter) != nil)
        #expect(refusal(try proof(hostJobs: nil), screen: idleWithAgentFooter) != nil)
    }

    @Test("A native child agent process refuses even when every agent is accounted for")
    func nativeChildAgentRefuses() throws {
        let reason = refusal(try proof(backgroundWork: true), screen: idleWithAgentFooter)
        #expect(reason?.contains("background shells or agent processes") == true)
    }

    @Test("An unavailable native process check refuses with a clear reason")
    func unavailableNativeCheckRefuses() throws {
        let reason = refusal(try proof(backgroundWork: nil), screen: idleWithAgentFooter)
        #expect(reason?.contains("native process check is unavailable") == true)
    }

    @Test("Footer shells still hold even when every agent is accounted for")
    func footerShellsStillHold() throws {
        let shells = idleWithAgentFooter.replacingOccurrences(of: "← 1 agent", with: "← 1 agent · 3 shells")
        #expect(refusal(try proof(), screen: shells) != nil)
    }

    @Test("Maintenance invokes the native daemon with exact host, pane and accounts")
    func nativeMaintenanceCommandPreservesSelectors() throws {
        let expected = RelayAgentAccount(provider: "claude", label: "team", dir: "~/.claude-team")
        let remote = ConnectionProfile.sshConfigHost("maintenance-fixture.invalid")
        for profile in [ConnectionProfile.local, remote] {
            let command = try RelayAgentMaintenanceReader.maintenanceCommand(profile: profile, paneID: paneID,
                expectedAccount: expected, targetAccount: personal)
            let binary = profile.kind == .local
                ? "'" + Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd").path + "'"
                : "\"$HOME/.local/bin/relayd\""
            #expect(command == binary + " 'agent-maintenance' '--pane' '7d85fd72-64ec-46a4-8591-567bf64f7c93' '--expect-account' '~/.claude-team' '--target-account' '~/.claude-personal'")
            #expect(!command.contains("python"))
        }
        let invalid = RelayAgentAccount(provider: "claude", label: "bad", dir: "~/../escape")
        #expect(throws: (any Error).self) {
            try RelayAgentMaintenanceReader.maintenanceCommand(profile: .local, paneID: paneID,
                expectedAccount: expected, targetAccount: invalid)
        }
    }
}
