import Foundation

enum WorkspaceMigrationPlanInboxError: Error, LocalizedError, Equatable {
    case notRegularFile, unsafeFolder, tooLarge, invalidName, notAnObject, previewOpen, previewMismatch, previewNotClean

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "A migration plan must be a regular file, not a symbolic link or folder."
        case .unsafeFolder: "The migration plan folder must be a real folder, reached without links, owned by you with mode 0700."
        case .tooLarge: "A migration plan must be at most 1 MB."
        case .invalidName: "A migration plan name may use letters, digits, '.', '_' and '-' only."
        case .notAnObject: "A migration plan must be a JSON object."
        case .previewOpen: "A different migration preview is already open. Discard it in Relay, or stage with replace."
        case .previewMismatch: "That is not the open migration preview (ID or checksum differs). Read the preview again."
        case .previewNotClean: "The open migration preview has refusals or name collisions; it must be applied by the user, if at all."
        }
    }
}

/// Relay's own folder of migration plans: what the sheet lists and where
/// staged or chosen plans are kept. Plans here are data; nothing is applied.
struct WorkspaceMigrationPlanInbox {
    static let maximumBytes = 1 << 20
    static let shared = WorkspaceMigrationPlanInbox(directory: RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/workspace-migration-plans", isDirectory: true))
    private static let validName = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")

    struct Entry: Equatable, Identifiable {
        let name: String
        let description: String?
        let size: Int
        let modified: Date
        var id: String { name }
    }

    let directory: URL

    /// Bytes of a regular, non-symlink file of at most 1 MB, read from the
    /// descriptor that was checked, so a file swapped after any earlier look
    /// is refused rather than followed.
    static func read(_ url: URL) throws -> Data { try read(at: AT_FDCWD, url.path) }

    /// A plan in this folder, opened through the folder's checked descriptor.
    func read(_ name: String) throws -> Data {
        let folder = try self.folder(create: false)
        defer { close(folder) }
        return try Self.read(at: folder, url(name).lastPathComponent)
    }

    func list() -> [Entry] {
        guard let folder = try? self.folder(create: false) else { return [] }
        defer { close(folder) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Entry? in
            var info = stat()
            guard (try? url(name)) != nil, fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, let data = try? Self.read(at: folder, name) else { return nil }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            return Entry(name: name, description: object?["description"] as? String, size: data.count, modified: modified)
        }
        .sorted { ($0.modified, $1.name) > ($1.modified, $0.name) }
    }

    func url(_ name: String) throws -> URL {
        guard Self.validName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
              name.hasSuffix(".json") else { throw WorkspaceMigrationPlanInboxError.invalidName }
        return directory.appendingPathComponent(name)
    }

    /// Writes the plan's exact bytes, owner-only, replacing a plan of that name.
    @discardableResult
    func store(_ data: Data, name: String?) throws -> URL {
        guard data.count <= Self.maximumBytes else { throw WorkspaceMigrationPlanInboxError.tooLarge }
        var file = name ?? "workspace-migration-plan-\(Self.stamp.string(from: Date())).json"
        if !file.hasSuffix(".json") { file += ".json" }
        let target = try url(file)
        let folder = try self.folder(create: true)
        defer { close(folder) }
        var existing = stat()
        if fstatat(folder, file, &existing, AT_SYMLINK_NOFOLLOW) == 0, existing.st_mode & S_IFMT != S_IFREG {
            throw WorkspaceMigrationPlanInboxError.notRegularFile
        }
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        let written = data.withUnsafeBytes { Self.write(fd, $0) } && fsync(fd) == 0
        let code = errno
        close(fd)
        guard written, renameat(folder, temporary, folder, file) == 0 else {
            let error = Self.failure(written ? errno : code)
            unlinkat(folder, temporary, 0)
            throw error
        }
        return target
    }

    /// A plan chosen elsewhere is copied in, so it is listed next time.
    func importPlan(_ data: Data, from url: URL) throws -> URL {
        if url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL { return url }
        return try store(data, name: Self.safeName(for: url))
    }

    /// An inbox name derived from a file name elsewhere.
    static func safeName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return String((base.first?.isLetter == true || base.first?.isNumber == true ? base : "plan-" + base).prefix(75)) + ".json"
    }

    /// The folder as a descriptor, reached one component at a time without
    /// following links (only root-owned system links such as /var are
    /// crossed), created 0700 when `create`, and refused unless it is a
    /// directory owned by this user with mode 0700.
    private func folder(create: Bool) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        let parts = Array(directory.path.split(separator: "/").map(String.init))
        for (index, part) in parts.enumerated() {
            var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), code = errno
            if next < 0, code == ENOENT, create {
                if mkdirat(fd, part, 0o700) == 0 || errno == EEXIST {
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                code = errno
            } else if next < 0, code == ELOOP || code == ENOTDIR, index < parts.count - 1 {
                var link = stat()
                if fstatat(fd, part, &link, AT_SYMLINK_NOFOLLOW) == 0, link.st_mode & S_IFMT == S_IFLNK, link.st_uid == 0 {
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    code = errno
                }
            }
            close(fd)
            guard next >= 0 else {
                throw code == ELOOP || code == ENOTDIR ? WorkspaceMigrationPlanInboxError.unsafeFolder : Self.failure(code)
            }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw WorkspaceMigrationPlanInboxError.unsafeFolder
        }
        return fd
    }

    /// Opens without following a final link (and without blocking on a FIFO),
    /// checks that same descriptor, and reads at most one byte past the limit.
    private static func read(at folder: Int32, _ path: String) throws -> Data {
        let fd = openat(folder, path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? WorkspaceMigrationPlanInboxError.notRegularFile : failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceMigrationPlanInboxError.notRegularFile }
        guard info.st_size <= maximumBytes else { throw WorkspaceMigrationPlanInboxError.tooLarge }
        var data = Data(count: maximumBytes + 1), total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            total += count
        }
        guard total <= maximumBytes else { throw WorkspaceMigrationPlanInboxError.tooLarge }
        return data.prefix(total)
    }

    private static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private static func failure(_ code: Int32 = errno) -> Error { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
