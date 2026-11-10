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
        /// Restore trackers' state at the payload's end; nil for legacy
        /// records, whose payload must be observed instead.
        var trackerState: TerminalSnapshotTrackerState? = nil
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

/// Per-pane append-only snapshot log. A checkpoint frame holds a bounded
/// payload; each delta frame holds only the bytes appended since. Every frame
/// records the restore trackers' state at its end, so a restore reads the
/// newest state instead of rescanning the whole payload. A frame's checksum
/// covers its header, state and payload; loading stops at the first torn or
/// corrupt frame and keeps everything before it.
enum TerminalSnapshotLogCodec {
    static let magic = Data("RELAYSL1".utf8)
    static var headerBytes: Int { magic.count + 4 }
    static let frameHeaderBytes = 1 + 1 + 4 + 8 + 4
    static let checksumBytes = 8

    enum Kind: UInt8 {
        case checkpoint = 1
        case delta = 2
    }

    struct Log: Equatable {
        var viewport: RelayViewport
        var payload: Data
        var remoteSequence: UInt64
        /// The checkpoint is a suffix without its screen base. It still carries
        /// a resume cursor, but replaying it would draw stray cells.
        var truncated: Bool
        var trackerState: TerminalSnapshotTrackerState?
        var validLength: Int
        var deltaFrames: Int
    }

    static func header(viewport: RelayViewport) -> Data {
        var data = magic
        append(viewport.columns, to: &data)
        append(viewport.rows, to: &data)
        return data
    }

    static func frame(
        kind: Kind,
        truncated: Bool,
        remoteSequence: UInt64,
        trackerState: TerminalSnapshotTrackerState?,
        payload: Data
    ) -> Data {
        let state = trackerState.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        var frame = Data()
        frame.reserveCapacity(frameHeaderBytes + state.count + payload.count + checksumBytes)
        frame.append(kind.rawValue)
        frame.append(truncated ? 1 : 0)
        append(UInt32(payload.count), to: &frame)
        append(remoteSequence, to: &frame)
        append(UInt32(state.count), to: &frame)
        frame.append(state)
        frame.append(payload)
        frame.append(contentsOf: SHA256.hash(data: frame).prefix(checksumBytes))
        return frame
    }

    /// The grid a log was saved at, from its header alone. A zero dimension
    /// is refused: no Relay grid has one.
    static func headerViewport(_ header: Data) -> RelayViewport? {
        let header = header.startIndex == 0 ? header : Data(header)
        guard header.count >= headerBytes, header.starts(with: magic) else { return nil }
        let columns = read(UInt16.self, from: header, at: magic.count)
        let rows = read(UInt16.self, from: header, at: magic.count + 2)
        guard columns > 0, rows > 0 else { return nil }
        return RelayViewport(columns: columns, rows: rows)
    }

    static func decode(_ file: Data) -> Log? {
        let file = file.startIndex == 0 ? file : Data(file)
        guard file.count >= headerBytes, file.starts(with: magic) else { return nil }
        let viewport = RelayViewport(
            columns: read(UInt16.self, from: file, at: magic.count),
            rows: read(UInt16.self, from: file, at: magic.count + 2)
        )
        guard let checkpoint = readFrame(file, at: headerBytes),
              checkpoint.kind == .checkpoint else { return nil }
        var log = Log(
            viewport: viewport,
            payload: checkpoint.payload,
            remoteSequence: checkpoint.remoteSequence,
            truncated: checkpoint.truncated,
            trackerState: checkpoint.trackerState,
            validLength: checkpoint.end,
            deltaFrames: 0
        )
        while let delta = readFrame(file, at: log.validLength), delta.kind == .delta {
            log.payload.append(delta.payload)
            log.remoteSequence = delta.remoteSequence
            log.trackerState = delta.trackerState
            log.validLength = delta.end
            log.deltaFrames += 1
        }
        return log
    }

