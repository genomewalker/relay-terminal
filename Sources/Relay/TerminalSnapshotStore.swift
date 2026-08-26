import Foundation

/// A small, local reconstruction stream for instant visual restore. The
/// authoritative PTY remains remote; this cache is display-only and is replaced
/// as soon as relayd finishes replaying the current screen.
final class TerminalSnapshotStore: @unchecked Sendable {
    static let shared = TerminalSnapshotStore()
    static let maximumBytes = 2 << 20

    private let directory: URL
    private let queue = DispatchQueue(label: "relay.terminal-snapshots", qos: .utility)
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Relay/TerminalSnapshots", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    }

    func load(paneID: UUID) -> Data? {
        let url = snapshotURL(paneID)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data
    }

    func save(_ data: Data, paneID: UUID) {
        guard !data.isEmpty else { return }
        let bounded = Self.bounded(data)
        lock.lock()
        let generation = (generations[paneID] ?? 0) &+ 1
        generations[paneID] = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generations[paneID] == generation
            self.lock.unlock()
            guard current else { return }
            let url = self.snapshotURL(paneID)
            do {
                try bounded.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                RelayDiagnostics.shared.record(category: "snapshot", name: "write-failed", details: [
                    "pane_id": paneID.uuidString.lowercased(),
                    "reason": error.localizedDescription,
                ])
            }
        }
    }

    func remove(paneID: UUID) {
        lock.lock()
        generations[paneID] = (generations[paneID] ?? 0) &+ 1
        lock.unlock()
        queue.async { [directory] in
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(paneID.uuidString.lowercased() + ".ansi")
            )
        }
    }

    private func snapshotURL(_ paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString.lowercased() + ".ansi")
    }

    static func bounded(_ data: Data) -> Data {
        let compacted = TerminalReplayCompactor.compact(data)
        guard compacted.count > maximumBytes else { return compacted }
        var result = Data("\u{001B}c".utf8)
        result.append(compacted.suffix(maximumBytes - result.count))
        return result
    }
}
