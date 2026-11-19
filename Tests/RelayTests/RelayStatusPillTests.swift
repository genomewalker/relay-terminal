import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// Restyle step 1 (mockup 2026-11-18): status labels with live timers in the
/// pane header, behind Interface: Classic | Refreshed, Classic by default.
@MainActor @Suite("Refreshed status labels with live timers", .serialized)
struct RelayStatusPillTests {
    private static let host = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07.status-pill.invalid")
    static let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func classicIsTheDefaultAndTheChoiceIsKept() throws {
        let suite = "relay.status-pill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RelayPreferences(defaults: defaults).interfaceStyle == .classic)
        RelayPreferences(defaults: defaults).interfaceStyle = .refreshed
        #expect(RelayPreferences(defaults: defaults).interfaceStyle == .refreshed)
    }

    @Test func eachStateMapsToOneLabelAndOnlyLiveWorkHasATimer() {
        func label(_ phase: AgentPhase, _ connection: PaneConnectionState = .connected, approvals: Int = 0,
                   finished: Bool = false, kind: AgentKind = .claude) -> RelayPaneStatusLabel? {
            RelayPaneStatusLabel.make(kind: kind, phase: phase, connection: connection, pendingApprovals: approvals,
                                      finishedUnseen: finished, phaseSince: Self.since)
        }
        #expect(label(.active)?.state == .running && label(.active)?.timerSince == Self.since)
        #expect(label(.needsInput)?.state == .needsYou && label(.needsInput)?.timerSince == Self.since)
        #expect(label(.active, approvals: 1)?.state == .needsYou, "a pending approval needs the user")
        #expect(label(.quiet, finished: true)?.state == .ready && label(.quiet, finished: true)?.timerSince == nil)
        #expect(label(.quiet)?.state == .idle)
        #expect(label(.exited)?.state == .exited)
        #expect(label(.connecting)?.state == .connecting)
        #expect(label(.active, .reconnecting("link"))?.state == .reconnecting)
        #expect(label(.active, .waitingForNetwork("offline"))?.state == .reconnecting)
        #expect(label(.active, .disconnected("lost"))?.state == .disconnected)
        #expect(label(.active, kind: .shell) == nil, "shells keep their classic header")
        #expect(RelayPaneStatusLabel.State.allCases.map(\.text) ==
                ["Running", "Needs you", "Ready", "Idle", "Exited", "Connecting", "Reconnecting", "Disconnected"])
    }

    @Test func elapsedTimeIsShortAndExact() {
        #expect(RelayPaneStatusLabel.elapsed(0) == "0s")
        #expect(RelayPaneStatusLabel.elapsed(59.9) == "59s")
        #expect(RelayPaneStatusLabel.elapsed(192) == "3m 12s")
        #expect(RelayPaneStatusLabel.elapsed(3_725) == "1h 02m")
        #expect(RelayPaneStatusLabel.elapsed(-5) == "0s", "a clock step never shows negative time")
    }

    /// Side-agent review 2026-11-19: raw-output detection marks an agent quiet
    /// after 1.4 s without output, so a long task with short pauses must keep
    /// its Running start; a long pause or a question starts a new run.
    @Test func shortPausesKeepTheRunningStartAndLongOnesRestartIt() {
        let t0 = Self.since
        let a = RelayPaneStatusLabel.nextTimer(old: .connecting, new: .active, lastChange: t0, runStart: nil, now: t0)
        #expect(a.since == t0 && a.runStart == t0)
        let q = RelayPaneStatusLabel.nextTimer(old: .active, new: .quiet, lastChange: a.since, runStart: a.runStart, now: t0 + 60)
        #expect(q.since == t0 + 60 && q.runStart == t0)
        let back = RelayPaneStatusLabel.nextTimer(old: .quiet, new: .active, lastChange: q.since, runStart: q.runStart, now: t0 + 65)
        #expect(back.since == t0, "a 5 s pause continues the same run")
        let late = RelayPaneStatusLabel.nextTimer(old: .quiet, new: .active, lastChange: q.since, runStart: q.runStart,
                                                  now: t0 + 60 + RelayPaneStatusLabel.pauseGrace + 1)
        #expect(late.since == t0 + 60 + RelayPaneStatusLabel.pauseGrace + 1, "a long pause starts a new run")
        let asked = RelayPaneStatusLabel.nextTimer(old: .active, new: .needsInput, lastChange: t0, runStart: t0, now: t0 + 70)
        #expect(asked.since == t0 + 70 && asked.runStart == nil, "a question starts its own timer and ends the run")
    }

    @Test func aPhaseChangeRestartsThePanesTimer() {
        let pane = PaneModel(profile: Self.host, customName: "a - claude 767dc7", directory: "/tmp")
        let before = pane.phaseChangedAt
        let start = Date()
        pane.connected(now: start)
        pane.exited(exitCode: 0, now: start.addingTimeInterval(0.5))
        #expect(pane.phase == .exited)
        #expect(pane.phaseChangedAt >= before && pane.phaseChangedAt >= start)
    }

    private func pane(_ phase: AgentPhase) -> PaneModel {
        let saved = PersistedAgentPaneState(cursor: 0, kind: .claude, phase: phase, summary: "Using Bash", subagents: [],
            activities: [AgentActivityItem(id: UUID(), label: "Using Bash", phase: phase, occurredAt: Date())],
            resourceUsage: nil, progressPercent: nil, pendingApprovals: 0)
        let pane = PaneModel(profile: Self.host, customName: "Sapropel - annotation jobs - claude 767dc7",
                             directory: "/projects/sapropel", savedAgentState: saved)
        pane.connectionState = .connected
        return pane
    }

    /// Lime appears only in Refreshed, in both appearances; Classic draws no lime.
    @Test func refreshedDrawsTheLimePillAndClassicDoesNot() throws {
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            for style in RelayInterfaceStyle.allCases {
                for phase in [AgentPhase.active, .needsInput, .quiet] {
                    let view = ConnectionPath(pane: pane(phase), active: true, compact: false, zoomed: false, isFloating: false,
                                              select: {}, toggleZoom: {}, toggleFloating: {}, rename: {}, terminate: nil, close: {})
                        .environmentObject(PaneLinkSelection())
                        .environment(\.colorScheme, scheme)
                        .environment(\.relayInterfaceStyle, style)
                    let name = "status-pill-\(style.rawValue)-\(phase)-\(scheme == .dark ? "dark" : "light")"
                    let result = try RelaySnapshot.render(view, name: name, width: 900, appearance: appearance)
                    #expect(result.size.width == 900 && result.size.height > 10)
                    let lime = RelayPalette.lime
                    let found = Self.containsColor(result.bitmap, near: lime, appearance: appearance)
                    if phase == .active {
                        #expect(found == (style == .refreshed), "\(name): lime only in Refreshed")
                    }
                    if style == .classic { #expect(!found, "\(name): Classic is unchanged") }
                }
            }
        }
    }

    static func containsColor(_ bitmap: NSBitmapImageRep, near color: NSColor, appearance: NSAppearance.Name) -> Bool {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let target = resolved else { return false }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - target.redComponent) < 0.09 && abs(c.greenComponent - target.greenComponent) < 0.09 &&
                    abs(c.blueComponent - target.blueComponent) < 0.09 { return true }
            }
        }
        return false
    }
}
