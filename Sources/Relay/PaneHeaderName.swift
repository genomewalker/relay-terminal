import Foundation

/// The pane name as shown in the pane header. Relay has no generator for the
/// trailing "<agent> <6-hex>" in names such as "Sapropel - annotation jobs -
/// claude 767dc7": agents and users add it when naming a pane. Only that exact
/// shape is split: the agent word is hidden (the agent badge shows it) and the
/// id is shown apart; the stored name, tooltip, search and copying are unchanged.
enum PaneHeaderName {
    /// The name without the agent word, and the id when the name ends in one.
    static func parts(_ name: String) -> (name: String, id: String?) {
        let words = name.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3, let id = words.last, let agent = words.dropLast().last,
              id.count == 6, id.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              id.contains(where: \.isNumber),
              AgentKind.allCases.contains(where: { $0 != .shell && $0 != .other && $0.rawValue == agent.lowercased() })
        else { return (name, nil) }
        var base = words.dropLast(2).map(String.init)
        if base.last == "-" || base.last == "·" || base.last == "–" { base.removeLast() }
        let shown = base.joined(separator: " ")
        return shown.isEmpty ? (name, nil) : (shown, String(id))
    }
}

extension PaneModel {
    var connectionIsNormal: Bool { connectionState == .connected && connectionStatusLabel == "Connected" }

    /// The one status shown for the pane, with its role. A connection problem
    /// takes precedence; otherwise program-reported status (its own badge) or
    /// the agent's phase.
    var headerStatus: (text: String, role: RelayTheme.StatusRole)? {
        if !connectionIsNormal {
            let role: RelayTheme.StatusRole
            switch connectionState {
            case .reconnecting, .waitingForNetwork: role = .warning
            case .disconnected: role = .danger
            case .connecting: role = .info
            case .connected: role = phase == .exited ? .danger : .info
            }
            return (connectionStatusLabel, role)
        }
        guard contentKind == .terminal, kind != .shell, programStatus.records.isEmpty else { return nil }
        let role: RelayTheme.StatusRole
        switch phase {
        case .connecting, .active: role = .info
        case .quiet: role = .neutral
        case .needsInput: role = .warning
        case .exited: role = .danger
        }
        return (phase.label, role)
    }

    /// What a working agent is doing, e.g. "Using Bash"; nil when idle or unknown.
    var headerActivityDetail: String? {
        guard connectionIsNormal, contentKind == .terminal, kind != .shell, phase == .active else { return nil }
        let text = AgentLabelFormatter.activity(activitySummary)
        return text == PaneDisplayState.working.label || text == phase.label ? nil : text
    }

    /// Tooltip for a compact reference to this pane, such as a stack tab.
    var statusTooltip: String {
        let name = customName ?? title
        guard let status = headerStatus else { return name }
        return name + " · " + status.text + (headerActivityDetail.map { " · " + $0 } ?? "")
    }
}
