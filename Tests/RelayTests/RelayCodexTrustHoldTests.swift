import Foundation
import Testing
@testable import Relay

/// Case 10 (0.5.113): pane 7b68ee70 (business account) was update-restarted
/// onto Codex 0.170.0 in a non-git subfolder of a project whose parent alone
/// is trusted in ~/.codex-business/config.toml, and stopped at Codex's
/// folder-trust dialog (verification_required). The dialog text is from bc08's
/// read-only viewport read (~06:20Z, 2026-11-18) as reported to this series:
/// "Folder access … Trust this folder? › 1. Trust and continue / 2. Back to
/// Agent Command Center"; the line breaks are reconstructed from that report.
@Suite("Codex folder-trust hold")
struct RelayCodexTrustHoldTests {
    static let trustScreen = [
        "  Folder access", " ",
        "  /Users/kbd606/Documents/Claude/Projects/Patent/drafts", " ",
        "  Trust this folder?", " ",
        "› 1. Trust and continue",
        "  2. Back to Agent Command Center",
    ].joined(separator: "\n")
    static let pane = UUID(uuidString: "7b68ee70-0000-4000-8000-000000000001")!
    static let cwd = "/Users/kbd606/Documents/Claude/Projects/Patent/drafts"

    static func proof(status: String, running: String = "0.169.0", installed: String? = "0.170.0") -> RelayAgentMaintenanceProbe {
        var proof = RelayAgentMaintenanceProbe(version: 1)
        proof.provider = "codex"
        proof.runningVersion = running
        proof.installedVersion = installed
        proof.configDir = "~/.codex-business"
        proof.codexTrust = .init(status: status, cwd: cwd, parent: status == "parent_only" ? "/Users/kbd606/Documents/Claude/Projects/Patent" : nil)
        return proof
    }

    @Test func theTrustDialogIsRecognizedAndNeverAnIdlePrompt() {
        #expect(RelayAgentMaintenancePrompt.isCodexFolderTrustDialog(Self.trustScreen))
        #expect(!RelayAgentMaintenancePrompt.isEmpty(Self.trustScreen, provider: "codex"))
        #expect(!RelayAgentMaintenancePrompt.isCodexFolderTrustDialog("› Ask Codex to do anything"))
        #expect(RelayPaneOperationRefusal.classify(RelayAgentMaintenancePrompt.folderTrustBlocker) == .trustPrompt)
    }

    @Test func anUpdateOnto0170InAParentOnlyTrustedFolderIsHeldBeforeExit() throws {
        let hold = try #require(RelayAgentMaintenancePolicy.codexTrustHold(Self.proof(status: "parent_only"), reason: .update))
        #expect(hold.code == .trustPrompt && hold.code.rawValue == "trust_prompt")
        #expect(hold.blocker == "Update 0.169.0 → 0.170.0 available, held: Codex folder trust required for " + Self.cwd)
        #expect(!hold.howToClear.isEmpty)
    }

    @Test func onlyAFolderThatWouldStopIsHeld() {
        // 0.169.0 accepted the parent's trust.
        #expect(RelayAgentMaintenancePolicy.codexTrustHold(Self.proof(status: "parent_only", installed: "0.169.0"), reason: .update) == nil)
        #expect(RelayAgentMaintenancePolicy.codexTrustHold(Self.proof(status: "trusted"), reason: .update) == nil)
        #expect(RelayAgentMaintenancePolicy.codexTrustHold(Self.proof(status: "unknown"), reason: .update) == nil)
        // Not observed to stop before exit: left to the post-launch check.
        #expect(RelayAgentMaintenancePolicy.codexTrustHold(Self.proof(status: "untrusted"), reason: .update) == nil)
        var claude = Self.proof(status: "parent_only"); claude.provider = "claude"
        #expect(RelayAgentMaintenancePolicy.codexTrustHold(claude, reason: .update) == nil)
    }

    @Test func codexVersionsCompareNumerically() {
        #expect(RelayAgentMaintenancePolicy.codexVersion("0.170.0", atLeast: [0, 170, 0]))
        #expect(RelayAgentMaintenancePolicy.codexVersion("0.171.2", atLeast: [0, 170, 0]))
        #expect(RelayAgentMaintenancePolicy.codexVersion("1.0.0", atLeast: [0, 170, 0]))
        #expect(!RelayAgentMaintenancePolicy.codexVersion("0.169.9", atLeast: [0, 170, 0]))
        #expect(!RelayAgentMaintenancePolicy.codexVersion("0.17.0", atLeast: [0, 170, 0]))
        #expect(!RelayAgentMaintenancePolicy.codexVersion(nil, atLeast: [0, 170, 0]))
    }

    @Test func relaydsTrustObservationDecodes() throws {
        let json = #"{"version":1,"codex_trust":{"status":"parent_only","cwd":"/a/b","parent":"/a"}}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        #expect(proof.codexTrust == .init(status: "parent_only", cwd: "/a/b", parent: "/a"))
    }

    @Test func theMirrorSettingIsOffByDefaultInTheSchemaAndMikoCannotSetIt() throws {
        #expect(RelaySettingsPolicy.definitions.contains { $0.key == "codex_trust_mirror_parent" && $0.type == "boolean" })
        #expect(!RelaySettingsPolicy.allows(changes: ["codex_trust_mirror_parent": .bool(true)], assistantIdentity: true))
        let defaults = UserDefaults(suiteName: "relay.test.codex-trust.\(UUID().uuidString)")!
        #expect(defaults.object(forKey: "relay.settings.agent-maintenance.codex-trust-mirror-parent") == nil)
    }
}
