import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

@MainActor @Suite("A pane that fails quickly stays readable")
struct PaneExitNoticeTests {
    // MARK: Decision

    private func decide(_ status: Int?, _ elapsed: TimeInterval?, user: Bool = false) -> PaneExitNotice? {
        PaneExitNotice.decide(program: "ssh", exitStatus: status, elapsed: elapsed, userInitiated: user)
    }

    @Test func aQuickCleanExitIsInformationWithoutAStatus() {
        #expect(decide(0, 0)?.title == "ssh exited after 0s")
        #expect(decide(0, 9.9)?.title == "ssh exited after 9.9s")
        #expect(decide(0, 9.9)?.role == .info)
        #expect(decide(0, 9.9)?.isFailure == false)
    }

    @Test func onlyAFailureStatusOrSignalIsDanger() {
        #expect(decide(1, 2)?.role == .danger)
        #expect(decide(1, nil)?.role == .danger)
        #expect(decide(-1, 2)?.role == .danger)
        #expect(decide(nil, 2)?.role == .info)
    }

    @Test func theWindowEndsAtTenSeconds() {
        #expect(PaneExitNotice.quickExitWindow == 10)
        #expect(decide(0, 9.99) != nil)
        #expect(decide(0, 10) == nil)
        #expect(decide(0, 3600) == nil)
    }

    @Test func aFailureStatusIsExplainedAtAnyAge() {
        #expect(decide(1, 1.2)?.title == "ssh exited with status 1 after 1.2s")
        #expect(decide(255, 60)?.title == "ssh exited with status 255 after 1m")
        #expect(decide(2, 7_380)?.title == "ssh exited with status 2 after 2h 3m")
    }

    @Test func anUnobservedStartOmitsTheDurationRatherThanGuessing() {
        #expect(decide(1, nil)?.title == "ssh exited with status 1")
        #expect(decide(0, nil) == nil)
    }

    @Test func aMissingStatusOmitsTheStatusRatherThanGuessing() {
        #expect(decide(nil, 3)?.title == "ssh exited after 3s")
        #expect(decide(nil, 30) == nil)
        #expect(decide(nil, nil) == nil)
    }

    @Test func aSignalOrWaitFailureReadsAsTerminated() {
        #expect(decide(-1, 4)?.title == "ssh was terminated after 4s")
        #expect(decide(-1, nil)?.title == "ssh was terminated")
    }

    @Test func aUserRequestedEndIsNeverExplainedAsAFailure() {
        #expect(decide(1, 2, user: true) == nil)
        #expect(decide(-1, 0.5, user: true) == nil)
        #expect(decide(0, 2, user: true) == nil)
    }

    @Test func aClockStepBackwardsIsNotAQuickExit() {
        #expect(decide(0, -5) == nil)
        #expect(decide(1, -5)?.title == "ssh exited with status 1 after 0s")
    }

    @Test func durationsAreCompact() {
        #expect(PaneExitNotice.duration(0.04) == "0s")
        #expect(PaneExitNotice.duration(0.4) == "0.4s")
        #expect(PaneExitNotice.duration(3) == "3s")
        #expect(PaneExitNotice.duration(42.9) == "42s")
        #expect(PaneExitNotice.duration(185) == "3m 5s")
        #expect(PaneExitNotice.duration(3_600) == "1h")
    }

    @Test func theProgramComesFromTheLaunchCommand() {
        #expect(PaneExitNotice.programName(command: "") == "Shell")
        #expect(PaneExitNotice.programName(command: "   ") == "Shell")
        #expect(PaneExitNotice.programName(command: "claude --resume abc") == "claude")
        #expect(PaneExitNotice.programName(command: "/usr/bin/ssh -p 22 login.hpc") == "ssh")
        #expect(PaneExitNotice.programName(command: "env FOO=1 exec codex") == "codex")
    }

    // MARK: Model

    private static let failingProfile = ConnectionProfile(
        name: "HPC login", kind: .ssh, host: "keep-failed-pane.invalid",
        command: "ssh -o BatchMode=yes login.invalid", backend: .relay)

