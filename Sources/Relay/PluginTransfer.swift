import Foundation
import CryptoKit
import Darwin

struct PluginTransferInfo: Codable, Sendable {
    let version: String
    let size: Int64
    let offset: Int64
    let sha256: String?
}

struct PluginTransferRequest: Sendable {
    let mode: String
    var version = ""
    var offset: Int64 = 0

    func validate(_ result: PluginOperationResult, path: String) throws {
        guard let info = result.transfer, result.text == path, info.offset == offset,
              mode == "stat" || info.version == version else {
            throw PluginError.invalid("Missing or mismatched transfer response; update relayd")
        }
        if mode == "chunk" {
            guard let data = result.verifiedBytes,
                  data.count == Int(min(4 << 20, info.size - offset)) else {
                throw PluginError.invalid("Incomplete transfer chunk")
            }
        } else {
            guard result.content == nil, result.sha256 == nil else { throw PluginError.invalid("Unexpected transfer payload") }
            if mode == "verify" {
                guard info.sha256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    throw PluginError.invalid("Missing final checksum")
                }
            }
        }
    }
}

/// One private spool per user-requested transfer. Pausing keeps only disk data;
/// every resume rechecks the remote identity. No unbounded in-memory file copy.
private final class PluginTransferHandles: @unchecked Sendable {
    let directory: Int32
    let lock: Int32
    init(directory: Int32, lock: Int32) { self.directory = directory; self.lock = lock }
    deinit { Darwin.close(lock); Darwin.close(directory) }
}

