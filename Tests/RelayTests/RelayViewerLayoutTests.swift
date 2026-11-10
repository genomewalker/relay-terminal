import AppKit
import SwiftUI
import Testing
@testable import Relay

/// View CLI conversation uses the shared viewer layout: the pane header's row
/// height, inset, type and colours, and no second copy of the pane's name or
/// status when it is shown inside the pane.
@MainActor @Suite(.serialized) struct RelayViewerLayoutTests {
    @Test func barMatchesThePaneHeaderRow() throws {
        _ = NSApplication.shared
        let compact = RelayPreferences.shared.compactInterface
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let bar = RelayViewerBar(symbol: "text.bubble", title: "Conversation", detail: "Claude · PID 4242 · 6f1d0c2e") {
                RelayViewerIconButton(title: "Refresh", symbol: "arrow.clockwise") {}
            }.environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(bar, name: "viewer-bar", width: 760, appearance: appearance)
            #expect(shot.size.height == RelayViewerMetrics.barHeight(compact: compact))
        }
        #expect(RelayViewerMetrics.barHeight(compact: false) == 34)
        #expect(RelayViewerMetrics.barHeight(compact: true) == 28)
        #expect(RelayViewerMetrics.barPadding == 12)
    }

    @Test func inAPaneTheBarNamesTheViewNotThePane() {
        #expect(RelayAgentTimelineView.headerTitle(paneName: "Sapropel - damage review", inPane: true) == "Conversation")
        #expect(RelayAgentTimelineView.headerTitle(paneName: "Sapropel - damage review", inPane: false) == "Sapropel - damage review")
        #expect(RelayAgentTimelineView.bindingDetail(nil, busy: true) == "Reading the conversation source…")
        #expect(RelayAgentTimelineView.bindingDetail(nil, busy: false) == "Not bound to a conversation")
    }

    @Test func rendersTheConversationInBothAppearancesInPaneAndWindow() throws {
        _ = NSApplication.shared
        var rendered = 0
        for inPane in [true, false] {
            for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
                let pane = RelayNativeChatFixture.pane(active: true)
                pane.nativeConversationVisible = inPane
                let conversation = RelayNativeChatFixture.timelineConversation(pane: pane)
                let store = RelayAgentTimelineStore(pane: pane, presenting: conversation)
                let view = RelayAgentTimelineView(pane: pane, store: store).frame(height: 900)
                    .environment(\.colorScheme, scheme)
                let shot = try RelaySnapshot.render(view, name: "viewer-conversation-\(inPane ? "pane" : "window")",
                                                    width: 760, appearance: appearance)
                #expect(shot.size.height >= 899)
                rendered += 1
            }
        }
        #expect(rendered == 4)
    }
}
