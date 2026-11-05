import Foundation

/// Shared by the address bar and navigation policy. Browsing never opens native URLs.
enum WorkspaceBrowserAddress {
    static func parse(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let input = value.contains("://") ? value : "https://" + value
        guard let parts = URLComponents(string: input),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    static func origin(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else { return "No page loaded" }
        return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    static func allows(_ url: URL, remotePort: Int?) -> Bool {
        guard parse(url.absoluteString) != nil else { return false }
        guard let remotePort else { return true }
        // A remote session is confined to the explicitly forwarded origin.
        // Absolute redirects to another loopback port must never hit a Mac service.
        return url.host?.lowercased() == "127.0.0.1" &&
            (url.port ?? (url.scheme == "https" ? 443 : 80)) == remotePort && url.scheme == "http"
    }

    static func remoteRules(port: Int) -> String {
        // Remote browsing has no network access except its exact loopback origin.
        // Apply to every resource type, including script-initiated requests.
        let origin = "^http://127\\.0\\.0\\.1:\(port)/"
        let socketOrigin = "^ws://127\\.0\\.0\\.1:\(port)/"
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": origin], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": socketOrigin], "action": ["type": "ignore-previous-rules"]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
    }
}
