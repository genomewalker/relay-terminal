import AppKit
import SwiftUI
import Testing
@testable import Relay

@Suite("Pane header name") struct PaneHeaderNameTests {
    @Test func hidesOnlyTheAgentAndSixHexSuffix() {
        #expect(PaneHeaderName.visible("Sapropel - annotation jobs - claude 767dc7") == "Sapropel - annotation jobs")
        #expect(PaneHeaderName.visible("annotation jobs Codex 0a1b2c") == "annotation jobs")
    }

    @Test func leavesUserChosenNamesAlone() {
        for name in ["claude 767dc7",                       // nothing left to show
                     "Sapropel - claude 767dc7x",           // not a 6-hex id
                     "Sapropel - claude 767DC7",            // ids are lowercase
                     "Sapropel - claude facade",            // a word, not an id
                     "Sapropel - shell 767dc7",             // not a generated agent label
                     "Sapropel - build 767dc7",
                     "Sapropel claude 767dc7 notes",        // not trailing
                     "annotation jobs", "dandy-07", ""] {
            #expect(PaneHeaderName.visible(name) == name, "\(name)")
        }
    }
}

/// Offscreen renders of the pane header. PNGs go to RELAY_SNAPSHOT_DIR when set.
@MainActor @Suite("Pane header snapshots", .serialized) struct PaneHeaderSnapshotTests {
    private static let host = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07.ux-header.invalid")

    private func pane(name: String, kind: AgentKind, phase: AgentPhase, summary: String,
                      state: PaneConnectionState = .connected, account: String? = nil) -> PaneModel {
        let saved = PersistedAgentPaneState(cursor: 0, kind: kind, phase: phase, summary: summary, subagents: [],
                                            activities: [], resourceUsage: nil, progressPercent: nil, pendingApprovals: 0)
        let pane = PaneModel(profile: Self.host, customName: name, directory: "/projects/sapropel", savedAgentState: saved)
        pane.connectionState = state
        if let account { pane.recordAgentAccount(RelayAgentAccount(provider: kind.rawValue, label: account, dir: "~/.\(kind.rawValue)-\(account)")) }
        return pane
    }

    private func cases() -> [(String, PaneModel)] {
        [("claude-idle", pane(name: "Sapropel - annotation jobs - claude 767dc7", kind: .claude, phase: .quiet,
                              summary: "Subagent finished", account: "business")),
         ("codex-waiting", pane(name: "Sapropel - read mapping - codex 1f3a9c", kind: .codex, phase: .needsInput,
                                summary: "Waiting for approval")),
         ("reconnecting", pane(name: "Sapropel - annotation jobs - claude 767dc7", kind: .claude, phase: .active,
                               summary: "Working", state: .reconnecting("link"), account: "business")),
         ("exited", pane(name: "Sapropel - annotation jobs - claude 767dc7", kind: .claude, phase: .exited,
                         summary: "Exited"))]
    }

    @Test func rendersAtWideAndNarrowWidthsInBothAppearances() throws {
        var rendered = 0
        for (label, pane) in cases() {
            if label == "exited" { pane.lastCommandExitCode = 2 }
            for width in [CGFloat(1200), 520] {
                for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
                    let view = ConnectionPath(pane: pane, active: true, compact: false, zoomed: false, isFloating: false,
                                              select: {}, toggleZoom: {}, toggleFloating: {}, rename: {}, terminate: nil, close: {})
                        .environmentObject(PaneLinkSelection())
                        .environment(\.colorScheme, scheme)
                    let result = try RelaySnapshot.render(view, name: "header-\(label)-\(Int(width))", width: width,
                                                          appearance: appearance)
                    #expect(result.size.width == width && result.size.height > 10)
                    rendered += 1
                }
            }
        }
        #expect(rendered == 16)
    }
}
