import Foundation
import Combine
import Darwin

/// Admission comes from the caller's trusted ownership registry. The on-disk
/// event's owner is never used to authorize itself. A failed durability barrier
/// stops this instance; restore is required before any further publication.
@MainActor
final class RelayDurableSurfaceStore: ObservableObject {
    @Published private(set) var snapshots: [UUID: RelaySurfaceSnapshot] = [:]
    @Published private(set) var available = true
    private var state = RelaySurfaceState()
    private let url: URL
    private let authorizedOwners: Set<RelaySurfaceOwner>
    private let admitOwner: ((RelaySurfaceOwner) -> Bool)?
    init(directory: URL? = nil, authorizedOwners: Set<RelaySurfaceOwner>, admitOwner: ((RelaySurfaceOwner) -> Bool)? = nil) {
        self.admitOwner = admitOwner
        self.authorizedOwners = authorizedOwners
        let directory = directory ?? RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/Surfaces")
        url = directory.appendingPathComponent("surfaces-v1.json")
        var info = stat()
        if lstat(directory.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR { available = false; return }
        SecureFiles.createPrivateDirectory(at: directory)
        do {
            let parent = try openDirectory(); defer { Darwin.close(parent) }
            let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno != ENOENT { throw POSIXError(.EIO) }
                return
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_size > 0, info.st_size <= 8_388_608,
                  let data = try file.read(upToCount: 8_388_609), data.count <= 8_388_608 else { throw POSIXError(.EACCES) }
            state = try restore(data)
            snapshots = state.snapshots
        } catch { available = false }
    }
    func publish(_ event: RelaySurfaceEvent, authorizedOwner: RelaySurfaceOwner) throws -> RelaySurfaceSnapshot? {
        guard available, (authorizedOwners.contains(authorizedOwner) || admitOwner?(authorizedOwner) == true) else { throw RelaySurfaceError.unauthorizedOwner }
        let parent = try openDirectory(); defer { Darwin.close(parent) }
        let lock = openat(parent, ".surfaces.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o077 == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RelaySurfaceError.revisionConflict }
        defer { flock(lock, LOCK_UN) }
        // Another renderer/process may have committed a revision since this
        // instance loaded. Re-read under the write lock before checking CAS.
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_size > 0, info.st_size <= 8_388_608,
                  let bytes = try file.read(upToCount: 8_388_609), bytes.count <= 8_388_608 else { available = false; throw POSIXError(.EACCES) }
            do { state = try restore(bytes); snapshots = state.snapshots }
            catch { available = false; throw error }
        } else {
            guard errno == ENOENT, try state.checkpoint() == Data("[]".utf8) else {
                available = false; throw POSIXError(.EIO)
            }
        }
        var next = state
        try next.apply(event, authorizedOwner: authorizedOwner)
        let data = try next.checkpoint()
        // An exact retry acknowledges the already committed revision.
        if data == (try state.checkpoint()) { snapshots = state.snapshots; return state.snapshots[event.surfaceID] }
        do { try writeDurably(data, directory: parent) }
        catch { available = false; throw error }
        state = next; snapshots = next.snapshots
        return snapshots[event.surfaceID]
    }
    /// Reads the current atomic checkpoint, including close tombstones.
    /// A failed refresh must never be represented as an empty successful read.
    func events() throws -> [RelaySurfaceEvent] {
        guard available else { throw RelaySurfaceError.unauthorizedOwner }
        let parent = try openDirectory(); defer { Darwin.close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT, state.latest.isEmpty else { throw POSIXError(.EIO) }
            return []
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 8_388_608,
              let data = try file.read(upToCount: 8_388_609), data.count <= 8_388_608 else {
            throw POSIXError(.EACCES)
        }
        let refreshed = try restore(data)
        state = refreshed; snapshots = refreshed.snapshots
        return state.latest.values.sorted { $0.surfaceID.uuidString < $1.surfaceID.uuidString }
    }
    private func restore(_ data: Data) throws -> RelaySurfaceState {
        guard data.count <= 8_388_608 else { throw RelaySurfaceError.capacityExceeded }
        let events = try JSONDecoder().decode([RelaySurfaceEvent].self, from: data)
        let admitted = Set(events.map(\.owner).filter { authorizedOwners.contains($0) || admitOwner?($0) == true })
        return try RelaySurfaceState.restore(data, authorizedOwners: admitted)
    }
    private func openDirectory() throws -> Int32 {
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor); throw POSIXError(.EACCES)
        }
        return descriptor
    }
    private func writeDurably(_ data: Data, directory: Int32) throws {
        func failed() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(directory, &info) == 0 else { throw failed() }
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
        let temporary = ".surfaces-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failed() }
        defer { Darwin.close(descriptor); unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw failed() }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failed() }
                written += count
            }
        }
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw failed() }
        guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else { throw failed() }
        // Flush both the payload and the namespace change before publication.
        guard fsync(directory) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw failed() }
    }
}
