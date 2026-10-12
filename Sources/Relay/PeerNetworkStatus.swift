import Foundation

struct PeerNetworkStatus: Codable, Identifiable, Sendable {
    enum Evidence: Int, Comparable {
        case connected, needsReview, earlier
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let schema: Int
    let pid: Int
    let host: String
    let localName: String
    let localSession: String
    let remoteName: String
    let remoteSession: String
    let state: String
    let updatedAt: String
    let attempt: Int
    let error: String?
    let rttMillis: Int64
    let lastMessageId: String?
    let lastReceipt: String?
    var sourceHost: String? = nil
    var remotePID: Int? = nil
    var remoteStart: String? = nil

    var sourceLocation: String { sourceHost ?? "This Mac" }
    var sourceIdentity: NetworkParticipant.Identity {
        .init(host: sourceLocation, session: localSession, local: sourceLocation == "This Mac")
    }
    var destinationIdentity: NetworkParticipant.Identity {
        .init(host: host, session: remoteSession, local: host == "This Mac")
    }

    var id: Int { pid }

    var latencyLabel: String { rttMillis < 0 ? "Not measured" : "\(rttMillis) ms" }

    func evidence(now: Date = Date()) -> Evidence {
        switch displayState(now: now) {
        case "Connected": .connected
        case "Needs attention": .needsReview
        default: .earlier
        }
    }

    func evidenceLabel(now: Date = Date()) -> String {
        switch evidence(now: now) {
        case .connected: return "Connected transport"
        case .needsReview: return "Needs review · remote identity changed"
        case .earlier:
            return state == "online" ? "Earlier connection · not verified now" :
                "Earlier route · \(displayState(now: now))"
        }
    }

    func displayState(now: Date = Date()) -> String {
        guard state != "stopped" else { return "Stopped" }
        // A latched identity failure remains actionable after its worker exits.
        guard state != "needs_attention" else { return "Needs attention" }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = format.date(from: updatedAt)
        format.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? format.date(from: updatedAt),
              now.timeIntervalSince(date) <= 25,
              date.timeIntervalSince(now) <= 5 else { return "Offline · stale status" }
        switch state {
        case "online": return "Connected"
        case "connecting": return "Connecting"
        case "offline": return "Offline"
        default: return "Unknown"
        }
    }

    static func read(directory: URL) -> [Self] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }
        // Retained stopped-process files must not crowd recent links out of the
        // bounded reader. Filesystem time chooses candidates, never liveness.
        let candidates = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 16_384 else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.path < rhs.0.path : lhs.1 > rhs.1
        }
        return candidates.map(\.0)
            .prefix(256).compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 16_384,
                      let data = try? Data(contentsOf: url), data.count <= 16_384,
                      let value = try? JSONDecoder().decode(Self.self, from: data),
                      value.schema == 1, value.pid > 0,
                      value.host.count <= 128, value.localName.count <= 128,
                      value.remoteName.count <= 128 else { return nil }
                return value
            }.sorted { ($0.host, $0.pid) < ($1.host, $1.pid) }
    }
}
