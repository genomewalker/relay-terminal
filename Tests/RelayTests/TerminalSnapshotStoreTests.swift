import CryptoKit
import Foundation
import Testing
@testable import Relay

private final class BoundCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bound(_ data: Data) -> (data: Data, truncated: Bool) {
        lock.lock()
        value += 1
        lock.unlock()
        return TerminalSnapshotStore.boundedReportingTruncation(data)
    }
}

private func temporarySnapshotDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-snapshot-test-\(UUID().uuidString)", isDirectory: true)
}

private func logFile(_ directory: URL, _ paneID: UUID) -> URL {
    directory.appendingPathComponent(paneID.uuidString.lowercased() + ".snap")
}

private func decodedLog(_ directory: URL, _ paneID: UUID) throws -> TerminalSnapshotLogCodec.Log? {
    TerminalSnapshotLogCodec.decode(try Data(contentsOf: logFile(directory, paneID)))
}

/// Exercises every tracker: alternate screen, bracketed paste, OSC 133
/// semantic prompts, a shell input prelude and an oversized ignored OSC.
private let trackerStream = Data((
    "user@host$ \u{1B}]133;A\u{07}prompt\u{1B}]133;B\u{07}ls\r\n" +
    "\u{1B}]133;C\u{07}file\r\n\u{1B}]133;D;0\u{07}" +
    "\u{1B}[?2004h\u{1B}[?1049h\u{1B}[2J\u{1B}[Htui\u{1B}[?1000h" +
    "\u{1B}]0;" + String(repeating: "t", count: 300) + "\u{07}" +
    "\u{1B}[?1049l\u{1B}[?2004l\u{1B}[<65535u\u{1B}[?2004h" +
    "\u{1B}]133;A\u{07}$ \u{1B}]133;A\u{07}"
).utf8)

@Test("Unchanged oversized terminal snapshots skip replay compaction")
func terminalSnapshotUnchangedRawSkipsCompaction() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = BoundCallCounter()
    let store = TerminalSnapshotStore(directory: directory, bound: counter.bound)
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    let oversized = Data("\u{001B}c".utf8)
        + Data(repeating: 0x78, count: TerminalSnapshotStore.maximumBytes + 1_024)

    store.saveSynchronously(oversized, paneID: paneID, viewport: viewport, remoteSequence: 7)
    #expect(counter.count == 1)
    // A cut without a screen base keeps its resume cursor but is never replayed.
    #expect(store.load(paneID: paneID, viewport: viewport) == nil)
    #expect(store.loadResumeCursor(paneID: paneID) == 7)

    // A spinner repaint that leaves the stream byte-identical must not rescan it.
    store.saveSynchronously(oversized, paneID: paneID, viewport: viewport, remoteSequence: 7)
    store.save(oversized, paneID: paneID, viewport: viewport, remoteSequence: 7)
    #expect(counter.count == 1)

    // Same length, different bytes: the hash, not the length, decides.
    var edited = oversized
    edited[edited.count - 1] = 0x79
    store.saveSynchronously(edited, paneID: paneID, viewport: viewport, remoteSequence: 7)
    #expect(counter.count == 2)

    // The record also encodes the resume cursor and viewport.
    store.saveSynchronously(edited, paneID: paneID, viewport: viewport, remoteSequence: 8)
    #expect(counter.count == 3)
    #expect(store.loadResumeCursor(paneID: paneID) == 8)
    let resized = RelayViewport(columns: 100, rows: 30)
    store.saveSynchronously(edited, paneID: paneID, viewport: resized, remoteSequence: 8)
    #expect(counter.count == 4)

    // Removing a pane forgets its identity so a recreated pane persists.
    store.remove(paneID: paneID)
    store.saveSynchronously(edited, paneID: paneID, viewport: resized, remoteSequence: 8)
    #expect(counter.count == 5)
    #expect(store.loadResumeCursor(paneID: paneID) == 8)
}

