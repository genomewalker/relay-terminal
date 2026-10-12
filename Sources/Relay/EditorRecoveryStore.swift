import Foundation
import CryptoKit

struct EditorRecoveryRecord: Codable, Equatable {
    let ownerID: UUID
    let profileID: UUID
    let path: String
    let content: String
    let savedContent: String
    let modificationNS: Int64
    let updated: Date
    var dirty: Bool { content != savedContent }
    var id: String { ownerID.uuidString + path }
}

/// Local recovery only: never writes through to the source document.
struct EditorRecoveryStore {
    let root: URL
    static let shared = EditorRecoveryStore(root: RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/EditorRecovery", isDirectory: true))

    private func url(profile: UUID, path: String, owner: UUID) -> URL {
        let key = Data((profile.uuidString + "\0" + owner.uuidString + "\0" + path).utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".json")
    }

    func save(_ record: EditorRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let destination = url(profile: record.profileID, path: record.path, owner: record.ownerID)
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func load(profile: UUID, path: String, owner: UUID) throws -> EditorRecoveryRecord? {
        let file = url(profile: profile, path: path, owner: owner)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(EditorRecoveryRecord.self, from: Data(contentsOf: file))
        guard record.profileID == profile, record.path == path else { return nil }
        return record
    }

    func recent(profile: UUID) -> [EditorRecoveryRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> EditorRecoveryRecord? in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(EditorRecoveryRecord.self, from: data),
                  record.profileID == profile else { return nil }
            return record
        }.sorted { $0.updated > $1.updated }
    }
}
