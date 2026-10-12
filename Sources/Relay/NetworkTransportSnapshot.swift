import Foundation

/// GUI-side remote protocol observation. This is not a broker process inventory
/// and does not certify a retained worker's lifecycle or an agent's work state.
struct NetworkTransportSnapshot: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable { case inactive, connecting, ready, reconnecting }
    let id: String
    let host: String
    let account: String
    let port: Int
    let phase: Phase
    let generation: Int
    let attachedSubscriptions: Int
    let lastConfirmedUptime: UInt64?
    var usesPersistentBroker = false

    func isCurrent(at uptime: UInt64) -> Bool {
        guard phase == .ready, let confirmed = lastConfirmedUptime,
              uptime >= confirmed else { return false }
        return uptime - confirmed <= RelayHeartbeatPolicy.timeoutNanoseconds
    }

    func label(at uptime: UInt64) -> String {
        switch phase {
        case .inactive: return "Not attached"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .ready: return isCurrent(at: uptime) ? "Remote protocol ready" : "Status unconfirmed"
        }
    }
}
