import Foundation
import Darwin

/// Captures only one synchronous write from an owned native surface action.
/// Other clipboard writes retain their ordinary behavior.
final class TerminalCapturedClipboardWrite: @unchecked Sendable {
    private struct Capture {
        let id: UUID
        let thread: UInt64
        var value: String?
    }
    private let lock = NSLock()
    private var capture: Capture?

    func begin() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard capture == nil else { return nil }
        let id = UUID()
        capture = Capture(id: id, thread: UInt64(pthread_mach_thread_np(pthread_self())))
        return id
    }

    func consume(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var value = capture, value.thread == UInt64(pthread_mach_thread_np(pthread_self())) else { return false }
        if value.value == nil, text.utf8.count <= 4096 { value.value = text }
        capture = value
        return true
    }

    func finish(_ id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let value = capture, value.id == id else { return nil }
        capture = nil
        return value.value
    }
}
