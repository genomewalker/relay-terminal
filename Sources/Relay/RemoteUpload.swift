import Foundation
import CryptoKit
import Darwin

struct RemoteUploadRequest: Encodable, Sendable {
    let operation: String
    let jobID: String
    var pane: String?
    var name: String?
    var size: Int64?
    var sha256: String?
    var offset: Int64?
    var data: Data?
    enum CodingKeys: String, CodingKey {
        case operation, data, offset
        case jobID = "job_id", pane = "upload_pane", name = "upload_name"
        case size = "upload_size", sha256 = "upload_sha256"
    }
}

struct RemoteUploadReceipt: Decodable, Sendable {
    let id: String
    let state: String
    let size: Int64
    let sha256: String
    let offset: Int64
    let directory: String
    let path: String?
    let prefixSHA256: String
    enum CodingKeys: String, CodingKey {
        case id, state, size, sha256, offset, directory, path
        case prefixSHA256 = "prefix_sha256"
    }
}

struct RemoteUploadCheckpoint: Codable, Sendable {
    var schema = 1
    let key: String
    let jobID: String
    let sourceVersion: String
    let size: Int64
    let sha256: String
    var offset: Int64 = 0
    var directory: String?
}

/// Descriptor ownership survives suspension without exposing file access to callers.
final class RemoteUploadStore: @unchecked Sendable {
    let directory: Int32
    let lock: Int32
    private let maximumCheckpointBytes: Int
    init(key: String, root: URL?, maximumCheckpointBytes: Int = 8192) throws {
        guard key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              maximumCheckpointBytes > 0, maximumCheckpointBytes <= 8 << 20 else { throw RemoteFileTransferError.failed("Invalid upload checkpoint bounds") }
        self.maximumCheckpointBytes = maximumCheckpointBytes
        let base = root ?? RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/Uploads")
        var info = stat()
        if lstat(base.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR { throw RemoteFileTransferError.failed("Unsafe upload directory") }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard lstat(base.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RemoteFileTransferError.failed("Upload directory is not private") }
        let target = base.appendingPathComponent(key)
        if mkdir(target.path, 0o700) != 0, errno != EEXIST { throw POSIXError(.EIO) }
        let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else { throw RemoteFileTransferError.failed("Unsafe upload directory") }
        defer { Darwin.close(baseFD) }
        guard fstat(baseFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              fsync(baseFD) == 0 else { throw RemoteFileTransferError.failed("Cannot persist upload directory") }
        let fd = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteFileTransferError.failed("Unsafe upload directory") }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw RemoteFileTransferError.failed("Upload directory is not private")
        }
        let locked = openat(fd, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard locked >= 0, fstat(locked, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(locked, LOCK_EX | LOCK_NB) == 0 else {
            if locked >= 0 { Darwin.close(locked) }; Darwin.close(fd)
            throw RemoteFileTransferError.failed("Upload is already open or its lock is unsafe")
        }
        directory = fd; lock = locked
    }
    deinit { Darwin.close(lock); Darwin.close(directory) }
    func read<T: Decodable>() throws -> T? {
        let fd = openat(directory, "checkpoint.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RemoteFileTransferError.failed("Cannot read upload checkpoint")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximumCheckpointBytes,
              let bytes = try file.read(upToCount: maximumCheckpointBytes + 1), bytes.count <= maximumCheckpointBytes else {
            throw RemoteFileTransferError.failed("Unsafe upload checkpoint")
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
    func save<T: Encodable>(_ checkpoint: T) throws {
        let bytes = try JSONEncoder().encode(checkpoint)
        guard bytes.count <= maximumCheckpointBytes else { throw RemoteFileTransferError.failed("Upload checkpoint exceeds its limit") }
        let name = ".checkpoint-" + UUID().uuidString.lowercased()
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd); unlinkat(directory, name, 0) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try file.write(contentsOf: bytes); try file.synchronize()
        guard renameat(directory, name, directory, "checkpoint.json") == 0, fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }
    func remove() throws {
        guard unlinkat(directory, "checkpoint.json", 0) == 0 || errno == ENOENT,
              fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }
}

actor RemoteUpload {
    typealias Fetch = @Sendable (RemoteUploadRequest) async throws -> RemoteUploadReceipt
    private let source: URL
    private let pane: String
    private let key: String
    private let store: RemoteUploadStore
    private var checkpoint: RemoteUploadCheckpoint?
    private var running = false

    static func identity(source: URL, pane: String, profile: ConnectionProfile) throws -> String {
        let fields = [source.standardizedFileURL.path, pane, profile.id.uuidString.lowercased(),
                      profile.kind.rawValue, profile.backend.rawValue, profile.host, profile.user,
                      String(profile.port), String(profile.usesSSHConfig), profile.command]
        return digest(try JSONEncoder().encode(fields))
    }
    init(source: URL, pane: String, profile: ConnectionProfile, root: URL? = nil) throws {
        self.source = source; self.pane = pane
        key = try Self.identity(source: source, pane: pane, profile: profile)
        store = try RemoteUploadStore(key: key, root: root)
        checkpoint = try store.read()
        if let saved = checkpoint {
            guard saved.schema == 1, saved.key == key, saved.jobID.range(of: "^upload-[0-9a-f-]{36}$", options: .regularExpression) != nil,
                  saved.size >= 0, saved.size <= RemoteFileTransfer.maximumBytes,
                  saved.offset >= 0, saved.offset <= saved.size,
                  saved.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw RemoteFileTransferError.failed("Invalid upload checkpoint")
            }
        }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func version(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private func checkSource(_ file: FileHandle, expected: String) throws {
        var fdInfo = stat(), pathInfo = stat()
        guard fstat(file.fileDescriptor, &fdInfo) == 0, lstat(source.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG, Self.version(fdInfo) == expected,
              Self.version(pathInfo) == expected else {
            throw RemoteFileTransferError.failed("Source file changed; discard the partial upload before starting again")
        }
    }
    private func accept(_ receipt: RemoteUploadReceipt, file: FileHandle, prefix: RelayTransferChecksum, saved: inout RemoteUploadCheckpoint) throws {
        guard receipt.id == saved.jobID, receipt.size == saved.size, receipt.sha256 == saved.sha256,
              receipt.offset >= saved.offset, receipt.offset <= saved.size,
              ["receiving", "committing", "committed"].contains(receipt.state),
              receipt.directory.hasPrefix("/"), saved.directory == nil || saved.directory == receipt.directory,
              prefix.offset == receipt.offset, prefix.digest == receipt.prefixSHA256 else { throw RemoteFileTransferError.invalidResponse }
        try checkSource(file, expected: saved.sourceVersion)
        saved.offset = receipt.offset; saved.directory = receipt.directory
        try store.save(saved); checkpoint = saved
    }
    func upload(resume: Bool, progress: RelayTransferProgressHandler? = nil, fetch: Fetch) async throws -> RemoteFileEntry {
        guard !running else { throw RemoteFileTransferError.failed("Upload is already running") }
        if checkpoint != nil, !resume { throw RemoteFileTransferError.recoveryAvailable }
        running = true; defer { running = false }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw RemoteFileTransferError.notAFile(source.lastPathComponent) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFileTransferError.notAFile(source.lastPathComponent) }
        guard info.st_size <= RemoteFileTransfer.maximumBytes else { throw RemoteFileTransferError.tooLarge(source.lastPathComponent) }
        let sourceVersion = Self.version(info)
        let name = source.lastPathComponent
        await progress?(.init(phase: .preparing, name: name, totalBytes: info.st_size))
        var full = RelayTransferChecksum()
        let sourceSize = info.st_size
        try await full.advance(file, to: sourceSize) { offset in
            await progress?(.init(phase: .preparing, name: name, completedBytes: offset, totalBytes: sourceSize))
        }
        let sha256 = full.digest
        try checkSource(file, expected: sourceVersion)
        let existing = checkpoint != nil
        var saved = checkpoint ?? RemoteUploadCheckpoint(key: key, jobID: "upload-" + UUID().uuidString.lowercased(), sourceVersion: sourceVersion, size: info.st_size, sha256: sha256)
        guard saved.sourceVersion == sourceVersion, saved.size == info.st_size, saved.sha256 == sha256 else {
            throw RemoteFileTransferError.failed("Source file changed; discard the partial upload before starting again")
        }
        try store.save(saved); checkpoint = saved
        let request = existing
            ? RemoteUploadRequest(operation: "file_upload_status", jobID: saved.jobID)
            : RemoteUploadRequest(operation: "file_upload_begin", jobID: saved.jobID, pane: pane, name: source.lastPathComponent, size: saved.size, sha256: saved.sha256)
        var receipt = try await fetch(request)
        guard receipt.offset >= 0, receipt.offset <= saved.size else { throw RemoteFileTransferError.invalidResponse }
        var prefix = RelayTransferChecksum()
        if receipt.offset > 0 { await progress?(.init(phase: .verifying, name: name, totalBytes: saved.size)) }
        try await prefix.advance(file, to: receipt.offset)
        try accept(receipt, file: file, prefix: prefix, saved: &saved)
        await progress?(.init(phase: .uploading, name: name, completedBytes: saved.offset, totalBytes: saved.size))
        while receipt.state == "receiving", saved.offset < saved.size {
            try Task.checkCancellation(); try checkSource(file, expected: saved.sourceVersion)
            try file.seek(toOffset: UInt64(saved.offset))
            guard let bytes = try file.read(upToCount: Int(min(4 << 20, saved.size - saved.offset))), !bytes.isEmpty else { throw RemoteFileTransferError.failed("Source file is incomplete") }
            try checkSource(file, expected: saved.sourceVersion)
            let expectedOffset = saved.offset + Int64(bytes.count)
            prefix.append(bytes)
            receipt = try await fetch(RemoteUploadRequest(operation: "file_upload_chunk", jobID: saved.jobID, offset: saved.offset, data: bytes))
            guard receipt.offset == expectedOffset else { throw RemoteFileTransferError.invalidResponse }
            try accept(receipt, file: file, prefix: prefix, saved: &saved)
            await progress?(.init(phase: .uploading, name: name, completedBytes: saved.offset, totalBytes: saved.size))
        }
        if receipt.state != "committed" {
            await progress?(.init(phase: .verifying, name: name, completedBytes: saved.offset, totalBytes: saved.size))
            try Task.checkCancellation(); try checkSource(file, expected: saved.sourceVersion)
            receipt = try await fetch(RemoteUploadRequest(operation: "file_upload_commit", jobID: saved.jobID))
            try accept(receipt, file: file, prefix: prefix, saved: &saved)
        }
        guard receipt.state == "committed", receipt.offset == saved.size,
              let path = receipt.path, (path as NSString).deletingLastPathComponent == receipt.directory,
              !path.contains("\0") else { throw RemoteFileTransferError.invalidResponse }
        await progress?(.init(phase: .complete, name: name, completedBytes: saved.size, totalBytes: saved.size))
        return RemoteFileEntry(name: (path as NSString).lastPathComponent, path: path, directory: false, symbolicLink: false, size: saved.size, modificationNS: 0)
    }
    func hasCheckpoint() -> Bool { checkpoint != nil }
    func discard(fetch: Fetch) async throws {
        guard !running else { throw RemoteFileTransferError.failed("Pause the upload before discarding it") }
        guard let saved = checkpoint else { return }
        running = true; defer { running = false }
        let receipt = try await fetch(RemoteUploadRequest(operation: "file_upload_cancel", jobID: saved.jobID))
        guard receipt.id == saved.jobID, receipt.state == "cancelled" || receipt.state == "committed" else {
            throw RemoteFileTransferError.failed("Upload outcome is pending; resume to recover the receipt")
        }
        try store.remove(); checkpoint = nil
    }
}