    private struct Frame {
        let kind: Kind
        let truncated: Bool
        let remoteSequence: UInt64
        let trackerState: TerminalSnapshotTrackerState?
        let payload: Data
        let end: Int
    }

    private static func readFrame(_ file: Data, at offset: Int) -> Frame? {
        guard file.count - offset >= frameHeaderBytes + checksumBytes,
              let kind = Kind(rawValue: file[offset]) else { return nil }
        let payloadLength = Int(read(UInt32.self, from: file, at: offset + 2))
        let remoteSequence = read(UInt64.self, from: file, at: offset + 6)
        let stateLength = Int(read(UInt32.self, from: file, at: offset + 14))
        let stateStart = offset + frameHeaderBytes
        let payloadStart = stateStart + stateLength
        let checksumStart = payloadStart + payloadLength
        let end = checksumStart + checksumBytes
        guard end <= file.count,
              SHA256.hash(data: file[offset..<checksumStart]).prefix(checksumBytes)
                .elementsEqual(file[checksumStart..<end]) else { return nil }
        var trackerState: TerminalSnapshotTrackerState?
        if stateLength > 0 {
            // A state this build cannot decode makes the frame unusable: its
            // payload is valid, but restore would observe the wrong modes.
            guard let decoded = try? JSONDecoder().decode(
                TerminalSnapshotTrackerState.self, from: file[stateStart..<payloadStart]
            ) else { return nil }
            trackerState = decoded
        }
        return Frame(
            kind: kind,
            truncated: file[offset + 1] != 0,
            remoteSequence: remoteSequence,
            trackerState: trackerState,
            payload: file.subdata(in: payloadStart..<checksumStart),
            end: end
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, from data: Data, at offset: Int) -> T {
        data[offset..<(offset + MemoryLayout<T>.size)].reduce(T(0)) { ($0 << 8) | T($1) }
    }
}

/// A small, local reconstruction stream for instant visual restore. The
/// authoritative PTY remains remote; this cache is display-only and is replaced
/// as soon as relayd finishes replaying the current screen.
///
/// Agent TUIs redraw by cursor addressing and rarely emit a full clear, so
/// compaction cannot shrink their streams. Saves therefore append only the
/// bytes added since the previous save instead of rewriting the payload, and
/// write a fresh checkpoint only when the stream is replaced, trimmed, resized
/// or has accumulated too many frames.
final class TerminalSnapshotStore: @unchecked Sendable {
    static let shared = TerminalSnapshotStore()
    static let maximumBytes = 16 << 20
    private static let legacyMaximumBytes = 2 << 20
    /// Bounds per-frame overhead and the frames verified on load.
    static let maximumDeltaFrames = 512
    private static let maximumLogBytes = maximumBytes + (8 << 20)
    /// Identifies the persisted prefix cheaply. A replaced or trimmed buffer
    /// differs at its start or at the old end; a full hash per save would cost
    /// a linear pass over megabytes on every debounce.
    private static let fingerprintBytes = 4_096

    typealias Bound = (Data) -> (data: Data, truncated: Bool)

    private let directory: URL
    private let queue = DispatchQueue(label: "relay.terminal-snapshots", qos: .utility)
    private let lock = NSLock()
    private var epochs: [UUID: UInt64] = [:]
    private var tips: [UUID: LogTip] = [:]
    /// Bracketed paste at a cursor-only restore point, for the suffix
    /// checkpoints written after it when the loaded log carried no state.
    private var bracketedPasteSeeds: [UUID: TerminalBracketedPasteStateTracker.PersistentState] = [:]
    private var paneLocks: [UUID: NSLock] = [:]
    private let bound: Bound

    /// What the newest enqueued write leaves on disk for a pane.
    private struct LogTip {
        let epoch: UInt64
        var viewport: RelayViewport
        var payloadCount: Int
        var fingerprint: Fingerprint
        var remoteSequence: UInt64
        var truncated: Bool
        var trackerState: TerminalSnapshotTrackerState?
        var fileLength: Int
        var deltaFrames: Int
        /// Set when the checkpoint bounded an oversized stream, so an unchanged
        /// oversized save is recognised before compacting it again.
        var oversizedSource: OversizedSource?
    }