@Test("Live snapshot buffers are trimmed below the bound once past 16 MiB")
func liveSnapshotBufferTrimsPastBound() {
    #expect(TerminalSnapshotCompactionPolicy.highWaterBytes == 16 << 20)
    #expect(!TerminalSnapshotCompactionPolicy.shouldCompact(byteCount: 16 << 20))
    #expect(TerminalSnapshotCompactionPolicy.shouldCompact(byteCount: (16 << 20) + 1))

    let oversized = Data("\u{001B}c".utf8) + Data(repeating: 0x78, count: 16 << 20)
    let trimmed = TerminalSnapshotCompactionPolicy.trim(oversized)
    #expect(trimmed.truncated)
    #expect(trimmed.data.count <= TerminalSnapshotCompactionPolicy.trimTargetBytes)
    #expect(trimmed.data.starts(with: Data("\u{001B}c".utf8)))
    // Headroom: appending another packet must not immediately re-trigger a scan.
    #expect(!TerminalSnapshotCompactionPolicy.shouldCompact(byteCount: trimmed.data.count + 65_536))
    // Already-bounded saves pass through the store without compaction.
    #expect(TerminalSnapshotStore.bounded(trimmed.data) == trimmed.data)

    // A full clear lets compaction rebuild a complete screen: no cut.
    let cleared = Data(repeating: 0x78, count: 16 << 20) + Data("\u{001B}[H\u{001B}[2Jfresh".utf8)
    let rebuilt = TerminalSnapshotCompactionPolicy.trim(cleared)
    #expect(!rebuilt.truncated)
    #expect(rebuilt.data.count < TerminalSnapshotCompactionPolicy.trimTargetBytes)
}

@Test("Restore tracker state is independent of how the stream was split")
func terminalSnapshotTrackerStateIsSplitInvariant() {
    let whole = TerminalSnapshotTrackerState.initial.advanced(by: trackerStream)
    #expect(whole != nil)
    #expect(whole != TerminalSnapshotTrackerState.initial)
    #expect(whole?.semanticChange != nil)
    for split in 1..<trackerStream.count {
        let first = TerminalSnapshotTrackerState.initial.advanced(by: trackerStream.prefix(split))
        let rest = Data(trackerStream.dropFirst(split))
        #expect(first?.advanced(by: rest) == whole, "split at \(split)")
    }
}

@Test("Snapshot saves append deltas and restore the trackers' end state")
func terminalSnapshotAppendsDeltas() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TerminalSnapshotStore(directory: directory)
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    let thirds = [0, trackerStream.count / 3, 2 * trackerStream.count / 3, trackerStream.count]

    for (index, end) in thirds.dropFirst().enumerated() {
        store.saveSynchronously(
            trackerStream.prefix(end), paneID: paneID, viewport: viewport,
            remoteSequence: UInt64(10 + index)
        )
    }
    let checkpointOnly = TerminalSnapshotLogCodec.header(viewport: viewport).count
        + TerminalSnapshotLogCodec.frameHeaderBytes + TerminalSnapshotLogCodec.checksumBytes
        + thirds[1]
    let log = try #require(try decodedLog(directory, paneID))
    #expect(log.deltaFrames == 2)
    #expect(log.payload == trackerStream)
    #expect(log.remoteSequence == 12)
    // Appends carry only the new bytes: the file is far smaller than three
    // full rewrites would be.
    #expect(log.validLength < checkpointOnly + 2 * trackerStream.count)

    // Quit-time checkpoints skip the tracker scan; restore falls back to it.
    #expect(log.trackerState == nil)

    // The next background save heals the stateless log with one checkpoint.
    let healed = trackerStream + Data("!".utf8)
    store.save(healed, paneID: paneID, viewport: viewport, remoteSequence: 13)
    store.saveSynchronously(healed, paneID: paneID, viewport: viewport, remoteSequence: 13)
    let healedLog = try #require(try decodedLog(directory, paneID))
    #expect(healedLog.deltaFrames == 0)
    #expect(healedLog.trackerState == TerminalSnapshotTrackerState.initial.advanced(by: healed))

    // A background save writes a scanned checkpoint once the buffer is replaced.
    let replaced = Data("\u{1B}[2J".utf8) + trackerStream
    store.save(replaced, paneID: paneID, viewport: viewport, remoteSequence: 20)
    store.saveSynchronously(replaced, paneID: paneID, viewport: viewport, remoteSequence: 20)
    store.saveSynchronously(
        replaced + Data("more".utf8), paneID: paneID, viewport: viewport, remoteSequence: 21
    )
    let reopened = TerminalSnapshotStore(directory: directory)
    let snapshot = try #require(reopened.loadSnapshot(paneID: paneID, viewport: viewport))
    #expect(snapshot.payload == replaced + Data("more".utf8))
    #expect(snapshot.remoteSequence == 21)
    #expect(snapshot.trackerState == TerminalSnapshotTrackerState.initial
        .advanced(by: replaced + Data("more".utf8)))
    #expect(try decodedLog(directory, paneID)?.deltaFrames == 1)
}

