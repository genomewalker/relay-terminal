import Foundation
import Testing
@testable import Relay

private func auditEvent(_ index: Int) -> RelaySupervisorAuditEvent {
    RelaySupervisorAuditEvent(
        id: UUID(), receiptID: UUID(),
        identity: RelaySupervisedSessionID(
            paneID: UUID(), sessionID: "codex-\(index)", generation: UInt64(index)
        ),
        stage: .gracefulInterrupt,
        kind: .executionDispatched,
        reason: .userReview,
        occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
    )
}

@Test("Supervisor audit is private, durable, and bounded")
func supervisorAuditRoundTripIsBounded() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-supervisor-audit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("audit.json")
    let store = RelaySupervisorAuditStore(
        fileURL: file, maximumEvents: 2, persistenceEnabled: true
    )
    let first = auditEvent(1)
    let second = auditEvent(2)
    let third = auditEvent(3)
    #expect(store.record(first))
    #expect(store.record(second))
    #expect(store.record(third))
    #expect(store.events() == [second, third])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    #expect(permissions == 0o600)
}

@Test("Corrupt supervisor audit evidence is preserved and fails closed")
func corruptSupervisorAuditFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-supervisor-audit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("audit.json")
    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: file)
    let store = RelaySupervisorAuditStore(fileURL: file, persistenceEnabled: true)
    #expect(!store.record(auditEvent(1)))
    #expect(store.events() == nil)
    #expect(try Data(contentsOf: file) == corrupt)
}
