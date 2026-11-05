import AppKit
import Darwin
import GhosttyTerminal
import Testing
@testable import Relay

/// libghostty's write_screen_file used to keep its temporary folder's two
/// directory descriptors open. Each pane screen read leaked both until the
/// process passed OPEN_MAX and could no longer spawn helpers (2026-10-18:
/// Relay held ~41,700 descriptors and desktop-task discovery returned 503).
/// The native library now closes them itself (relay-screen-file-descriptors.patch).
@Suite("Screen-file descriptors")
struct RelayScreenFileDescriptorTests {
    /// The process's open directory descriptors, with their paths.
    private func directoryDescriptors() -> [String] {
        var paths: [String] = []
        for fd in 0..<Int32(getdtablesize()) {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            paths.append(fcntl(fd, F_GETPATH, &buffer) == 0 ? String(cString: buffer) : "")
        }
        return paths
    }

    /// The directory libghostty creates its screen-file folder in: TMPDIR,
    /// then TMP, then /tmp (src/os/file.zig allocTmpDir), as F_GETPATH spells it.
    private func nativeTemporaryDirectory() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["TMPDIR"] ?? environment["TMP"] ?? "/tmp"
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @MainActor
    @Test("Repeated native screen reads do not leave directory descriptors open")
    func nativeScreenReadsDoNotLeak() async throws {
        _ = NSApplication.shared
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 440))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
        view.controller = controller
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.fitToSize()
        await Task.yield()
        session.receive("\u{1b}[2J\u{1b}[H❯ \r\n")
        await Task.detached { session.waitForPendingOutput() }.value
        let temporary = try #require(nativeTemporaryDirectory())
        func underTemporary(_ paths: [String]) -> Int {
            paths.filter { $0 == temporary || ($0 as NSString).deletingLastPathComponent == temporary }.count
        }
        let before = directoryDescriptors()
        for _ in 0..<30 {
            let screen = try #require(session.readActiveScreenVT())
            #expect(screen.contains("❯"))
        }
        let after = directoryDescriptors()
        // The 1630 library adds 60 of each (two per read), wherever its
        // temporary directory is. The total does not depend on paths; the
        // native one names the leak. Other tests running in parallel may hold
        // a few directories open briefly.
        #expect(after.count - before.count <= 10, "directory descriptors before \(before.count), after \(after.count)")
        #expect(underTemporary(after) - underTemporary(before) <= 10,
                "descriptors in \(temporary): before \(underTemporary(before)), after \(underTemporary(after))")
    }
}
