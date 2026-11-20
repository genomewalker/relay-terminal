import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// Restyle step 1 (mockup 2026-11-18), redone as release A (2026-11-20): one
/// status label with a live timer in the pane header, behind Interface:
/// Classic | Refreshed, Classic by default.
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
                                      finishedUnseen: finished, phaseSince: Self.since, program: nil)
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
                ["Running", "Needs you", "Ready", "Idle", "Failed", "Exited", "Connecting", "Reconnecting", "Disconnected"])
    }

    /// Release A (2026-11-20): an idle Codex pane showed "Running 22m 08s"
    /// beside the program's own "Idle". A current program report now decides
    /// the label; terminal output only fills in when no program reports.
    @Test func aProgramsOwnReportDecidesTheLabel() {
        let reported = Self.since.addingTimeInterval(40)
        func label(_ state: String, phase: AgentPhase = .active, approvals: Int = 0, finished: Bool = false,
                   connection: PaneConnectionState = .connected, kind: AgentKind = .codex) -> RelayPaneStatusLabel? {
            RelayPaneStatusLabel.make(kind: kind, phase: phase, connection: connection, pendingApprovals: approvals,
                                      finishedUnseen: finished, phaseSince: Self.since,
                                      program: .init(state: state, since: reported))
        }
        #expect(label("idle") == .init(state: .idle, timerSince: nil), "busy terminal output, idle program")
        #expect(label("idle", finished: true)?.state == .ready)
        #expect(label("working", phase: .quiet) == .init(state: .running, timerSince: reported))
        #expect(label("blocked", phase: .quiet) == .init(state: .needsYou, timerSince: reported))
        #expect(label("done")?.state == .ready)
        #expect(label("error")?.state == .failed)
        #expect(label("idle", approvals: 1)?.state == .needsYou, "a Relay approval still needs the user")
        #expect(label("working", connection: .disconnected("lost"))?.state == .disconnected)
        #expect(label("working", phase: .exited)?.state == .exited)
        #expect(label("working", kind: .shell)?.state == .running, "a shell that reports gets a label")
    }

    @Test func thePrimaryProgramStateIsTheMostUrgentAndItsTimerStartsWhenItChanges() throws {
        let pane = PaneModel(profile: Self.host, customName: "codex", directory: "/tmp")
        pane.connectionState = .connected
        #expect(pane.programStatusPrimary == nil, "no report")
        let before = Date()
        #expect(pane.programStatus.replace(try Self.records(#"[{"id":"a","state":"idle"},{"id":"b","state":"working"}]"#), revision: 1))
        let first = try #require(pane.programStatusPrimary)
        #expect(first.state == "working" && first.since >= before)
        #expect(pane.programStatus.replace(try Self.records(#"[{"id":"a","state":"idle"},{"id":"b","state":"working","progress":50}]"#), revision: 2))
        #expect(pane.programStatusPrimary == first, "same state keeps its start")
        #expect(pane.programStatus.replace(try Self.records(#"[{"id":"a","state":"blocked"}]"#), revision: 3))
        #expect(pane.programStatusPrimary?.state == "blocked")
        pane.connectionState = .disconnected("lost")
        #expect(pane.programStatusPrimary == nil, "a report over a lost connection is not current")
    }

    /// Side-agent review 2026-11-20: a reconnect starts a new delivery, which
    /// clears the report until the program replays it. The same state after
    /// the replay keeps its start; a different state starts a new timer.
    @Test func aReconnectKeepsTheProgramTimerWhenTheStateIsUnchanged() throws {
        let pane = PaneModel(profile: Self.host, customName: "codex", directory: "/tmp")
        pane.connectionState = .connected
        let working = try Self.records(#"[{"id":"a","state":"working"}]"#)
        pane.programStatus.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: working, programStatusRevision: 7), deliveryEpoch: UUID())
        let first = try #require(pane.programStatusPrimary)
        pane.connectionState = .reconnecting("link")
        let epoch = UUID()
        pane.programStatus.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: epoch)
        pane.connectionState = .connected
        #expect(pane.programStatusPrimary == nil, "no current report until the replay")
        pane.programStatus.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: working, programStatusRevision: 1), deliveryEpoch: epoch)
        #expect(pane.programStatusPrimary == first, "the replayed state keeps its start")
        pane.programStatus.applyTransportStatus(RelayStatus(state: "attached"), deliveryEpoch: UUID())
        let idle = try Self.records(#"[{"id":"a","state":"idle"}]"#)
        let next = UUID()
        pane.programStatus.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: idle, programStatusRevision: 1), deliveryEpoch: next)
        #expect(pane.programStatusPrimary?.state == "idle")
        pane.programStatus.applyTransportStatus(
            RelayStatus(state: "program_status", programStatus: [], programStatusRevision: 2), deliveryEpoch: next)
        #expect(pane.programStatusPrimary == nil, "an explicit empty report clears it")
    }

    /// A reconnect resets the output detector to Connecting, and connecting
    /// again marks the agent active. Working before and after keeps the run.
    @Test func aReconnectKeepsTheRunningTimerOfAWorkingAgent() throws {
        let pane = PaneModel(profile: Self.host, customName: "claude", directory: "/tmp")
        pane.connected()
        #expect(pane.phase == .active)
        let start = pane.phaseChangedAt
        pane.reconnecting()
        #expect(pane.phase == .connecting)
        pane.connected()
        #expect(pane.phase == .active)
        #expect(pane.phaseChangedAt == start, "the run continues across the reconnect")
    }

    /// Release A follow-up (2026-11-20): the grey activity text ("Thinking",
    /// "Using Bash") contradicted the label beside it. Refreshed headers
    /// leave it out; the label's hover and agent details still show it.
    @Test func refreshedHeadersLeaveOutTheActivityText() {
        #expect(ConnectionPath.usesRefreshedLabel(style: .refreshed, kind: .claude, programReport: false))
        #expect(ConnectionPath.usesRefreshedLabel(style: .refreshed, kind: .shell, programReport: true))
        #expect(!ConnectionPath.usesRefreshedLabel(style: .refreshed, kind: .shell, programReport: false))
        #expect(!ConnectionPath.usesRefreshedLabel(style: .classic, kind: .codex, programReport: true))
        #expect(RelayRefreshedPaneStatus.help(activity: "Using Bash", programReport: false)
                == "Latest activity: Using Bash · Show agent details")
        #expect(RelayRefreshedPaneStatus.help(activity: nil, programReport: false) == "Show agent details")
        #expect(RelayRefreshedPaneStatus.help(activity: "Thinking", programReport: true)
                == "Latest activity: Thinking · Show program tasks")
    }

    static func records(_ json: String) throws -> [RelayProgramStatusRecord] {
        try JSONDecoder().decode([RelayProgramStatusRecord].self, from: Data(json.utf8))
    }

    @Test func refreshedTokensMatchTheDesignCanvas() {
        let tokens: [(NSColor, UInt32, UInt32)] = [
            (RelayRefreshedPalette.paper, 0xFAFAF8, 0x0F0F0E), (RelayRefreshedPalette.ink, 0x20211F, 0xFAFAF8),
            (RelayRefreshedPalette.muted, 0x5F615B, 0xB4B6AE), (RelayRefreshedPalette.working, 0x4C6610, 0xB9DC4F),
            (RelayRefreshedPalette.ok, 0x367740, 0xA4D4AA), (RelayRefreshedPalette.warn, 0x885C12, 0xE7C47B),
            (RelayRefreshedPalette.bad, 0xB83329, 0xF1A298), (RelayRefreshedPalette.accent, 0xCDEA5C, 0xCDEA5C),
        ]
        for (color, light, dark) in tokens {
            #expect(Self.hex(color, .aqua) == light)
            #expect(Self.hex(color, .darkAqua) == dark)
        }
        #expect(RelayPaneStatusLabel.State.running.color == RelayRefreshedTheme.working)
        #expect(RelayPaneStatusLabel.State.needsYou.color == RelayRefreshedTheme.warn)
        #expect(RelayPaneStatusLabel.State.ready.color == RelayRefreshedTheme.ok)
        #expect(RelayPaneStatusLabel.State.failed.color == RelayRefreshedTheme.bad)
        #expect(RelayPaneStatusLabel.State.disconnected.color == RelayRefreshedTheme.bad)
    }

    static func hex(_ color: NSColor, _ appearance: NSAppearance.Name) -> UInt32 {
        var value: UInt32 = 0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            value = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
                | UInt32((c.blueComponent * 255).rounded())
        }
        return value
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

    private func pane(_ phase: AgentPhase, program: String? = nil) throws -> PaneModel {
        let saved = PersistedAgentPaneState(cursor: 0, kind: .claude, phase: phase, summary: "Using Bash", subagents: [],
            activities: [AgentActivityItem(id: UUID(), label: "Using Bash", phase: phase, occurredAt: Date())],
            resourceUsage: nil, progressPercent: nil, pendingApprovals: 0)
        let pane = PaneModel(profile: Self.host, customName: "Sapropel - annotation jobs - claude 767dc7",
                             directory: "/projects/sapropel", savedAgentState: saved)
        pane.connectionState = .connected
        if let program {
            #expect(pane.programStatus.replace(try Self.records(#"[{"id":"task","state":"\#(program)"}]"#), revision: 1))
        }
        return pane
    }

    /// The working colour appears only where the agent is working, only in
    /// Refreshed, in both appearances; a program's idle report wins over
    /// busy terminal output, and the program badge's blue is not drawn beside
    /// the label (one label). Classic draws none of the Refreshed colours.
    @Test func refreshedDrawsOneLabelThatFollowsTheProgram() throws {
        let cases: [(AgentPhase, String?, Bool)] = [
            (.active, nil, true), (.needsInput, nil, false), (.quiet, nil, false),
            (.active, "idle", false), (.quiet, "working", true), (.quiet, "blocked", false),
        ]
        var accent: [String: Int] = [:]
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            for style in RelayInterfaceStyle.allCases {
                for (phase, program, working) in cases {
                    let view = ConnectionPath(pane: try pane(phase, program: program), active: false, compact: false, zoomed: false,
                                              isFloating: false, select: {}, toggleZoom: {}, toggleFloating: {}, rename: {},
                                              terminate: nil, close: {})
                        .environmentObject(PaneLinkSelection())
                        .environment(\.colorScheme, scheme)
                        .environment(\.relayInterfaceStyle, style)
                    let name = "status-label-\(style.rawValue)-\(phase)-\(program ?? "none")-\(scheme == .dark ? "dark" : "light")"
                    let result = try RelaySnapshot.render(view, name: name, width: 900, appearance: appearance)
                    #expect(result.size.width == 900 && result.size.height > 10)
                    let found = Self.containsColor(result.bitmap, near: RelayRefreshedPalette.working, appearance: appearance)
                    #expect(found == (style == .refreshed && working), "\(name): working colour")
                    if style == .refreshed {
                        accent["\(phase)-\(program ?? "none")-\(scheme)"] =
                            Self.countColor(result.bitmap, near: RelayPalette.accent, appearance: appearance)
                    }
                    if style == .refreshed, phase == .needsInput || program == "blocked" {
                        #expect(Self.containsColor(result.bitmap, near: RelayRefreshedPalette.warn, appearance: appearance),
                                "\(name): needs-you colour")
                    }
                }
            }
        }
        // The program badge draws in the accent blue; with one label a
        // reporting pane draws no more accent than the same pane without a
        // report (the header's own dot and agent link stay as they are).
        for scheme in [ColorScheme.dark, .light] {
            for (phase, program) in [(AgentPhase.active, "idle"), (.quiet, "working"), (.quiet, "blocked")] {
                #expect(accent["\(phase)-\(program)-\(scheme)"] == accent["\(phase)-none-\(scheme)"],
                        "\(phase) \(program) \(scheme): no second, program-reported label")
            }
        }
    }

    static func countColor(_ bitmap: NSBitmapImageRep, near color: NSColor, appearance: NSAppearance.Name) -> Int {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let t = resolved else { return 0 }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - t.redComponent) < 0.09 && abs(c.greenComponent - t.greenComponent) < 0.09 &&
                    abs(c.blueComponent - t.blueComponent) < 0.09 { count += 1 }
            }
        }
        return count
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
