import Foundation

enum RelaySupervisorAuditKind: String, Codable, Sendable {
    case proposed
    case approved
    case rejected
    case expired
    case staleIdentity
    case executionRejected
    case executionDispatched
    case executionSucceeded
    case executionFailed
}

enum RelaySupervisorAuditReason: String, Codable, Sendable {
    case userReview
    case alreadyConsumed
    case notApproved
    case expired
    case staleIdentity
    case unreachable
    case unsupportedStage
    case missingCapability
    case transportUnavailable
}

struct RelaySupervisorAuditEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let receiptID: UUID
    let identity: RelaySupervisedSessionID
    let stage: RelaySupervisorStage
    let kind: RelaySupervisorAuditKind
    let reason: RelaySupervisorAuditReason
    let occurredAt: Date
}

/// A small local enforcement ledger. Existing corrupt or oversized evidence is
/// never overwritten: callers receive `false` and must fail closed before any
/// lifecycle mutation. The file contains identities and policy outcomes only,
/// never terminal output, prompts, credentials, or arbitrary error text.
final class RelaySupervisorAuditStore: @unchecked Sendable {
    static let shared = RelaySupervisorAuditStore()

    private struct Envelope: Codable {
        let schema: Int
        var events: [RelaySupervisorAuditEvent]
    }

    private let fileURL: URL
    private let maximumEvents: Int
    private let persistenceEnabled: Bool
    private let lock = NSLock()

    init(
        fileURL: URL? = nil,
        maximumEvents: Int = 512,
        persistenceEnabled: Bool? = nil
    ) {
        self.fileURL = fileURL ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/Supervisor/audit.json")
        self.maximumEvents = max(1, min(maximumEvents, 4_096))
        self.persistenceEnabled = persistenceEnabled ?? !RelayLaunchMode.isRunningTests
    }

    func record(_ event: RelaySupervisorAuditEvent) -> Bool {
        guard persistenceEnabled else { return true }
        lock.lock()
        defer { lock.unlock() }

        var events: [RelaySupervisorAuditEvent]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let envelope = loadUnlocked() else { return false }
            events = envelope.events
        } else {
            events = []
        }
        guard !events.contains(where: { $0.id == event.id }) else { return true }
        events.append(event)
        if events.count > maximumEvents {
            events.removeFirst(events.count - maximumEvents)
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schema: 1, events: events))
            guard data.count <= 1 << 20 else { return false }
            try data.write(to: fileURL, options: .atomic)
            SecureFiles.restrictToOwner(fileURL)
            return true
        } catch {
            RelayDiagnostics.shared.record(
                category: "supervisor", name: "audit-write-failed",
                details: ["reason": error.localizedDescription]
            )
            return false
        }
    }

    func events() -> [RelaySupervisorAuditEvent]? {
        guard persistenceEnabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return loadUnlocked()?.events
    }

    private func loadUnlocked() -> Envelope? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 1 << 20,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.schema == 1,
              envelope.events.count <= maximumEvents else { return nil }
        return envelope
    }
}
