import Foundation

/// Shares short-lived reads only for an identical host and pane context.
/// Consumer cancellation does not cancel a read another window may be using.
actor RelaySubscriptionQuotaReader {
    struct Snapshot: Sendable {
        let data: Data
        let observedAt: Date
    }
    private struct Pending {
        let id: UUID
        let task: Task<Snapshot, Error>
    }

    static let shared = RelaySubscriptionQuotaReader()
    private let maximumAge: TimeInterval
    private let maximumConcurrentReads: Int
    private let maximumCachedReads: Int
    private var pending: [String: Pending] = [:]
    private var cache: [String: Snapshot] = [:]

    init(maximumAge: TimeInterval = 15, maximumConcurrentReads: Int = 2,
         maximumCachedReads: Int = 32) {
        self.maximumAge = max(0, maximumAge)
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.maximumCachedReads = max(1, maximumCachedReads)
    }

    func read(key: String, force: Bool = false,
              operation: @escaping @Sendable () async throws -> Data) async throws -> Snapshot {
        while true {
            try Task.checkCancellation()
            let now = Date()
            cache = cache.filter {
                let age = now.timeIntervalSince($0.value.observedAt)
                return age >= 0 && age < maximumAge
            }
            if let existing = pending[key] { return try await resolve(key: key, read: existing) }
            if !force, let recent = cache[key] { return recent }
            if pending.count >= maximumConcurrentReads, let next = pending.first {
                // Finish an existing bounded read before starting another process.
                _ = try? await resolve(key: next.key, read: next.value)
                continue
            }
            let task = Task.detached(priority: .utility) {
                let data = try await operation()
                return Snapshot(data: data, observedAt: Date())
            }
            let read = Pending(id: UUID(), task: task)
            pending[key] = read
            return try await resolve(key: key, read: read)
        }
    }

    private func resolve(key: String, read: Pending) async throws -> Snapshot {
        let result = await read.task.result
        if pending[key]?.id == read.id {
            pending.removeValue(forKey: key)
            if case .success(let snapshot) = result {
                cache[key] = snapshot
                if cache.count > maximumCachedReads,
                   let oldest = cache.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
                    cache.removeValue(forKey: oldest)
                }
            }
        }
        try Task.checkCancellation()
        return try result.get()
    }
}
