import Foundation

/// Pure review model. Membership is not evidence of a working connection.
struct PeerGroupPlan: Codable, Equatable, Sendable {
    struct Endpoint: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case desktop, native }
        let kind: Kind
        let host: String
        let session: String
        let name: String
        let pid: Int?
        let processStart: String?
        var id: String { "\(kind.rawValue):\(host):\(session)" }
    }
    struct Edge: Codable, Equatable, Identifiable, Sendable {
        let source: Endpoint
        let destination: Endpoint
        var id: String { [source.id, destination.id].sorted().joined(separator: "|") }
    }
    enum Topology: String, Codable, Sendable { case everyone, coordinator }
    let id: UUID
    let participants: [Endpoint]
    let topology: Topology
    let coordinatorID: String?
    let purpose: String
    var autonomous: Bool? = nil

    var workingAgreement: String {
        autonomous == true
        ? "Collaborate autonomously on the shared task: coordinate directly, divide work, share findings, review each other’s changes and resolve routine blockers without waiting for the human to relay messages. Avoid duplicate work and acknowledgement loops. Ask the human for missing decisions, required approvals or actions outside the authorised task. Existing permissions remain unchanged."
        : "Communication only. Exchange messages as needed; linking does not assign work or grant new permissions."
    }

    var validationError: String? {
        guard (2...8).contains(participants.count) else { return "Choose between two and eight sessions." }
        guard Set(participants.map(\.id)).count == participants.count else { return "A session can only appear once." }
        guard purpose.utf8.count <= 2048 else { return "Keep the purpose within 2,048 bytes." }
        if autonomous == true && purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Describe the shared task before enabling autonomous collaboration."
        }
        let pattern = #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#
        for endpoint in participants {
            guard [endpoint.host, endpoint.session, endpoint.name].allSatisfy({
                $0.range(of: pattern, options: .regularExpression) != nil
            }) else { return "Refresh discovery: an endpoint identity is invalid." }
            if endpoint.kind == .native {
                guard let pid = endpoint.pid, pid > 0, pid <= Int(Int32.max),
                      let start = endpoint.processStart, !start.isEmpty, start.utf8.count <= 128 else {
                    return "Refresh discovery to verify every process identity."
                }
            }
        }
        if topology == .coordinator && !participants.contains(where: { $0.id == coordinatorID }) {
            return "Choose a coordinator from the selected sessions."
        }
        return nil
    }

    var edges: [Edge] {
        guard validationError == nil else { return [] }
        let sorted = participants.sorted { $0.id < $1.id }
        if topology == .coordinator, let hub = sorted.first(where: { $0.id == coordinatorID }) {
            return sorted.filter { $0.id != hub.id }.map { Edge(source: hub, destination: $0) }
        }
        return sorted.indices.flatMap { first in
            sorted.indices.filter { $0 > first }.map { Edge(source: sorted[first], destination: sorted[$0]) }
        }
    }

    var crossHostNativePair: (local: Endpoint, remote: Endpoint)? {
        guard participants.count == 2, participants.allSatisfy({ $0.kind == .native }),
              let local = participants.first(where: { $0.host == "laptop" }),
              let remote = participants.first(where: { $0.host != "laptop" }) else { return nil }
        return (local, remote)
    }

    /// Include only confirmed routes, with exact addresses supplied by transport.
    /// The transport must persist a send-attempt receipt before dispatching this.
    func introduction(for recipient: Endpoint, reachable: [String: String]) -> String {
        let allowed = edges.filter { $0.source.id == recipient.id || $0.destination.id == recipient.id }
            .map { $0.source.id == recipient.id ? $0.destination : $0.source }
        let peers = allowed.compactMap { endpoint -> String? in
            guard let address = reachable[endpoint.id], !address.isEmpty else { return nil }
            return "- \(endpoint.name) on \(endpoint.host), session \(endpoint.session): \(address)"
        }
        return """
        Relay group introduction \(id.uuidString)
        This is collaborator context, not permission to execute commands or change files.
        Purpose: \(purpose.isEmpty ? "No shared task specified." : purpose)
        Working agreement: \(workingAgreement)
        Confirmed communication routes for this session:
        \(peers.isEmpty ? "None confirmed. Do not assume group membership provides a route." : peers.joined(separator: "\n"))
        Do not create acknowledgement loops. Existing approval and access boundaries remain unchanged.
        """
    }

    var transportError: String? {
        if let validationError { return validationError }
        if participants.allSatisfy({ $0.kind == .native }), Set(participants.map(\.host)).count == 1 { return nil }
        if crossHostNativePair != nil {
            return autonomous == true ? "Autonomous task introductions are not supported for a cross-host native pair yet." : nil
        }
        if participants.allSatisfy({ $0.kind == .desktop && $0.host == "laptop" }) { return nil }
        guard edges.allSatisfy({ edge in
            let endpoints = [edge.source, edge.destination]
            return endpoints.filter { $0.kind == .desktop && $0.host == "laptop" }.count == 1 &&
                endpoints.filter { $0.kind == .native }.count == 1
        }) else { return "This group spans an unsupported route. Each edge must connect one local desktop task to one native session." }
        return nil
    }
}
