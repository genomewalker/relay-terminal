import SwiftUI

/// Ownership is containment; the relationship list carries communication evidence.
struct PeerNetworkMap: View {
    let participants: [NetworkParticipant]
    let links: [PeerNetworkStatus]
    let now: Date
    @Binding var selection: NetworkParticipant.Identity?
    let inspectLink: (Int) -> Void
    var reportedLinks: [HostedPeerLink] = []
    var nativeGroupEdges: [HostedNativeGroupEdge] = []
    var teams: [HostedClaudeTeam] = []
    var inspectReportedLink: (HostedPeerLink) -> Void = { _ in }
    @State private var showEarlier = false
    @State private var showAllLinks = true

    private var hosts: [String] {
        Array(Set(participants.map { $0.id.host })).sorted {
            if $0 == "This Mac" { return true }
            if $1 == "This Mac" { return false }
            return $0 < $1
        }
    }
    private func visible(_ a: NetworkParticipant.Identity, _ b: NetworkParticipant.Identity) -> Bool {
        showAllLinks || selection == a || selection == b
    }
    private func name(_ id: NetworkParticipant.Identity) -> String {
        participants.first { $0.id == id }?.name ?? id.session
    }

    var body: some View {
        VSplitView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(hosts, id: \.self) { peerLane($0) }
                }
                .padding(RelayTheme.spacing(16))
            }.frame(minHeight: 140, idealHeight: 300)
            ScrollView {
                relationships.padding(RelayTheme.spacing(16)).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(minHeight: 160, idealHeight: 240)
        }
        .background(RelayTheme.canvas)
    }

    private var relationships: some View {
        let scoped = links.filter { visible($0.sourceIdentity, $0.destinationIdentity) }
        let connected = scoped.filter { $0.evidence(now: now) == .connected }
        let review = scoped.filter { $0.evidence(now: now) == .needsReview }
        let earlier = scoped.filter { $0.evidence(now: now) == .earlier }
            .sorted { $0.updatedAt > $1.updatedAt }
        let reported = reportedLinks.filter { visible($0.source, $0.destination) }
        let introduced = nativeGroupEdges.filter { visible($0.source, $0.destination) }
        let visibleTeams = teams.filter { showAllLinks || $0.team.leadSessionId == selection?.session && $0.host == selection?.host }
        return VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            HStack {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text("Connections").font(.headline)
                    Text(showAllLinks ? "All reported relationships" :
                         (selection == nil ? "Select a session above to see its links" : "Links for the selected session"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show all links", isOn: $showAllLinks)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            if connected.isEmpty && review.isEmpty && earlier.isEmpty &&
                reported.isEmpty && introduced.isEmpty && visibleTeams.isEmpty {
                Text(selection == nil && !showAllLinks ? "Choose a session to inspect its connections." :
                    "No observed links for this selection. Configure an exact session pair in Connections.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !connected.isEmpty {
                Text("Connected now").font(.caption.weight(.semibold))
                ForEach(connected) { link in
                    Button { inspectLink(link.pid) } label: {
                        routeRow(link)
                    }.buttonStyle(.plain)
                }
            }
            if !review.isEmpty {
                Text("Needs review").font(.caption.weight(.semibold)).padding(.top, RelayTheme.spacing(5))
                ForEach(review) { link in
                    Button { inspectLink(link.pid) } label: { routeRow(link) }
                        .buttonStyle(.plain)
                }
                Text("The saved remote process changed. Relay will not silently reconnect to a different agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showEarlier && !earlier.isEmpty {
                Text("Earlier observations").font(.caption.weight(.semibold)).padding(.top, RelayTheme.spacing(5))
                ForEach(Array(earlier.prefix(showEarlier ? earlier.count : 3))) { link in
                    Button { inspectLink(link.pid) } label: { routeRow(link) }
                        .buttonStyle(.plain)
                }
                if earlier.count > 3 {
                    Button(showEarlier ? "Show fewer earlier routes" : "Show all \(earlier.count) earlier routes") {
                        showEarlier.toggle()
                    }.font(.caption)
                }
                Text("An old receipt is not proof that an agent processed a message or remains connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !reported.isEmpty || !introduced.isEmpty {
                Divider().padding(.vertical, RelayTheme.spacing(4))
                Text("Provider and group reports").font(.caption.weight(.semibold))
                ForEach(reported) { report in
                    Button { inspectReportedLink(report) } label: {
                        relationshipRow(name(report.source), name(report.destination),
                            "Provider-reported · delivery unverified", "arrow.up.right", verified: false)
                    }.buttonStyle(.plain)
                }
                ForEach(Array(introduced.enumerated()), id: \.offset) { _, edge in
                    relationshipRow(name(edge.source), name(edge.destination),
                        "Introduced group · delivery unverified", "person.2", verified: false)
                }
            }
            if !visibleTeams.isEmpty {
                DisclosureGroup("Claude team metadata · \(visibleTeams.count)") {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                        Text("Membership records are not live agent or messaging links.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(visibleTeams) { entry in
                            Text("\(entry.team.name) · lead on \(entry.host) · \(entry.team.members.count) listed members")
                                .font(.callout).lineLimit(2)
                        }
                    }.padding(.top, RelayTheme.spacing(6))
                }.font(.caption.weight(.semibold)).padding(.top, RelayTheme.spacing(5))
            }
        }
        .padding(RelayTheme.spacing(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
    }

    private func routeRow(_ link: PeerNetworkStatus) -> some View {
        relationshipRow(
            link.localName, link.remoteName, link.evidenceLabel(now: now),
            link.evidence(now: now) == .needsReview ? "exclamationmark.circle" :
                (link.evidence(now: now) == .connected ? "link" : "clock"),
            verified: link.evidence(now: now) == .connected,
            attention: link.evidence(now: now) == .needsReview)
        .accessibilityLabel("\(link.localName) to \(link.remoteName): \(link.evidenceLabel(now: now))")
    }

    private func relationshipRow(_ source: String, _ destination: String, _ evidence: String,
                                 _ symbol: String, verified: Bool, attention: Bool = false) -> some View {
        HStack(spacing: RelayTheme.spacing(10)) {
            Image(systemName: symbol).frame(width: 22)
                .foregroundStyle(verified ? Color.accentColor : (attention ? Color.orange : Color.secondary))
            Text(source).lineLimit(1)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(destination).lineLimit(1)
            Spacer(minLength: 8)
            Text(evidence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout).padding(.vertical, RelayTheme.spacing(6)).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func peerLane(_ host: String) -> some View {
        let ordered = NetworkParticipant.orderedForMap(participants, host: host)
        let sessions = ordered.filter { $0.parentID == nil }
        let orphans = ordered.filter { node in
            node.parentID != nil && !sessions.contains { $0.id == node.parentID }
        }
        return VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text(host).font(.headline).lineLimit(1)
                    Text(host == "This Mac" ? "Local peer" : "Remote peer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(sessions.count) sessions").font(.caption)
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            if sessions.isEmpty {
                Text("No sessions reported").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                sessionCard(session, agents: ordered.filter { $0.parentID == session.id })
            }
            if !orphans.isEmpty {
                Text("Parent session not visible").font(.caption).foregroundStyle(.secondary)
                ForEach(orphans) { agent in agentRow(agent) }
            }
        }
        .padding(RelayTheme.spacing(14)).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RelayTheme.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(host == "This Mac" ? "Local" : "Remote") peer \(host)")
    }

    private func sessionCard(_ session: NetworkParticipant, agents: [NetworkParticipant]) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            Button { selection = session.id } label: {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(7)) {
                    HStack(spacing: RelayTheme.spacing(8)) {
                        Image(systemName: session.externalEndpoint ? "arrow.up.forward.app" : "terminal")
                            .foregroundStyle(selection == session.id ? Color.accentColor : Color.secondary)
                    Text(session.name).font(RelayTheme.font(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    if let directory = session.directory {
                        Text(directory).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(directory)
                    }
                    if let taskState = session.taskState {
                        Text(taskState).font(.caption.weight(.medium))
                            .foregroundStyle(taskState == "Working now" ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RelayTheme.spacing(8)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !agents.isEmpty {
                Divider().padding(.leading, RelayTheme.spacing(12))
                ForEach(agents) { agent in agentRow(agent) }
            }
        }
        .background(selection == session.id ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func agentRow(_ agent: NetworkParticipant) -> some View {
        Button { selection = agent.id } label: {
            HStack(spacing: RelayTheme.spacing(8)) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(agent.name).font(.callout).lineLimit(1)
                    Text(agent.activity ?? "Activity unknown").font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RelayTheme.spacing(12)).padding(.vertical, RelayTheme.spacing(7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == agent.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
