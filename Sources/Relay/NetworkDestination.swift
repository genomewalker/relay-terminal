import Foundation

enum NetworkDestination: String, CaseIterable, Identifiable {
    case live = "Live network"
    case sessions = "Sessions & agents"
    case groups = "Link groups"
    case approvals = "Approvals"
    case history = "History"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: "network"
        case .sessions: "terminal"
        case .groups: "person.3.sequence"
        case .approvals: "checkmark.shield"
        case .history: "clock"
        }
    }
}
