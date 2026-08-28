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

    private let now: @Sendable () -> Date
    private var modelInFlight = false
    private var lastStarted: [OnDeviceIntelligencePriority: Date] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func perform<T: Sendable>(
        priority: OnDeviceIntelligencePriority,
        minimumInterval: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        if priority == .background {
            let appIsActive = await MainActor.run {
                RelayApplicationActivityState.allowsContinuousUpdates
            }
            guard appIsActive else { return nil }
        }
        let startedAt = now()
        guard !modelInFlight else { return nil }
        let interval = priority == .background
            ? max(Self.backgroundIntervalFloor, minimumInterval)
            : max(0, minimumInterval)
        if let previous = lastStarted[priority],
           startedAt.timeIntervalSince(previous) < interval {
            return nil
        }

        modelInFlight = true
        lastStarted[priority] = startedAt
        defer { modelInFlight = false }
        return await operation()
    }
}
