import Foundation
import Combine

/// Owns the existing helper task independently of a presenter disappearing.
/// No new executor or authorization path; callers keep all existing checks.
@MainActor final class PluginPresentationOperation: ObservableObject {
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var retainedOnHide = false

    @discardableResult
    func start(retainOnHide: Bool, operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !running else { return false }
        running = true
        retainedOnHide = retainOnHide
        // Strong self retention ends on completion. Dismissing the presenter
        // cannot destroy bookkeeping for a dispatched mutation.
        task = Task { @MainActor [self] in
            await operation()
            running = false
            task = nil
        }
        return true
    }

    func presenterHidden() {
        if !retainedOnHide { cancel() }
    }

    /// Explicit cancellation retains the existing helper's uncertain-outcome
    /// semantics. It never calls pane stop/close or claims remote cancellation.
    func cancel() { task?.cancel() }
}
