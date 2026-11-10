import AppKit
import SwiftUI
import Testing
@testable import Relay

struct RelayMikoComposerTests {
    @Test func returnSendsWhileModifiedReturnAndIMEStayInEditor() {
        #expect(RelayMikoComposerKeys.sends(keyCode: 36, modifiers: [], hasMarkedText: false))
        #expect(RelayMikoComposerKeys.sends(keyCode: 76, modifiers: .command, hasMarkedText: false))
        let modifiers: [NSEvent.ModifierFlags] = [.shift, .option, .control, [.command, .shift]]
        for modifier in modifiers {
            #expect(!RelayMikoComposerKeys.sends(keyCode: 36, modifiers: modifier, hasMarkedText: false))
        }
        #expect(!RelayMikoComposerKeys.sends(keyCode: 36, modifiers: [], hasMarkedText: true))
        #expect(!RelayMikoComposerKeys.sends(keyCode: 0, modifiers: [], hasMarkedText: false))
    }
    @Test func panelRemainsReachableAfterDragAndWindowResize() {
        let bounds = CGSize(width: 1200, height: 900)
        #expect(RelayMikoPanelPlacement.clampedOffset(CGSize(width: -10000, height: 10000), in: bounds) == CGSize(width: -608, height: 150))
        #expect(RelayMikoPanelPlacement.clampedOffset(CGSize(width: 10000, height: -10000), in: bounds) == CGSize(width: 0, height: -46))
        let small = CGSize(width: 460, height: 550)
        #expect(RelayMikoPanelPlacement.panelSize(in: small) == CGSize(width: 428, height: 480))
        #expect(RelayMikoPanelPlacement.clampedOffset(CGSize(width: -600, height: 150), in: small) == .zero)
    }
    @MainActor @Test func returnNeverSendsEmptyOrBusyAndSendsDraftOnce() {
        let editor = RelayMikoComposer.Editor()
        var sent = 0
        editor.send = { sent += 1 }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                    isARepeat: false, keyCode: 36)!
        editor.canSend = true
        editor.string = "  "
        editor.keyDown(with: event)
        editor.string = "hello"
        editor.canSend = false
        editor.keyDown(with: event)
        #expect(sent == 0)
        editor.canSend = true
        editor.keyDown(with: event)
        editor.keyDown(with: event)
        #expect(sent == 1)
    }
    @Test func exactControlCenterActionBeatsSimilarlyNamedCurrentPane() {
        let pane = RelayWorkOverviewIndex.Entry(id: "pane:test", title: "Relay Miko Control Center",
            location: "Current workspace", status: "Working", details: "", symbol: "terminal",
            destination: .pane(UUID(), UUID()), searchFields: [], needsAttention: false, isCurrent: true, changedAt: nil)
        let entries = RelayWorkOverviewIndex.navigationEntries(query: "Control Center") + [pane]
        #expect(RelayWorkOverviewIndex.results(entries, query: "Control Center").first?.destination == .controlCenter)
    }
    @MainActor @Test func composerGrowsWithItsContent() {
        let editor = RelayMikoComposer.Editor()
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.setFrameSize(NSSize(width: 400, height: 30))
        editor.string = "a"
        let one = editor.contentHeight
        editor.string = "a\nb\nc\nd"
        let four = editor.contentHeight
        #expect(one > 12 && RelayMikoComposerHeight.clamped(one) < 40)
        #expect(four > one + 30)
        #expect(RelayMikoComposerHeight.clamped(four) > RelayMikoComposerHeight.minimum)
        #expect(RelayMikoComposerHeight.clamped(four) <= RelayMikoComposerHeight.maximum)
    }
    @MainActor @Test func renderPanelOffscreenForInspection() async throws {
        guard let path = ProcessInfo.processInfo.environment["RELAY_MIKO_PREVIEW_PATH"] else { return }
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let harness = RelayAssistantHarness(workspace: workspace, supervision: RelayMikoSupervision(url: nil))
        let content = RelayAssistantHaikuPanel(workspace: workspace, harness: harness)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
        #expect(png.count > 1000)
    }

}
