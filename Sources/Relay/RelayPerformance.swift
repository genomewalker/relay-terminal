import Foundation
import os

struct RelayPerformanceCounterSnapshot: Sendable {
    let capturedAtNanoseconds: UInt64
    let terminalBatches: UInt64
    let terminalOutputBytes: UInt64
    let terminalInputBytes: UInt64
    let maximumPendingBytes: Int
    let overloadedSamples: UInt64
    let mainThreadStalls: UInt64
    let maximumMainThreadStallMilliseconds: Double
    let delayedKeyEvents: UInt64
    let maximumKeyDispatchMilliseconds: Double
}

/// Low-overhead counters for the hot terminal path. Signposts remain available
/// in Instruments, while diagnostics receive one aggregate record per window
/// instead of one event per network packet.
final class RelayPerformance: @unchecked Sendable {
    static let shared = RelayPerformance()

    private let lock = NSLock()
    private let signposter = OSSignposter(subsystem: "com.relay.terminal", category: "performance")
    private var windowStarted = DispatchTime.now().uptimeNanoseconds
    private var batchCount = 0
    private var byteCount = 0
    private var maximumBatchBytes = 0
    private var maximumPendingBytes = 0
    private var overloadedSamples = 0
    private var totalBatchCount: UInt64 = 0
    private var totalOutputBytes: UInt64 = 0
    private var totalInputBytes: UInt64 = 0
    private var totalOverloadedSamples: UInt64 = 0
    private var lifetimeMaximumPendingBytes = 0
    private var totalMainThreadStalls: UInt64 = 0
    private var maximumMainThreadStallMilliseconds = 0.0
    private var totalDelayedKeyEvents: UInt64 = 0
    private var maximumKeyDispatchMilliseconds = 0.0
    private let reportingIntervalNanoseconds: UInt64 = 10_000_000_000

    private init() {}

    func recordTerminalBatch(bytes: Int, pendingBytes: Int) {
        if signposter.isEnabled {
            signposter.emitEvent(
                "TerminalBatch",
                "bytes=\(bytes) pending=\(pendingBytes)"
            )
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        batchCount += 1
        byteCount += bytes
        totalBatchCount &+= 1
        totalOutputBytes &+= UInt64(max(0, bytes))
        maximumBatchBytes = max(maximumBatchBytes, bytes)
        maximumPendingBytes = max(maximumPendingBytes, pendingBytes)
        lifetimeMaximumPendingBytes = max(lifetimeMaximumPendingBytes, pendingBytes)
        if pendingBytes >= 2 << 20 {
            overloadedSamples += 1
            totalOverloadedSamples &+= 1
        }
        guard now &- windowStarted >= reportingIntervalNanoseconds else {
            lock.unlock()
            return
        }
        let report = (
            batches: batchCount,
            bytes: byteCount,
            maxBatch: maximumBatchBytes,
            maxPending: maximumPendingBytes,
            overloads: overloadedSamples
        )
        windowStarted = now
        batchCount = 0
        byteCount = 0
        maximumBatchBytes = 0
        maximumPendingBytes = 0
        overloadedSamples = 0
        lock.unlock()

        RelayDiagnostics.shared.record(category: "performance", name: "terminal-window", details: [
            "batches": String(report.batches),
            "bytes": String(report.bytes),
            "maximum_batch_bytes": String(report.maxBatch),
            "maximum_pending_bytes": String(report.maxPending),
            "overloaded_samples": String(report.overloads),
        ])
    }

    func recordTerminalInput(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        totalInputBytes &+= UInt64(bytes)
        lock.unlock()
    }

    func recordMainThreadStall(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 200 else { return }
        lock.lock()
        totalMainThreadStalls &+= 1
        maximumMainThreadStallMilliseconds = max(maximumMainThreadStallMilliseconds, milliseconds)
        lock.unlock()
        RelayDiagnostics.shared.record(category: "performance", name: "main-thread-stall", details: [
            "milliseconds": String(format: "%.1f", milliseconds),
        ])
    }

    func recordKeyDispatchLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        maximumKeyDispatchMilliseconds = max(maximumKeyDispatchMilliseconds, milliseconds)
        if milliseconds >= 100 { totalDelayedKeyEvents &+= 1 }
        lock.unlock()
    }

    /// Read only while the Performance panel is visible. Keeping cumulative
    /// counters makes sampling a constant-time lock instead of walking pane or
    /// packet histories.
    func snapshot() -> RelayPerformanceCounterSnapshot {
        lock.lock()
        let snapshot = RelayPerformanceCounterSnapshot(
            capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            terminalBatches: totalBatchCount,
            terminalOutputBytes: totalOutputBytes,
            terminalInputBytes: totalInputBytes,
            maximumPendingBytes: lifetimeMaximumPendingBytes,
            overloadedSamples: totalOverloadedSamples,
            mainThreadStalls: totalMainThreadStalls,
            maximumMainThreadStallMilliseconds: maximumMainThreadStallMilliseconds,
            delayedKeyEvents: totalDelayedKeyEvents,
            maximumKeyDispatchMilliseconds: maximumKeyDispatchMilliseconds
        )
        lock.unlock()
        return snapshot
    }
}

/// One coalesced ping detects genuine AppKit stalls without sampling stacks,
/// polling terminals, or waking the renderer. Only one main-queue block can be
/// outstanding, so a long freeze cannot build an unbounded callback backlog.
final class RelayResponsivenessMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    private var pendingStartedAt: UInt64?
    private var running = false

    init() {
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    deinit { timer.cancel() }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        timer.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .milliseconds(500), leeway: .milliseconds(100)
        )
    }

    func stop() {
        lock.lock()
        running = false
        pendingStartedAt = nil
        lock.unlock()
        timer.schedule(deadline: .distantFuture)
    }

    private func ping() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard running, pendingStartedAt == nil else { lock.unlock(); return }
        pendingStartedAt = startedAt
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.mainQueueResponded(to: startedAt) }
    }

    private func mainQueueResponded(to startedAt: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        lock.lock()
        guard pendingStartedAt == startedAt else { lock.unlock(); return }
        pendingStartedAt = nil
        lock.unlock()
        RelayPerformance.shared.recordMainThreadStall(
            milliseconds: Double(elapsed) / 1_000_000
        )
    }
}
