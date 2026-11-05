import CryptoKit
import Darwin
import Foundation

/// Capture through a descriptor and keep an independent, private copy. Provider
/// paths use a generated basename; the user's original name stays in the draft.
enum RelayAgentAttachmentSnapshot {
    struct Record: Codable, Hashable, Sendable {
        let url: URL
        let bytes: Int64
        let digest: String
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        var isValid: Bool {
            url.isFileURL && url.path.hasPrefix("/") && url.absoluteString.utf8.count <= 4096 &&
                !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) &&
                bytes >= 0 && bytes <= RemoteFileTransfer.maximumBytes && inode > 0 &&
                digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
        }

        func verify() -> Bool {
            guard isValid else { return false }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, matches(before),
                  before.st_uid == geteuid(), before.st_mode & 0o077 == 0 else { return false }
            do {
                let actual = try RelayAgentAttachmentSnapshot.copyAndHash(source: fd, destination: nil, limit: bytes)
                var after = stat()
                return fstat(fd, &after) == 0 && matches(after) && actual.bytes == bytes && actual.digest == digest
            } catch { return false }
        }

        func withVerifiedFile<T>(_ body: (Int32) throws -> T) throws -> T {
            try Task.checkCancellation()
            guard isValid else { throw Failure.unsuitable }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unsuitable }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, matches(before), before.st_uid == geteuid(),
                  before.st_mode & 0o077 == 0 else { throw Failure.changed }
            let actual = try RelayAgentAttachmentSnapshot.copyAndHash(source: fd, destination: nil, limit: bytes)
            var after = stat()
            guard fstat(fd, &after) == 0, RelayAgentAttachmentSnapshot.sameSource(before, after),
                  actual.bytes == bytes, actual.digest == digest,
                  lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.changed }
            let result = try body(fd)
            guard fstat(fd, &after) == 0, RelayAgentAttachmentSnapshot.sameSource(before, after) else { throw Failure.changed }
            return result
        }

        /// Read and authenticate the same open descriptor, never reopen a path
        /// after verification. Used by previews of the captured attachment.
        func verifiedData() throws -> Data {
            try Task.checkCancellation()
            guard isValid else { throw Failure.unsuitable }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unsuitable }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, matches(before),
                  before.st_uid == geteuid(), before.st_mode & 0o077 == 0 else { throw Failure.changed }
            var data = Data()
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 128 << 10)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.unsuitable
                }
                if count == 0 { break }
                guard Int64(data.count) + Int64(count) <= bytes else { throw Failure.changed }
                let chunk = Data(buffer.prefix(count))
                data.append(chunk); hash.update(data: chunk)
            }
            var after = stat()
            let actualDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard fstat(fd, &after) == 0, matches(after),
                  Int64(data.count) == bytes, actualDigest == digest else { throw Failure.changed }
            return data
        }

        private func matches(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && info.st_size == bytes &&
                UInt64(bitPattern: Int64(info.st_dev)) == device && UInt64(info.st_ino) == inode &&
                Int64(info.st_mtimespec.tv_sec) == modifiedSeconds &&
                Int64(info.st_mtimespec.tv_nsec) == modifiedNanoseconds
        }
    }

    enum Failure: LocalizedError {
        case unsuitable, tooLarge, changed
        var errorDescription: String? {
            switch self {
            case .unsuitable: "Choose a readable regular file to attach."
            case .tooLarge: "This attachment has an invalid file length."
            case .changed: "The file changed while being prepared. Attach it again."
            }
        }
    }

    static func createPrivateDirectory(_ directory: URL) throws {
        var existing = stat()
        if lstat(directory.path, &existing) == 0, existing.st_mode & S_IFMT != S_IFDIR { throw Failure.unsuitable }
        SecureFiles.createPrivateDirectory(at: directory)
        var parent = stat()
        guard lstat(directory.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == geteuid(), parent.st_mode & 0o077 == 0 else { throw Failure.unsuitable }
    }

    static func capture(_ sourceURL: URL, directory: URL) throws -> Record {
        try Task.checkCancellation()
        guard sourceURL.isFileURL, sourceURL.path.hasPrefix("/"),
              !sourceURL.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.unsuitable }
        let source = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard source >= 0 else { throw posixFailure() }
        defer { Darwin.close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.unsuitable }
        guard before.st_size >= 0, before.st_size <= RemoteFileTransfer.maximumBytes else { throw Failure.tooLarge }
        try createPrivateDirectory(directory)
        let ext = sourceURL.pathExtension
        let safeExtension = !ext.isEmpty && ext.utf8.count <= 16 &&
            ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let name = "file-" + UUID().uuidString.lowercased() + (safeExtension ? "." + ext : "")
        let url = directory.appendingPathComponent(name)
        let destination = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard destination >= 0 else { throw posixFailure() }
        var complete = false
        defer {
            Darwin.close(destination)
            if !complete { Darwin.unlink(url.path) }
        }
        let result = try copyAndHash(source: source, destination: destination, limit: before.st_size)
        var after = stat()
        guard fstat(source, &after) == 0, sameSource(before, after), result.bytes == before.st_size else { throw Failure.changed }
        guard fchmod(destination, mode_t(0o400)) == 0, fsync(destination) == 0 else { throw posixFailure() }
        var saved = stat()
        guard fstat(destination, &saved) == 0, saved.st_size == result.bytes else { throw Failure.changed }
        var named = stat()
        guard lstat(url.path, &named) == 0, sameSource(saved, named) else { throw Failure.changed }
        let record = Record(url: url, bytes: result.bytes, digest: result.digest,
            device: UInt64(bitPattern: Int64(saved.st_dev)), inode: UInt64(saved.st_ino),
            modifiedSeconds: Int64(saved.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(saved.st_mtimespec.tv_nsec))
        guard record.isValid else { throw Failure.unsuitable }
        complete = true
        return record
    }

    static func captureAsync(_ sourceURL: URL, directory: URL) async throws -> Record {
        let task = Task.detached(priority: .utility) { try capture(sourceURL, directory: directory) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func sameSource(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func copyAndHash(source: Int32, destination: Int32?, limit: Int64) throws -> (bytes: Int64, digest: String) {
        var hash = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 128 << 10)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw posixFailure() }
            if count == 0 { break }
            total += Int64(count)
            guard total <= limit else { throw Failure.changed }
            let data = Data(buffer.prefix(count))
            hash.update(data: data)
            if let destination {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 { if errno == EINTR { continue }; throw posixFailure() }
                        guard written > 0 else { throw Failure.changed }
                        offset += written
                    }
                }
            }
        }
        return (total, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
