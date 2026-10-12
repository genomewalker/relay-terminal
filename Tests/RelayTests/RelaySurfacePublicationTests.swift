import Foundation
import Testing
@testable import Relay

@Test @MainActor func surfacePublicationScopesReadsAndRetainsClosedRevision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-publisher-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let principal = UUID().uuidString.lowercased(), pane = UUID(), host = UUID(), surface = UUID(), generation = UUID()
    var paused = false
    var registered = true
    let service = RelaySurfacePublication(directory: directory, registered: { $0 == principal && registered }, permitted: { $0 == principal && !paused })
    let owner = RelaySurfaceOwner(paneID: pane, host: host.uuidString, session: "caller/" + principal, producer: principal)
    let first = RelaySurfacePublication.Request(paneID: pane, surfaceID: surface, generation: generation, revision: 1, expectedRevision: 0, operation: .snapshot, content: .init(kind: .text, text: "private fixture"))
    try service.publish(first, authorizedOwner: owner)
    let restored = RelaySurfacePublication(directory: directory, registered: { $0 == principal && registered }, permitted: { _ in false })
    #expect(try restored.read(paneID: pane, hostID: host, principal: principal, includeContent: false).first?.content == nil)
    #expect(try restored.read(paneID: pane, hostID: host, principal: principal, includeContent: true).first?.content?.text == "private fixture")
    #expect(try restored.read(paneID: UUID(), hostID: host, principal: principal, includeContent: true).isEmpty)
    #expect(try restored.read(paneID: pane, hostID: UUID(), principal: principal, includeContent: true).isEmpty)
    #expect(throws: (any Error).self) { try restored.read(paneID: pane, hostID: host, principal: UUID().uuidString, includeContent: true) }
    paused = true
    #expect(throws: (any Error).self) { try service.publish(first, authorizedOwner: owner) }
    #expect(try service.read(paneID: pane, hostID: host, principal: principal, includeContent: false).first?.revision == 1)
    paused = false
    try service.publish(.init(paneID: pane, surfaceID: surface, generation: generation, revision: 2, expectedRevision: 1, operation: .close, content: nil), authorizedOwner: owner)
    let closed = try restored.read(paneID: pane, hostID: host, principal: principal, includeContent: true)
    #expect(closed.count == 1 && closed.first?.revision == 2 && closed.first?.operation == .close && closed.first?.content == nil)
    #expect(throws: (any Error).self) { try service.publish(first, authorizedOwner: owner) }
    registered = false
    #expect(throws: (any Error).self) { try restored.read(paneID: pane, hostID: host, principal: principal, includeContent: true) }
    registered = true
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("surfaces-v1.json"))
    #expect(throws: (any Error).self) { try restored.read(paneID: pane, hostID: host, principal: principal, includeContent: true) }
}

@Test @MainActor func nativeSurfaceRefreshPreservesLastViewAndReportsFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-native-surface-refresh-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = PaneModel(id: UUID(), profile: .local)
    let principal = UUID().uuidString.lowercased()
    let service = RelaySurfacePublication(directory: directory, registered: { $0 == principal }, permitted: { $0 == principal })
    pane.richContents = [.init(kind: .equation, text: "x=1")]
    let first = RelaySurfacePublication.Request(paneID: pane.id, surfaceID: UUID(), generation: UUID(), revision: 1, expectedRevision: 0, operation: .snapshot, content: .init(kind: .status, text: "saved fixture"))
    try service.publish(first, pane: pane, principal: principal)
    #expect(pane.presentedRichContents.count == 2 && pane.durableSurfaceError == nil)
    let previous = pane.durableSurfaceContents
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("surfaces-v1.json"))
    service.refresh(pane)
    #expect(pane.durableSurfaceContents == previous && pane.durableSurfaceError != nil)
    #expect(pane.richContents.first?.text == "x=1")
}
