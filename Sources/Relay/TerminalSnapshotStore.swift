import CryptoKit
import Foundation

enum TerminalSnapshotWritePolicy {
    static let debounceMilliseconds = 1_500
    static let leewayMilliseconds = 500
    static let maximumIntervalMilliseconds = 5_000
    // The remote PTY is authoritative and continues recording while Relay is
    // inactive. A local snapshot is only an instant visual cache, so rewriting
    // multi-megabyte ANSI streams every five seconds in the background wastes
    // CPU and battery without improving recoverability.
    static let backgroundDebounceMilliseconds = 30_000
    static let backgroundMaximumIntervalMilliseconds = 30_000
}

enum TerminalSnapshotRecordCodec {
    private static let legacyMagic = Data("RELAYSS1".utf8)
    private static let magic = Data("RELAYSS2".utf8)
    static var minimumHeaderBytes: Int { legacyMagic.count + 4 }
    static var headerBytes: Int { magic.count + 12 }

    struct Snapshot: Equatable {
        let payload: Data
        let remoteSequence: UInt64
    }

    static func encode(
        _ payload: Data,
        viewport: RelayViewport,
        remoteSequence: UInt64 = 0
    ) -> Data {
        var record = magic
        var columns = viewport.columns.bigEndian
        var rows = viewport.rows.bigEndian
        var sequence = remoteSequence.bigEndian
        withUnsafeBytes(of: &columns) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: &rows) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: &sequence) { record.append(contentsOf: $0) }
        record.append(payload)
        return record
    }

    static func decode(_ record: Data, expectedViewport: RelayViewport) -> Data? {
        decodeSnapshot(record, expectedViewport: expectedViewport)?.payload
    }

    static func decodeSnapshot(
        _ record: Data,
        expectedViewport: RelayViewport
    ) -> Snapshot? {
        let isCurrent = record.starts(with: magic)
        let isLegacy = record.starts(with: legacyMagic)
        guard isCurrent || isLegacy else { return nil }
        let requiredBytes = isCurrent ? headerBytes : minimumHeaderBytes
        guard record.count >= requiredBytes else { return nil }
        let offset = magic.count
        let columns = record[offset..<(offset + 2)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        let rows = record[(offset + 2)..<(offset + 4)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        guard columns == expectedViewport.columns, rows == expectedViewport.rows else { return nil }
        if isCurrent {
            let sequence = record[(offset + 4)..<(offset + 12)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            return Snapshot(payload: Data(record.dropFirst(headerBytes)), remoteSequence: sequence)
        }
        return Snapshot(
            payload: Data(record.dropFirst(minimumHeaderBytes)),
            remoteSequence: 0
        )
    }

    /// The ANSI payload is only safe to draw at its recorded viewport, but
    /// its durable relayd sequence remains a valid resume cursor at every
    /// viewport. Keeping those concerns separate prevents a window-size
    /// change from replaying a multi-megabyte agent transcript from byte zero.
    static func resumeCursor(_ record: Data) -> UInt64? {
        guard record.starts(with: magic), record.count >= headerBytes else { return nil }
        let offset = magic.count + 4
        return record[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}

/// A small, local reconstruction stream for instant visual restore. The
/// authoritative PTY remains remote; this cache is display-only and is replaced
/// as soon as relayd finishes replaying the current screen.
final class TerminalSnapshotStore: @unchecked Sendable {
    static let shared = TerminalSnapshotStore()
    static let maximumBytes = 16 << 20
    private static let legacyMaximumBytes = 2 << 20

    private let directory: URL
    private let queue = DispatchQueue(label: "relay.terminal-snapshots", qos: .utility)
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]
    private var scheduledDigests: [UUID: Data] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/TerminalSnapshots", isDirectory: true)
        self.directory = base
        SecureFiles.createPrivateDirectory(at: base)
    }

    func load(paneID: UUID, viewport: RelayViewport) -> Data? {
        loadSnapshot(paneID: paneID, viewport: viewport)?.payload
    }

    func loadSnapshot(
        paneID: UUID,
        viewport: RelayViewport
    ) -> TerminalSnapshotRecordCodec.Snapshot? {
        guard let record = loadRecord(paneID: paneID) else { return nil }
        guard let snapshot = TerminalSnapshotRecordCodec.decodeSnapshot(
            record, expectedViewport: viewport
        ) else { return nil }
        // Legacy overflow records can contain a 2 MiB cursor-addressed suffix
        // with no self-contained screen. Replaying that suffix on a reset grid
        // produces stray cells even if its first escape is complete. Request
        // an application repaint instead of treating it as a valid cache.
        guard !Self.isLegacyLossySnapshot(snapshot.payload) else { return nil }
        return TerminalSnapshotRecordCodec.Snapshot(
            payload: Self.repairLegacyCut(snapshot.payload),
            remoteSequence: snapshot.remoteSequence
        )
    }

    func loadResumeCursor(paneID: UUID) -> UInt64? {
        guard let record = loadRecord(paneID: paneID) else { return nil }
        return TerminalSnapshotRecordCodec.resumeCursor(record)
    }

    func save(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64 = 0
    ) {
        guard let pending = reserve(
            data, paneID: paneID, viewport: viewport, remoteSequence: remoteSequence
        ) else { return }
        queue.async { [weak self] in
            self?.write(pending.record, paneID: paneID, generation: pending.generation)
        }
    }

    /// App termination cannot rely on a queued utility task running before
    /// process exit. Drain older writes and persist the newest screen now.
    func saveSynchronously(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64 = 0
    ) {
        if let pending = reserve(
            data, paneID: paneID, viewport: viewport, remoteSequence: remoteSequence
        ) {
            queue.sync {
                write(pending.record, paneID: paneID, generation: pending.generation)
            }
        } else {
            // An identical async write may already be queued. A synchronous
            // barrier guarantees it completes before AppKit exits.
            queue.sync {}
        }
    }

    func remove(paneID: UUID) {
        lock.lock()
        generations[paneID] = (generations[paneID] ?? 0) &+ 1
        scheduledDigests.removeValue(forKey: paneID)
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

    private func loadRecord(paneID: UUID) -> Data? {
        let url = snapshotURL(paneID)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > TerminalSnapshotRecordCodec.minimumHeaderBytes,
              size <= Self.maximumBytes + TerminalSnapshotRecordCodec.headerBytes
        else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func reserve(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64
    ) -> (record: Data, generation: UInt64)? {
        guard !data.isEmpty else { return nil }
        let bounded = Self.bounded(data)
        let record = TerminalSnapshotRecordCodec.encode(
            bounded, viewport: viewport, remoteSequence: remoteSequence
        )
        let digest = Data(SHA256.hash(data: record))
        lock.lock()
        defer { lock.unlock() }
        guard scheduledDigests[paneID] != digest else { return nil }
        scheduledDigests[paneID] = digest
        let generation = (generations[paneID] ?? 0) &+ 1
        generations[paneID] = generation
        return (record, generation)
    }

    private func write(_ record: Data, paneID: UUID, generation: UInt64) {
        lock.lock()
        let current = generations[paneID] == generation
        lock.unlock()
        guard current else { return }
        let url = snapshotURL(paneID)
        do {
            try record.write(to: url, options: .atomic)
            SecureFiles.restrictToOwner(url)
        } catch {
            lock.lock()
            if generations[paneID] == generation {
                scheduledDigests.removeValue(forKey: paneID)
            }
            lock.unlock()
            RelayDiagnostics.shared.record(category: "snapshot", name: "write-failed", details: [
                "pane_id": paneID.uuidString.lowercased(),
                "reason": error.localizedDescription,
            ])
        }
    }

    static func bounded(_ data: Data) -> Data {
        // Small snapshots are already bounded and replay quickly. Scanning the
        // same ANSI stream on every periodic save was pure background work.
        guard data.count > maximumBytes else { return data }
        let compacted = TerminalReplayCompactor.compact(data)
        guard compacted.count > maximumBytes else { return compacted }
        var result = Data("\u{001B}c".utf8)
        result.append(TerminalReplayCompactor.safeSuffix(
            compacted,
            maximumBytes: maximumBytes - result.count
        ))
        return result
    }

    /// Older overflow snapshots were cut at an arbitrary byte, including the
    /// middle of SGR parameters. Repair that known on-disk shape on load so a
    /// new build does not immediately redraw the same damaged cached screen.
    static func repairLegacyCut(_ data: Data) -> Data {
        let bytes = Array(data.prefix(32))
        guard bytes.count >= 6, bytes[0] == 0x1B, bytes[1] == 0x63 else { return data }
        var index = 2
        var hasSeparator = false
        while index < bytes.count, (bytes[index] >= 0x30 && bytes[index] <= 0x39) || bytes[index] == 0x3B {
            if bytes[index] == 0x3B { hasSeparator = true }
            index += 1
        }
        guard hasSeparator, index < bytes.count, bytes[index] == 0x6D else { return data }
        var repaired = Data("\u{001B}c".utf8)
        repaired.append(TerminalReplayCompactor.safeSuffix(
            data, maximumBytes: data.count - 2
        ))
        return repaired
    }

    static func isLegacyLossySnapshot(_ data: Data) -> Bool {
        // Keep rejecting records truncated by the previous 2 MiB limit.
        // Raising the limit cannot repair a suffix already missing its base.
        let atOverflowLimit = [legacyMaximumBytes, maximumBytes].contains {
            data.count >= $0 - 4_096 && data.count <= $0
        }
        return atOverflowLimit &&
            data.starts(with: Data("\u{001B}c".utf8)) &&
            !data.contains(0x0A)
    }
}
