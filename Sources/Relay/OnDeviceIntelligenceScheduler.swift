import Foundation

enum OnDeviceIntelligencePriority: Sendable {
    case background
    case interactive
}

/// Keeps Foundation Models work from competing with terminal rendering.
///
/// Automatic work is deliberately lossy: the exact structured event remains
/// available when a summary or ranking pass is skipped. Interactive requests
/// may run more frequently, but all model work is serialized process-wide.
actor OnDeviceIntelligenceScheduler {
    static let shared = OnDeviceIntelligenceScheduler()
    static let backgroundIntervalFloor: TimeInterval = 20
    static let interactiveIntervalFloor: TimeInterval = 0.75

    private let now: @Sendable () -> Date
    private var modelInFlight = false
    private var queued: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var lastStarted: [OnDeviceIntelligencePriority: Date] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func perform<T: Sendable>(
        priority: OnDeviceIntelligencePriority,
        minimumInterval: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let appIsActive = await MainActor.run {
            RelayApplicationActivityState.allowsContinuousUpdates
        }
        guard appIsActive else { return nil }
        let startedAt = now()
        guard !modelInFlight else { return nil }
        let interval = priority == .background
            ? max(Self.backgroundIntervalFloor, minimumInterval)
            : max(Self.interactiveIntervalFloor, minimumInterval)
        if let previous = lastStarted[priority],
           startedAt.timeIntervalSince(previous) < interval {
            return nil
        }

        modelInFlight = true
        lastStarted[priority] = startedAt
        defer { releaseModelSlot() }
        return await operation()
    }

    /// Accepted assistant requests wait for the current model call to finish;
    /// background ranking may still be skipped by perform above.
    func performQueued<T: Sendable>(priority: OnDeviceIntelligencePriority,
        minimumInterval: TimeInterval, operation: @escaping @Sendable () async -> T) async throws -> T {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await acquireModelSlot(id)
            defer { releaseModelSlot() }
            try Task.checkCancellation()
            let floor = priority == .interactive ? Self.interactiveIntervalFloor : Self.backgroundIntervalFloor
            let interval = max(floor, minimumInterval)
            if let previous = lastStarted[priority] {
                let remaining = interval - now().timeIntervalSince(previous)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
            try Task.checkCancellation()
            lastStarted[priority] = now()
            return await operation()
        } onCancel: {
            Task { await self.cancelQueued(id) }
        }
    }

    private func acquireModelSlot(_ id: UUID) async throws {
        if !modelInFlight { modelInFlight = true; return }
        guard queued.count < 16 else { throw CancellationError() }
        try await withCheckedThrowingContinuation { queued.append((id, $0)) }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.0 == id }) else { return }
        queued.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseModelSlot() {
        if queued.isEmpty { modelInFlight = false }
        else { queued.removeFirst().1.resume() }
    }
}
