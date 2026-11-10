import SwiftUI

/// The topology is derived from actual link snapshots, never a mock agent graph.
struct PeerNetworkView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var managing = false

    var body: some View {
        ZStack {
            PeerNetworkTopologyView(workspace: workspace) { managing = true }
                .opacity(managing ? 0 : 1)
                .allowsHitTesting(!managing)
                .accessibilityHidden(managing)
            if managing {
                VStack(spacing: RelayTheme.spacing(0)) {
                    HStack {
                        Button("Back to Network", systemImage: "chevron.left") { managing = false }
                        Spacer()
                    }.padding(RelayTheme.spacing(12))
                    Divider()
                    PeerNetworkLinksView()
                }.background(RelayTheme.canvas)
            }
        }.frame(minWidth: 640, minHeight: 440)
    }
}

struct PeerNetworkTopologyView: View {
    @ObservedObject var workspace: WorkspaceModel
    var connectionOnly = false
    var startingPaneID: UUID? = nil
    var startingTabID: UUID? = nil
    var initiallyAcrossApp = false
    var requestedPaneIDs: Set<UUID> = []
    @State private var seededPaneIDs: Set<UUID> = []
    @State private var checkedHosts: Set<String> = []
    @State private var verificationStartedAt = Date()
    @Environment(\.dismiss) private var dismiss
    @State private var seededStartingPane = false
    @State private var links: [PeerNetworkStatus] = []
    @State private var host: String?
    @State private var selected: Int?
    @State private var now = Date()
    @State private var localPeers: [DiscoveredPeer] = []
    @State private var discoveryError: String?
    @State private var discoveryFailures: [String: String] = [:]
    @State private var participant: NetworkParticipant.Identity?
    @State private var networkView = "Live network"
    @State private var inspectorOpen = true
    @State private var selectedRoute: PeerNetworkStatus?
    @AppStorage("relay.network.mapPresentation", store: RelayStateProfile.defaults) private var mapPresentation = false
    @State private var transportSnapshots: [NetworkTransportSnapshot] = []
    @State private var search = ""
    @State private var lastInspectedParticipant: NetworkParticipant?
    @State private var remoteDiscoveries: [String: PeerDiscovery] = [:]
    @State private var discoveringHost: String?
    @State private var discoveryStatus: String?
    @State private var showOffline = false
    @State private var discoveryDates: [String: Date] = [:]
    @State private var reportedSelection: HostedPeerLink?
    @State private var desktopTasks: [DesktopPeerRoute.TaskInfo] = []
    @State private var desktopTaskObservedAt: Date?
    @State private var desktopDiscoveryError: String?
    @State private var chosenConnections: [NetworkParticipant.Identity: PeerGroupPlan.Endpoint] = [:]
    @State private var groupSheet = false
    @State private var verifiedPaneSelection: [PeerGroupPlan.Endpoint]?
    @State private var paneMessageLink: RelayPaneMessaging.Link?
    @State private var connectingPaneMessages = false
    @State private var paneMessageError: String?
    @State private var daemonCheck = RelayPaneMessaging.DaemonPairCheck()
    @State private var addingSessions = false
    @State private var includeAllAppSessions = false
    @State private var additionalPaneSearch = ""
    @State private var previousConnections: [NetworkParticipant.Identity: PeerGroupPlan.Endpoint]?
    @State private var selectionError: String?
    @State private var panePicker = false
    @State private var reviewAfterPicker = false
    let manage: () -> Void