    private struct Fingerprint: Equatable {
        let head: SHA256.Digest
        let tail: SHA256.Digest
    }

    private struct OversizedSource: Equatable {
        let byteCount: Int
        let digest: SHA256.Digest
    }

    private enum PendingWrite {
        case checkpoint(Data)
        case append(Data, offset: Int)
    }

    init(
        directory: URL? = nil,
        bound: @escaping Bound = { TerminalSnapshotStore.boundedReportingTruncation($0) }
    ) {
        let base = directory ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/TerminalSnapshots", isDirectory: true)
        self.directory = base
        self.bound = bound
        SecureFiles.createPrivateDirectory(at: base)
    }

    /// The grid this pane's log was last saved at, read from its header only.
    func savedViewport(paneID: UUID) -> RelayViewport? {
        guard let handle = try? FileHandle(forReadingFrom: snapshotURL(paneID)) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: TerminalSnapshotLogCodec.headerBytes) else { return nil }
        return TerminalSnapshotLogCodec.headerViewport(header)
    }

    func load(paneID: UUID, viewport: RelayViewport) -> Data? {
        loadSnapshot(paneID: paneID, viewport: viewport)?.payload
    }

    /// The files a restore reads, read and decoded once away from the main
    /// thread. The loaders take it in place of the disk; every decision
    /// about the bytes is still made by them, at restore time.
    struct Prefetched: Sendable {
        let paneID: UUID
        let log: TerminalSnapshotLogCodec.Log?
        let legacyRecord: Data?
    }

    func prefetch(paneID: UUID) -> Prefetched {
        let log = loadLog(paneID: paneID)
        // Every loader reads the legacy record only when there is no log.
        return Prefetched(paneID: paneID, log: log, legacyRecord: log == nil ? loadLegacyRecord(paneID: paneID) : nil)
    }

    /// Reads on the write queue, so the result reflects every save queued
    /// before it. `completion` runs on that queue.
    func prefetch(paneID: UUID, completion: @escaping @Sendable (Prefetched) -> Void) {
        queue.async { [self] in completion(prefetch(paneID: paneID)) }
    }