@Test("Snapshot logs drop a torn or corrupt tail and keep appending")
func terminalSnapshotTornTail() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    let first = Data("base screen\r\n".utf8)
    let second = first + Data("second line\r\n".utf8)
    let store = TerminalSnapshotStore(directory: directory)
    store.save(first, paneID: paneID, viewport: viewport, remoteSequence: 1)
    store.save(second, paneID: paneID, viewport: viewport, remoteSequence: 2)
    store.saveSynchronously(second, paneID: paneID, viewport: viewport, remoteSequence: 2)
    let url = logFile(directory, paneID)
    let intact = try Data(contentsOf: url)

    // A crash mid-append leaves a partial frame: everything before it survives.
    try (intact + intact.suffix(9)).write(to: url)
    #expect(try decodedLog(directory, paneID)?.payload == second)
    try intact.dropLast(3).write(to: url)
    #expect(try decodedLog(directory, paneID)?.payload == first)

    // A flipped payload byte fails the frame checksum.
    var corrupt = intact
    corrupt[corrupt.count - TerminalSnapshotLogCodec.checksumBytes - 1] ^= 0xFF
    try corrupt.write(to: url)
    #expect(try decodedLog(directory, paneID)?.payload == first)

    // A new process adopts the valid prefix and truncates the torn tail on append.
    try (intact + Data(repeating: 0xAB, count: 40)).write(to: url)
    let reopened = TerminalSnapshotStore(directory: directory)
    #expect(reopened.load(paneID: paneID, viewport: viewport) == second)
    let third = second + Data("third\r\n".utf8)
    reopened.saveSynchronously(third, paneID: paneID, viewport: viewport, remoteSequence: 3)
    let log = try #require(try decodedLog(directory, paneID))
    #expect(log.payload == third)
    #expect(log.validLength == (try Data(contentsOf: url)).count)
}

