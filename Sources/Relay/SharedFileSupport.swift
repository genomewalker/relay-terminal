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

/// Byte-budgeted suffix of a string, aligned to a character boundary so the
/// retained tail never starts mid-scalar and decodes as U+FFFD garbage.
enum UTF8TailTruncation {
    static func tail(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var cut = text.utf8.index(text.utf8.endIndex, offsetBy: -maximumUTF8Bytes)
        while cut != text.utf8.endIndex, String.Index(cut, within: text) == nil {
            cut = text.utf8.index(after: cut)
        }
        guard let aligned = String.Index(cut, within: text) else { return "" }
        return String(text[aligned...])
    }
}
