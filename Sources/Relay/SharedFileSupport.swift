import Foundation

/// POSIX single-quote escaping shared by every place Relay builds a remote
/// shell command line. One definition keeps escaping rules from drifting
/// between call sites, which would reopen shell-injection gaps.
enum ShellQuoting {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Owner-only permissions for Relay's on-disk state, applied identically
/// everywhere snapshots, diagnostics, and agent state are persisted.
enum SecureFiles {
    static func createPrivateDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
