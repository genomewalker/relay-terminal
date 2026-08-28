import Combine
import Foundation

/// A low-frequency invalidation boundary for sidebar aggregates. Pane views
/// observe their own models directly; terminal and agent updates must not make
/// the entire workspace canvas rebuild.
@MainActor
final class WorkspaceActivityIndex: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var refreshTask: Task<Void, Never>?

    func observe(_ pane: PaneModel) {
        subscriptions[pane.id] = pane.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    func remove(_ paneID: UUID) {
        subscriptions.removeValue(forKey: paneID)
        scheduleRefresh()
    }

    func removeAll() {
        subscriptions.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        revision &+= 1
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            // Sidebar summaries do not need terminal-frame cadence. Two
            // refreshes per second still feel live while avoiding a full
            // sidebar layout pass for every repainting TUI pane.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.revision &+= 1
        }
    }
}