    private var hosts: [String] { Array(Set(workspace.panes.values.filter { $0.profile.kind == .ssh }.map { $0.profile.host })).sorted() }
    private var activeLinks: [PeerNetworkStatus] {
        links.filter { $0.evidence(now: now) == .connected }
    }
    private var scopedLinks: [PeerNetworkStatus] {
        let ids = Set(participants.map(\.id))
        return activeLinks.filter { ids.contains($0.sourceIdentity) && ids.contains($0.destinationIdentity) }
    }
    private var visible: [PeerNetworkStatus] { links.filter { host == nil || $0.host == host } }
    private var inspected: PeerNetworkStatus? {
        guard let saved = selectedRoute else { return nil }
        return links.first { $0.pid == saved.pid && $0.host == saved.host &&
            $0.localSession == saved.localSession && $0.remoteSession == saved.remoteSession &&
            $0.remotePID == saved.remotePID && $0.remoteStart == saved.remoteStart } ?? saved
    }
    private var participants: [NetworkParticipant] {
        let recent = remoteDiscoveries.filter { target, _ in
            showOffline || PeerDiscovery.isFresh(discoveryDates[target], now: now)
        }
        let local = showOffline || PeerDiscovery.isFresh(discoveryDates["This Mac"], now: now) ? localPeers : []
        let discovered = NetworkParticipant.collect(local: local, links: activeLinks, remote: recent)
        let paneParticipants = workspace.panes.values.filter { $0.contentKind == .terminal }.sorted { $0.id.uuidString < $1.id.uuidString }.flatMap { pane in
            let location = pane.profile.kind == .ssh ? pane.profile.host : "This Mac"
            let peers = pane.profile.kind == .ssh ? (recent[location]?.peers ?? []) : local
            let matches: [DiscoveredPeer]
            if pane.profile.kind == .local {
                matches = NetworkParticipant.localPeersForPane(peers, paneID: pane.id.uuidString.lowercased(), foregroundPID: pane.networkForegroundPID)
            } else {
                matches = NetworkParticipant.peersForPane(peers, paneID: pane.id.uuidString.lowercased(), roots: pane.networkAgentRoots)
            }
            // Never guess an address from a title, directory, or PID alone.
            let unique = matches.count == 1
            // Shared conversation IDs are not process identities. Keep ambiguous
            // conversation-level graph links detached, but retain the exact pane binding.
            let sharedSession = unique && peers.filter { $0.sessionId == matches[0].sessionId }.count > 1
            let session = unique && !sharedSession ? matches[0].sessionId : "pane-" + pane.id.uuidString.lowercased()
            let identity = NetworkParticipant.Identity(host: location, session: session, local: pane.profile.kind != .ssh)
            var parent = discovered.first { $0.id == identity } ?? NetworkParticipant(id: identity, name: pane.displayName)
            parent.name = unique ? matches[0].name : pane.displayName
            parent.boundPeer = unique ? matches[0] : nil
            parent.discovered = unique
            parent.identityStatus = NetworkParticipant.unresolvedStatus(
                isShell: pane.kind == .shell, connected: pane.connectionState == .connected,
                observed: discoveryDates[location] != nil,
                fresh: PeerDiscovery.isFresh(discoveryDates[location], now: now),
                matchCount: matches.count,
                sessionCount: unique ? 1 : 0)
            parent.paneID = pane.id
            parent.activity = pane.connectionStatusLabel
            parent.directory = pane.directory
            parent.tabName = workspace.tabs.first { $0.allPaneIDs.contains(pane.id) }?.name
            parent.provider = pane.kind.label
            parent.lastEvent = pane.agentActivities.last?.label
            parent.lastEventAt = pane.agentActivities.last?.occurredAt
            parent.lastTurnAt = pane.lastCompletedAgentTurn
            parent.activity = "\(pane.connectionStatusLabel) · \(pane.phase.label)"
            var nodes = [parent]
            for child in peers where child.paneID == pane.id.uuidString.lowercased() && child.parentSession == parent.boundPeer?.sessionId && child.parentSession != nil {
                let id = NetworkParticipant.Identity(host: location, session: child.sessionId, local: identity.local)
                var node = discovered.first { $0.id == id } ?? NetworkParticipant(id: id, name: child.name)
                node.parentID = identity; node.paneID = pane.id; node.activity = "Running child agent"
                nodes.append(node)
            }
            if pane.connectionState == .connected || showOffline {
                for child in pane.subagents where child.reportedChild == true && (showOffline || child.completedAt == nil) {
                    let childID = NetworkParticipant.Identity(host: location,
                        session: child.threadID ?? "agent-\(pane.id.uuidString)-\(child.id)", local: identity.local)
                    guard childID != identity else { continue }
                    guard !nodes.contains(where: { $0.id == childID }) else { continue }
                    var node = discovered.first { $0.id == childID } ?? NetworkParticipant(id: childID, name: child.label)
                    node.parentID = identity
                    node.paneID = pane.id
                    node.activity = child.completedAt == nil ? "Child agent" : "Completed agent"
                    nodes.append(node)
                }
            }
            return nodes
        }
        var allParticipants = paneParticipants
        for task in desktopTasks {
            let identity = NetworkParticipant.Identity(host: "This Mac", session: task.id, local: true)
            var node = allParticipants.first(where: { $0.id == identity }) ??
                NetworkParticipant(id: identity, name: task.displayName)
            node.name = task.displayName
            node.discovered = true
            node.provider = "ChatGPT desktop task"
            node.taskState = desktopTaskObservedAt.map { now.timeIntervalSince($0) <= 15 } == true ?
                task.activityLabel : "Activity unknown · desktop unavailable"
            if let index = allParticipants.firstIndex(where: { $0.id == identity }) {
                allParticipants[index] = node
            } else {
                allParticipants.append(node)
            }
        }
        return NetworkParticipant.withActiveLinkEndpoints(allParticipants, links: activeLinks)
    }
    private var filteredParticipants: [NetworkParticipant] { participants.filter { $0.matches(search) } }
    private var mapParticipants: [NetworkParticipant] {
        NetworkParticipant.withBoundaryEndpoints(filteredParticipants, links: activeLinks)
    }
    private var reportedLinks: [HostedPeerLink] {
        remoteDiscoveries.flatMap { target, discovery in
            (discovery.links ?? []).filter { $0.isCurrent(peers: discovery.peers, now: now) }
                .map { HostedPeerLink(host: target, report: $0) }
        }.sorted { $0.id < $1.id }
    }
    private var nativeGroupEdges: [HostedNativeGroupEdge] {
        remoteDiscoveries.flatMap { target, discovery -> [HostedNativeGroupEdge] in
            guard PeerDiscovery.isFresh(discoveryDates[target], now: now) else { return [] }
            return (discovery.groups ?? []).filter(\.current).flatMap { group -> [HostedNativeGroupEdge] in
                let members = group.participants.compactMap { member -> NetworkParticipant? in
                    let matches = participants.filter { node in
                        node.id.host == target && node.boundPeer?.pid == member.pid &&
                        node.boundPeer?.procStart == member.processStart &&
                        node.boundPeer?.sessionId == member.session && node.boundPeer?.name == member.name
                    }
                    return matches.count == 1 ? matches[0] : nil
                }
                guard members.count == group.participants.count else { return [] }
                let pairs: [(NetworkParticipant, NetworkParticipant)]
                if group.topology == "coordinator" {
                    guard let hub = members.first(where: { "native:\(target):\($0.boundPeer!.sessionId)" == group.coordinatorID }) else { return [] }
                    pairs = members.filter { $0.id != hub.id }.map { (hub, $0) }
                } else {
                    pairs = members.indices.flatMap { i in members.indices.filter { $0 > i }.map { (members[i], members[$0]) } }
                }
                return pairs.map { HostedNativeGroupEdge(groupID: group.id, source: $0.0.id, destination: $0.1.id) }
            }
        }
    }
    private var reportedTeams: [HostedClaudeTeam] {
        remoteDiscoveries.flatMap { target, discovery -> [HostedClaudeTeam] in
            guard PeerDiscovery.isFresh(discoveryDates[target], now: now) else { return [] }
            return (discovery.teams ?? []).map { HostedClaudeTeam(host: target, team: $0) }
        }.sorted { $0.id < $1.id }
    }
    private var inspectedParticipant: NetworkParticipant? {
        NetworkParticipant.resolveSelection(participant, current: mapParticipants, previous: lastInspectedParticipant)
    }

