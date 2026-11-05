import Foundation

/// Search only public control names; never indexes account data or credentials.
enum RelaySettingsSearch {
    static let sections: [(id: String, title: String, icon: String)] = [
        ("general", "Appearance", "paintbrush"), ("keyboard", "Keyboard", "keyboard"),
        ("accounts", "Relay API keys", "key"), ("agent-accounts", "Agent Accounts", "person.2.badge.key"),
        ("intelligence", "Intelligence", "sparkles"), ("connections", "Connections", "server.rack"),
        ("clients", "Clients", "person.2"), ("plugins", "Plugins", "puzzlepiece.extension"),
        ("advanced", "Advanced", "gearshape.2")
    ]
    private static let aliases: [String: String] = [
            "general": "font family size padding cursor blink palette compact appearance fullscreen sidebar artifact preview presentation",
            "keyboard": "key bindings shortcuts hotkey keyboard",
            "accounts": "api keys credentials secrets vault",
            "agent-accounts": "claude codex account routing default mcp servers sync sign in login usage quota",
            "intelligence": "miko assistant model intelligence decision autonomy pause shepherd supervisors hotkey budget",
            "connections": "host ssh remote connection helper server",
            "clients": "client caller grant permission authorization access",
            "plugins": "plugin extension",
            "advanced": "terminal terminfo compatibility diagnostics"
        ]
    static func keywords(for section: String) -> String { aliases[section] ?? "" }

    static func matches(section: String, title: String, query: String) -> Bool {
        let terms = query.lowercased().replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        let text = (title + " " + (aliases[section] ?? "")).lowercased()
        return terms.allSatisfy { text.contains($0) }
    }
}