@Test("Snapshot checkpoints follow viewport changes, cuts and frame limits")
func terminalSnapshotCheckpointTriggers() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TerminalSnapshotStore(directory: directory)
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    var stream = Data("start\r\n".utf8)
    store.saveSynchronously(stream, paneID: paneID, viewport: viewport, remoteSequence: 1)
    for sequence in 2...(TerminalSnapshotStore.maximumDeltaFrames + 2) {
        stream.append(Data("line \(sequence)\r\n".utf8))
        store.saveSynchronously(
            stream, paneID: paneID, viewport: viewport, remoteSequence: UInt64(sequence)
        )
    }
    // The frame limit forces a fresh checkpoint instead of an endless log.
    var log = try #require(try decodedLog(directory, paneID))
    #expect(log.payload == stream)
    #expect(log.deltaFrames < TerminalSnapshotStore.maximumDeltaFrames)
    // Its state carries over from the deltas instead of being dropped.
    #expect(log.trackerState == nil)
    stream.append(Data("async\r\n".utf8))
    store.save(stream, paneID: paneID, viewport: viewport, remoteSequence: 800)
    for sequence in 801...(800 + TerminalSnapshotStore.maximumDeltaFrames + 1) {
        stream.append(Data("bg \(sequence)\r\n".utf8))
        store.save(stream, paneID: paneID, viewport: viewport, remoteSequence: UInt64(sequence))
    }
    store.saveSynchronously(stream, paneID: paneID, viewport: viewport, remoteSequence: 9_999)
    log = try #require(try decodedLog(directory, paneID))
    #expect(log.payload == stream)
    #expect(log.trackerState == TerminalSnapshotTrackerState.initial.advanced(by: stream))

    // A new viewport makes the old cursor addressing invalid: checkpoint.
    let resized = RelayViewport(columns: 120, rows: 40)
    store.saveSynchronously(stream, paneID: paneID, viewport: resized, remoteSequence: 9_000)
    log = try #require(try decodedLog(directory, paneID))
    #expect(log.viewport == resized && log.deltaFrames == 0)
    #expect(store.load(paneID: paneID, viewport: viewport) == nil)
    #expect(store.loadResumeCursor(paneID: paneID) == 9_000)

    // A buffer the bridge cut to a suffix is persisted only for its cursor.
    store.saveSynchronously(
        stream, paneID: paneID, viewport: resized, remoteSequence: 9_001, truncated: true
    )
    log = try #require(try decodedLog(directory, paneID))
    #expect(log.truncated && log.deltaFrames == 0)
    #expect(store.load(paneID: paneID, viewport: resized) == nil)
    #expect(store.loadResumeCursor(paneID: paneID) == 9_001)
}

@Test("Legacy snapshot records still restore and migrate on the next save")
func terminalSnapshotLegacyMigration() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let paneID = UUID()
    let viewport = RelayViewport(columns: 80, rows: 24)
    let legacyURL = directory.appendingPathComponent(paneID.uuidString.lowercased() + ".ansi")
    let payload = Data("legacy screen\r\n".utf8)
    try TerminalSnapshotRecordCodec.encode(payload, viewport: viewport, remoteSequence: 55)
        .write(to: legacyURL)

    let store = TerminalSnapshotStore(directory: directory)
    let snapshot = try #require(store.loadSnapshot(paneID: paneID, viewport: viewport))
    #expect(snapshot.payload == payload && snapshot.remoteSequence == 55)
    #expect(snapshot.trackerState == nil)
    #expect(store.loadResumeCursor(paneID: paneID) == 55)

    store.save(payload + Data("next\r\n".utf8), paneID: paneID, viewport: viewport, remoteSequence: 56)
    store.saveSynchronously(
        payload + Data("next\r\n".utf8), paneID: paneID, viewport: viewport, remoteSequence: 56
    )
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    let migrated = try #require(store.loadSnapshot(paneID: paneID, viewport: viewport))
    #expect(migrated.payload == payload + Data("next\r\n".utf8))
    #expect(migrated.trackerState != nil)

    store.remove(paneID: paneID)
    store.saveSynchronously(Data(), paneID: paneID, viewport: viewport)
    #expect(!FileManager.default.fileExists(atPath: logFile(directory, paneID).path))
}

