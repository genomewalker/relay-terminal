import Foundation
import Testing
@testable import Relay

/// Installed 0.5.112 rewrote host-registry-v1.json about 11 times a second
/// because every transport observation stamped connectionObservedAt and
/// persisted the whole registry (122 atomic renames in 10.7 s). Steady
/// observations must now stay in memory; real transitions still persist.
@MainActor
struct RelayHostRegistryWriteCoalescingTests {
    final class Clock { var time = Date(timeIntervalSince1970: 1_800_000_000) }

    private func makeRegistry() throws -> (RelayHostRegistry, Clock, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-host-registry-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("host-registry-v1.json")
        let clock = Clock()
        return (RelayHostRegistry(url: url, now: { clock.time }), clock, url)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    @Test func steadyObservationsDoNotRewriteTheFile() throws {
        let (registry, clock, url) = try makeRegistry()
        registry.connection(.local, ready: true, capabilities: ["b", "a"], version: "0.5.62", protocolVersion: 2, supervisorPID: 36399)
        let afterConnect = registry.persistCount
        #expect(afterConnect >= 1)
        let firstInode = try inode(url)

        for _ in 0..<100 {
            clock.time += 0.1
            registry.connection(.local, ready: true, capabilities: ["a", "b"], version: "0.5.62", protocolVersion: 2, supervisorPID: 36399)
        }
        #expect(registry.persistCount == afterConnect, "steady observations must not persist")
        // An atomic write replaces the file; the same inode proves no rename happened.
        #expect(try inode(url) == firstInode)
        // The in-memory record still carries the freshest observation.
        #expect(registry.records[ConnectionProfile.local.connectionKey]?.connectionObservedAt == clock.time)
    }

    @Test func realTransitionsPersistImmediately() throws {
        let (registry, clock, url) = try makeRegistry()
        registry.connection(.local, ready: true, version: "0.5.62", protocolVersion: 2, supervisorPID: 1)
        let base = registry.persistCount

        clock.time += 1
        registry.connection(.local, ready: false)
        #expect(registry.persistCount == base + 1, "disconnect persists at once")

        clock.time += 1
        registry.connection(.local, ready: true, version: "0.5.63", protocolVersion: 2, supervisorPID: 2)
        #expect(registry.persistCount == base + 2, "reconnect with a new supervisor persists at once")

        let saved = try JSONDecoder().decode([String: RelayHostRecord].self, from: Data(contentsOf: url))
        #expect(saved[ConnectionProfile.local.connectionKey]?.liveVersion == "0.5.63")
        #expect(saved[ConnectionProfile.local.connectionKey]?.supervisorPID == 2)
    }

    @Test func timestampOnlyChangesAreCheckpointedAndFlushed() throws {
        let (registry, clock, url) = try makeRegistry()
        registry.connection(.local, ready: true, version: "0.5.62", protocolVersion: 2, supervisorPID: 1)
        let base = registry.persistCount

        clock.time += RelayHostRegistry.observationCheckpointInterval - 1
        registry.connection(.local, ready: true, version: "0.5.62", protocolVersion: 2, supervisorPID: 1)
        #expect(registry.persistCount == base)

        clock.time += 2
        registry.connection(.local, ready: true, version: "0.5.62", protocolVersion: 2, supervisorPID: 1)
        #expect(registry.persistCount == base + 1, "one checkpoint after the interval")

        clock.time += 5
        registry.connection(.local, ready: true, version: "0.5.62", protocolVersion: 2, supervisorPID: 1)
        #expect(registry.persistCount == base + 1)
        registry.flush()
        #expect(registry.persistCount == base + 2, "flush writes the pending observation")
        let saved = try JSONDecoder().decode([String: RelayHostRecord].self, from: Data(contentsOf: url))
        #expect(saved[ConnectionProfile.local.connectionKey]?.connectionObservedAt == clock.time)

        registry.flush()
        #expect(registry.persistCount == base + 2, "flush with nothing pending does not write")
    }
}