actor PluginTransferDownload {
    private let directory: URL
    private let file: URL
    private var info: PluginTransferInfo?
    private var offset: Int64 = 0
    private var hasher = SHA256()
    private var complete = false
    private var running = false

    private struct Checkpoint: Codable {
        let schema: Int
        let key: String
        let info: PluginTransferInfo
        let offset: Int64
        let sha256: String
    }
    private let persistenceKey: String?
    private let handles: PluginTransferHandles
    private var directoryFD: Int32 { handles.directory }

    init(persistenceKey: String? = nil, root: URL? = nil, discardExisting: Bool = false) throws {
        guard persistenceKey == nil || persistenceKey!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PluginError.invalid("Invalid transfer identity")
        }
        self.persistenceKey = persistenceKey
        let base = root ?? RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/Transfers")
        if persistenceKey != nil {
            var info = stat()
            if lstat(base.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR { throw PluginError.invalid("Unsafe transfer directory") }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(base.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginError.invalid("Transfer directory is not private") }
        }
        directory = persistenceKey.map { base.appendingPathComponent($0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-transfer-" + UUID().uuidString)
        file = directory.appendingPathComponent("download")
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw POSIXError(.EIO) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginError.invalid("Unsafe transfer directory") }
        var attributes = stat()
        guard fstat(parent, &attributes) == 0, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            Darwin.close(parent); throw PluginError.invalid("Transfer directory is not private")
        }
        let lock = openat(parent, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, fstat(lock, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1, attributes.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { Darwin.close(lock) }; Darwin.close(parent)
            throw PluginError.invalid("Transfer is already open or its lock is unsafe")
        }
        handles = PluginTransferHandles(directory: parent, lock: lock)
        do {
            if discardExisting {
                guard unlinkat(parent, "checkpoint.json", 0) == 0 || errno == ENOENT,
                      unlinkat(parent, "download", 0) == 0 || errno == ENOENT,
                      fsync(parent) == 0 else { throw POSIXError(.EIO) }
            }
            let dataFD = openat(parent, "download", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard dataFD >= 0 else { throw PluginError.invalid("Unsafe transfer file") }
            let input = FileHandle(fileDescriptor: dataFD, closeOnDealloc: true)
            guard fstat(dataFD, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                  attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0, attributes.st_nlink == 1 else { throw PluginError.invalid("Unsafe transfer file") }
            let checkpointFD = openat(parent, "checkpoint.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if checkpointFD >= 0 {
                let checkpointFile = FileHandle(fileDescriptor: checkpointFD, closeOnDealloc: true)
                var details = stat()
                guard let persistenceKey, fstat(checkpointFD, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
                      details.st_uid == getuid(), details.st_mode & 0o077 == 0, details.st_size > 0, details.st_size <= 4096,
                      let data = try checkpointFile.read(upToCount: 4097), data.count <= 4096 else { throw PluginError.invalid("Unsafe transfer checkpoint") }
                let saved = try JSONDecoder().decode(Checkpoint.self, from: data)
                guard saved.schema == 1, saved.key == persistenceKey, saved.offset >= 0,
                      saved.offset <= saved.info.size, saved.info.size <= 64 << 30,
                      saved.info.version.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      attributes.st_size >= saved.offset else { throw PluginError.invalid("Invalid transfer checkpoint") }
                var remaining = saved.offset
                while remaining > 0 {
                    guard let data = try input.read(upToCount: Int(min(1 << 20, remaining))), !data.isEmpty else { throw PluginError.invalid("Partial transfer is incomplete") }
                    hasher.update(data: data); remaining -= Int64(data.count)
                }
                let digest = hasher
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == saved.sha256 else { throw PluginError.invalid("Partial transfer checksum mismatch; discard this copy") }
                info = saved.info; offset = saved.offset
            } else if errno != ENOENT { throw PluginError.invalid("Cannot read transfer checkpoint") }
            // A crash after writing a chunk but before committing its checkpoint
            // leaves only an unacknowledged tail. Recover the durable prefix.
            try input.truncate(atOffset: UInt64(offset)); try input.synchronize()
        } catch { throw error }
    }

    deinit {
        if persistenceKey == nil { try? FileManager.default.removeItem(at: directory) }
    }

    private func checkpoint() throws {
        guard let persistenceKey, let info else { return }
        let copy = hasher
        let digest = copy.finalize().map { String(format: "%02x", $0) }.joined()
        let bytes = try JSONEncoder().encode(Checkpoint(schema: 1, key: persistenceKey, info: info, offset: offset, sha256: digest))
        let name = ".checkpoint-" + UUID().uuidString
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd); unlinkat(directoryFD, name, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard renameat(directoryFD, name, directoryFD, "checkpoint.json") == 0, fsync(directoryFD) == 0 else { throw POSIXError(.EIO) }
    }

    func discard() throws {
        guard !running else { throw PluginError.invalid("Pause the transfer before discarding it") }
        guard unlinkat(directoryFD, "checkpoint.json", 0) == 0 || errno == ENOENT,
              unlinkat(directoryFD, "download", 0) == 0 || errno == ENOENT,
              fsync(directoryFD) == 0 else { throw POSIXError(.EIO) }
        complete = false
    }

    func download(fetch: @Sendable (PluginTransferRequest) async throws -> PluginOperationResult,
                  progress: @Sendable (Int64, Int64) async -> Void) async throws -> URL {
        guard !running else { throw PluginError.invalid("Transfer is already running") }
        running = true
        defer { running = false }
        let current = try await fetch(PluginTransferRequest(mode: "stat"))
        guard let metadata = current.transfer else { throw PluginError.invalid("Missing transfer metadata") }
        if let info, info.version != metadata.version || info.size != metadata.size {
            throw PluginError.invalid("Source changed. Discard this transfer and start again.")
        }
        guard metadata.size >= 0, metadata.size <= 64 << 30,
              metadata.version.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PluginError.invalid("Invalid transfer metadata") }
        info = metadata
        let fd = openat(directoryFD, "download", O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PluginError.invalid("Unsafe transfer file") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try checkpoint()
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        await progress(offset, metadata.size)
        while offset < metadata.size {
            try Task.checkCancellation()
            let response = try await fetch(PluginTransferRequest(mode: "chunk", version: metadata.version, offset: offset))
            guard let data = response.verifiedBytes, !data.isEmpty,
                  response.transfer?.size == metadata.size, response.transfer?.version == metadata.version,
                  response.transfer?.offset == offset,
                  data.count == Int(min(4 << 20, metadata.size - offset)) else { throw PluginError.invalid("Incomplete chunk") }
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            hasher.update(data: data)
            offset += Int64(data.count)
            try output.synchronize()
            try checkpoint()
            await progress(offset, metadata.size)
        }
        try output.synchronize()
        let verification = try await fetch(PluginTransferRequest(mode: "verify", version: metadata.version, offset: offset))
        let finalHasher = hasher
        let digest = finalHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard verification.transfer?.sha256 == digest else { throw PluginError.invalid("Final file checksum mismatch; discard this transfer") }
        try Task.checkCancellation()
        complete = true
        return file
    }

    func save(to destination: URL) throws {
        guard complete, !running else { throw PluginError.invalid("Transfer is not verified") }
        // Stage on the destination volume so the final rename is atomic. Copying
        // streams through the filesystem; the complete file never enters memory.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".relay-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: file, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}
