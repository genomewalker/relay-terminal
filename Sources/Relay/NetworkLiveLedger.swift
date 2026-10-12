import SwiftUI

/// Connections lead; execution inventory remains a separate destination.
struct NetworkLiveLedger: View {
    let profiles: [ConnectionProfile]
    let transports: [NetworkTransportSnapshot]
    let participants: [NetworkParticipant]
    let links: [PeerNetworkStatus]
    let now: Date
    let query: String
    var history = false
    let inspectLink: (Int) -> Void
    let viewSessions: () -> Void
    @State private var selectedTransport: String?

    private var uptime: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func matches(_ values: String...) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(term) }
    }
    private var uniqueProfiles: [ConnectionProfile] {
        var seen = Set<String>()
        let known = Set(profiles.map(\.connectionKey))
        let observed = transports.filter { !known.contains($0.id) }.map {
            ConnectionProfile(kind: .ssh, host: $0.host, user: $0.account, port: $0.port,
                              usesSSHConfig: $0.id.hasPrefix("config:"))
        }
        return (profiles + observed).sorted { $0.connectionKey < $1.connectionKey }
            .filter { seen.insert($0.connectionKey).inserted }
            .filter { matches($0.name, $0.host, $0.user, $0.connectionKey) }
    }
    private var routes: [PeerNetworkStatus] {
        links.filter { history ? $0.evidence(now: now) == .earlier : $0.state != "stopped" }
            .filter { matches($0.localName, $0.remoteName, $0.host, $0.localSession, $0.remoteSession) }
            .sorted { ($0.host, $0.localName, $0.remoteName, $0.pid) < ($1.host, $1.localName, $1.remoteName, $1.pid) }
    }
    private func name(_ id: NetworkParticipant.Identity, fallback: String) -> String {
        participants.first { $0.id == id }?.name ?? fallback
    }

    var body: some View {
        List {
            if !history {
                Section("Hosts") {
                    if matches("This Mac", "Local execution") {
                        HStack(spacing: RelayTheme.spacing(12)) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                Text("This Mac").fontWeight(.medium)
                                Text("Local execution").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View sessions", action: viewSessions).buttonStyle(.borderless)
                        }.padding(.vertical, RelayTheme.spacing(4))
                    }
                    ForEach(uniqueProfiles, id: \.connectionKey) { profile in
                        let snapshot = transports.first { $0.id == profile.connectionKey }
                        DisclosureGroup(isExpanded: Binding(
                            get: { selectedTransport == profile.connectionKey },
                            set: { selectedTransport = $0 ? profile.connectionKey : nil }
                        )) {
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                                Text("Observation: this GUI's remote protocol channel")
                                Text(snapshot.map { "Generation \($0.generation) · \($0.attachedSubscriptions) session subscriptions" }
                                    ?? "No current protocol observation. Retained workers may still be running.")
                                Text(snapshot?.usesPersistentBroker == true ?
                                     "This channel uses the persistent connection broker." :
                                     "Independent broker process status is unconfirmed.").foregroundStyle(.secondary)
                                Button("View sessions", action: viewSessions)
                            }.font(.caption).padding(.vertical, RelayTheme.spacing(8)).textSelection(.enabled)
                        } label: {
                            HStack(spacing: RelayTheme.spacing(12)) {
                                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                    Text(profile.host).fontWeight(.medium)
                                    Text(profile.usesSSHConfig ? "SSH configuration" : "\(profile.user.isEmpty ? "Default account" : profile.user) · port \(profile.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(snapshot?.label(at: uptime) ?? "Status unknown",
                                      systemImage: snapshot?.isCurrent(at: uptime) == true ? "checkmark.circle" : "questionmark.circle")
                                    .font(.caption).foregroundStyle(snapshot?.isCurrent(at: uptime) == true ? RelayTheme.accent : Color.secondary)
                            }.padding(.vertical, RelayTheme.spacing(4))
                        }
                    }
                }
            }
            Section(history ? "Earlier messaging observations" : "Messaging routes") {
                if routes.isEmpty {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                        Text(query.isEmpty ? (history ? "No earlier observations" : "No messaging links") : "No matching routes")
                        Text(query.isEmpty ? "Sessions can run without agent messaging." : "Clear the search to see all routes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, RelayTheme.spacing(8))
                }
                ForEach(routes) { link in
                    Button { inspectLink(link.pid) } label: {
                        HStack(spacing: RelayTheme.spacing(12)) {
                            Image(systemName: history ? "clock" : "link").frame(width: 20).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                HStack(spacing: RelayTheme.spacing(6)) {
                                    Text(name(link.sourceIdentity, fallback: link.localName)).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                    Text(name(link.destinationIdentity, fallback: link.remoteName)).lineLimit(1)
                                }.fontWeight(.medium)
                                Text("\(link.sourceLocation) → \(link.host)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(history ? link.evidenceLabel(now: now) :
                                    link.evidence(now: now) == .connected ? "Ready" :
                                    link.evidence(now: now) == .needsReview ? "Needs review" : "State unconfirmed")
                                .font(.caption).foregroundStyle(link.evidence(now: now) == .connected && !history ? RelayTheme.accent : Color.secondary)
                        }.padding(.vertical, RelayTheme.spacing(5)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("Messaging route, \(link.localName) to \(link.remoteName), \(link.evidenceLabel(now: now))")
                }
            }
            Section {
                Text(history ? "Past observations do not establish current connectivity or message handling." :
                        "Route readiness does not mean an agent has read or handled a message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.listStyle(.inset).font(RelayTheme.font(size: 13))
        .accessibilityIdentifier("relay.network.liveLedger")
    }
}
