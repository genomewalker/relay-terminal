import Foundation
import Testing
@testable import Relay

@Test @MainActor func durableSurfacesRetainOwnerRevisionAndTombstone() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-surfaces-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = RelaySurfaceOwner(paneID: UUID(), host: "fixture-host", session: "fixture-session", producer: "fixture-producer")
    let store = RelayDurableSurfaceStore(directory: directory, authorizedOwners: [owner])
    #expect(store.available)
    let id = UUID(), generation = UUID()
    let first = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation, revision: 1, expectedRevision: 0, operation: .snapshot, content: .init(kind: .text, text: "fixture"))
    _ = try store.publish(first, authorizedOwner: owner)
    _ = try store.publish(first, authorizedOwner: owner)
    let restored = RelayDurableSurfaceStore(directory: directory, authorizedOwners: [owner])
    #expect(restored.available && restored.snapshots[id]?.revision == 1)
    let close = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation, revision: 2, expectedRevision: 1, operation: .close, content: nil)
    _ = try restored.publish(close, authorizedOwner: owner)
    let staleUpdate = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation, revision: 2, expectedRevision: 1, operation: .snapshot, content: .init(kind: .text, text: "must not resurrect"))
    #expect(throws: (any Error).self) { try store.publish(staleUpdate, authorizedOwner: owner) }
    #expect(store.snapshots.isEmpty)
    let closed = RelayDurableSurfaceStore(directory: directory, authorizedOwners: [owner])
    #expect(closed.available && closed.snapshots.isEmpty)
    #expect(throws: (any Error).self) { try closed.publish(first, authorizedOwner: owner) }
    #expect(!RelayDurableSurfaceStore(directory: directory, authorizedOwners: []).available)
    let file = directory.appendingPathComponent("surfaces-v1.json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor func durableSurfacesRejectSymlinkStoreWithoutChangingTarget() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-surfaces-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = directory.appendingPathComponent("fixture-target")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("surfaces-v1.json"), withDestinationURL: target)
    #expect(!RelayDurableSurfaceStore(directory: directory, authorizedOwners: []).available)
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
}
