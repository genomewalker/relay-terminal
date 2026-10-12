import SwiftUI

/// Explicit configuration controls. No messages are fetched, replayed or executed.
struct PeerNetworkLinksView: View {
    @ObservedObject private var controller = PeerNetworkController.shared
    @State private var links: [PeerNetworkStatus] = []
    @State private var observedAt = Date()
    @State private var adding = false
    @State private var addingDesktop = false
    @State private var addingGroup = false
    @State private var desktopRoutes: [DesktopPeerRoute] = []
    @State private var connectionRecords: [DesktopPeerRoute.ConnectionRecord] = []
    @State private var handoffRoute: DesktopPeerRoute?
    @State private var changingRoute: String?

    private var directory: URL {
        RelayStateProfile.peerNetworkStatusRoot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
            HStack {
                Label("Session network", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.semibold))
                Spacer()
                Menu("Add connection") {
                    Button("Link a group of sessions…") { addingGroup = true }
                    Button("Desktop task to remote agent…") { addingDesktop = true }
                    Button("Two native agent sessions…") { adding = true }
                }
            }
            Text("Local and remote session links. Connected means the link is alive—not that an agent has processed a message.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !desktopRoutes.isEmpty {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                    Text("Desktop tasks").font(.headline)
                    ForEach(desktopRoutes) { route in
                        let status = links.first(where: route.matches)
                        let connected = status?.displayState(now: observedAt) == "Connected"
                        HStack {
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                Text("\(route.remoteName) on \(route.host)").fontWeight(.medium)
                                Text("Desktop task \(route.thread)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let record = connectionRecords.first(where: { $0.replyName == route.localName }),
                                   record.tasks.count > 1 {
                                    Text("Continued across \(record.tasks.count) tasks")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(status?.displayState(now: observedAt) ?? "Not connected").font(.caption)
                            }
                            Spacer()
                            Button("Continue in another task…") { handoffRoute = route }
                            Button(connected ? "Disconnect" : "Connect") {
                                changingRoute = route.id
                                Task {
                                    do { try await Task.detached(priority: .utility) { try route.setConnected(!connected) }.value }
                                    catch { controller.error = error.localizedDescription }
                                    changingRoute = nil
                                }
                            }.disabled(changingRoute != nil)
                        }
                    }
                    Text("Disconnect stops messaging only. Tasks and terminals keep running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Divider()
            }
            if !controller.configurations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                        ForEach(controller.configurations) { configuration in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(configuration.host): \(configuration.remoteName)")
                                    Text("From \(configuration.localName)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controller.running.contains(configuration.id) {
                                    Button("Disconnect") { controller.disconnect(configuration) }
                                } else {
                                    Button("Connect") { controller.connect(configuration, observed: links) }
                                    Button("Remove") { controller.remove(configuration) }
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 130)
                Divider()
            }
            if links.isEmpty {
                ContentUnavailableView("No configured links", systemImage: "network",
                    description: Text("Add a link with the exact local and remote peer identities. The remote helper must already be installed. Relay will not create or terminate agent sessions."))
            } else {
                Table(links) {
                    TableColumn("Host") { row in Text(row.host).textSelection(.enabled) }
                        .width(min: 90, ideal: 120)
                    TableColumn("Sessions") { row in
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                            Text(row.localName).lineLimit(1).help(row.localSession)
                            Label(row.remoteName, systemImage: "arrow.turn.down.right")
                                .foregroundStyle(.secondary).lineLimit(1).help(row.remoteSession)
                        }.padding(.vertical, RelayTheme.spacing(4))
                    }.width(min: 240, ideal: 350)
                    TableColumn("Connection") { row in
                        Text(row.displayState(now: observedAt))
                            .help(row.error ?? "No transport error reported")
                    }.width(min: 140, ideal: 160)
                    TableColumn("Round trip") { row in
                        Text(row.displayState(now: observedAt) == "Connected" ? row.latencyLabel : "—")
                            .monospacedDigit()
                    }.width(80)
                    TableColumn("Last receipt") { row in
                        Text(receiptLabel(row.lastReceipt)).help(row.lastMessageId ?? "No message receipt")
                    }.width(min: 120, ideal: 150)
                }
            }
            Text("Messages arrive through native inboxes. This view reads connection metadata only. Offline queues and Chitta synchronization are not enabled.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(RelayTheme.spacing(20))
        .frame(minWidth: 860, minHeight: 360)
        .sheet(isPresented: $adding) {
            PeerLinkSetupView {
                controller.save($0) ? nil : (controller.error ?? "Could not save the link.")
            }
        }
        .sheet(isPresented: $addingDesktop) { DesktopRouteSetupView() }
        .sheet(item: $handoffRoute) { DesktopRouteHandoffView(route: $0) }
        .sheet(isPresented: $addingGroup) { PeerGroupSetupView() }
        .alert("Peer link", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .task {
            let location = directory
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) {
                    (PeerNetworkStatus.read(directory: location), DesktopPeerRoute.read(),
                     (try? DesktopPeerRoute.connections()) ?? [])
                }.value
                guard !Task.isCancelled else { return }
                links = result.0
                desktopRoutes = result.1
                connectionRecords = result.2
                observedAt = Date()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func receiptLabel(_ receipt: String?) -> String {
        switch receipt {
        case "socket-written", "written_to_socket": "Written to socket"
        case "admitted": "Accepted by desktop"
        case "not_sent": "Not delivered"
        case "unknown": "Delivery uncertain"
        case "failed": "Delivery failed"
        case "duplicate": "Duplicate suppressed"
        default: "None"
        }
    }
}

private struct DesktopRouteHandoffView: View {
    @Environment(\.dismiss) private var dismiss
    let route: DesktopPeerRoute
    @State private var tasks: [String] = []
    @State private var selected = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
            Text("Continue this connection").font(.title2.weight(.semibold))
            Text("Move the reply route from task \(route.thread) to an open task. The remote agent keeps the same reply address. No messages or chat history are copied.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("New desktop task", selection: $selected) {
                Text("Choose a task").tag("")
                ForEach(tasks.filter { $0 != route.thread }, id: \.self) { Text($0).tag($0) }
            }
            Button("Refresh open tasks") { loadTasks() }.disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button("Move and connect") { move() }.disabled(busy || selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(RelayTheme.spacing(24)).frame(width: 560)
        .onAppear { loadTasks() }
    }

    private func loadTasks() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { tasks = try await Task.detached { try DesktopPeerRoute.loadedTasks() }.value }
            catch { self.error = error.localizedDescription }
        }
    }

    private func move() {
        let task = selected
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try route.handoff(to: task) }.value
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DesktopRouteSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [String] = []
    @State private var thread = ""
    @State private var host = ""
    @State private var peers: [DiscoveredPeer] = []
    @State private var selectedPID = 0
    @State private var busy = false
    @State private var error: String?
    private var peer: DiscoveredPeer? { peers.first { $0.pid == selectedPID } }
    private var savedRoute: DesktopPeerRoute? {
        guard let peer else { return nil }
        return DesktopPeerRoute.read().first {
            $0.thread == thread && $0.host == host && $0.remoteSession == peer.sessionId
        }
    }
    private var needsRebind: Bool {
        guard let peer, let savedRoute else { return false }
        return savedRoute.remotePID != peer.pid || savedRoute.remoteStart != peer.procStart ||
            savedRoute.remoteName != peer.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
            Text("Connect a desktop task").font(.title2.weight(.semibold))
            Text("Choose the two endpoints once. Relay remembers the reply route and reconnects after SSH interruptions.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Section("This Mac") {
                    Picker("Open desktop task", selection: $thread) {
                        Text("Choose a task").tag("")
                        ForEach(tasks, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Refresh open tasks") { loadTasks() }
                    Text("Only already-open tasks are listed. Relay never resumes a closed task.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Remote agent") {
                    TextField("SSH host", text: $host).textFieldStyle(.roundedBorder)
                    Button("Find sessions") { discover() }.disabled(host.isEmpty)
                    Picker("Session", selection: $selectedPID) {
                        Text("Choose a session").tag(0)
                        ForEach(peers) { Text("\($0.name) (\($0.pid))").tag($0.pid) }
                    }
                    if let peer {
                        Text(peer.sessionId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if needsRebind, let savedRoute, let peer {
                        Text("Saved process \(savedRoute.remotePID) has ended. Rebind this route to the selected process \(peer.pid) for the same session.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped).disabled(busy)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(needsRebind ? "Rebind and connect" : "Connect and remember") { connect() }
                    .keyboardShortcut(.defaultAction).disabled(busy || thread.isEmpty || peer?.procStart == nil)
            }
        }.padding(RelayTheme.spacing(24)).frame(width: 590, height: 520)
        .onAppear { loadTasks() }
        .onChange(of: host) { _, _ in peers = []; selectedPID = 0 }
    }

    private func loadTasks() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                tasks = try await Task.detached { try DesktopPeerRoute.loadedTasks() }.value
                if !tasks.contains(thread) { thread = "" }
                if tasks.isEmpty { error = "No open desktop tasks. Open the intended task, then refresh." }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func discover() {
        let target = host
        busy = true; error = nil; peers = []; selectedPID = 0
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached {
                    try PeerDiscovery.remote(host: target, helper: ".local/share/relay/peer-network/relay-peer-link")
                }.value
                guard host == target else { return }
                peers = result.peers.filter { $0.procStart != nil }
                if peers.isEmpty { error = "No compatible sessions found. Check the host and update its Relay peer helper." }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func connect() {
        guard let peer else { return }
        let task = thread, target = host, rebind = needsRebind
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try DesktopPeerRoute.remember(thread: task, host: target, peer: peer, rebind: rebind) }.value
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PeerLinkSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = PeerLinkConfiguration()
    @State private var peers: [DiscoveredPeer] = []
    @State private var discovering = false
    @State private var discoveryMessage: String?
    @State private var remotePeers: [DiscoveredPeer] = []
    @State private var discoveringRemote = false
    @State private var remoteDiscoveryMessage: String?
    @State private var saveError: String?
    let save: (PeerLinkConfiguration) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
            Text("Connect two agent sessions").font(.title2.weight(.semibold))
            Text("Use exact native peer identities. Saving does not connect. SSH must already authenticate without a prompt; the connection never types into a terminal.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Section("Local endpoint") {
                    Button(discovering ? "Finding sessions…" : "Find local sessions") {
                        discovering = true
                        discoveryMessage = nil
                        Task {
                            do {
                                guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                                    .appendingPathComponent("relay-peer-link") else { throw CocoaError(.fileNoSuchFile) }
                                let result = try await Task.detached(priority: .utility) {
                                    try PeerDiscovery.local(executable: executable)
                                }.value
                                peers = result.peers
                                discoveryMessage = result.truncated ? "Partial list; some registry entries were not inspected." :
                                    (peers.isEmpty ? "No verified local sessions found." : nil)
                            } catch { discoveryMessage = error.localizedDescription }
                            discovering = false
                        }
                    }.disabled(discovering)
                    if !peers.isEmpty {
                        Menu("Choose local session") {
                            ForEach(peers) { peer in
                                Button("\(peer.name) — process \(peer.pid)") {
                                    configuration.localName = peer.name
                                    configuration.localSession = peer.sessionId
                                    configuration.localPID = String(peer.pid)
                                }
                            }
                        }
                    }
                    if let discoveryMessage { Text(discoveryMessage).font(.caption) }
                    TextField("Host label", text: $configuration.localLabel)
                    TextField("Peer name", text: $configuration.localName)
                    TextField("Session ID", text: $configuration.localSession)
                    TextField("Process ID", text: $configuration.localPID)
                }
                Section("Remote endpoint") {
                    TextField("SSH host alias", text: $configuration.host)
                    Button(discoveringRemote ? "Finding sessions…" : "Find remote sessions") {
                        let host = configuration.host
                        let helper = configuration.remoteBinary
                        discoveringRemote = true
                        remotePeers = []
                        remoteDiscoveryMessage = nil
                        Task {
                            defer { discoveringRemote = false }
                            do {
                                let result = try await Task.detached(priority: .utility) {
                                    try PeerDiscovery.remote(host: host, helper: helper)
                                }.value
                                guard configuration.host == host, configuration.remoteBinary == helper else { return }
                                remotePeers = result.peers
                                remoteDiscoveryMessage = result.truncated ? "Partial list; some registry entries were not inspected." :
                                    (remotePeers.isEmpty ? "No verified sessions on this host." : nil)
                            } catch {
                                guard configuration.host == host, configuration.remoteBinary == helper else { return }
                                remoteDiscoveryMessage = error.localizedDescription
                            }
                        }
                    }.disabled(discoveringRemote || configuration.host.isEmpty)
                    if !remotePeers.isEmpty {
                        Menu("Choose remote session") {
                            ForEach(remotePeers) { peer in
                                Button("\(peer.name) — process \(peer.pid)") {
                                    configuration.remoteName = peer.name
                                    configuration.remoteSession = peer.sessionId
                                    configuration.remotePID = String(peer.pid)
                                    configuration.remoteStart = peer.procStart
                                    if configuration.remoteLabel.isEmpty { configuration.remoteLabel = configuration.host }
                                }
                            }
                        }
                    }
                    if let remoteDiscoveryMessage { Text(remoteDiscoveryMessage).font(.caption) }
                    TextField("Host label", text: $configuration.remoteLabel)
                    TextField("Peer name", text: $configuration.remoteName)
                    TextField("Session ID", text: $configuration.remoteSession)
                    TextField("Process ID", text: $configuration.remotePID)
                    TextField("Process start identity", text: Binding(
                        get: { configuration.remoteStart ?? "" },
                        set: { configuration.remoteStart = $0.isEmpty ? nil : $0 }))
                    TextField("Installed helper path", text: $configuration.remoteBinary)
                }
            }.formStyle(.grouped)
            if let error = configuration.validationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save link") {
                    saveError = save(configuration)
                    if saveError == nil { dismiss() }
                }
                    .disabled(configuration.validationError != nil).keyboardShortcut(.defaultAction)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
        }.padding(RelayTheme.spacing(20)).frame(width: 620, height: 630)
        .onChange(of: configuration.host) { _, _ in invalidateRemoteSelection() }
        .onChange(of: configuration.remoteBinary) { _, _ in invalidateRemoteSelection() }
    }

    private func invalidateRemoteSelection() {
        remotePeers = []
        remoteDiscoveryMessage = nil
        configuration.remoteName = ""
        configuration.remoteSession = ""
        configuration.remotePID = ""
        configuration.remoteStart = nil
    }
}
