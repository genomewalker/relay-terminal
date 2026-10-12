import Foundation

enum RelayPromptEditorLeaseWaiter {
    private enum Wakeup: Sendable { case changed, timeout }

    @MainActor static func wait(for lease: RelayPromptEditorControlLease, events: AsyncStream<Void>,
        timeout: Duration = .seconds(3), identity: () -> RelayPromptEditorControlLease?,
        ready: () -> RelayPromptEditorControlLease?) async throws {
        let (wakeups, continuation) = AsyncStream<Wakeup>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let forward = Task {
            for await _ in events {
                guard !Task.isCancelled else { break }
                continuation.yield(.changed)
            }
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(.timeout)
        }
        defer { forward.cancel(); deadline.cancel(); continuation.finish() }
        continuation.yield(.changed)
        for await wakeup in wakeups {
            try Task.checkCancellation()
            guard identity() == lease else { throw RelayPromptEditorRPC.Failure.changedConnection }
            if ready() == lease { return }
            if case .timeout = wakeup { throw RelayPromptEditorRPC.Failure.changedConnection }
        }
        try Task.checkCancellation()
        throw RelayPromptEditorRPC.Failure.changedConnection
    }
}
