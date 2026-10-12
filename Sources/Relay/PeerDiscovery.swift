import Foundation

struct DiscoveredPeer: Codable, Identifiable, Sendable {
    let name: String
    let sessionId: String
    let pid: Int
    var procStart: String? = nil
    var paneID: String? = nil
    var parentSession: String? = nil
    var id: Int { pid }
}

struct PeerDiscovery: Codable, Sendable {
    static func failureSummary(_ error: Error) -> String {
        if let capture = error as? ProcessCaptureError {
            switch capture {
            case .timedOut: return "The discovery helper timed out."
            case .outputTooLarge: return "The discovery response exceeded its size limit."
            case .readFailed: return "The discovery response could not be read."
            }
        }
        if error is DecodingError { return "The discovery response has an unsupported format." }
        let value = error as NSError
        if value.domain == "PeerDiscovery", value.code == 1 { return "The discovery helper exited unsuccessfully." }
        return "The discovery response failed validation."
    }
    let peers: [DiscoveredPeer]
    let truncated: Bool
    var links: [ReportedPeerLink]? = nil
    var groups: [NativeGroupStatus]? = nil
    var teams: [ClaudeTeamMetadata]? = nil

    static func isFresh(_ observedAt: Date?, now: Date) -> Bool {
        guard let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 && age <= 30
    }

    static func remoteArguments(host: String, helper: String) throws -> [String] {
        guard host.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil,
              helper.count <= 512,
              helper.range(of: #"^[A-Za-z0-9_./][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "PeerDiscovery", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Enter a valid SSH alias and helper path without shell characters."])
        }
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=5", "--", host, "exec '\(helper)' --discover"]
    }

    static func remoteArgumentsIfValid(host: String) -> Bool {
        (try? remoteArguments(host: host, helper: ".local/share/relay/peer-network/relay-peer-link")) != nil
    }

    static func routeHostIsValid(_ host: String) -> Bool {
        host == "laptop" || remoteArgumentsIfValid(host: host)
    }

    static func validProcessStart(_ value: String, host: String) -> Bool {
        if host != "laptop" {
            return value.range(of: #"^[0-9]{1,24}$"#, options: .regularExpression) != nil
        }
        return !value.isEmpty && value.utf8.count <= 128 &&
            value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
    }

    static func routePeers(host: String, localExecutable: URL) throws -> Self {
        host == "laptop"
            ? try local(executable: localExecutable)
            : try remote(host: host, helper: ".local/share/relay/peer-network/relay-peer-link")
    }

    static func remote(host: String, helper: String) throws -> Self {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try remoteArguments(host: host, helper: helper)
        return try capture(process)
    }

    static func remotePanes(host: String) throws -> Self {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try remotePaneArguments(host: host)
        return try capture(process)
    }

    static func remotePaneArguments(host: String) throws -> [String] {
        var args = try remoteArguments(host: host, helper: ".local/bin/relayd")
        args[args.count - 1] = "exec '.local/bin/relayd' network"
        return args
    }

    static func localPanes(executable: URL) throws -> Self {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["network"]
        return try capture(process)
    }

    /// Merge raw local peer discovery with relayd's stronger pane ancestry
    /// evidence. Direct Ghostty panes remain discoverable without a worker.
    static func localCombined(peerExecutable: URL, relaydExecutable: URL) throws -> Self {
        let raw = try local(executable: peerExecutable)
        let bound = try localPanes(executable: relaydExecutable)
        return mergeLocal(raw: raw, paneBound: bound)
    }

    static func mergeLocal(raw: Self, paneBound: Self) -> Self {
        var byPID = Dictionary(uniqueKeysWithValues: raw.peers.map { ($0.pid, $0) })
        for peer in paneBound.peers {
            guard let existing = byPID[peer.pid], existing.sessionId == peer.sessionId,
                  existing.name == peer.name, existing.procStart == peer.procStart else { continue }
            var enriched = existing
            enriched.paneID = peer.paneID
            enriched.parentSession = peer.parentSession
            byPID[peer.pid] = enriched
        }
        return Self(peers: byPID.values.sorted { $0.pid < $1.pid },
            truncated: raw.truncated || paneBound.truncated,
            links: paneBound.links ?? raw.links, groups: paneBound.groups ?? raw.groups,
            teams: paneBound.teams ?? raw.teams)
    }

    static func local(executable: URL) throws -> Self {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--discover"]
        return try capture(process)
    }

    private static func capture(_ process: Process) throws -> Self {
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let result = try ProcessCapture.run(process, output: output, errors: errors,
            timeout: 10, maximumBytesPerStream: 262_144)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PeerDiscovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Session discovery failed. Check the installed peer helper."])
        }
        return try decodeValidated(result.standardOutput)
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw CocoaError(.coderReadCorrupt) }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        func validIdentity(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 110 && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
        guard decoded.peers.count <= 1024,
              (decoded.teams?.count ?? 0) <= 16,
              (decoded.teams ?? []).allSatisfy({ team in
                  validIdentity(team.leadSessionId) && team.name.utf8.count <= 128 &&
                  team.name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } &&
                  team.members.count <= 16 && team.members.allSatisfy { member in
                      [member.agentId, member.name, member.agentType, member.model ?? ""].allSatisfy {
                          $0.utf8.count <= 128 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                      }
                  }
              }),
              (decoded.links?.count ?? 0) <= 1024,
              (decoded.groups?.count ?? 0) <= 64,
              (decoded.groups ?? []).allSatisfy({ group in
                  UUID(uuidString: group.id) != nil &&
                  (group.topology == "everyone" || group.topology == "coordinator") &&
                  (2...8).contains(group.participants.count) &&
                  group.participants.allSatisfy { member in
                      validIdentity(member.host) && validIdentity(member.session) &&
                      validIdentity(member.name) && member.pid > 0 &&
                      member.processStart.utf8.count <= 128
                  }
              }),
              Set((decoded.links ?? []).map { "\($0.sourcePID):\($0.destinationPID)" }).count == (decoded.links?.count ?? 0),
              (decoded.links ?? []).allSatisfy({ $0.sourcePID > 0 && $0.destinationPID > 0 &&
                  $0.sourcePID <= Int(Int32.max) && $0.destinationPID <= Int(Int32.max) &&
                  validIdentity($0.sourceSession) && validIdentity($0.destinationSession) }),
              Set(decoded.peers.map(\.pid)).count == decoded.peers.count,
              decoded.peers.allSatisfy({ $0.pid > 0 && $0.pid <= Int(Int32.max) &&
                  validIdentity($0.name) && validIdentity($0.sessionId) }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return decoded
    }
}