@Test("Cursor-only resumes persist their delta-only buffer as truncated")
func terminalSnapshotCursorOnlyResumeStaysTruncated() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewport = RelayViewport(columns: 80, rows: 24)
    let resized = RelayViewport(columns: 120, rows: 40)
    let truncatedPane = UUID()
    let resizedPane = UUID()
    let store = TerminalSnapshotStore(directory: directory)
    // Neither log can render at the relaunch viewport: one lost its screen
    // base to a suffix cut, the other was drawn for another viewport.
    store.saveSynchronously(
        Data("\u{001B}csuffix\r\n".utf8), paneID: truncatedPane, viewport: viewport,
        remoteSequence: 40, truncated: true
    )
    store.saveSynchronously(
        Data("\u{001B}[H\u{001B}[2Jfull screen\r\n".utf8), paneID: resizedPane,
        viewport: viewport, remoteSequence: 70
    )

    let relaunched = TerminalSnapshotStore(directory: directory)
    for (paneID, cursor, at) in [
        (truncatedPane, UInt64(40), viewport), (resizedPane, UInt64(70), resized),
    ] {
        #expect(relaunched.loadSnapshot(paneID: paneID, viewport: at) == nil)
        #expect(relaunched.loadResumeCursor(paneID: paneID) == cursor)
        // relayd resumes a valid cursor with only the bytes after it; the
        // bridge marks that buffer truncated, so it must never replay.
        relaunched.saveSynchronously(
            Data("delta\r\n".utf8), paneID: paneID, viewport: at,
            remoteSequence: cursor + 1, truncated: true
        )
        let after = TerminalSnapshotStore(directory: directory)
        #expect(after.loadSnapshot(paneID: paneID, viewport: at) == nil)
        #expect(after.loadResumeCursor(paneID: paneID) == cursor + 1)
        let log = try #require(try decodedLog(directory, paneID))
        #expect(log.truncated && log.viewport == at)
    }

    // A mode-only snapshot loads but draws nothing, so the bridge also resumes
    // from its cursor alone and persists the delta the same way.
    let modeOnlyPane = UUID()
    let modes = Data("\u{001B}[?1049h\u{001B}[?2004h".utf8)
    store.saveSynchronously(modes, paneID: modeOnlyPane, viewport: viewport, remoteSequence: 90)
    let cached = try #require(relaunched.loadSnapshot(paneID: modeOnlyPane, viewport: viewport))
    #expect(!TerminalSnapshotDisplayPolicy.hasVisibleContent(cached.payload))
    relaunched.saveSynchronously(
        Data("delta\r\n".utf8), paneID: modeOnlyPane, viewport: viewport,
        remoteSequence: 91, truncated: true
    )
    let after = TerminalSnapshotStore(directory: directory)
    #expect(after.loadSnapshot(paneID: modeOnlyPane, viewport: viewport) == nil)
    #expect(after.loadResumeCursor(paneID: modeOnlyPane) == 91)
}

// A relaunch whose viewport differs (or whose log is a cursor-only suffix)
// cannot render the cache, yet the worker resumes after its cursor. The
// bytes that enabled bracketed paste are never replayed, so the input mode
// must survive both that restore and the suffix checkpoint it then writes.
@Test("Cursor-only restores keep bracketed paste across viewport changes and suffix checkpoints")
func terminalSnapshotCursorOnlyRestoreKeepsBracketedPaste() throws {
    let directory = temporarySnapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paneID = UUID()
    let saved = RelayViewport(columns: 157, rows: 47)
    let relaunched = RelayViewport(columns: 80, rows: 24)
    let store = TerminalSnapshotStore(directory: directory)
    store.saveSynchronously(
        Data("\u{1B}[?2004h\u{1B}[2J\u{1B}[H❯ ".utf8),
        paneID: paneID, viewport: saved, remoteSequence: 40
    )

    let first = TerminalSnapshotStore(directory: directory)
    #expect(first.loadSnapshot(paneID: paneID, viewport: relaunched) == nil)
    #expect(first.loadResumeCursor(paneID: paneID) == 40)
    #expect(first.loadBracketedPasteState(paneID: paneID)?.active == true)
    // The bridge then persists only the delta after the cursor.
    first.saveSynchronously(
        Data("spinner\r\n".utf8), paneID: paneID, viewport: relaunched,
        remoteSequence: 41, truncated: true
    )

    let second = TerminalSnapshotStore(directory: directory)
    #expect(second.loadSnapshot(paneID: paneID, viewport: relaunched) == nil)
    #expect(second.loadResumeCursor(paneID: paneID) == 41)
    #expect(second.loadBracketedPasteState(paneID: paneID)?.active == true)

    // A later explicit disable in the suffix still wins.
    second.saveSynchronously(
        Data("\u{1B}[?2004l$ ".utf8), paneID: paneID, viewport: relaunched,
        remoteSequence: 42, truncated: true
    )
    let third = TerminalSnapshotStore(directory: directory)
    #expect(third.loadBracketedPasteState(paneID: paneID)?.active == false)
}
