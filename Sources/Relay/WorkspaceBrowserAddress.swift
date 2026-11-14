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
}
