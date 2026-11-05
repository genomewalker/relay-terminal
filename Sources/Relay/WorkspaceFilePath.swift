import Foundation

enum WorkspaceFilePath {
    static func relative(_ path: String, root: String) -> String? {
        guard root.hasPrefix("/"), path.hasPrefix("/"), !path.contains("\0"), !root.contains("\0") else { return nil }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return relative
    }
}