struct NativeGroupStatus: Codable, Sendable {
    struct Member: Codable, Sendable {
        let host: String
        let session: String
        let name: String
        let pid: Int
        let processStart: String
    }
    let id: String
    let topology: String
    let coordinatorID: String?
    let participants: [Member]
    let current: Bool
}

struct HostedNativeGroupEdge: Identifiable {
    let groupID: String
    let source: NetworkParticipant.Identity
    let destination: NetworkParticipant.Identity
    var id: String { "\(groupID):\(source.host):\(source.session):\(destination.session)" }
}

struct ClaudeTeamMetadata: Codable, Sendable {
    let name: String
    let leadSessionId: String
    let members: [ClaudeMemberMetadata]
}

struct HostedClaudeTeam: Identifiable {
    let host: String
    let team: ClaudeTeamMetadata
    var id: String { "\(host):\(team.leadSessionId):\(team.name)" }
}

struct ClaudeMemberMetadata: Codable, Sendable {
    let agentId: String
    let name: String
    let agentType: String
    let model: String?
}

/// Provider-reported relationships, distinct from Relay's own transport status.
struct ReportedPeerLink: Codable, Sendable {
    let sourcePID: Int
    let sourceSession: String
    let destinationPID: Int
    let destinationSession: String
    let updatedMs: Int64

    func isCurrent(peers: [DiscoveredPeer], now: Date) -> Bool {
        guard sourcePID != destinationPID,
              PeerDiscovery.isFresh(Date(timeIntervalSince1970: Double(updatedMs) / 1000), now: now) else { return false }
        // Do not attach an edge to an ambiguous resumed-session node.
        return [(sourcePID, sourceSession), (destinationPID, destinationSession)].allSatisfy { pid, session in
            let matches = peers.filter { $0.sessionId == session }
            return matches.count == 1 && matches[0].pid == pid
        }
    }
}

struct HostedPeerLink: Identifiable {
    let host: String
    let report: ReportedPeerLink
    var id: String { "\(host):\(report.sourcePID):\(report.destinationPID)" }
    var source: NetworkParticipant.Identity { .init(host: host, session: report.sourceSession, local: false) }
    var destination: NetworkParticipant.Identity { .init(host: host, session: report.destinationSession, local: false) }
}
