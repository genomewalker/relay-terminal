import CryptoKit
import Darwin
import Foundation

/// Durable, private single-attempt record keyed by the selected process
/// incarnation, not by a transport request. A crash before dispatch leaves a
/// conservative hold; a new card cannot silently retry the same process.
struct RelayAccountForceJournal {
    struct Reservation: Codable {
        let version: Int
        let actionID: UUID
        let paneID: UUID
        let provider: String
        let providerPID: Int
        let providerStart: String
        let blockerPID: Int
        let blockerStart: String
        let host: String
        let sessionID: String
        let commandDigest: String
        let createdAt: Date
    }
    enum Failure: Error { case unavailable }
    let directory: URL

    init(directory: URL = RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/agent-maintenance/force-attempts")) {
        self.directory = directory
    }

    func reserve(preview: RelayAccountForcePreview, actionID: UUID) throws {
        guard preview.isValid else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let info = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (info[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw Failure.unavailable }
        // Length-prefix each component to avoid tuple ambiguities. Do not key
        // on argv or account: neither permits a repeat of the same process.
        let parts = [preview.paneID.uuidString.lowercased(), preview.provider, String(preview.providerPID),
                     preview.providerStart, String(preview.blockerPID), preview.blockerStart]
        let bytes = parts.map { "\($0.utf8.count):\($0)" }.joined()
        let key = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".json")
        let record = Reservation(version: 1, actionID: actionID, paneID: preview.paneID, provider: preview.provider,
            providerPID: preview.providerPID, providerStart: preview.providerStart, blockerPID: preview.blockerPID,
            blockerStart: preview.blockerStart, host: preview.host, sessionID: preview.sessionID,
            commandDigest: preview.commandDigest, createdAt: Date())
        let data = try JSONEncoder().encode(record)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        let synced = written && fsync(fd) == 0
        let closed = close(fd) == 0
        guard synced, closed else { throw Failure.unavailable }
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw Failure.unavailable }
        let dirSynced = fsync(dirFD) == 0
        let dirClosed = close(dirFD) == 0
        guard dirSynced, dirClosed else { throw Failure.unavailable }
    }
}
