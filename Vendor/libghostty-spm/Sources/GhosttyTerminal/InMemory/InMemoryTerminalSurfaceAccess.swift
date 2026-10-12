import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0
    private var hostOutputRevision: UInt64 = 0
    private var hostOutputObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    var parsedHostOutputRevision: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return hostOutputRevision
    }

    func parsedHostOutputEvents() -> AsyncStream<UInt64> {
        let id = UUID()
        let (events, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.hostOutputObservers.removeValue(forKey: id)
            self.condition.unlock()
        }
        condition.lock()
        hostOutputObservers[id] = continuation
        continuation.yield(hostOutputRevision)
        condition.unlock()
        return events
    }

    deinit {
        condition.lock()
        let observers = Array(hostOutputObservers.values)
        hostOutputObservers.removeAll()
        condition.unlock()
        for observer in observers { observer.finish() }
    }
    /// Bytes received while no surface is attached, replayed into the next
    /// one. The host's transport does not pause while a view (re)builds its
    /// surface — a reattach replay that lands in that gap used to be dropped
    /// wholesale, leaving the restored session showing only whatever the
    /// shell printed afterwards. Bounded: oldest bytes go first, matching
    /// what a terminal scrollback would have forgotten anyway.
    private var pendingWrites = Data()
    private static let pendingWriteByteLimit = 1 << 20

    /// Bytes waiting for the attached surface. A single queue job drains this
    /// buffer, so a burst produces bounded storage rather than one retained
    /// closure (and one retained `Data`) per host packet.
    private var leadingWrite: Data?
    private var queuedWrites = Data()
    private var postExitWrites = Data()
    private var queuedWriteGeneration: UInt64 = 0
    private var outputDrainScheduled = false
    private let queuedWriteByteLimit: Int

    /// Process exit is ordered after all bytes accepted before it.
    private var pendingProcessExit: (generation: UInt64, code: UInt32, runtime: UInt64)?

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit,
        queuedWriteByteLimit: Int = 8 << 20
    ) {
        self.write = write
        self.processExit = processExit
        self.queuedWriteByteLimit = max(1, queuedWriteByteLimit)
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        self.surface = nil
        waitForActiveOperations()
        self.surface = surface
        queuedWrites = Data()
        leadingWrite = nil
        postExitWrites = Data()
        queuedWriteGeneration = generation
        pendingProcessExit = nil
        // Flush bytes that arrived surfaceless, ahead of anything received
        // after this call: both ride the same serial queue, so enqueueing
        // here (before the lock drops for good) preserves stream order.
        var flush: Data?
        if surface != nil, !pendingWrites.isEmpty {
            flush = pendingWrites
            pendingWrites = Data()
        }
        if let flush {
            if outputDrainScheduled {
                queuedWrites.append(flush)
            } else {
                leadingWrite = flush
            }
        }
        let shouldSchedule = surface != nil && leadingWrite != nil && !outputDrainScheduled
        if shouldSchedule {
            outputDrainScheduled = true
        }
        condition.broadcast()
        condition.unlock()
        if shouldSchedule { scheduleOutputDrain() }
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations()
        queuedWrites = Data()
        leadingWrite = nil
        postExitWrites = Data()
        queuedWriteGeneration = generation
        pendingProcessExit = nil
        condition.broadcast()
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    var pendingOutputByteCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pendingWrites.count + (leadingWrite?.count ?? 0) + queuedWrites.count + postExitWrites.count
    }

    @discardableResult
    func enqueueWrite(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        condition.lock()
        guard surface != nil else {
            pendingWrites.append(data)
            let excess = pendingWrites.count - Self.pendingWriteByteLimit
            if excess > 0 {
                pendingWrites.removeFirst(excess)
            }
            condition.unlock()
            return true
        }
        let writeGeneration = generation
        while surface != nil,
              generation == writeGeneration,
              !((leadingWrite?.isEmpty ?? true) && queuedWrites.isEmpty && postExitWrites.isEmpty),
              (leadingWrite?.count ?? 0) + queuedWrites.count + postExitWrites.count + data.count > queuedWriteByteLimit
        {
            condition.wait()
        }
        guard surface != nil, generation == writeGeneration else {
            condition.unlock()
            return false
        }
        if queuedWriteGeneration != writeGeneration {
            leadingWrite = nil
            queuedWrites = Data()
            queuedWriteGeneration = writeGeneration
        }
        if pendingProcessExit != nil {
            postExitWrites.append(data)
        } else if !outputDrainScheduled {
            leadingWrite = data
        } else {
            queuedWrites.append(data)
        }
        let shouldSchedule = !outputDrainScheduled
        if shouldSchedule { outputDrainScheduled = true }
        condition.unlock()
        if shouldSchedule { scheduleOutputDrain() }
        return true
    }

    @discardableResult
    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) -> Bool {
        condition.lock()
        guard surface != nil else {
            condition.unlock()
            return false
        }
        pendingProcessExit = (generation, exitCode, runtimeMilliseconds)
        let shouldSchedule = !outputDrainScheduled
        if shouldSchedule { outputDrainScheduled = true }
        condition.unlock()
        if shouldSchedule { scheduleOutputDrain() }
        return true
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    func waitForPendingOutput() {
        outputQueue.sync {}
    }

    private func scheduleOutputDrain() {
        outputQueue.async { [self] in drainOutput() }
    }

    /// Runs as the only consumer on `outputQueue`. New writes are folded into
    /// the next batch while the current batch is parsed by Ghostty.
    private func drainOutput() {
        while true {
            condition.lock()
            let batch: Data
            if let leadingWrite {
                batch = leadingWrite
                self.leadingWrite = nil
            } else {
                batch = queuedWrites
                queuedWrites = Data()
            }
            let batchGeneration = queuedWriteGeneration
            let exit = batch.isEmpty ? pendingProcessExit : nil
            if exit != nil { pendingProcessExit = nil }
            if batch.isEmpty, exit == nil {
                outputDrainScheduled = false
                condition.broadcast()
                condition.unlock()
                return
            }
            condition.broadcast()
            condition.unlock()

            if !batch.isEmpty {
                withSurface(generation: batchGeneration) { surface in
                    write(surface, batch)
                    condition.lock()
                    hostOutputRevision &+= 1
                    for observer in hostOutputObservers.values { observer.yield(hostOutputRevision) }
                    condition.unlock()
                }
            } else if let exit {
                withSurface(generation: exit.generation) { surface in
                    processExit(surface, exit.code, exit.runtime)
                }
                condition.lock()
                if !postExitWrites.isEmpty {
                    queuedWrites.append(postExitWrites)
                    postExitWrites = Data()
                    queuedWriteGeneration = exit.generation
                }
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    private var currentGeneration: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return surface == nil ? nil : generation
    }

    private func withSurface(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Void
    ) {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        operation(surface)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func waitForActiveOperations() {
        while activeOperations > 0 {
            condition.wait()
        }
    }
}
