import Foundation
import CryptoKit
import Darwin

struct RemoteFolderEntry: Codable, Sendable {
    let path: String
    let kind: String
    let size: Int64?
    let sha256: String?
}

struct RemoteFolderSourceVersion: Codable, Sendable {
    let path: String
    let version: String
}

struct RemoteFolderSnapshot: Codable, Sendable {
    let entries: [RemoteFolderEntry]
    let versions: [RemoteFolderSourceVersion]
    let manifestSHA256: String
    let sourceVersion: String
    let totalBytes: Int64
}

/// Reads the tree through pinned directory descriptors. No symlink or special
/// file is followed; empty directories remain explicit manifest entries.
final class RemoteFolderSource {
    private let source: URL
    private let root: Int32

    init(source: URL) throws {
        self.source = source
        let fd = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteFileTransferError.failed("Cannot open folder source without following links") }
        root = fd
    }
    deinit { Darwin.close(root) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func version(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func ordered(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    private static func childName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static var changed: RemoteFileTransferError {
        .failed("Folder source changed; forget the saved upload before starting again")
    }

    // Match Go encoding/json's struct field order, omitempty and string escapes.
    // This avoids accepting a different canonical manifest after a retry.
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32, 38, 60, 62, 0x2028, 0x2029:
                result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    static func canonicalManifest(_ entries: [RemoteFolderEntry]) -> Data {
        let rows = entries.sorted { ordered($0.path, $1.path) }.map { entry in
            var row = "{\"path\":\(quoted(entry.path)),\"kind\":\(quoted(entry.kind))"
            if let size = entry.size, size != 0 { row += ",\"size\":\(size)" }
            if let sha = entry.sha256, !sha.isEmpty { row += ",\"sha256\":\(quoted(sha))" }
            return row + "}"
        }
        return Data(("[" + rows.joined(separator: ",") + "]").utf8)
    }

    static func validate(_ snapshot: RemoteFolderSnapshot) throws {
        guard snapshot.entries.count <= 1024, snapshot.versions.count == snapshot.entries.count + 1 else { throw RemoteFileTransferError.invalidResponse }
        var seen = Set<Data>(), directories = Set<Data>(), total: Int64 = 0
        for entry in snapshot.entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.count <= 32, entry.path.utf8.count <= 1024, parts.allSatisfy(childName),
                  parts[0] != ".relay-folder-owner", seen.insert(Data(entry.path.utf8)).inserted else { throw RemoteFileTransferError.invalidResponse }
            if entry.kind == "directory" {
                guard entry.size == nil, entry.sha256 == nil else { throw RemoteFileTransferError.invalidResponse }
                directories.insert(Data(entry.path.utf8))
            } else {
                guard entry.kind == "file", let size = entry.size, size >= 0, size <= RemoteFileTransfer.maximumBytes,
                      let sha = entry.sha256, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw RemoteFileTransferError.invalidResponse }
                total += size
            }
        }
        for entry in snapshot.entries {
            let parent = (entry.path as NSString).deletingLastPathComponent
            guard parent.isEmpty || directories.contains(Data(parent.utf8)) else { throw RemoteFileTransferError.invalidResponse }
        }
        var versionPaths = Set<Data>()
        for version in snapshot.versions {
            guard !version.version.isEmpty, version.version.utf8.count <= 256,
                  versionPaths.insert(Data(version.path.utf8)).inserted,
                  version.path == "." || seen.contains(Data(version.path.utf8)) else { throw RemoteFileTransferError.invalidResponse }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let versions = snapshot.versions.sorted { ordered($0.path, $1.path) }
        guard versionPaths.contains(Data(".".utf8)), total <= 1 << 30, total == snapshot.totalBytes,
              digest(canonicalManifest(snapshot.entries)) == snapshot.manifestSHA256,
              digest(try encoder.encode(versions)) == snapshot.sourceVersion else { throw RemoteFileTransferError.invalidResponse }
    }

    func snapshot() throws -> RemoteFolderSnapshot {
        var rootInfo = stat(), pathInfo = stat()
        guard fstat(root, &rootInfo) == 0, lstat(source.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFDIR, Self.version(rootInfo) == Self.version(pathInfo),
              Self.childName(source.lastPathComponent) else { throw Self.changed }
        var entries: [RemoteFolderEntry] = []
        var versions = [RemoteFolderSourceVersion(path: ".", version: Self.version(rootInfo))]
        var total: Int64 = 0
        try walk(root, relative: "", depth: 0, entries: &entries, versions: &versions, total: &total)
        guard fstat(root, &pathInfo) == 0, Self.version(pathInfo) == Self.version(rootInfo),
              lstat(source.path, &pathInfo) == 0, Self.version(pathInfo) == Self.version(rootInfo) else { throw Self.changed }
        entries.sort { Self.ordered($0.path, $1.path) }
        versions.sort { Self.ordered($0.path, $1.path) }
        let manifest = Self.canonicalManifest(entries)
        let versionEncoder = JSONEncoder()
        versionEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return RemoteFolderSnapshot(entries: entries, versions: versions, manifestSHA256: Self.digest(manifest),
                                    sourceVersion: Self.digest(try versionEncoder.encode(versions)), totalBytes: total)
    }

    private func walk(_ fd: Int32, relative: String, depth: Int, entries: inout [RemoteFolderEntry],
                      versions: inout [RemoteFolderSourceVersion], total: inout Int64) throws {
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw Self.changed }
        let listingFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listingFD >= 0 else { throw Self.changed }
        guard let listing = fdopendir(listingFD) else { Darwin.close(listingFD); throw Self.changed }
        defer { closedir(listing) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(listing) else {
                guard errno == 0 else { throw Self.changed }; break
            }
            let nameCapacity = MemoryLayout.size(ofValue: item.pointee.d_name)
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw RemoteFileTransferError.failed("Folder names must use valid UTF-8") }
            if name == "." || name == ".." { continue }
            let child = relative.isEmpty ? name : relative + "/" + name
            guard Self.childName(name), child.utf8.count <= 1024, depth < 32, entries.count < 1024,
                  !relative.isEmpty || name != ".relay-folder-owner" else {
                throw RemoteFileTransferError.failed("Folder manifest exceeds its limits or uses a reserved name")
            }
            var info = stat(), current = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.changed }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw Self.changed }
                defer { Darwin.close(childFD) }
                guard fstat(childFD, &current) == 0, Self.version(current) == Self.version(info) else { throw Self.changed }
                entries.append(RemoteFolderEntry(path: child, kind: "directory", size: nil, sha256: nil))
                versions.append(RemoteFolderSourceVersion(path: child, version: Self.version(info)))
                try walk(childFD, relative: child, depth: depth + 1, entries: &entries, versions: &versions, total: &total)
            case S_IFREG:
                guard info.st_size >= 0, info.st_size <= RemoteFileTransfer.maximumBytes else { throw RemoteFileTransferError.tooLarge(child) }
                total += info.st_size
                guard total <= 1 << 30 else { throw RemoteFileTransferError.failed("Folder exceeds the 1 GiB transfer limit") }
                let childFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard childFD >= 0 else { throw Self.changed }
                let file = FileHandle(fileDescriptor: childFD, closeOnDealloc: true)
                defer { try? file.close() }
                guard fstat(childFD, &current) == 0, Self.version(current) == Self.version(info) else { throw Self.changed }
                let sha = try Self.hash(file, count: info.st_size)
                guard fstat(childFD, &current) == 0, Self.version(current) == Self.version(info) else { throw Self.changed }
                entries.append(RemoteFolderEntry(path: child, kind: "file", size: info.st_size, sha256: sha))
                versions.append(RemoteFolderSourceVersion(path: child, version: Self.version(info)))
            default:
                throw RemoteFileTransferError.failed("Folder transfers require regular files and directories; links and special files are unsupported")
            }
            guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, Self.version(current) == Self.version(info) else { throw Self.changed }
        }
        guard fstat(fd, &after) == 0, Self.version(before) == Self.version(after) else { throw Self.changed }
    }

    static func hash(_ file: FileHandle, count: Int64) throws -> String {
        try file.seek(toOffset: 0)
        var remaining = count, hasher = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try file.read(upToCount: Int(min(1 << 20, remaining))), !bytes.isEmpty else { throw Self.changed }
            hasher.update(data: bytes); remaining -= Int64(bytes.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func openFile(_ entry: RemoteFolderEntry, snapshot: RemoteFolderSnapshot) throws -> FileHandle {
        guard entry.kind == "file", entry.path.utf8.count <= 1024, let size = entry.size,
              size >= 0, size <= RemoteFileTransfer.maximumBytes else { throw Self.changed }
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy(Self.childName) else { throw Self.changed }
        func expected(_ path: String) throws -> String {
            guard let version = snapshot.versions.first(where: { Self.exact($0.path, path) })?.version else { throw Self.changed }
            return version
        }
        var info = stat(), named = stat()
        guard fstat(root, &info) == 0, Self.version(info) == (try expected(".")),
              lstat(source.path, &named) == 0, Self.version(named) == Self.version(info) else { throw Self.changed }
        let duplicate = dup(root)
        guard duplicate >= 0 else { throw Self.changed }
        guard fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(duplicate); throw Self.changed }
        var parent = duplicate
        defer { Darwin.close(parent) }
        var prefix = ""
        for (index, component) in parts.enumerated() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            let expectedVersion = try expected(prefix)
            let last = index == parts.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY)
            let fd = openat(parent, component, flags)
            guard fd >= 0 else { throw Self.changed }
            guard fstat(fd, &info) == 0, Self.version(info) == expectedVersion,
                  fstatat(parent, component, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.version(named) == Self.version(info) else { Darwin.close(fd); throw Self.changed }
            if last {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size == size else { Darwin.close(fd); throw Self.changed }
                return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { Darwin.close(fd); throw Self.changed }
            Darwin.close(parent); parent = fd
        }
        throw Self.changed
    }

    func checkFile(_ file: FileHandle, entry: RemoteFolderEntry, snapshot: RemoteFolderSnapshot) throws {
        let named = try openFile(entry, snapshot: snapshot)
        defer { try? named.close() }
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(file.fileDescriptor, &descriptorInfo) == 0, fstat(named.fileDescriptor, &pathInfo) == 0,
              Self.version(descriptorInfo) == Self.version(pathInfo) else { throw Self.changed }
    }
}
