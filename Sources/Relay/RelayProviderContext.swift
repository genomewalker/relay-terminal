import Foundation

struct RelayProviderContext: Equatable, Sendable {
    let binding: RelayAgentConversationBinding
    let usedTokens: Int?
    let limitTokens: Int?

    private struct Response: Decodable {
        struct Binding: Decodable {
            let paneId: String
            let provider: String
            let processId: Int
            let processStart: String
            let sessionId: String
            let sourceIdentity: String
        }
        struct Usage: Decodable {
            let usedTokens: Int?
            let limitTokens: Int?
        }
        let version: Int
        let binding: Binding?
        let contextUsage: Usage?
    }

    static func decode(_ data: Data, hostID: String, paneID: UUID, provider: AgentKind) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        guard response.version == 1, let source = response.binding,
              source.paneId == paneID.uuidString.lowercased(), source.provider == provider.rawValue,
              !source.sourceIdentity.isEmpty, source.sourceIdentity.utf8.count <= 80 else { return nil }
        let binding = RelayAgentConversationBinding(hostID: hostID, paneID: paneID, provider: source.provider,
            processID: source.processId, processStart: source.processStart, sessionID: source.sessionId,
            sourceIdentity: source.sourceIdentity)
        guard binding.isValid else { return nil }
        return .init(binding: binding, usedTokens: count(response.contextUsage?.usedTokens, minimum: 0),
                     limitTokens: count(response.contextUsage?.limitTokens, minimum: 1))
    }

    private static func count(_ value: Int?, minimum: Int) -> Int? {
        guard let value, value >= minimum, value < 9_007_199_254_740_992 else { return nil }
        return value
    }

    func matches(_ other: RelayAgentConversationBinding) -> Bool {
        binding == other
    }

    var label: String {
        guard let usedTokens, let limitTokens else { return Self.unknown }
        let occupancy = (Double(usedTokens) / Double(limitTokens)).formatted(.percent.precision(.fractionLength(0...1)))
        return "Context \(usedTokens.formatted()) / \(limitTokens.formatted()) · \(occupancy)"
    }

    static let unknown = "Context unknown"
}