    private func isolatedWorkspace() throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-failed-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(
            restoreSavedWorkspace: false,
            workspaceDirectory: root.appendingPathComponent("Workspace", isDirectory: true),
            recoveryStore: RelayRecoveryStore(directory: root.appendingPathComponent("Recovery", isDirectory: true)))
        return (workspace, root)
    }

    @Test func aQuickFailureKeepsThePaneWithItsBanner() throws {
        let (workspace, root) = try isolatedWorkspace()
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        workspace.newTab(profile: Self.failingProfile)
        let pane = try #require(workspace.activePane)
        let tab = try #require(workspace.selectedTab)
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 1, now: start.addingTimeInterval(2))

        #expect(workspace.panes[pane.id] === pane)
        #expect(workspace.tabs.contains { $0 === tab })
        #expect(tab.allPaneIDs.contains(pane.id))
        #expect(pane.remoteExitCode == 1)
        #expect(pane.exitNotice?.title == "ssh exited with status 1 after 2s")
    }

    @Test func aCleanExitAfterTheWindowKeepsTodaysNotice() throws {
        let (workspace, root) = try isolatedWorkspace()
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        workspace.newTab(profile: Self.failingProfile)
        let pane = try #require(workspace.activePane)
        let start = Date()
        pane.connected(now: start)
        pane.connectionInterrupted("blip")
        // A reconnect to the same worker keeps the original start.
        pane.connected(now: start.addingTimeInterval(25))
        pane.exited(exitCode: 0, now: start.addingTimeInterval(30))

        #expect(workspace.panes[pane.id] === pane)
        #expect(pane.remoteExitCode == 0)
        #expect(pane.exitNotice == nil)
    }

    @Test func aRestoredPaneHasNoObservedStart() {
        let pane = PaneModel(profile: Self.failingProfile, requiresExistingWorker: true)
        pane.connected(now: Date())
        pane.exited(exitCode: 0, now: Date())
        #expect(pane.exitNotice == nil)
        pane.connected()
        pane.exited(exitCode: 3)
        #expect(pane.exitNotice?.title == "ssh exited with status 3")
    }

    @Test func aReplayedExitAfterReconnectKeepsTheOriginalRunTime() {
        let pane = PaneModel(profile: Self.failingProfile)
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 1, now: start.addingTimeInterval(2))
        pane.connectionInterrupted("blip")
        pane.connected(now: start.addingTimeInterval(300))
        #expect(pane.exitNotice == nil)
        pane.exited(exitCode: 1, now: start.addingTimeInterval(300))
        #expect(pane.exitNotice?.title == "ssh exited with status 1 after 2s")
    }

    @Test func aUserTerminationIsNotAFailure() {
        let pane = PaneModel(profile: Self.failingProfile)
        let start = Date()
        pane.connected(now: start)
        pane.userRequestedTermination = true
        pane.exited(exitCode: -1, now: start.addingTimeInterval(1))
        #expect(pane.remoteExitCode == -1)
        #expect(pane.exitNotice == nil)
    }

    @Test func reconnectingClearsTheBanner() {
        let pane = PaneModel(profile: Self.failingProfile)
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 1, now: start.addingTimeInterval(1))
        #expect(pane.exitNotice != nil)
        pane.reconnecting()
        #expect(pane.exitNotice == nil)
        #expect(pane.remoteExitCode == nil)
    }

    @Test func runAgainStartsTheSameCommandInAFreshPane() throws {
        let (workspace, root) = try isolatedWorkspace()
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        workspace.newTab(profile: Self.failingProfile)
        let pane = try #require(workspace.activePane)
        let tab = try #require(workspace.selectedTab)
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 255, now: start.addingTimeInterval(0.5))

        let replacementID = try #require(workspace.restartExitedPane(pane.id))
        let replacement = try #require(workspace.panes[replacementID])
        #expect(workspace.panes[pane.id] == nil)
        #expect(tab.allPaneIDs.contains(replacementID))
        #expect(replacement.profile.command == Self.failingProfile.command)
        #expect(replacement.requiresExistingWorker == false)
        #expect(replacement.exitNotice == nil && replacement.remoteExitCode == nil)
    }

    // MARK: Snapshot

    /// Magenta marks the final output line so a render can prove it is visible.
    private static let lastLineMarker = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    /// A terminal-like area: bottom-anchored like a real grid, clipped at the
    /// top, with the banner as its own row underneath (as in WorkspaceView).
    private struct TerminalLikeArea: View {
        let notice: PaneExitNotice
        let lines: [String]
        var body: some View {
            VStack(spacing: 0) {
                // Like the terminal NSView, the grid takes the height it is
                // given; the overlay never asks for its content's height.
                Color(white: 0.09)
                    .overlay(alignment: lines.count > 4 ? .bottomLeading : .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .background(index == lines.count - 1 ? Color(nsColor: PaneExitNoticeTests.lastLineMarker) : .clear)
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(10)
                    }
                    .clipped()
                FailedPaneExitBanner(notice: notice, runAgain: {}, close: {}, dismiss: {})
            }
            .frame(height: 240)
        }
    }

    private static let startupError = [
        "$ ssh -o BatchMode=yes login.hpc.example",
        "ssh: connect to host login.hpc.example port 22: Connection refused",
    ]

    private static let fullScreen = (1...40).map { "build step \($0): compiling module \($0)" }
        + ["error: linker command failed with exit code 1"]

    private func markerPixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            // Tolerates the cached bitmap's colour-space conversion; nothing
            // else in the scene is close to magenta (danger red has low blue).
            if c.redComponent > 0.8, c.greenComponent < 0.4, c.blueComponent > 0.8 { count += 1 }
        } }
        return count
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theBannerRendersUnderATerminal(appearance: NSAppearance.Name) throws {
        let failed = try #require(PaneExitNotice.decide(program: "ssh", exitStatus: 255, elapsed: 1.4, userInitiated: false))
        let wide = try RelaySnapshot.render(TerminalLikeArea(notice: failed, lines: Self.startupError),
                                            name: "failed-pane-wide", width: 760, appearance: appearance)
        #expect(wide.size.height == 240)
        let unknown = try #require(PaneExitNotice.decide(program: "claude", exitStatus: 1, elapsed: nil, userInitiated: false))
        let narrow = try RelaySnapshot.render(TerminalLikeArea(notice: unknown, lines: Self.startupError),
                                              name: "failed-pane-narrow", width: 420, appearance: appearance)
        #expect(narrow.size.height == 240)
        let clean = try #require(PaneExitNotice.decide(program: "Shell", exitStatus: 0, elapsed: 3, userInitiated: false))
        _ = try RelaySnapshot.render(TerminalLikeArea(notice: clean, lines: Self.startupError),
                                     name: "failed-pane-quick-clean", width: 760, appearance: appearance)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aFullScreenOfOutputKeepsItsLastLineVisible(appearance: NSAppearance.Name) throws {
        let failed = try #require(PaneExitNotice.decide(program: "make", exitStatus: 2, elapsed: 95, userInitiated: false))
        let shot = try RelaySnapshot.render(TerminalLikeArea(notice: failed, lines: Self.fullScreen),
                                            name: "failed-pane-full-screen", width: 760, appearance: appearance)
        #expect(shot.size.height == 240)
        // The marked last line is drawn, not hidden under the banner.
        #expect(markerPixels(shot.bitmap) > 200)
    }
}
