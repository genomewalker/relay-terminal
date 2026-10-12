import Foundation
import Darwin

/// A captured paste is available only during its synchronous native binding.
/// Other threads/requests cannot consume it or accidentally receive it as an
/// OSC clipboard query. No system pasteboard mutation is required.
final class TerminalCapturedClipboardRead: @unchecked Sendable {
    enum Read { case absent, captured(String), blocked }
    private struct Capture {
        let id: UUID
        let thread: UInt64
        let text: String
        var consumed = false
    }
    private let lock = NSLock()
    private var capture: Capture?

    func begin(_ text: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard capture == nil else { return nil }
        let id = UUID()
        capture = Capture(id: id, thread: UInt64(pthread_mach_thread_np(pthread_self())), text: text)
        return id
    }

    func read() -> Read {
        lock.lock(); defer { lock.unlock() }
        guard var current = capture else { return .absent }
        guard current.thread == UInt64(pthread_mach_thread_np(pthread_self())), !current.consumed else { return .blocked }
        current.consumed = true
        capture = current
        return .captured(current.text)
    }

    func finish(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = capture, current.id == id else { return false }
        capture = nil
        return current.consumed
    }
}
