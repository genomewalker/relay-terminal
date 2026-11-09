import Foundation

/// The pane name as shown in the pane header. Relay has no generator for the
/// trailing "<agent> <6-hex>" in names such as "Sapropel - annotation jobs -
/// claude 767dc7": agents and users add it when naming a pane. Only that exact
/// shape is hidden; the stored name, tooltip, search and copying keep the id.
enum PaneHeaderName {
    static func visible(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3, let id = words.last, let agent = words.dropLast().last,
              id.count == 6, id.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              id.contains(where: \.isNumber),
              AgentKind.allCases.contains(where: { $0 != .shell && $0 != .other && $0.rawValue == agent.lowercased() })
        else { return name }
        var base = words.dropLast(2).map(String.init)
        if base.last == "-" || base.last == "·" || base.last == "–" { base.removeLast() }
        let shown = base.joined(separator: " ")
        return shown.isEmpty ? name : shown
    }
}