    func loadSnapshot(
        paneID: UUID,
        viewport: RelayViewport,
        prefetched: Prefetched? = nil
    ) -> TerminalSnapshotRecordCodec.Snapshot? {
        if let log = log(paneID, prefetched) {
            // Bounded overflow suffixes have no self-contained screen; the
            // window check still catches buffers bounded outside this store.
            guard log.viewport == viewport, !log.truncated,
                  !Self.isLegacyLossySnapshot(log.payload) else { return nil }
            adoptLoadedLog(log, paneID: paneID)
            return TerminalSnapshotRecordCodec.Snapshot(
                payload: log.payload,
                remoteSequence: log.remoteSequence,
                trackerState: log.trackerState
            )
        }
        guard let record = legacyRecord(paneID, prefetched) else { return nil }
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

    /// Bracketed paste is an input mode, not screen geometry. A cursor-only
    /// restore (other viewport, truncated suffix) still resumes after the
    /// bytes that enabled it, so its last observed state must survive. Also
    /// adopts the log so a later suffix checkpoint can carry that state.
    func loadBracketedPasteState(
        paneID: UUID, prefetched: Prefetched? = nil
    ) -> TerminalBracketedPasteStateTracker.PersistentState? {
        guard let log = log(paneID, prefetched) else { return nil }
        let state: TerminalBracketedPasteStateTracker.PersistentState
        if let saved = log.trackerState {
            state = saved.bracketedPaste
        } else if !log.truncated {
            // Quit-time checkpoints skip the tracker scan; a complete
            // stream's last 2004 toggle is still authoritative.
            let tracker = TerminalBracketedPasteStateTracker()
            tracker.observe(log.payload)
            state = tracker.persistentState
        } else {
            return nil
        }
        adoptLoadedLog(log, paneID: paneID)
        lock.lock()
        bracketedPasteSeeds[paneID] = state
        lock.unlock()
        return state
    }

    func loadResumeCursor(paneID: UUID, prefetched: Prefetched? = nil) -> UInt64? {
        if let log = log(paneID, prefetched) { return log.remoteSequence }
        guard let record = legacyRecord(paneID, prefetched) else { return nil }
        return TerminalSnapshotRecordCodec.resumeCursor(record)
    }

    /// `truncated` marks a buffer already cut to a suffix without its screen
    /// base; it is persisted for the resume cursor but never replayed.
    func save(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64 = 0,
        truncated: Bool = false
    ) {
        let paneLock = lockForPane(paneID)
        paneLock.lock()
        defer { paneLock.unlock() }
        guard let (pending, epoch) = reserve(
            data, paneID: paneID, viewport: viewport,
            remoteSequence: remoteSequence, truncated: truncated,
            computesTrackerState: true
        ) else { return }
        // Enqueued under the pane lock: appends must reach disk in the order
        // their offsets were assigned.
        queue.async { [weak self] in
            self?.perform(pending, paneID: paneID, epoch: epoch)
        }
    }

    /// App termination cannot rely on a queued utility task running before
    /// process exit. Drain older writes and persist the newest screen now.
    func saveSynchronously(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64 = 0,
        truncated: Bool = false
    ) {
        let paneLock = lockForPane(paneID)
        paneLock.lock()
        defer { paneLock.unlock() }
        // Quit must stay fast across many panes: a checkpoint written here
        // skips the tracker scan, and restore falls back to observing it.
        if let (pending, epoch) = reserve(
            data, paneID: paneID, viewport: viewport,
            remoteSequence: remoteSequence, truncated: truncated,
            computesTrackerState: false
        ) {
            queue.sync { perform(pending, paneID: paneID, epoch: epoch) }
        } else {
            // An identical async write may already be queued. A synchronous
            // barrier guarantees it completes before AppKit exits.
            queue.sync {}
        }
    }

    func remove(paneID: UUID) {
        lock.lock()
        epochs[paneID] = (epochs[paneID] ?? 0) &+ 1
        tips.removeValue(forKey: paneID)
        bracketedPasteSeeds.removeValue(forKey: paneID)
        lock.unlock()
        let urls = [snapshotURL(paneID), legacySnapshotURL(paneID)]
        queue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func snapshotURL(_ paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString.lowercased() + ".snap")
    }

    private func legacySnapshotURL(_ paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString.lowercased() + ".ansi")
    }

