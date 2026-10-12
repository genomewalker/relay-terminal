import SwiftUI

struct PeerGroupSetupView: View {
    private let capturedSelection: Bool
    let endpoints: [PeerGroupPlan.Endpoint]
    var addMore: (() -> Void)? = nil
    init(endpoints: [PeerGroupPlan.Endpoint] = [], addMore: (() -> Void)? = nil) {
        self.endpoints = endpoints
        self.addMore = addMore
        capturedSelection = !endpoints.isEmpty
        _candidates = State(initialValue: endpoints)
        _selected = State(initialValue: Set(endpoints.map(\.id)))
        _topology = State(initialValue: endpoints.count == 2 ? .everyone : .coordinator)
        _coordinator = State(initialValue: endpoints.first(where: { $0.kind == .desktop })?.id ?? "")
    }
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PeerGroupPlan.Endpoint] = []
    @State private var selected: Set<String> = []
    @State private var host = ""
    @State private var purpose = ""
    @State private var autonomous = false
    @State private var topology = PeerGroupPlan.Topology.coordinator
    @State private var coordinator = ""
    @State private var busy = false
    @State private var reviewing = false
    @State private var error: String?
    @State private var receipt: String?
    @State private var groupID = UUID()
    @State private var submitted = false
    private var plan: PeerGroupPlan {
        .init(id: groupID, participants: candidates.filter { selected.contains($0.id) },
              topology: topology, coordinatorID: coordinator, purpose: purpose, autonomous: autonomous)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                Label(reviewing ? "Review collaboration" : "Link sessions", systemImage: "link").font(RelayTheme.font(size: 16, weight: .medium))
            }
            if reviewing {
                Text("Only connected routes will be introduced. Group membership grants no additional permissions.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(18)) {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                            Text("Connections").font(.headline)
                            ForEach(plan.edges) { edge in
                                Text("\(edge.source.name) on \(edge.source.host) ↔ \(edge.destination.name) on \(edge.destination.host)")
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                            Text(autonomous ? "Shared task" : "Purpose").font(.headline)
                            Text(purpose.isEmpty ? "No shared task specified." : purpose).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                            Text("Working agreement").font(.headline)
                            Text(plan.workingAgreement).font(.callout).textSelection(.enabled)
                        }
                        Text("Each session receives the task, agreement and verified reply routes. No automatic message retries.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let warning = plan.transportError { Text(warning).foregroundStyle(.orange) }
            } else {
                if !capturedSelection { HStack {
                    Button("Find desktop tasks") { discoverDesktop() }
                    TextField("SSH host", text: $host).textFieldStyle(.roundedBorder)
                    Button("Find remote sessions") { discoverRemote() }.disabled(host.isEmpty)
                }.disabled(busy) }
                if capturedSelection {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(9)) {
                        HStack {
                            Label("Included sessions", systemImage: "checkmark.circle.fill")
                                .font(RelayTheme.font(size: 12, weight: .medium))
                            Spacer()
                            Text("\(candidates.count) selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(spacing: RelayTheme.spacing(6)) {
                                ForEach(candidates) { endpoint in
                                    HStack(spacing: RelayTheme.spacing(10)) {
                                        Image(systemName: endpoint.kind == .native ? "terminal" : "bubble.left.and.bubble.right")
                                            .font(RelayTheme.font(size: 13, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 24, height: 24)
                                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                                        VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                            Text(endpoint.name).font(RelayTheme.font(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                            Text("\(endpoint.host == "laptop" ? "This Mac" : endpoint.host) · \(endpoint.session)")
                                                .font(RelayTheme.font(size: 9.5, design: .monospaced))
                                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "lock.fill").font(RelayTheme.font(size: 9)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, RelayTheme.spacing(9)).padding(.vertical, RelayTheme.spacing(7))
                                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                                    .help("\(endpoint.name) · \(endpoint.host) · \(endpoint.session)")
                                }
                            }
                        }
                        .frame(height: CGFloat(min(4, candidates.count)) * 48)
                        if let addMore {
                            Button(action: addMore) {
                                Label("Add another session…", systemImage: "plus.circle")
                                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(8))
                            }
                            .buttonStyle(.plain)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                            .accessibilityIdentifier("relay.peer-group.add-session")
                        }
                    }
                    .padding(RelayTheme.spacing(10))
                    .background(RelayTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
                } else {
                List(candidates) { endpoint in
                    Toggle(isOn: Binding(get: { selected.contains(endpoint.id) }, set: { checked in
                        if checked { selected.insert(endpoint.id) } else { selected.remove(endpoint.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text("\(endpoint.name) on \(endpoint.host)")
                            Text(endpoint.session).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(busy || (!selected.contains(endpoint.id) && selected.count >= 8))
                }.frame(height: 160)
                }
                if candidates.count > 2 { Picker("Connections", selection: $topology) {
                    Text("Through a coordinator").tag(PeerGroupPlan.Topology.coordinator)
                    Text("Everyone to everyone").tag(PeerGroupPlan.Topology.everyone)
                } }
                if topology == .coordinator {
                    Picker("Coordinator", selection: $coordinator) {
                        Text("Choose a selected session").tag("")
                        ForEach(plan.participants) { Text("\($0.name) on \($0.host)").tag($0.id) }
                    }
                }
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    Picker("Working mode", selection: $autonomous) {
                        Text("Message").tag(false)
                        Text("Collaborate").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(autonomous ? "Work autonomously on the task below." : "Exchange messages without assigning work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    HStack {
                        Text(autonomous ? "Shared task" : "Purpose").font(.headline)
                        Text(autonomous ? "Required" : "Optional").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(autonomous ? "What should they accomplish together?" : "What is this connection for?", text: $purpose, axis: .vertical)
                        .lineLimit(3...5).textFieldStyle(.plain).padding(RelayTheme.spacing(12))
                        .background(RelayTheme.canvas, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
                        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).strokeBorder(.secondary.opacity(0.25)))
                        .accessibilityLabel(autonomous ? "Shared task (required)" : "Shared purpose (optional)")
                }
                Text(autonomous ? "They coordinate directly. You still approve sensitive actions and changes outside the task." : "Nothing is sent until you review and confirm.")
                    .font(.caption).foregroundStyle(.secondary)
                if plan.crossHostNativePair != nil {
                    Text("This starts a direct SSH peer link for the selected pair. Group purpose introductions are not sent on this route.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let receipt { Text(receipt).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(submitted ? "Close" : "Cancel") { dismiss() }.disabled(busy)
                if reviewing && !submitted { Button("Back") { reviewing = false }.disabled(busy) }
                if !submitted {
                    Button(reviewing ? (plan.crossHostNativePair == nil ? "Connect and introduce" : "Start direct link") : "Review connections") {
                        if reviewing { apply() } else { reviewing = true }
                    }.buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(busy || plan.validationError != nil || (reviewing && plan.transportError != nil))
                }
            }
        }.padding(RelayTheme.spacing(20)).frame(width: capturedSelection ? 540 : 500)
            .frame(height: reviewing ? 480 : nil)
            .onChange(of: endpoints.map(\.id)) { _, _ in
                guard capturedSelection else { return }
                candidates = endpoints
                selected = Set(endpoints.map(\.id))
            }
    }

    private func modeOption(_ value: Bool, title: String, detail: String) -> some View {
        Button { autonomous = value } label: {
            HStack(alignment: .top, spacing: RelayTheme.spacing(8)) {
                Image(systemName: autonomous == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(autonomous == value ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(RelayTheme.spacing(12)).frame(maxWidth: .infinity, alignment: .leading)
                .background(autonomous == value ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
                .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).strokeBorder(autonomous == value ? Color.accentColor : Color.secondary.opacity(0.25)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityValue(autonomous == value ? "Selected" : "Not selected")
            .disabled(busy)
    }

    private func discoverDesktop() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let tasks = try await Task.detached { try DesktopPeerRoute.loadedTasks() }.value
                let additions = tasks.map { PeerGroupPlan.Endpoint(kind: .desktop, host: "laptop", session: $0,
                    name: "desktop-" + String($0.prefix(8)), pid: nil, processStart: nil) }
                candidates.removeAll { $0.kind == .desktop }
                candidates += additions
            } catch { self.error = error.localizedDescription }
        }
    }
    private func discoverRemote() {
        let target = host
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached {
                    try PeerDiscovery.remote(host: target, helper: ".local/share/relay/peer-network/relay-peer-link")
                }.value
                candidates.removeAll { $0.kind == .native && $0.host == target }
                candidates += result.peers.map { .init(kind: .native, host: target, session: $0.sessionId,
                    name: $0.name, pid: $0.pid, processStart: $0.procStart) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func apply() {
        let reviewed = plan
        if let pair = reviewed.crossHostNativePair {
            if let message = PeerNetworkController.shared.connectNativePair(local: pair.local, remote: pair.remote) {
                error = message
            } else {
                receipt = "Direct SSH link process started. Check Network → Connections for its live status. The group purpose was not sent."
                submitted = true
            }
            return
        }
        busy = true; submitted = true; error = nil
        Task {
            defer { busy = false }
            do {
                receipt = try await Task.detached { try DesktopPeerRoute.applyGroup(reviewed) }.value
            } catch { self.error = error.localizedDescription + " Introductions will not be automatically retried." }
        }
    }
}
