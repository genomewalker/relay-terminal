import Foundation
import SwiftUI

struct RelayHostRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var origins: [String] = []
    var registeredAt = Date()
    var installation = "unknown"
    var architecture: String?
    var installedVersion: String?
    var payloadHash: String?
    var liveVersion: String?
    var supervisorPID: Int?
    var protocolVersion: Int?
    var capabilities: [String] = []
    var checkedAt: Date?
    var connectionObservedAt: Date?
    var connected = false
    var message: String?
    var sshIdentityEvidence = "External SSH policy; server fingerprint not attested by this registry"
}

/// Historical facts persist; current connectivity comes only from this app session.
@MainActor
final class RelayHostRegistry: ObservableObject {
    static let shared = RelayHostRegistry()
    @Published private(set) var records: [String: RelayHostRecord] = [:]
    @Published private(set) var persistenceError: String?
    private let url = RelayStateProfile.applicationSupportRoot.appendingPathComponent("host-registry-v1.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: RelayHostRecord].self, from: data) {
            records = saved.mapValues { record in
                var value = record
                value.connected = false
                return value
            }
        }
    }

    func register(_ profile: ConnectionProfile, origin: String) {
        let key = profile.connectionKey
        var record = records[key] ?? RelayHostRecord(id: key, name: profile.name, host: profile.host)
        record.name = profile.name
        record.host = profile.kind == .local ? "This Mac" : profile.host
        let boundedOrigin = String(origin.prefix(160))
        if !record.origins.contains(boundedOrigin) {
            record.origins = Array((record.origins + [boundedOrigin]).suffix(32))
        }
        if profile.kind == .local { record.sshIdentityEvidence = "Local process transport" }
        guard records[key] != record else { return }
        records[key] = record
        persist()
    }

    func observe(_ report: RelaydHostReport, profile: ConnectionProfile) {
        register(profile, origin: "Relay installation manager")
        guard var record = records[profile.connectionKey] else { return }
        record.installation = report.state.rawValue
        record.architecture = report.architecture
        record.installedVersion = report.version
        record.payloadHash = report.payloadHash
        record.liveVersion = report.liveVersion
        record.supervisorPID = report.supervisorPID
        record.protocolVersion = report.protocolVersion
        record.checkedAt = report.checkedAt
        record.message = report.message.map { String(RelayDiagnostics.redact($0).prefix(1000)) }
        records[record.id] = record
        persist()
    }

    func observeFailedCheck(_ report: RelaydHostReport, profile: ConnectionProfile) {
        register(profile, origin: "Relay installation manager")
        guard var record = records[profile.connectionKey] else { return }
        // Failure to reach the host cannot invalidate previous installed bytes
        // or an independently observed live transport handshake.
        record.installation = report.state.rawValue
        record.checkedAt = report.checkedAt
        record.message = report.message.map { String(RelayDiagnostics.redact($0).prefix(1000)) }
        records[record.id] = record
        persist()
    }

    func connection(_ profile: ConnectionProfile, ready: Bool, capabilities: [String] = [],
                    version: String? = nil, protocolVersion: Int? = nil, supervisorPID: Int? = nil) {
        register(profile, origin: "Relay node transport")
        guard var record = records[profile.connectionKey] else { return }
        record.connected = ready
        record.connectionObservedAt = Date()
        if ready {
            record.capabilities = capabilities.sorted()
            // These fields come from the current daemon handshake, independently
            // of historical checks of the executable installed on disk.
            record.liveVersion = version
            record.protocolVersion = protocolVersion
            record.supervisorPID = supervisorPID
        }
        records[record.id] = record
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            persistenceError = nil
        } catch { persistenceError = "Host registry could not be saved: \(error.localizedDescription)" }
    }
}

struct RelayHostsMonitor: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var registry = RelayHostRegistry.shared
    @ObservedObject private var manager = RelaydManager.shared
    private var profiles: [ConnectionProfile] {
        workspace.profileStore.connectableHosts.filter { $0.kind == .ssh && $0.backend == .relay }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            Text("Saved hosts and observed connections").font(.headline)
            Text("Installation checks are historical. Live connectivity is observed in this Relay session.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = registry.persistenceError { Text(error).foregroundStyle(.orange) }
            ForEach(registry.records.values.sorted { $0.name < $1.name }) { record in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                    HStack {
                        Text(record.name).font(.headline)
                        Spacer()
                        Text(connectionLabel(record)).foregroundStyle(.secondary)
                        if let profile = profiles.first(where: { $0.connectionKey == record.id }) {
                            Button("Check installation") { manager.check(profile, allowAutomaticUpdate: false) }
                                .disabled([RelaydHostState.checking, .installing].contains(manager.report(for: profile).state))
                        }
                    }
                    Text("\(record.host) · installation: \(record.installation) · architecture: \(record.architecture ?? "unknown")")
                    Text("Installed: \(record.installedVersion ?? "unknown") · observed daemon: \(record.liveVersion ?? "unknown")")
                    if let checked = record.checkedAt { Text("Last installation check: \(checked.formatted())") }
                    if !record.capabilities.isEmpty { Text("Capabilities: " + record.capabilities.joined(separator: ", ")) }
                    Text("Sources: " + record.origins.joined(separator: ", "))
                    Text(record.sshIdentityEvidence).foregroundStyle(.secondary)
                    if let message = record.message { Text(message).foregroundStyle(.secondary) }
                }.font(.caption).padding(RelayTheme.spacing(12))
                    .background(RelayTheme.surface).overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)).stroke(RelayTheme.line))
            }
        }.padding(RelayTheme.spacing(12)).onAppear {
            profiles.forEach { registry.register($0, origin: "Configured host") }
            registry.register(.local, origin: "Local Relay")
        }
    }
    private func connectionLabel(_ record: RelayHostRecord) -> String {
        // A persisted ready event never establishes current connectivity.
        let live = RelayNodeTransportPool.shared.networkSnapshots().first { $0.id == record.id }
        return live == nil ? "No current transport observation" : "Transport observed; see Network"
    }
}
