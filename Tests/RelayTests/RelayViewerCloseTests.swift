import AppKit
import SwiftUI
import Testing
@testable import Relay

/// Every in-window viewer uses the shared viewer bar, whose close button is
/// always the last control on the right, at the pane header's size. The bar
/// itself is checked by pixels; each viewer is rendered in light and dark
/// for review (panel borders and shadows make a pixel rule unreliable there).
@MainActor @Suite(.serialized) struct RelayViewerCloseTests {
    private static let appearances: [(NSAppearance.Name, ColorScheme)] = [(.darkAqua, .dark), (.aqua, .light)]

    /// The rightmost ink in the bar row is the close glyph: within one icon
    /// slot of the bar's right inset, with nothing to its right.
    private static func closeIsLast(_ shot: RelaySnapshot.Result, barTop: Int = 0) -> Bool {
        let rep = shot.bitmap
        let scale = CGFloat(rep.pixelsWide) / shot.size.width
        let barHeight = RelayViewerMetrics.barHeight(compact: RelayPreferences.shared.compactInterface)
        let rows = Int(CGFloat(barTop) * scale)..<Int((CGFloat(barTop) + barHeight) * scale)
        guard let background = rep.colorAt(x: 2, y: rows.lowerBound + 2)?.usingColorSpace(.deviceRGB) else { return false }
        func ink(_ x: Int) -> Bool {
            rows.contains { y in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent)
                    + abs(c.blueComponent - background.blueComponent) > 0.25
            }
        }
        let inset = RelayViewerMetrics.barPadding * scale
        let slot = RelayViewerMetrics.iconSize * scale
        let right = rep.pixelsWide - Int(inset)
        guard let last = (0..<right).reversed().first(where: ink) else { return false }
        return CGFloat(right - last) <= slot && !(right..<(rep.pixelsWide - 1)).contains(where: ink)
    }

    @Test func barDrawsCloseLastAtThePaneHeaderSize() throws {
        _ = NSApplication.shared
        for (appearance, scheme) in Self.appearances {
            let bar = RelayViewerBar(symbol: "text.bubble", title: "Viewer", detail: "detail", close: {}) {
                RelayViewerIconButton(title: "Refresh", symbol: "arrow.clockwise") {}
                Button("Action") {}.buttonStyle(RelayAgentQuietButtonStyle())
            }.environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(bar, name: "viewer-bar-close", width: 520, appearance: appearance)
            #expect(shot.size.height == RelayViewerMetrics.barHeight(compact: RelayPreferences.shared.compactInterface))
            #expect(Self.closeIsLast(shot))
        }
        // Without a close action the bar has no close button.
        let plain = RelayViewerBar(symbol: "text.bubble", title: "Viewer")
        let shot = try RelaySnapshot.render(plain, name: "viewer-bar-plain", width: 520, appearance: .darkAqua)
        #expect(!Self.closeIsLast(shot))
    }

    @Test func conversationInAPaneClosesBackToTheTerminal() throws {
        _ = NSApplication.shared
        for (appearance, scheme) in Self.appearances {
            let pane = RelayNativeChatFixture.pane(active: true)
            pane.nativeConversationVisible = true
            let conversation = RelayNativeChatFixture.timelineConversation(pane: pane)
            let store = RelayAgentTimelineStore(pane: pane, presenting: conversation)
            let view = RelayAgentTimelineView(pane: pane, store: store).frame(height: 500)
                .environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(view, name: "viewer-close-conversation", width: 760, appearance: appearance)
            #expect(Self.closeIsLast(shot))
            #expect(pane.nativeConversationVisible)
        }
    }

    @Test func agentDetailsMikoAndRecentPlacesCloseLast() async throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let harness = RelayAssistantHarness(policy: { .init() }, budget: RelayMikoActionBudget(),
            workspace: workspace, model: { _ in throw CancellationError() },
            taskJournal: try RelayMikoTaskJournal.temporary())
        let switcher = RelayRecentPlacesSwitcher()
        let place = RelayRecentPlaces.Place(id: pane.id, tabID: UUID(), title: "Figure review", location: "Alpha › Plots",
            host: "dandy-07", status: "Working", statusRole: .info, symbol: "sparkles", needsAttention: true, isCurrent: false)
        switcher.showForTesting(places: [place], selection: 0)
        for (appearance, scheme) in Self.appearances {
            let details = try RelaySnapshot.render(
                AgentInspectorPanel(pane: pane, subagentID: nil, showTerminal: {}, close: {}).environment(\.colorScheme, scheme),
                name: "viewer-close-agent-details", width: 520, appearance: appearance)
            #expect(details.size.height > 200)
            let miko = try RelaySnapshot.render(
                RelayAssistantHaikuPanel(workspace: workspace, harness: harness).environment(\.colorScheme, scheme),
                name: "viewer-close-miko", width: 560, appearance: appearance)
            #expect(miko.size.height > 400)
            let recent = try RelaySnapshot.render(
                RelayRecentPlacesPanel(switcher: switcher).environment(\.colorScheme, scheme),
                name: "viewer-close-recent-places", width: 600, appearance: appearance)
            #expect(recent.size.height > RelayViewerMetrics.barHeight(compact: false))
        }
    }

    @Test func inboxMonitoringArtifactAndNetworkCloseLast() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let artifact = PaneArtifact(remotePath: "/tmp/run.log", kind: .log, failure: "Not read yet")
        for (appearance, scheme) in Self.appearances {
            let inbox = try RelaySnapshot.render(
                AgentIntelligencePanel(workspace: workspace, close: {}).environment(\.colorScheme, scheme),
                name: "viewer-close-agent-activity", width: 570, appearance: appearance)
            #expect(inbox.size.height > 400)
            let monitoring = try RelaySnapshot.render(
                RelayPerformancePanel(workspace: workspace, close: {}).environment(\.colorScheme, scheme),
                name: "viewer-close-monitoring", width: 560, appearance: appearance)
            #expect(monitoring.size.height > 300)
            let inline = try RelaySnapshot.render(
                InlineArtifactView(artifact: artifact, dismiss: {}).frame(height: 200).environment(\.colorScheme, scheme),
                name: "viewer-close-inline-artifact", width: 520, appearance: appearance)
            #expect(inline.size.height >= 199)
            let network = try RelaySnapshot.render(
                PeerNetworkView(workspace: workspace).frame(height: 500).environment(\.colorScheme, scheme),
                name: "viewer-close-network", width: 1000, appearance: appearance)
            #expect(network.size.height >= 499)
        }
    }

    @Test func floatingPaneBarClosesLast() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let placement = FloatingPanePlacement(paneID: pane.id, originX: 0, originY: 0, width: 520, height: 300)
        for (appearance, scheme) in Self.appearances {
            let window = FloatingPaneWindow(pane: pane, placement: placement, bounds: CGSize(width: 520, height: 300),
                isActive: true, select: {}, move: { _, _ in }, resize: { _, _ in }, zoom: {}, dock: {}, minimize: {},
                rename: {}, terminate: {}, close: {})
                .frame(width: 520, height: 300, alignment: .topLeading)
                .environmentObject(PaneLinkSelection())
                .environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(window, name: "viewer-close-floating-pane", width: 520, appearance: appearance)
            #expect(shot.size.height >= 299)
        }
    }
}
