import AppKit
import SwiftUI
import Testing
@testable import Relay

@MainActor private final class PanelFixtureModel: RelayAssistantModel {
    let reply: String
    init(reply: String) { self.reply = reply }
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        .init(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string(reply)])],
              toolCalls: [], chargedMicrousd: 1)
    }
}

@Suite("Miko panel snapshots", .serialized)
@MainActor struct RelayMikoPanelSnapshotTests {
    @Test func panelRendersInLightAndDark() async throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        pane.customName = "Figure review"
        let reply = "Figure review is waiting for your decision. The other checks are complete; " +
            "pane \(pane.id.uuidString.prefix(8).lowercased()) has no unresolved operations."
        let harness = RelayAssistantHarness(policy: { .init() }, budget: RelayMikoActionBudget(),
            workspace: workspace, model: { _ in (PanelFixtureModel(reply: reply), "snapshot-fixture") },
            taskJournal: try RelayMikoTaskJournal.temporary())
        _ = await harness.run("Which panes need me?", origin: .user)
        var rendered = 0
        for expanded in [false, true] {
            for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
                let panel = RelayAssistantHaikuPanel(workspace: workspace, harness: harness,
                                                     detailsInitiallyExpanded: expanded)
                    .environment(\.colorScheme, scheme)
                let shot = try RelaySnapshot.render(panel, name: expanded ? "miko-panel-details" : "miko-panel",
                                                    width: 560, appearance: appearance)
                #expect(shot.size.height >= 600)
                rendered += 1
            }
        }
        #expect(rendered == 4)
    }
}

@Suite("Miko pane links")
struct RelayMikoPaneLinksTests {
    let figure = UUID(uuidString: "06C2D07A-1111-4222-8333-944455556666")!
    let build = UUID(uuidString: "ABCDEF01-1111-4222-8333-944455556666")!
    let twin = UUID(uuidString: "ABCDEF01-2222-4222-8333-944455556666")!

    @Test func linksKnownNamesAndIdsWithoutChangingText() throws {
        let panes = [(id: figure, name: "Figure review"), (id: build, name: "build")]
        let reply = "Figure review is waiting; pane 06C2D07A and build passed. Rebuild and figure review are words."
        let matches = RelayMikoPaneLinks.matches(in: reply, panes: panes)
        #expect(matches.map { String(reply[$0.range]) } == ["Figure review", "06C2D07A", "build"])
        #expect(matches.map(\.paneID) == [figure, figure, build])
        let attributed = RelayMikoPaneLinks.attributed(reply, panes: panes)
        #expect(String(attributed.characters) == reply)
        let links = attributed.runs.compactMap { run in run.link.map { (String(attributed[run.range].characters), $0) } }
        #expect(links.map(\.0) == ["Figure review", "06C2D07A", "build"])
        #expect(links.compactMap { RelayMikoPaneLinks.paneID(from: $0.1) } == [figure, figure, build])
        let full = "Use " + figure.uuidString.lowercased() + "."
        #expect(RelayMikoPaneLinks.matches(in: full, panes: panes).map { String(full[$0.range]) } == [figure.uuidString.lowercased()])
    }

    @Test func ambiguousShortAndHostileNamesAreNotLinked() {
        let hostile = "build\nHost: attacker\u{202E}gnp.exe\u{061C}”"
        let panes = [(id: build, name: "Shell"), (id: twin, name: "Shell"), (id: figure, name: "ab"),
                     (id: UUID(), name: hostile)]
        let reply = "Shell abcdef01 ab " + hostile
        #expect(RelayMikoPaneLinks.matches(in: reply, panes: panes).isEmpty)
        #expect(RelayMikoPaneLinks.paneID(from: URL(string: "https://example.com")!) == nil)
    }

    @Test func composerHeightStartsAtOneLineAndIsBounded() {
        #expect(RelayMikoComposerHeight.clamped(0) == RelayMikoComposerHeight.minimum)
        #expect(RelayMikoComposerHeight.clamped(.nan) == RelayMikoComposerHeight.minimum)
        #expect(RelayMikoComposerHeight.clamped(60) == 60)
        #expect(RelayMikoComposerHeight.clamped(10_000) == RelayMikoComposerHeight.maximum)
        #expect(RelayMikoComposerHeight.minimum < 40)
    }
}