    private func lockForPane(_ paneID: UUID) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = paneLocks[paneID] { return existing }
        let created = NSLock()
        paneLocks[paneID] = created
        return created
    }

    private func log(_ paneID: UUID, _ prefetched: Prefetched?) -> TerminalSnapshotLogCodec.Log? {
        if let prefetched, prefetched.paneID == paneID { return prefetched.log }
        return loadLog(paneID: paneID)
    }

    private func legacyRecord(_ paneID: UUID, _ prefetched: Prefetched?) -> Data? {
        if let prefetched, prefetched.paneID == paneID { return prefetched.legacyRecord }
        return loadLegacyRecord(paneID: paneID)
    }

    private func loadLog(paneID: UUID) -> TerminalSnapshotLogCodec.Log? {
        let url = snapshotURL(paneID)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > TerminalSnapshotLogCodec.headerBytes,
              size <= Self.maximumLogBytes,
              let file = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return TerminalSnapshotLogCodec.decode(file)
    }

    private func loadLegacyRecord(paneID: UUID) -> Data? {
        let url = legacySnapshotURL(paneID)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > TerminalSnapshotRecordCodec.minimumHeaderBytes,
              size <= Self.maximumBytes + TerminalSnapshotRecordCodec.headerBytes
        else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// A restored payload becomes the live buffer, so the next save can append
    /// to the log it came from. A torn tail beyond `validLength` is truncated
    /// by that first append.
    private func adoptLoadedLog(_ log: TerminalSnapshotLogCodec.Log, paneID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard tips[paneID] == nil else { return }
        tips[paneID] = LogTip(
            epoch: epochs[paneID] ?? 0,
            viewport: log.viewport,
            payloadCount: log.payload.count,
            fingerprint: Self.fingerprint(log.payload, count: log.payload.count),
            remoteSequence: log.remoteSequence,
            truncated: log.truncated,
            trackerState: log.trackerState,
            fileLength: log.validLength,
            deltaFrames: log.deltaFrames,
            oversizedSource: nil
        )
    }

    private static func fingerprint(_ data: Data, count: Int) -> Fingerprint {
        let sample = min(fingerprintBytes, count)
        let start = data.startIndex
        return Fingerprint(
            head: SHA256.hash(data: data[start..<(start + sample)]),
            tail: SHA256.hash(data: data[(start + count - sample)..<(start + count)])
        )
    }

    /// Caller holds the pane lock.
    private func reserve(
        _ data: Data,
        paneID: UUID,
        viewport: RelayViewport,
        remoteSequence: UInt64,
        truncated: Bool,
        computesTrackerState: Bool
    ) -> (PendingWrite, epoch: UInt64)? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        let epoch = epochs[paneID] ?? 0
        let tip = tips[paneID].flatMap { $0.epoch == epoch ? $0 : nil }
        let bracketedPasteSeed = tip?.trackerState?.bracketedPaste ?? bracketedPasteSeeds[paneID]
        lock.unlock()

        // Tracker state at the end of `data`, when it extends the persisted log.
        var extendedState: TerminalSnapshotTrackerState?
        if let tip, tip.viewport == viewport, tip.truncated == truncated,
           data.count <= Self.maximumBytes, data.count >= tip.payloadCount,
           Self.fingerprint(data, count: tip.payloadCount) == tip.fingerprint {
            if data.count == tip.payloadCount, remoteSequence == tip.remoteSequence {
                return nil
            }
            let delta = data.subdata(in: (data.startIndex + tip.payloadCount)..<data.endIndex)
            let state = tip.trackerState.flatMap { $0.advanced(by: delta) }
            extendedState = state
            // A quit-time checkpoint has no state; the next background save
            // replaces it once rather than appending stateless frames forever.
            let healsState = computesTrackerState && tip.trackerState == nil
            if tip.deltaFrames < Self.maximumDeltaFrames, !healsState {
                let frame = TerminalSnapshotLogCodec.frame(
                    kind: .delta, truncated: truncated, remoteSequence: remoteSequence,
                    trackerState: state, payload: delta
                )
                var next = tip
                next.payloadCount = data.count
                next.fingerprint = Self.fingerprint(data, count: data.count)
                next.remoteSequence = remoteSequence
                next.trackerState = state
                next.fileLength += frame.count
                next.deltaFrames += 1
                next.oversizedSource = nil
                lock.lock()
                tips[paneID] = next
                lock.unlock()
                return (.append(frame, offset: tip.fileLength), epoch)
            }
        }

        var payload = data
        var payloadTruncated = truncated
        var oversizedSource: OversizedSource?
        if data.count > Self.maximumBytes {
            // Hashing is a single linear pass; compaction rescans for replay
            // sequences. Rule out an unchanged stream before paying for it.
            let source = OversizedSource(byteCount: data.count, digest: SHA256.hash(data: data))
            if let tip, tip.oversizedSource == source, tip.viewport == viewport,
               tip.remoteSequence == remoteSequence {
                return nil
            }
            let bounded = bound(data)
            payload = bounded.data
            payloadTruncated = truncated || bounded.truncated
            oversizedSource = source
        }
        // A frame-limit checkpoint reuses the incremental state: `payload` is
        // `data` there, since only in-bound streams extend the log.
        // A suffix has no screen base, but bracketed paste is last-wins over
        // the whole stream: seed it from the previous state so a mode enabled
        // before the cut survives the next cursor-only restore. Suffix logs
        // never hydrate the screen trackers, so even a quit-time checkpoint
        // records this one cheap mode.
        var state = extendedState
        if state == nil, computesTrackerState {
            var base = TerminalSnapshotTrackerState.initial
            if payloadTruncated, let bracketedPasteSeed { base.bracketedPaste = bracketedPasteSeed }
            state = base.advanced(by: payload)
        } else if state == nil, payloadTruncated, let bracketedPasteSeed {
            let tracker = TerminalBracketedPasteStateTracker()
            tracker.restore(bracketedPasteSeed)
            tracker.observe(payload)
            var suffix = TerminalSnapshotTrackerState.initial
            suffix.bracketedPaste = tracker.persistentState
            state = suffix
        }
        var file = TerminalSnapshotLogCodec.header(viewport: viewport)
        file.append(TerminalSnapshotLogCodec.frame(
            kind: .checkpoint, truncated: payloadTruncated, remoteSequence: remoteSequence,
            trackerState: state, payload: payload
        ))
        lock.lock()
        tips[paneID] = LogTip(
            epoch: epoch,
            viewport: viewport,
            payloadCount: payload.count,
            fingerprint: Self.fingerprint(payload, count: payload.count),
            remoteSequence: remoteSequence,
            truncated: payloadTruncated,
            trackerState: state,
            fileLength: file.count,
            deltaFrames: 0,
            oversizedSource: oversizedSource
        )
        lock.unlock()
        return (.checkpoint(file), epoch)
    }

    private func perform(_ pending: PendingWrite, paneID: UUID, epoch: UInt64) {
        lock.lock()
        let current = (epochs[paneID] ?? 0) == epoch
        lock.unlock()
        guard current else { return }
        let url = snapshotURL(paneID)
        do {
            switch pending {
            case .checkpoint(let file):
                try file.write(to: url, options: .atomic)
                SecureFiles.restrictToOwner(url)
                try? FileManager.default.removeItem(at: legacySnapshotURL(paneID))
            case .append(let frame, let offset):
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                // Drops a torn frame left by a crash before appending.
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: frame)
            }
        } catch {
            // Later queued deltas assume this write landed. Invalidate them;
            // the next save starts a fresh checkpoint.
            lock.lock()
            if (epochs[paneID] ?? 0) == epoch {
                epochs[paneID] = epoch &+ 1
                tips.removeValue(forKey: paneID)
            }
            lock.unlock()
            RelayDiagnostics.shared.record(category: "snapshot", name: "write-failed", details: [
                "pane_id": paneID.uuidString.lowercased(),
                "reason": error.localizedDescription,
            ])
        }
    }

    static func bounded(_ data: Data, maximumBytes: Int = maximumBytes) -> Data {
        boundedReportingTruncation(data, maximumBytes: maximumBytes).data
    }

    /// `truncated` is true when even the compacted stream had to be cut to a
    /// suffix, which loses the screen base its cursor addressing relies on.
    static func boundedReportingTruncation(
        _ data: Data,
        maximumBytes: Int = maximumBytes
    ) -> (data: Data, truncated: Bool) {
        // Small snapshots are already bounded and replay quickly. Scanning the
        // same ANSI stream on every periodic save was pure background work.
        guard data.count > maximumBytes else { return (data, false) }
        let compacted = TerminalReplayCompactor.compact(data)
        guard compacted.count > maximumBytes else { return (compacted, false) }
        var result = Data("\u{001B}c".utf8)
        result.append(TerminalReplayCompactor.safeSuffix(
            compacted,
            maximumBytes: maximumBytes - result.count
        ))
        return (result, true)
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
