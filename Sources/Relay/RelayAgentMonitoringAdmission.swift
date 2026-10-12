import Foundation

enum RelayAgentMonitoringAdmission {
    static func allows(profile: ConnectionProfile, contentKind: PaneContentKind) -> Bool {
        // Relay terminal streams exclude agent events on both local and remote
        // hosts. Their separate pooled observer must therefore cover both.
        contentKind == .terminal && profile.backend == .relay
    }
}