    var body: some View {
        Group {
            if connectionOnly, let paneMessageLink {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
                    Label("Communication pair saved", systemImage: "link").font(.headline)
                    ForEach(paneMessageLink.members, id: \.paneID) { member in
                        Text("\(workspace.panes[member.paneID]?.displayName ?? member.name) · \(member.provider.capitalized)")
                    }
                    Text("The relationship is saved independently of the current processes. Relay checks the exact recipient conversation and its messaging endpoint before each delivery.")
                        .foregroundStyle(.secondary)
                    if let errors = paneMessageLink.resolutionErrors {
                        Text("Messaging endpoint unavailable").font(.headline).foregroundStyle(.orange)
                        ForEach(errors.keys.sorted(), id: \.self) { id in
                            Text(errors[id] ?? "Unavailable").font(.caption).textSelection(.enabled)
                        }
                        Text("The pair remains saved. Delivery becomes available when both agents expose a verified messaging endpoint.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Endpoint identity was verified when you saved this pair. Saving does not send a message or prove delivery.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("This does not send an introduction or assign a task.").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Done") { dismiss() } }
                }.padding(RelayTheme.spacing(20)).frame(width: 480)
            } else if connectionOnly, addingSessions {
                additionalPanePicker
            } else if connectionOnly, let verifiedPaneSelection {
                PeerGroupSetupView(endpoints: verifiedPaneSelection, addMore: beginAddingSessions)
            } else if connectionOnly, !requestedPaneIDs.isEmpty {
                selectedPaneVerification
            } else if connectionOnly { panePickerContent }
            else { networkContent }
        }
        .sheet(isPresented: $groupSheet) {
            PeerGroupSetupView(endpoints: chosenConnections.values.sorted { $0.id < $1.id })
        }
        .sheet(isPresented: $panePicker, onDismiss: {
            if reviewAfterPicker { reviewAfterPicker = false; groupSheet = true }
        }) { panePickerContent }
        .background(discoveryAnchor)
    }

    private var selectedPaneHosts: Set<String> {
        Set(requestedPaneIDs.compactMap { id in
            workspace.panes[id].map { $0.profile.kind == .ssh ? $0.profile.host : "This Mac" }
        })
    }
    private var selectionCheckFinished: Bool {
        selectedPaneHosts.isSubset(of: checkedHosts) || now.timeIntervalSince(verificationStartedAt) >= 25
    }
    /// Two panes on one relayd can be verified and linked by that relayd alone.
    /// Its per-pane check resolves Codex app-server endpoints, which the
    /// host-wide peer inventory (Claude session records only) never lists.
    private var daemonPairProfile: ConnectionProfile? {
        guard requestedPaneIDs.count == 2 else { return nil }
        return RelayPaneMessaging.sharedDaemonProfile(
            requestedPaneIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { workspace.panes[$0] })
    }
    private var daemonPairVerified: Bool {
        daemonPairProfile != nil && RelayPaneMessaging.daemonPairVerified(requestedPaneIDs, transports: daemonCheck.transports)
    }
    private func paneVerified(_ id: UUID) -> Bool {
        seededPaneIDs.contains(id) || daemonCheck.transports[id] != nil
    }
    private func verifyDaemonPair() async {
        guard daemonPairProfile != nil else { return }
        let check = daemonCheck.begin()
        for id in requestedPaneIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let pane = workspace.panes[id] else {
                daemonCheck.record(id, check: check, result: .failure(RemoteCatalogError.failed("Pane unavailable.")))
                continue
            }
            do {
                let transport = try await RelayPaneMessaging.shared.daemonEndpointTransport(pane)
                daemonCheck.record(id, check: check, result: .success(transport))
            } catch {
                daemonCheck.record(id, check: check, result: .failure(error))
            }
        }
    }
    private var selectedPaneVerification: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
            Label(daemonPairVerified ? "Link these panes" : selectionCheckFinished ? "Choose a messaging connection" : "Verifying selected panes", systemImage: "link")
                .font(.headline)
            Text(daemonPairVerified ? "Both panes have a verified messaging endpoint on \(daemonPairProfile?.kind == .ssh ? daemonPairProfile?.host ?? "their host" : "This Mac"). Their relayd saves and checks the pair." : selectionCheckFinished ? "Native peer messaging is unavailable for one or more selected panes. You can connect two live Claude or Codex panes through their existing terminals instead." : "Relay is checking the messaging identity for each pane you selected. You don’t need to select them again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: RelayTheme.spacing(8)) {
                if !selectionCheckFinished && !daemonPairVerified { ProgressView().controlSize(.small) }
                Text("\(requestedPaneIDs.filter(paneVerified).count) of \(requestedPaneIDs.count) verified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    ForEach(requestedPaneIDs.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        HStack(spacing: RelayTheme.spacing(9)) {
                            Image(systemName: paneVerified(id) ? "checkmark.circle.fill" : (selectionCheckFinished ? "exclamationmark.circle" : "hourglass.circle"))
                                .foregroundStyle(paneVerified(id) ? RelayTheme.mint : RelayTheme.textMuted)
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                                Text(workspace.panes[id]?.displayName ?? "Pane unavailable")
                                    .font(RelayTheme.font(size: 12, weight: .medium))
                                if let pane = workspace.panes[id] {
                                    Text("\(pane.profile.kind == .ssh ? pane.profile.host : "This Mac") · \(pane.id.uuidString.lowercased())")
                                        .font(RelayTheme.font(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if pane.connectionState != .connected && !paneVerified(id) {
                                        Text("Reconnect this pane before linking.")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else if (selectionCheckFinished || daemonCheck.failures[id] != nil) && !paneVerified(id) {
                                        Text(daemonCheck.failures[id].map { "relayd: \($0)" } ?? "No verified messaging endpoint. This pane’s terminal output remains separate from messaging.")
                                            .font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            if paneVerified(id) {
                                Text("Verified").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(RelayTheme.spacing(8))
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                    }
                }
            }
            ForEach(selectedPaneHosts.sorted(), id: \.self) { host in
                if let failure = discoveryFailures[host] {
                    Text("\(host): \(failure) Messaging identity has not been verified.")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if let paneMessageError { Text(paneMessageError).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if connectingPaneMessages { ProgressView().controlSize(.small) }
                if selectionCheckFinished {
                    Button("Check again") {
                        verificationStartedAt = Date()
                        let target = requestedPaneIDs.subtracting(seededPaneIDs).compactMap { workspace.panes[$0] }.first
                        let host = target?.profile.kind == .ssh ? target?.profile.host : nil
                        checkedHosts.remove(host ?? "This Mac")
                        discover(host: host)
                        Task { await verifyDaemonPair() }
                    }.disabled(discoveringHost != nil || connectingPaneMessages)
                }
                if requestedPaneIDs.count == 2 && (selectionCheckFinished || daemonPairVerified) {
                    Button(daemonPairVerified ? "Link panes" : "Connect pane messaging") {
                        connectingPaneMessages = true; paneMessageError = nil
                        Task {
                            defer { connectingPaneMessages = false }
                            do { paneMessageLink = try await RelayPaneMessaging.shared.connect(panes: Array(requestedPaneIDs), workspace: workspace) }
                            catch { paneMessageError = error.localizedDescription }
                        }
                    }.buttonStyle(RelayPrimaryButtonStyle()).disabled(connectingPaneMessages)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(connectingPaneMessages)
            }
        }
        .padding(RelayTheme.spacing(20))
        .frame(width: 480, height: 390)
        .task(id: requestedPaneIDs) { await verifyDaemonPair() }
    }

    private var additionalPaneCandidates: [NetworkParticipant] {
        let scopeTabID = startingTabID ?? workspace.selectedTabID
        return participants.filter { node in
            guard node.parentID == nil, let paneID = node.paneID,
                  !requestedPaneIDs.contains(paneID) else { return false }
            return includeAllAppSessions || workspace.tabID(containingPane: paneID) == scopeTabID
        }.filter { node in
            let query = additionalPaneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return [node.name, node.id.host, node.id.session, node.tabName ?? "", node.directory ?? "", node.provider ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }.sorted {
            let left = "\($0.id.host) \($0.tabName ?? "") \($0.name)"
            let right = "\($1.id.host) \($1.tabName ?? "") \($1.name)"
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private var additionalPanePicker: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack(spacing: RelayTheme.spacing(9)) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(RelayTheme.font(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text("Add sessions").font(RelayTheme.font(size: 15, weight: .semibold))
                    Text("Your original pane selection stays included.")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(chosenConnections.count) of 8")
                    .font(RelayTheme.font(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: RelayTheme.spacing(7)) {
                Label("Already included", systemImage: "lock.fill")
                    .font(RelayTheme.font(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(requestedPaneIDs.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                    let pane = workspace.panes[id]
                    HStack(spacing: RelayTheme.spacing(8)) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                            Text(pane?.displayName ?? "Pane unavailable")
                                .font(RelayTheme.font(size: 11, weight: .medium))
                            Text("\(pane.map { $0.profile.kind == .ssh ? $0.profile.host : "This Mac" } ?? "Unknown host") · \(id.uuidString.lowercased())")
                                .font(RelayTheme.font(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("Included").font(RelayTheme.font(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, RelayTheme.spacing(9)).padding(.vertical, RelayTheme.spacing(7))
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                }
            }

            HStack(spacing: RelayTheme.spacing(8)) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, host, tab, path, or ID", text: $additionalPaneSearch)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("relay.peer-group.add-session-search")
                if !additionalPaneSearch.isEmpty {
                    Button { additionalPaneSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear session filter")
                }
            }
            .font(RelayTheme.font(size: 11))
            .padding(.horizontal, RelayTheme.spacing(10)).frame(height: 34)
            .background(RelayTheme.canvas, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
            .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).strokeBorder(.secondary.opacity(0.18)))

            Toggle("Search all Relay sessions", isOn: $includeAllAppSessions)
                .toggleStyle(.checkbox)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .help("By default, only panes in the starting tab and window are listed.")

            HStack {
                Text(includeAllAppSessions ? "All app sessions" : "Starting tab only")
                    .font(RelayTheme.font(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("Only connected sessions with a verified identity can be added.")
                    .font(RelayTheme.font(size: 9.5)).foregroundStyle(.tertiary)
            }

            ScrollView {
                LazyVStack(spacing: RelayTheme.spacing(5)) {
                    ForEach(additionalPaneCandidates) { node in
                        let isSelected = chosenConnections[node.id] != nil
                        let pane = node.paneID.flatMap { workspace.panes[$0] }
                        let locked = node.paneID.map(requestedPaneIDs.contains) ?? false
                        Button { chooseConnection(node) } label: {
                            HStack(spacing: RelayTheme.spacing(9)) {
                                Image(systemName: locked ? "lock.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                                    .foregroundStyle(locked || isSelected ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                    HStack(spacing: RelayTheme.spacing(5)) {
                                        Text(node.name).font(RelayTheme.font(size: 11, weight: .medium)).lineLimit(1)
                                        if let tabName = node.tabName {
                                            Text(tabName).font(RelayTheme.font(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Text([node.id.host == "laptop" ? "This Mac" : node.id.host,
                                          node.directory ?? pane?.directory ?? node.id.session]
                                        .joined(separator: " · "))
                                        .font(RelayTheme.font(size: 9.5)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if !node.discovered {
                                    Text("Not verified").font(RelayTheme.font(size: 9)).foregroundStyle(.orange)
                                } else if isSelected {
                                    Text("Added").font(RelayTheme.font(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "plus").font(RelayTheme.font(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, RelayTheme.spacing(9)).padding(.vertical, RelayTheme.spacing(7))
                            .background(isSelected ? Color.accentColor.opacity(0.08) : RelayTheme.surface.opacity(0.72),
                                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(locked || (!isSelected && (!node.discovered || pane?.connectionState != .connected || chosenConnections.count >= 8)))
                        .opacity(node.discovered ? 1 : 0.62)
                    }
                    if additionalPaneCandidates.isEmpty {
                        Text(additionalPaneSearch.isEmpty ? "No other panes in this scope." : "No sessions match this filter.")
                            .font(RelayTheme.font(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(RelayTheme.spacing(20))
                    }
                }
            }
            .frame(minHeight: 130)

            HStack {
                Button("Cancel") { cancelAddingSessions() }
                Spacer()
                Button("Done") { finishAddingSessions() }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .accessibilityIdentifier("relay.peer-group.add-session-done")
            }
        }
        .padding(RelayTheme.spacing(18))
        .frame(width: 560, height: 560)
    }

    private func beginAddingSessions() {
        previousConnections = chosenConnections
        additionalPaneSearch = ""
        includeAllAppSessions = initiallyAcrossApp
        addingSessions = true
    }

    private func cancelAddingSessions() {
        if let previousConnections { chosenConnections = previousConnections }
        previousConnections = nil
        additionalPaneSearch = ""
        addingSessions = false
    }

    private func finishAddingSessions() {
        verifiedPaneSelection = chosenConnections.values.sorted { $0.id < $1.id }
        previousConnections = nil
        additionalPaneSearch = ""
        addingSessions = false
    }

    @ViewBuilder private var networkContent: some View {
        if networkView == "Live network" { liveHUDContent } else { standardNetworkContent }
    }

    private var liveHUDContent: some View {
        GeometryReader { geometry in
            VStack(spacing: RelayTheme.spacing(0)) {
                RelayViewerBarFrame(close: { workspace.hideNetwork() }, closeLabel: "Close Network") {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(RelayViewerMetrics.icon).foregroundStyle(RelayTheme.textFaint)
                    Menu {
                        ForEach(NetworkDestination.allCases) { item in
                            Button(item.rawValue) { networkView = item.rawValue }
                        }
                    } label: {
                        Text("Network").font(RelayViewerMetrics.title).foregroundStyle(RelayTheme.text)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .controlSize(.small)
                    Text("\(scopedLinks.count) links").font(RelayViewerMetrics.meta).foregroundStyle(RelayTheme.textFaint)
                    Spacer(minLength: RelayViewerMetrics.barSpacing)
                } trailing: {
                    TextField("Find a session…", text: $search)
                        .textFieldStyle(.plain).font(RelayViewerMetrics.meta).frame(maxWidth: 190)
                        .accessibilityIdentifier("relay.network.search")
                    Menu {
                        Button("Link sessions…") { chosenConnections.removeAll(); panePicker = true }
                        Button("Connection settings…", action: manage)
                    } label: { RelayViewerMenuLabel(symbol: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("New link")
                    RelayViewerIconButton(title: "Show or hide details", symbol: "sidebar.right") { inspectorOpen.toggle() }
                }
                Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: RelayTheme.spacing(0)) {
                        browserContent.frame(minWidth: 440)
                        if inspectorOpen { hudInspector.frame(width: 270) }
                    }
                    VStack(spacing: RelayTheme.spacing(0)) {
                        browserContent
                        if inspectorOpen { hudInspector.frame(maxHeight: 240) }
                    }
                }
            }
            .frame(maxWidth: 1120, maxHeight: 500)
            .background(RelayTheme.canvas, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
            .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.85)))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(geometry.size.width < 760 ? 12 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hudInspector: some View {
        ScrollView {
            if let link = inspected {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                    NetworkConnectionDetails(status: link.displayState(now: now),
                        endpoints: [connectionEndpoint(link.sourceIdentity, fallbackName: link.localName),
                                    connectionEndpoint(link.destinationIdentity, fallbackName: link.remoteName)],
                        lastReceipt: receipt(link.lastReceipt))
                    if let error = link.error, !error.isEmpty { Text(error).foregroundStyle(RelayTheme.red) }
                    DisclosureGroup("Diagnostics") {
                        Text("Source: \(link.sourceLocation) / \(link.localSession)\nDestination: \(link.destinationIdentity.host) / \(link.remoteSession)")
                            .textSelection(.enabled)
                    }.font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                }.padding(RelayTheme.spacing(20))
            } else {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    Text("Select a connection").font(RelayTheme.font(size: 12, weight: .medium))
                    Text("View both sessions and their last observed turns.").font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                }.padding(RelayTheme.spacing(20))
            }
        }.background(RelayTheme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(RelayTheme.line).frame(width: 1) }
    }

    private var standardNetworkContent: some View {
        GeometryReader { geometry in
            VStack(spacing: RelayTheme.spacing(0)) {
                RelayViewerBar(symbol: "point.3.connected.trianglepath.dotted", title: "Network",
                               close: { workspace.hideNetwork() }, closeLabel: "Close Network") {
                    TextField("Search hosts, sessions or routes", text: $search)
                        .textFieldStyle(.plain).font(RelayViewerMetrics.meta).frame(maxWidth: 300)
                        .accessibilityIdentifier("relay.network.search")
                    Menu {
                        Button("Link a group of sessions…") { chosenConnections.removeAll(); panePicker = true }
                        Button("Other connection types…", action: manage)
                    } label: { Label("New link", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(RelayViewerMetrics.meta).foregroundStyle(RelayTheme.textMuted)
                    RelayViewerIconButton(title: "Show or hide details", symbol: "sidebar.right") { inspectorOpen.toggle() }
                        .help("Show or hide details")
                    Menu {
                        Toggle("Include inactive sessions", isOn: $showOffline)
                        Button("Refresh This Mac") { discover(host: nil) }
                        ForEach(hosts, id: \.self) { target in
                            Button("Refresh \(target)") { discover(host: target) }
                        }
                        Button("Advanced connection settings…", action: manage)
                    } label: { RelayViewerMenuLabel(symbol: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More network actions")
                }
                Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
                if geometry.size.width < 700 {
                    Picker("Destination", selection: $networkView) {
                        ForEach(NetworkDestination.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
                    }.padding(.horizontal, RelayTheme.spacing(16)).padding(.vertical, RelayTheme.spacing(8))
                } else {
                    HStack {
                        Picker("Destination", selection: $networkView) {
                            ForEach(NetworkDestination.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 680)
                        Spacer()
                    }.padding(.horizontal, RelayTheme.spacing(16)).padding(.vertical, RelayTheme.spacing(8))
                }
                HStack(spacing: RelayTheme.spacing(0)) {
                    VStack(spacing: RelayTheme.spacing(0)) {
                        if inspectorOpen && geometry.size.width < 1100 && networkView != "Live network" {
                            HStack {
                                Button("Back", systemImage: "chevron.left") { inspectorOpen = false }
                                Spacer()
                            }.padding(RelayTheme.spacing(12))
                            inspectionContent
                        } else {
                            browserContent
                            if inspectorOpen && networkView == "Live network" {
                                Divider()
                                HStack {
                                    Text("Connection details").font(.headline)
                                    Spacer()
                                    Button { inspectorOpen = false } label: { Image(systemName: "xmark") }
                                        .accessibilityLabel("Close connection details")
                                }.padding(.horizontal, RelayTheme.spacing(16)).padding(.top, RelayTheme.spacing(8))
                                inspectionContent.frame(maxHeight: 320)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorOpen && geometry.size.width >= 1100 && networkView != "Live network" {
                        Divider()
                        VStack(spacing: RelayTheme.spacing(0)) {
                            HStack {
                                Text("Details").font(.headline)
                                Spacer()
                                Button { inspectorOpen = false } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close details")
                            }.padding(RelayTheme.spacing(16))
                            inspectionContent
                        }.frame(width: 320)
                    }
                }
            }.background(RelayTheme.canvas)
        }
    }

    @ViewBuilder private var browserContent: some View {
        if networkView == "Live network" {
            NetworkTopologyGraph(participants: participants, links: links,
                transports: transportSnapshots, now: now, query: search,
                inspectLink: { selectRoute($0); inspectorOpen = true })
        } else if networkView == "Sessions & agents" {
            sessionsContent
        } else if networkView == "Link groups" {
            ScrollView { PeerNetworkLinksView().padding(RelayTheme.spacing(16)) }
        } else if networkView == "Approvals" {
            List {
                Section("Identity reviews") {
                    ForEach(links.filter { $0.evidence(now: now) == .needsReview }) { link in
                        Button("\(link.localName) → \(link.remoteName)") { selectRoute(link.pid); inspectorOpen = true }
                    }
                    if !links.contains(where: { $0.evidence(now: now) == .needsReview }) {
                        Label("No messaging identity changes to review", systemImage: "checkmark.shield")
                    }
                }
                Section("Connection requests") {
                    Text("Connection requests are reviewed in Relay's approval dialog. Approval does not establish route readiness.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Manage saved connections", action: manage)
                }
            }.listStyle(.inset)
        } else { liveLedger(history: true) }
    }

    private func liveLedger(history: Bool) -> some View {
        NetworkLiveLedger(
            profiles: workspace.panes.values.filter { $0.profile.kind == .ssh }.map(\.profile),
            transports: transportSnapshots, participants: participants, links: links,
            now: now, query: search, history: history, inspectLink: selectRoute,
            viewSessions: { networkView = "Sessions & agents" })
    }

    private func selectRoute(_ pid: Int) {
        guard let link = links.first(where: { $0.pid == pid }) else { return }
        selected = pid
        selectedRoute = link
        participant = nil
        reportedSelection = nil
    }

    @ViewBuilder private var inspectionContent: some View {
        if selectedRoute != nil { routeInspector } else { participantInspector }
    }

    private var sessionsContent: some View {
                    List(selection: $participant) {
                        ForEach(Array(Set(filteredParticipants.map { $0.id.host })).sorted(), id: \.self) { host in
                            Section(host == "This Mac" ? "Local peer · This Mac" : "Remote peer · \(host)") {
                                ForEach(NetworkParticipant.orderedForMap(filteredParticipants, host: host)) { peer in
                                    VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                        Label(peer.name, systemImage: peer.parentID == nil ? "terminal" : "arrow.turn.down.right").fontWeight(.medium)
                                        if let taskState = peer.taskState {
                                            Text(taskState).font(.caption.weight(.medium))
                                                .foregroundStyle(taskState == "Working now" ? Color.accentColor : Color.secondary)
                                        }
                                        sessionContext(peer)

                                    }.padding(.vertical, RelayTheme.spacing(4)).padding(.leading, peer.parentID == nil ? 0 : 20).tag(peer.id)
                                }
                            }
                        }
                    }
    }

    private var participantInspector: some View {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                            if let link = reportedSelection {
                                Text("Reported communication link").font(.headline)
                                detail("Host", link.host)
                                detail("Source session", link.report.sourceSession)
                                detail("Destination session", link.report.destinationSession)
                                detail("Source / destination processes", "\(link.report.sourcePID) / \(link.report.destinationPID)")
                                detail("Evidence", reportedLinks.contains(where: { $0.id == link.id }) ? "Current provider report; delivery not tested by Relay" : "Expired provider report; not shown as active")
                                Button("Close link details") { reportedSelection = nil }
                            } else if let peer = inspectedParticipant {
                                Text(peer.name).font(.title3.weight(.semibold))
                                if peer.externalEndpoint {
                                    Text("External endpoint · connected to a Relay session, not running in a Relay pane").foregroundStyle(.secondary)
                                } else if !participants.contains(where: { $0.id == peer.id }) {
                                    Label("No longer reported — showing last observation", systemImage: "clock")
                                        .foregroundStyle(.secondary)
                                } else if !peer.matches(search) {
                                    Text("Selected session is filtered out").foregroundStyle(.secondary)
                                    Button("Clear search") { search = "" }
                                }
                                detail("Peer", peer.id.host == "This Mac" ? "Local · This Mac" : "Remote · \(peer.id.host)")
                                detail("Messaging", peer.messagingLabel(now: now))
                                if let taskState = peer.taskState { detail("Task activity", taskState) }
                                if let parent = peer.parentID { detail("Owned by session", parent.session) }
                                if let paneID = peer.paneID { Button("Open pane") { workspace.revealPane(paneID, origin: .user) } }
                                Text("Activity").font(.headline)
                                detail("Last reported activity", peer.lastEvent ?? "Not reported")
                                detail("Last completed turn", peer.lastTurnAt?.formatted() ?? "Not observed in this Relay run")
                                if let reason = peer.identityStatus {
                                    Text(reason.explanation).font(.callout).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Session details") {
                                    VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                                        detail("Session ID", peer.boundPeer?.sessionId ?? peer.id.session)
                                        if let bound = peer.boundPeer { detail("Process", "\(bound.pid) · started \(bound.procStart ?? "unknown")") }
                                        detail("Provider", peer.provider ?? "Not reported")
                                        detail("Tab", peer.tabName ?? "Not in a Relay tab")
                                        detail("Working directory", peer.directory ?? "Not reported")
                                        if let date = peer.lastEventAt { detail("Activity time", date.formatted()) }
                                        detail("Pane state", peer.activity ?? "Unknown")
                                    }.padding(.top, RelayTheme.spacing(8))
                                }
                                if let teams = remoteDiscoveries[peer.id.host]?.teams {
                                    let memberships = teams.filter { $0.leadSessionId == peer.id.session }
                                    if !memberships.isEmpty {
                                        Text("Claude team metadata").font(.headline)
                                        Text("Membership is not proof of activity or communication. Unverified members are hidden in the active view.").font(.caption).foregroundStyle(.secondary)
                                        if showOffline {
                                            ForEach(Array(memberships.enumerated()), id: \.offset) { _, team in
                                                DisclosureGroup(team.name) {
                                                    ForEach(Array(team.members.enumerated()), id: \.offset) { _, member in
                                                        VStack(alignment: .leading) {
                                                            Text(member.name)
                                                            Text(member.agentId).textSelection(.enabled)
                                                            Text("\(member.agentType) · activity unknown").foregroundStyle(.secondary)
                                                        }.padding(.vertical, RelayTheme.spacing(4))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                detail("Topology reporting", reportedLinks.contains(where: { $0.source == peer.id || $0.destination == peer.id }) ? "Current provider link report available" : "No current provider link report; child-agent inventory unavailable")
                                Text("Communication").font(.headline)
                                ForEach(peer.links) { link in
                                    VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                        Text(peer.id == link.sourceIdentity ? link.remoteName : link.localName)
                                        Text(link.displayState(now: now)).foregroundStyle(.secondary)
                                        Button("Inspect connection") { selectRoute(link.pid); inspectorOpen = true }
                                    }
                                }
                                if peer.links.isEmpty { Text("No observed links. Use Manage connections to choose an exact session pair.").foregroundStyle(.secondary) }
                            } else {
                                Text("Select a session or agent").font(.headline)
                                Text("Inspect its peer, observed activity and messaging links.").foregroundStyle(.secondary)
                            }
                            if let discoveryError { Text(discoveryError).foregroundStyle(.secondary) }
                            Text("Agents appear inside their owning session. Connection records show observed communication, not ownership or task completion.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(RelayTheme.spacing(16))
                    }
    }

    private func connectionEndpoint(_ identity: NetworkParticipant.Identity, fallbackName: String) -> NetworkConnectionEndpoint {
        let participant = participants.first { $0.id == identity }
        let pane = participant?.paneID.flatMap { workspace.panes[$0] }
        let turn = pane?.lastNetworkConversationTurn ?? participant?.lastTurnAt.map {
            NetworkConversationTurn(occurredAt: $0, speaker: participant?.provider ?? "Agent", text: nil)
        }
        return NetworkConnectionEndpoint(id: "\(identity.host)/\(identity.session)",
            name: participant?.name ?? fallbackName, host: identity.host, turn: turn,
            openSession: pane.map { pane in { workspace.revealPane(pane.id, origin: .user) } })
    }

    private var routeInspector: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                        Text("Link details").font(.headline)
                        if let link = inspected {
                            NetworkConnectionDetails(status: link.displayState(now: now),
                                endpoints: [connectionEndpoint(link.sourceIdentity, fallbackName: link.localName),
                                            connectionEndpoint(link.destinationIdentity, fallbackName: link.remoteName)],
                                lastReceipt: receipt(link.lastReceipt))
                            if let error = link.error, !error.isEmpty { detail("Transport error", error) }
                            DisclosureGroup("Diagnostics") {
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                                    detail("Source host", link.sourceLocation)
                                    detail("Source session", link.localSession)
                                    detail("Destination session", link.remoteSession)
                                    detail("Last receipt", receipt(link.lastReceipt))
                                    if let id = link.lastMessageId { detail("Message ID", id) }
                                    detail("Reconnect attempts", String(link.attempt))
                                    Text("A socket receipt confirms transport delivery, not that the agent processed the message.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }.padding(.top, RelayTheme.spacing(8))
                            }
                        } else {
                            Text("Select a connection to inspect its endpoints and receipt.")
                                .foregroundStyle(.secondary)
                        }
                    }.padding(RelayTheme.spacing(18))
                }
    }

    private var panePickerContent: some View {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                Label("Choose sessions", systemImage: "link").font(.headline)
                Text("Select panes from any tab.").font(.caption).foregroundStyle(.secondary)
                if !requestedPaneIDs.isEmpty && seededPaneIDs.count < requestedPaneIDs.count {
                    Text("\(seededPaneIDs.count) of \(requestedPaneIDs.count) selected panes verified. Unresolved or disconnected panes cannot be linked.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let startingPaneID, let pane = workspace.panes[startingPaneID] {
                    Text("Starting pane: \(pane.displayName) on \(pane.profile.kind == .ssh ? pane.profile.host : "This Mac")")
                        .font(.callout.weight(.medium))
                    if !seededStartingPane { Text("Verifying this pane’s messaging identity…").font(.caption).foregroundStyle(.secondary) }
                }
                List {
                    ForEach(workspace.tabs) { tab in
                        Section(tab.name) {
                            ForEach(participants.filter { node in node.parentID == nil && node.paneID.map { tab.allPaneIDs.contains($0) } == true }) { node in
                                Button { chooseConnection(node) } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: chosenConnections[node.id] == nil ? "circle" : "checkmark.circle.fill")
                                        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                            Text(node.name).fontWeight(.medium)
                                            Text(node.directory ?? node.id.host).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                            if !node.discovered {
                                                Text(node.messagingLabel(now: now))
                                                    .foregroundStyle(node.identityStatus == .noAgent ? Color.secondary : Color.orange)
                                                    .font(.caption).help(node.identityStatus?.explanation ?? "")
                                            }
                                        }
                                        Spacer()
                                    }.padding(RelayTheme.spacing(8)).contentShape(Rectangle())
                                        .background(chosenConnections[node.id] == nil ? Color.clear : Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                                }.buttonStyle(.plain).padding(.vertical, RelayTheme.spacing(4))
                            }
                        }
                    }
                }
                if let desktopDiscoveryError { Text(desktopDiscoveryError).foregroundStyle(.orange) }
                if let selectionError { Text(selectionError).foregroundStyle(.orange) }
                HStack {
                    Text("\(chosenConnections.count) selected · up to 8")
                    Button("Clear") { chosenConnections.removeAll(); selectionError = nil }
                    Spacer()
                    Button("Cancel") { if connectionOnly { dismiss() } else { panePicker = false } }
                    Button("Review connections…") {
                        if connectionOnly { groupSheet = true }
                        else { reviewAfterPicker = true; panePicker = false }
                    }
                        .disabled(chosenConnections.count < 2 || (!requestedPaneIDs.isEmpty && seededPaneIDs.count < requestedPaneIDs.count))
                }
            }.padding(RelayTheme.spacing(20)).frame(width: 520, height: 480)
    }

    private var discoveryAnchor: some View {
        Color.clear.frame(width: 0, height: 0)
        .task {
            let directory = RelayStateProfile.peerNetworkStatusRoot
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { PeerNetworkStatus.read(directory: directory) }.value
                guard !Task.isCancelled else { return }
                links = result
                transportSnapshots = RelayNodeTransportPool.shared.networkSnapshots()
                now = Date()
                if let host, !result.contains(where: { $0.host == host }) { self.host = nil }
                if let current = participants.first(where: { $0.id == participant }) {
                    lastInspectedParticipant = current
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task {
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) {
                    Result { try DesktopPeerRoute.loadedTaskDetails() }
                }.value
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let tasks):
                    desktopTasks = tasks
                    desktopTaskObservedAt = Date()
                    desktopDiscoveryError = nil
                case .failure(let error):
                    desktopTaskObservedAt = nil
                    desktopDiscoveryError = DesktopPeerRoute.discoveryMessage(error)
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task {
            guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
            let peerExecutable = directory.appendingPathComponent("relay-peer-link")
            let relaydExecutable = directory.appendingPathComponent("relayd")
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) {
                    Result { try PeerDiscovery.localCombined(peerExecutable: peerExecutable, relaydExecutable: relaydExecutable) }
                }.value
                guard !Task.isCancelled else { return }
                checkedHosts.insert("This Mac")
                switch result {
                case .success(let value):
                    localPeers = value.peers
                    discoveryFailures.removeValue(forKey: "This Mac")
                    discoveryDates["This Mac"] = Date()
                    seedStartingPane()
                    discoveryError = value.truncated ? "Local discovery was truncated." : nil
                case .failure(let error):
                    let reason = PeerDiscovery.failureSummary(error)
                    discoveryFailures["This Mac"] = reason
                    discoveryError = reason + " Showing the last observation; session liveness is unknown."
                    RelayDiagnostics.shared.record(category: "network", name: "peer-discovery-failed", details: ["host": "This Mac", "reason": reason])
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .task {
            // Only revisit hosts already configured for messaging. Never scan
            // arbitrary SSH aliases or create communication links during discovery.
            var retryAfter: [String: Date] = [:]
            while !Task.isCancelled {
                for target in hosts.prefix(16) {
                    guard !Task.isCancelled else { return }
                    checkedHosts.insert(target)
                    if discoveringHost != nil || (retryAfter[target] ?? .distantPast) > Date() { continue }
                    let result = await Task.detached(priority: .utility) {
                        Result { try PeerDiscovery.remotePanes(host: target) }
                    }.value
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(let value):
                        remoteDiscoveries[target] = value
                        discoveryFailures.removeValue(forKey: target)
                        discoveryDates[target] = Date()
                        seedStartingPane()
                        retryAfter[target] = Date().addingTimeInterval(20)
                    case .failure(let error):
                        discoveryFailures[target] = PeerDiscovery.failureSummary(error)
                        // Preserve history without extending its active lifetime.
                        retryAfter[target] = Date().addingTimeInterval(60)
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: participant) { _, id in
            if id != nil { reportedSelection = nil; selectedRoute = nil }
            lastInspectedParticipant = participants.first { $0.id == id }
        }
    }

    private func endpoint(_ name: String, subtitle: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(7)) {
            Label(subtitle, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.body.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func discover(host target: String?) {
        guard discoveringHost == nil else { return }
        discoveringHost = target ?? "This Mac"
        let label = target ?? "This Mac"
        discoveryStatus = "Checking \(label)… Existing observations are retained."
        Task {
            defer { discoveringHost = nil; checkedHosts.insert(label) }
            do {
                let result = try await Task.detached(priority: .utility) {
                    if let target {
                        return try PeerDiscovery.remotePanes(host: target)
                    }
                    guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { throw CocoaError(.fileNoSuchFile) }
                    return try PeerDiscovery.localCombined(
                        peerExecutable: directory.appendingPathComponent("relay-peer-link"),
                        relaydExecutable: directory.appendingPathComponent("relayd"))
                }.value
                if let target { remoteDiscoveries[target] = result } else { localPeers = result.peers }
                discoveryDates[label] = Date()
                discoveryFailures.removeValue(forKey: label)
                seedStartingPane()
                discoveryStatus = "\(label): \(result.peers.count) sessions, \(result.links?.count ?? 0) reported links checked at \(Date().formatted(date: .omitted, time: .standard)). \(result.truncated ? "Partial results. " : "")No connections created."
            } catch {
                discoveryFailures[label] = PeerDiscovery.failureSummary(error)
                discoveryStatus = "\(label): discovery unavailable. Previous observations retained, not reverified. Check SSH and the installed peer helper."
            }
        }
    }

    private func chooseConnection(_ node: NetworkParticipant) {
        if let paneID = node.paneID, requestedPaneIDs.contains(paneID) { return }
        if chosenConnections.removeValue(forKey: node.id) != nil { selectionError = nil; return }
        guard chosenConnections.count < 8 else { selectionError = "Choose at most eight sessions."; return }
        let endpoint: PeerGroupPlan.Endpoint
        if node.taskState != nil && node.id.local {
            guard DesktopPeerRoute.read().contains(where: { $0.thread == node.id.session }) else {
                selectionError = "This endpoint is not a saved desktop task route."; return
            }
            endpoint = .init(kind: .desktop, host: "laptop", session: node.id.session, name: node.name, pid: nil, processStart: nil)
        } else {
            guard let paneID = node.paneID, let pane = workspace.panes[paneID], pane.connectionState == .connected else {
                selectionError = "Reconnect this pane before selecting its session."; return
            }
            let observedAt = discoveryDates[node.id.host]
            guard PeerDiscovery.isFresh(observedAt, now: Date()) else { selectionError = "Refresh discovery before selecting this session."; return }
            let peers = node.id.local ? localPeers : remoteDiscoveries[node.id.host]?.peers ?? []
            let matches: [DiscoveredPeer]
            if pane.profile.kind == .local {
                matches = NetworkParticipant.localPeersForPane(peers, paneID: pane.id.uuidString.lowercased(), foregroundPID: pane.networkForegroundPID)
            } else {
                matches = NetworkParticipant.peersForPane(peers, paneID: paneID.uuidString.lowercased(), roots: pane.networkAgentRoots)
            }
            guard matches.count == 1, let peer = matches.first, let start = peer.procStart,
                  let bound = node.boundPeer, peer.pid == bound.pid, peer.procStart == bound.procStart,
                  peer.sessionId == bound.sessionId, peer.name == bound.name else {
                selectionError = "This pane does not yet have a unique messaging identity."; return
            }
            endpoint = .init(kind: .native, host: node.id.local ? "laptop" : node.id.host,
                session: peer.sessionId, name: peer.name, pid: peer.pid, processStart: start)
        }
        chosenConnections[node.id] = endpoint
        selectionError = nil
    }

    private func seedStartingPane() {
        for id in requestedPaneIDs.subtracting(seededPaneIDs) {
            guard let node = participants.first(where: { $0.paneID == id && $0.parentID == nil }), node.discovered else { continue }
            chooseConnection(node)
            if chosenConnections[node.id] != nil { seededPaneIDs.insert(id) }
        }
        // Direct pane selection already chose membership. Once identities are
        // verified, freeze them for review instead of asking the user to pick again.
        if connectionOnly, !requestedPaneIDs.isEmpty, verifiedPaneSelection == nil,
           seededPaneIDs == requestedPaneIDs, chosenConnections.count >= 2 {
            verifiedPaneSelection = chosenConnections.values.sorted { $0.id < $1.id }
        }
        guard !seededStartingPane, let startingPaneID,
              let node = participants.first(where: { $0.paneID == startingPaneID && $0.parentID == nil }),
              node.discovered else { return }
        chooseConnection(node)
        seededStartingPane = chosenConnections[node.id] != nil
    }

    private func sessionContext(_ peer: NetworkParticipant) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
            if let directory = peer.directory {
                Text(directory).lineLimit(1).truncationMode(.middle).help(directory)
            }
            Text([peer.provider, peer.tabName, peer.activity].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            if let date = peer.lastEventAt {
                Text("\(peer.lastEvent ?? "Activity") · \(date.formatted(date: .abbreviated, time: .shortened))")
            }
            if let date = peer.lastTurnAt { Text("Last turn · \(date.formatted(date: .abbreviated, time: .shortened))") }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func receipt(_ value: String?) -> String {
        switch value {
        case "socket-written", "written_to_socket": "Written to the receiving socket"
        case "admitted": "Accepted by desktop · processing not confirmed"
        case "not_sent": "Not delivered · no automatic replay"
        case "unknown": "Delivery uncertain · no automatic replay"
        case "failed": "Delivery outcome unknown · do not replay"
        case "duplicate": "Duplicate suppressed"
        default: "No receipt"
        }
    }
}
