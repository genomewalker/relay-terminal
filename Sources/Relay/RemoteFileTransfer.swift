import Foundation
import Darwin

enum RemoteFileTransferError: LocalizedError {
    case notAFile(String)
    case tooLarge(String)
    case failed(String)
    case invalidResponse
    case recoveryAvailable

    var errorDescription: String? {
        switch self {
        case .notAFile(let name): "\(name) is not a regular file"
        case .tooLarge(let name): "\(name) has an invalid file length"
        case .failed(let message): message
        case .invalidResponse: "The remote file transfer returned an invalid response"
        case .recoveryAvailable: "A saved upload exists for these items. Resume uses the original destination and recovers completed files without uploading another copy. Forget cancels unfinished uploads and clears saved receipts; completed remote files are kept."
        }
    }
}

enum RemoteFileTransfer {
    // The representable file-offset range, with no application byte cap.
    static let maximumBytes: Int64 = .max
    private struct Capabilities: Decodable {
        let operations: [String]
        let unbounded: Bool?
        let folderProtocol: Int?
        let folderLimits: FolderLimits?
        enum CodingKeys: String,CodingKey { case operations; case unbounded = "file_upload_unbounded"; case folderProtocol = "folder_upload_protocol",folderLimits = "folder_upload_limits" }
    }
    private struct FolderLimits: Decodable {
        let entries: Int, chunk: Int
        enum CodingKeys: String,CodingKey { case entries = "max_entries", chunk = "max_chunk_bytes" }
    }
    private enum Session: Sendable {
        case file(RemoteUpload), folder(RemoteFolderUpload)
        var isFolder: Bool { if case .folder = self { return true };return false }
        func hasCheckpoint() async -> Bool {
            switch self { case .file(let session): await session.hasCheckpoint();case .folder(let session): await session.hasCheckpoint() }
        }
    }
    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }
    private static func request<T: Decodable>(_ payload: Data, profile: ConnectionProfile, as type: T.Type) async throws -> T {
        let response = try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload)
        let decoded = try JSONDecoder().decode(Envelope<T>.self, from: response)
        if let error = decoded.error { throw RemoteFileTransferError.failed(error) }
        guard let result = decoded.result else { throw RemoteFileTransferError.invalidResponse }
        return result
    }
    private static func capabilities(profile: ConnectionProfile, folders: Bool = false) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["request_id": "rpc-" + UUID().uuidString.lowercased(), "operation": "capabilities"])
        let capabilities = try await request(payload, profile: profile, as: Capabilities.self)
        let required = ["file_upload_begin", "file_upload_status", "file_upload_chunk", "file_upload_commit", "file_upload_cancel"]
        guard capabilities.unbounded == true, required.allSatisfy(capabilities.operations.contains) else {
            throw RemoteFileTransferError.failed("Update this host’s Relay helper to enable recoverable uploads")
        }
        if folders {
            let operations = ["destination","begin","status","chunk","file_commit","commit","cancel","cleanup"].map { "file_folder_" + $0 }
            guard capabilities.folderProtocol == 1, operations.allSatisfy(capabilities.operations.contains),
                  let limits = capabilities.folderLimits, limits.entries >= 1024, limits.chunk >= 4 << 20 else {
                throw RemoteFileTransferError.failed("Update this host’s Relay helper to enable recoverable folder uploads")
            }
        }
    }
    static func fetch(_ upload: RemoteFolderRequest, profile: ConnectionProfile) async throws -> RemoteFolderReceipt {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String:Any] else { throw RemoteFileTransferError.invalidResponse }
        object["request_id"] = "rpc-" + UUID().uuidString.lowercased()
        return try await request(JSONSerialization.data(withJSONObject: object), profile: profile, as: RemoteFolderReceipt.self)
    }
    private static func session(source: URL, pane: String, profile: ConnectionProfile) async throws -> Session {
        let folder = try RemoteFolderUpload(source: source, pane: pane, profile: profile)
        if await folder.hasCheckpoint() { return .folder(folder) }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        var info = stat()
        if lstat(source.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR { return .folder(folder) }
        return .file(try RemoteUpload(source: source, pane: pane, profile: profile))
    }
    private static func folderDestination(pane: String, profile: ConnectionProfile) async throws -> String {
        struct Destination: Decodable { let pane: String,path: String }
        let payload = try JSONSerialization.data(withJSONObject:["request_id":"rpc-" + UUID().uuidString.lowercased(),"operation":"file_folder_destination","upload_pane":pane])
        let destination = try await request(payload,profile:profile,as:Destination.self)
        guard destination.pane == pane,destination.path.hasPrefix("/"),!destination.path.contains("\0") else { throw RemoteFileTransferError.invalidResponse }
        return destination.path
    }
    static func fetch(_ upload: RemoteUploadRequest, profile: ConnectionProfile) async throws -> RemoteUploadReceipt {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any] else { throw RemoteFileTransferError.invalidResponse }
        object["request_id"] = "rpc-" + UUID().uuidString.lowercased()
        let payload = try JSONSerialization.data(withJSONObject: object)
        do {
            return try await request(payload, profile: profile, as: RemoteUploadReceipt.self)
        } catch {
            throw RemoteFileTransferError.failed("Upload \(upload.jobID) paused: \(error.localizedDescription). Drop the same file into this pane to resume or forget the saved upload.")
        }
    }
    static func upload(_ urls: [URL], toPane paneID: String, profile: ConnectionProfile, resume: Bool = false, progress: RelayTransferProgressHandler? = nil) async throws -> [RemoteFileEntry] {
        try Task.checkCancellation()
        var sessions: [Session] = []
        for url in urls { sessions.append(try await session(source:url,pane:paneID,profile:profile)) }
        try await capabilities(profile: profile,folders:sessions.contains(where: { $0.isFolder }))
        if !resume {
            for session in sessions {
                if await session.hasCheckpoint() { throw RemoteFileTransferError.recoveryAvailable }
            }
        }
        let itemCount = sessions.count
        var imported: [RemoteFileEntry] = []
        for (index, session) in sessions.enumerated() {
            try Task.checkCancellation()
            let report: RelayTransferProgressHandler = { update in
                var update = update; update.itemIndex = index + 1; update.itemCount = itemCount
                await progress?(update)
            }
            switch session {
            case .file(let upload):
                imported.append(try await upload.upload(resume:resume,progress:report,fetch:{ try await fetch($0,profile:profile) }))
            case .folder(let upload):
                let destination = await upload.hasCheckpoint() ? nil : try await folderDestination(pane:paneID,profile:profile)
                imported.append(try await upload.upload(resume:resume,destination:destination,progress:report,fetch:{ try await fetch($0,profile:profile) }))
            }
        }
        return imported
    }
    static func discard(_ urls: [URL], toPane paneID: String, profile: ConnectionProfile) async throws {
        var sessions: [Session] = []
        for url in urls { sessions.append(try await session(source:url,pane:paneID,profile:profile)) }
        try await capabilities(profile:profile,folders:sessions.contains(where: { $0.isFolder }))
        for session in sessions {
            switch session {
            case .file(let upload): try await upload.discard(fetch:{ try await fetch($0,profile:profile) })
            case .folder(let upload): try await upload.discard(fetch:{ try await fetch($0,profile:profile) })
            }
        }
    }
}
