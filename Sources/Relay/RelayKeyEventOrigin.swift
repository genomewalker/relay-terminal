import AppKit
import Darwin

/// Whether a key event came from the hardware keyboard or was posted by a
/// process (computer use, AppleScript, accessibility automation, Relay itself).
///
/// macOS stamps a posted CGEvent with its poster's process ID
/// (eventSourceUnixProcessID); checked 2026-11-06 for every event source state.
/// The source state ID cannot tell them apart: a poster using the HID system
/// state gets state 1, like the keyboard. A hardware event is taken to carry
/// process ID 0 or WindowServer's, with no source user data. Everything else,
/// including an NSEvent without a CGEvent, counts as synthesized (fail safe:
/// a misread costs strong intent, never grants it).
enum RelayKeyEventOrigin: String, Equatable, Sendable {
    case hardware
    case synthesized

    static func classify(sourcePID: Int64, userData: Int64, windowServerPID: pid_t?) -> Self {
        guard userData == 0 else { return .synthesized }
        if sourcePID == 0 { return .hardware }
        if let windowServerPID, windowServerPID > 0, sourcePID == Int64(windowServerPID) { return .hardware }
        return .synthesized
    }

    static func of(_ event: NSEvent?) -> Self {
        guard let event = event?.cgEvent else { return .synthesized }
        return classify(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                        userData: event.getIntegerValueField(.eventSourceUserData),
                        windowServerPID: windowServerPID)
    }

    /// The key press that an insertText belongs to, or nil when it belongs to
    /// none. Text counts as the keyboard's only while AppKit is still
    /// dispatching that key press: an accessibility or programmatic insert can
    /// arrive while an older key press is still NSApp.currentEvent. A replayed
    /// deferred key press is judged by its own stored event.
    static func keyPress(forInsertedText handling: NSEvent?, current: NSEvent?, replaying: Bool) -> NSEvent? {
        guard let handling, handling.type == .keyDown else { return nil }
        if replaying { return handling }
        guard let current, current === handling else { return nil }
        return handling
    }

    /// Found once: WindowServer runs for the whole login session.
    static let windowServerPID: pid_t? = findProcess(named: "WindowServer")

    static func findProcess(named target: String) -> pid_t? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        // sysctl reads another user's process name; proc_name cannot.
        return pids.prefix(Int(filled)).first { $0 > 0 && command($0) == target }
    }

    private static func command(_ pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
