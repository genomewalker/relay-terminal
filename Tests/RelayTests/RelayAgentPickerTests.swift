import Foundation
import Testing
@testable import Relay

@Suite("Start-agent popover")
struct RelayAgentPickerTests {
    private let claudeWork = RelayAgentAccount(provider: "claude", label: "work", dir: "")
    private let claudePersonal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
    private let codexWork = RelayAgentAccount(provider: "codex", label: "work", dir: "")
    private let codexPersonal = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")

    @Test func oneRowPerProviderInProviderOrder() {
        let rows = RelayAgentPickerRow.rows(accounts: [codexWork, claudePersonal, codexPersonal, claudeWork], choices: [:])
        #expect(rows.map(\.provider) == ["claude", "codex"])
        #expect(rows.map(\.title) == ["Claude", "Codex"])
        #expect(rows[0].accounts == [claudePersonal, claudeWork])
        #expect(rows[1].accounts == [codexWork, codexPersonal])
        #expect(RelayAgentPickerRow.rows(accounts: [codexWork], choices: [:]).map(\.provider) == ["codex"])
    }

    @Test func theRoutingRulesAccountIsPreselected() {
        let rows = RelayAgentPickerRow.rows(accounts: [claudeWork, claudePersonal, codexWork, codexPersonal], choices: [
            "claude": RelayAgentAccountChoice(account: claudePersonal, source: .workspace),
        ])
        #expect(rows[0].preselected == claudePersonal)
        // Without a rule: the account on the provider's default directory.
        #expect(rows[1].preselected == codexWork)
    }

    @Test func withoutARuleTheDefaultDirectoryWinsOverListOrder() {
        let rows = RelayAgentPickerRow.rows(accounts: [claudePersonal, claudeWork], choices: [:])
        #expect(rows[0].preselected == claudeWork)
        let named = RelayAgentPickerRow.rows(accounts: [claudePersonal], choices: [:])
        #expect(named[0].preselected == claudePersonal)
    }

    @Test func aRuleNamingAnAccountTheHostLacksIsIgnored() {
        let elsewhere = RelayAgentAccount(provider: "claude", label: "lab", dir: "~/.claude-lab")
        let rows = RelayAgentPickerRow.rows(accounts: [claudePersonal, claudeWork], choices: [
            "claude": RelayAgentAccountChoice(account: elsewhere, source: .host),
        ])
        #expect(rows[0].preselected == claudeWork)
    }

    @Test func hoverShowsTheDirectoryThenUsage() {
        #expect(RelayAgentPickerRow.help(claudeWork, summary: "", suggested: false) == "~/.claude")
        #expect(RelayAgentPickerRow.help(claudePersonal, summary: "a@b · 5h 12%", suggested: true)
            == "~/.claude-personal\na@b · 5h 12%\nMost headroom now")
    }

    @Test func returnStartsThePanesOwnAgentElseTheFirstRow() {
        let rows = RelayAgentPickerRow.rows(accounts: [claudeWork, codexWork], choices: [:])
        #expect(RelayAgentPickerRow.returnRow(rows, paneKind: .codex) == "codex")
        #expect(RelayAgentPickerRow.returnRow(rows, paneKind: .claude) == "claude")
        #expect(RelayAgentPickerRow.returnRow(rows, paneKind: .shell) == "claude")
        let codexOnly = RelayAgentPickerRow.rows(accounts: [codexWork], choices: [:])
        #expect(RelayAgentPickerRow.returnRow(codexOnly, paneKind: .claude) == "codex")
        #expect(RelayAgentPickerRow.returnRow([], paneKind: .shell) == nil)
    }

    @Test func onlyAShellTakesTheAgentInPlace() {
        #expect(RelayAgentPickerRow.action(paneKind: .shell, newTab: false) == .here)
        #expect(RelayAgentPickerRow.action(paneKind: .shell, newTab: true) == .newTab)
        #expect(RelayAgentPickerRow.action(paneKind: .claude, newTab: false) == .newTab)
        #expect(RelayAgentPickerRow.action(paneKind: .codex, newTab: false) == .newTab)
    }

    @Test func aWorkspaceDefaultIsNotSetTwice() {
        let workspaceDefault = RelayAgentAccountChoice(account: claudeWork, source: .workspace)
        let hostDefault = RelayAgentAccountChoice(account: claudeWork, source: .host)
        let none: RelayAgentAccountChoice? = nil
        #expect(RelayAgentPickerRow.canMakeDefault(claudeWork, choice: none) == false)
        #expect(RelayAgentPickerRow.canMakeDefault(claudeWork, choice: workspaceDefault) == false)
        #expect(RelayAgentPickerRow.canMakeDefault(claudeWork, choice: hostDefault))
        #expect(RelayAgentPickerRow.canMakeDefault(claudePersonal, choice: workspaceDefault))
    }
}
