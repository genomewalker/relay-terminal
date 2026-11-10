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

    /// Hosts in use: the recently used one (panes), the saved one, the ones with a
    /// check result this session, and one checked in an earlier session.
    static var usedKeys: Set<String> {
        let hosts = profiles
        return RelaydHostGrouping.usedKeys(
            reports: reports, lastKnown: [:], recentHostKeys: [hosts[0].connectionKey], savedProfiles: []
        )
    }

    @Test func groupsHostsInUseBeforeOtherSSHHosts() {
        let hosts = Self.profiles
        let saved = ConnectionProfile(name: "saved", kind: .ssh, host: "saved.fixture.invalid")
        let local = ConnectionProfile(name: "local", kind: .local)
        var unknownWithPanes = RelaydHostReport()
        unknownWithPanes.paneCount = 1
        let used = RelaydHostGrouping.usedKeys(
            reports: [
                hosts[1].connectionKey: RelaydHostReport(state: .outdated),
                hosts[3].connectionKey: RelaydHostReport(state: .unknown),
                hosts[4].connectionKey: unknownWithPanes,
            ],
            lastKnown: [hosts[5].connectionKey: .ready, hosts[6].connectionKey: .unknown],
            recentHostKeys: [hosts[7].connectionKey],
            savedProfiles: [saved, local]
        )
        #expect(used == [hosts[1].connectionKey, hosts[4].connectionKey, hosts[5].connectionKey,
                         hosts[7].connectionKey, saved.connectionKey])
        #expect(!used.contains(local.connectionKey))

        let groups = RelaydHostGrouping.split(hosts, usedKeys: used)
        // Input order (recency, then name) is kept within each group.
        #expect(groups.inUse.map(\.connectionKey) == [1, 4, 5, 7].map { hosts[$0].connectionKey })
        #expect(groups.other.count == hosts.count - 4)
        #expect(groups.other.map(\.connectionKey) == hosts.enumerated()
            .filter { ![1, 4, 5, 7].contains($0.offset) }.map(\.element.connectionKey))
        #expect(Set(groups.inUse.map(\.id)).isDisjoint(with: groups.other.map(\.id)))

        let none = RelaydHostGrouping.split(hosts, usedKeys: [])
        #expect(none.inUse.isEmpty && none.other.count == hosts.count)
    }

    @Test func rendersHostRailAndMetricsInBothAppearances() throws {
        _ = NSApplication.shared
        let hosts = Self.profiles
        let reports = Self.reports
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let rail = RelaydHostRail(
                profiles: hosts, reports: reports, usedKeys: Self.usedKeys,
                selectedKey: hosts[0].connectionKey,
                select: { _ in }, updateRow: { _ in EmptyView() }
            )
            .frame(height: 610)
            .foregroundStyle(RelayTheme.text)
            .environment(\.colorScheme, scheme)
            let railShot = try RelaySnapshot.render(rail, name: "remote-helpers-rail", width: 220, appearance: appearance)
            #expect(railShot.size.height == 610)

            // A host with panes from an earlier session but no check yet in this one.
            let earlier = RelaydHostRail(
                profiles: hosts, reports: [:], lastKnown: [hosts[1].connectionKey: .ready],
                usedKeys: [hosts[0].connectionKey, hosts[1].connectionKey], selectedKey: nil,
                select: { _ in }, updateRow: { _ in EmptyView() }
            )
            .frame(height: 300)
            .foregroundStyle(RelayTheme.text)
            .environment(\.colorScheme, scheme)
            _ = try RelaySnapshot.render(earlier, name: "remote-helpers-rail-earlier", width: 220, appearance: appearance)

            // Nothing used yet: the other hosts are listed open, not hidden.
            let fresh = RelaydHostRail(
                profiles: Array(hosts.suffix(5)), reports: [:], usedKeys: [], selectedKey: nil,
                select: { _ in }, updateRow: { _ in EmptyView() }
            )
            .frame(height: 360)
            .foregroundStyle(RelayTheme.text)
            .environment(\.colorScheme, scheme)
            _ = try RelaySnapshot.render(fresh, name: "remote-helpers-rail-unused", width: 220, appearance: appearance)

            let metrics = RelaydHostMetrics(report: reports[hosts[0].connectionKey] ?? RelaydHostReport())
                .padding(20)
                .foregroundStyle(RelayTheme.text)
                .environment(\.colorScheme, scheme)
            let metricsShot = try RelaySnapshot.render(metrics, name: "remote-helpers-metrics", width: 640, appearance: appearance)
            #expect(metricsShot.size.height > 40)
        }
    }
}
