import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// The Remote helpers host list, rendered offscreen from fixture hosts. Nothing
/// here reads ~/.ssh/config or contacts a host.
@MainActor @Suite(.serialized) struct RelaydHostRailTests {
    static let usedNames = ["dandy-07", "mjolnir", "lab-gpu"]
    static let unusedNames = ["archive", "backup-01", "build-arm", "ci-runner", "gitlab",
                              "jump", "nas", "pi-hole", "staging-db", "web-01", "web-02"]

    static var profiles: [ConnectionProfile] {
        (usedNames + unusedNames).map { ConnectionProfile.sshConfigHost("\($0).fixture.invalid") }
    }

    static var reports: [String: RelaydHostReport] {
        let hosts = profiles
        var ready = RelaydHostReport(state: .ready, architecture: "x86_64", version: "0.9.4")
        ready.liveVersion = "0.9.4"
        ready.supervisorPID = 41234
        ready.sessionCount = 2
        ready.paneCount = 3
        ready.runningPaneCount = 2
        return [
            hosts[0].connectionKey: ready,
            hosts[1].connectionKey: RelaydHostReport(state: .outdated, architecture: "aarch64", version: "0.9.1"),
            hosts[2].connectionKey: RelaydHostReport(state: .unreachable, message: "No route to host"),
        ]
    }

    @Test func rendersHostRailAndMetricsInBothAppearances() throws {
        _ = NSApplication.shared
        let hosts = Self.profiles
        let reports = Self.reports
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let rail = RelaydHostRail(
                profiles: hosts, reports: reports, selectedKey: hosts[0].connectionKey,
                select: { _ in }, updateRow: { _ in EmptyView() }
            )
            .frame(height: 610)
            .foregroundStyle(RelayTheme.text)
            .environment(\.colorScheme, scheme)
            let railShot = try RelaySnapshot.render(rail, name: "remote-helpers-rail", width: 220, appearance: appearance)
            #expect(railShot.size.height == 610)

            let metrics = RelaydHostMetrics(report: reports[hosts[0].connectionKey] ?? RelaydHostReport())
                .padding(20)
                .foregroundStyle(RelayTheme.text)
                .environment(\.colorScheme, scheme)
            let metricsShot = try RelaySnapshot.render(metrics, name: "remote-helpers-metrics", width: 640, appearance: appearance)
            #expect(metricsShot.size.height > 40)
        }
    }
}
