import SwiftUI

/// Stable endpoint identities, independent of labels, discovery order, or selection.
struct NetworkTopologyProjection {
    struct Node: Identifiable {
        let id: NetworkParticipant.Identity
        let name: String
    }
    let links: [PeerNetworkStatus]
    let nodes: [Node]
    let hosts: [String]

    init(links: [PeerNetworkStatus], participants: [NetworkParticipant], query: String) {
        let names = Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.links = links.filter { link in
            link.state != "stopped" && (term.isEmpty || [link.localName, link.remoteName,
                link.localSession, link.remoteSession, link.host, link.sourceLocation,
                names[link.sourceIdentity] ?? "", names[link.destinationIdentity] ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(term) })
        }.sorted { $0.pid < $1.pid }
        var endpoints: [NetworkParticipant.Identity: Node] = [:]
        for link in self.links {
            endpoints[link.sourceIdentity] = Node(id: link.sourceIdentity, name: names[link.sourceIdentity] ?? link.localName)
            endpoints[link.destinationIdentity] = Node(id: link.destinationIdentity, name: names[link.destinationIdentity] ?? link.remoteName)
        }
        nodes = endpoints.values.sorted { ($0.id.host, $0.name, $0.id.session) < ($1.id.host, $1.name, $1.id.session) }
        hosts = Set(nodes.map { $0.id.host }).sorted {
            if $0 == "This Mac" { return $1 != "This Mac" }
            if $1 == "This Mac" { return false }
            return $0 < $1
        }
    }
}

/// The same curve geometry drives drawing and route hit testing.
struct NetworkTopologyCurve {
    let a: CGPoint
    let b: CGPoint
    let c: CGPoint
    let d: CGPoint

    init(source: CGPoint, target: CGPoint, nodeWidth: CGFloat, sameHost: Bool, clearance: CGFloat, railOffset: CGFloat = 0) {
        if sameHost {
            a = CGPoint(x: source.x + nodeWidth, y: source.y + 18)
            b = CGPoint(x: target.x + nodeWidth, y: target.y + 18)
            let bend = max(16, min(88, clearance))
            c = CGPoint(x: a.x + bend, y: a.y - (source == target ? 24 : 0))
            d = CGPoint(x: b.x + bend, y: b.y + (source == target ? 24 : 0))
        } else {
            let forward = target.x > source.x
            a = CGPoint(x: source.x + (forward ? nodeWidth : 0), y: source.y + 18)
            b = CGPoint(x: target.x + (forward ? 0 : nodeWidth), y: target.y + 18)
            let corridor = (a.x + b.x) / 2 + railOffset
            c = CGPoint(x: corridor, y: a.y)
            d = CGPoint(x: corridor, y: b.y)
        }
    }

    func point(at t: CGFloat) -> CGPoint {
        let vertices = [a, c, d, b]
        let position = max(0, min(1, t)) * 3
        let segment = min(2, Int(position))
        let fraction = position - CGFloat(segment)
        let start = vertices[segment], end = vertices[segment + 1]
        return CGPoint(x: start.x + (end.x - start.x) * fraction,
                       y: start.y + (end.y - start.y) * fraction)
    }

    var path: Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: c)
        path.addLine(to: d)
        path.addLine(to: b)
        return path
    }

}

struct NetworkTopologyGraph: View {
    let participants: [NetworkParticipant]
    let links: [PeerNetworkStatus]
    let transports: [NetworkTransportSnapshot]
    let now: Date
    let query: String
    let inspectLink: (Int) -> Void
    @State private var selectedNode: NetworkParticipant.Identity?
    @State private var selectedLink: Int?

    private var projection: NetworkTopologyProjection {
        NetworkTopologyProjection(links: links, participants: participants, query: query)
    }

    var body: some View {
        let data = projection
        ScrollView {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                if data.nodes.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No messaging links" : "No matching links",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(query.isEmpty ? "Sessions can run without messaging. Use New link to connect exact endpoints." : "Clear the search to show the complete topology."))
                } else {
                    GeometryReader { geometry in
                        diagram(data, width: max(geometry.size.width, 440))
                    }.frame(height: graphHeight(data))
                }
                DisclosureGroup("All connections") {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
                        ForEach(data.links) { link in
                            Button { select(link) } label: {
                                HStack {
                                    Text(name(link.sourceIdentity, in: data))
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text(name(link.destinationIdentity, in: data))
                                    Spacer()
                                    Text(link.evidenceLabel(now: now)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, RelayTheme.spacing(8)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }.font(RelayTheme.font(size: 10)).padding(RelayTheme.spacing(16)).frame(minWidth: 440, maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("relay.network.topology")
    }

    private func graphHeight(_ data: NetworkTopologyProjection) -> CGFloat {
        CGFloat(data.hosts.map { host in data.nodes.filter { $0.id.host == host }.count }.max() ?? 0) * 76 + 78
    }

    private func name(_ id: NetworkParticipant.Identity, in data: NetworkTopologyProjection) -> String {
        data.nodes.first { $0.id == id }?.name ?? id.session
    }

    private func select(_ link: PeerNetworkStatus) {
        selectedLink = link.pid
        selectedNode = nil
        inspectLink(link.pid)
    }

    private func orderedNodes(_ data: NetworkTopologyProjection, host: String) -> [NetworkTopologyProjection.Node] {
        let hosted = data.nodes.filter { $0.id.host == host }
        guard host == data.hosts.first else { return hosted }
        let ranks = Dictionary(uniqueKeysWithValues: data.nodes.enumerated().map { ($0.element.id, $0.offset) })
        func rank(_ node: NetworkTopologyProjection.Node) -> Int {
            data.links.compactMap { link -> Int? in
                let other: NetworkParticipant.Identity
                if link.sourceIdentity == node.id { other = link.destinationIdentity }
                else if link.destinationIdentity == node.id { other = link.sourceIdentity }
                else { return nil }
                return other.host == host ? nil : ranks[other]
            }.min() ?? Int.max
        }
        return hosted.sorted { (rank($0), $0.name, $0.id.session) < (rank($1), $1.name, $1.id.session) }
    }

    private func diagram(_ data: NetworkTopologyProjection, width: CGFloat) -> some View {
        let laneWidth = width / CGFloat(max(data.hosts.count, 1))
        let nodeWidth = min(260.0, laneWidth - 64)
        let points = Dictionary(uniqueKeysWithValues: data.hosts.enumerated().flatMap { lane, host in
            orderedNodes(data, host: host).enumerated().map { row, node in
                (node.id, CGPoint(x: CGFloat(lane) * laneWidth + (laneWidth - nodeWidth) / 2,
                                  y: 58 + CGFloat(row) * 76))
            }
        })
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for link in data.links.sorted(by: { ($0.pid == selectedLink ? 1 : 0) < ($1.pid == selectedLink ? 1 : 0) }) {
                    guard let source = points[link.sourceIdentity], let target = points[link.destinationIdentity] else { continue }
                    let curve = NetworkTopologyCurve(source: source, target: target, nodeWidth: nodeWidth,
                        sameHost: link.sourceIdentity.host == link.destinationIdentity.host,
                        clearance: (laneWidth - nodeWidth) / 2 - 8,
                        railOffset: CGFloat((data.links.firstIndex(where: { $0.pid == link.pid }) ?? 0) % 7 - 3) * 6)
                    let highlighted = selectedLink == link.pid || selectedNode == link.sourceIdentity || selectedNode == link.destinationIdentity
                    let hasSelection = selectedLink != nil || selectedNode != nil
                    for endpoint in [curve.a, curve.b] {
                        context.fill(Path(ellipseIn: CGRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4)), with: .color(highlighted ? RelayTheme.accent : RelayTheme.textMuted.opacity(0.4)))
                    }
                    context.stroke(curve.path, with: .color(highlighted ? .accentColor : .secondary.opacity(hasSelection ? 0.16 : 0.4)),
                                   style: StrokeStyle(lineWidth: highlighted ? 1.8 : 1.0,
                                       dash: link.evidence(now: now) == .connected ? [] : [4, 4]))
                }
            }.onTapGesture(coordinateSpace: .local) { location in
                var nearest: (PeerNetworkStatus, CGFloat)?
                for link in data.links {
                    guard let source = points[link.sourceIdentity], let target = points[link.destinationIdentity] else { continue }
                    let curve = NetworkTopologyCurve(source: source, target: target, nodeWidth: nodeWidth,
                        sameHost: link.sourceIdentity.host == link.destinationIdentity.host,
                        clearance: (laneWidth - nodeWidth) / 2 - 8,
                        railOffset: CGFloat((data.links.firstIndex(where: { $0.pid == link.pid }) ?? 0) % 7 - 3) * 6)
                    for step in 0...40 {
                        let point = curve.point(at: CGFloat(step) / 40)
                        let distance = hypot(point.x - location.x, point.y - location.y)
                        if distance < 12 && (nearest == nil || distance < nearest!.1) { nearest = (link, distance) }
                    }
                }
                if let nearest { select(nearest.0) }
            }.accessibilityHidden(true)
            ForEach(Array(data.hosts.enumerated()), id: \.element) { lane, host in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text(host).font(RelayTheme.font(size: 11, weight: .semibold))
                    if let transport = transports.first(where: { $0.host == host }) {
                        Text(transport.label(at: DispatchTime.now().uptimeNanoseconds))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text(host == "This Mac" ? "Local execution" : "Host status unconfirmed").font(.caption).foregroundStyle(.secondary) }
                }.frame(width: nodeWidth, alignment: .leading)
                    .offset(x: CGFloat(lane) * laneWidth + (laneWidth - nodeWidth) / 2)
            }
            ForEach(data.nodes) { node in
                if let point = points[node.id] {
                    let highlighted = selectedNode == node.id || data.links.contains {
                        ($0.pid == selectedLink || (selectedNode != nil && ($0.sourceIdentity == selectedNode || $0.destinationIdentity == selectedNode)))
                            && ($0.sourceIdentity == node.id || $0.destinationIdentity == node.id)
                    }
                    Button {
                        selectedNode = node.id; selectedLink = nil
                        if let link = data.links.first(where: { $0.sourceIdentity == node.id || $0.destinationIdentity == node.id }) {
                            inspectLink(link.pid)
                        }
                    } label: {
                        HStack(spacing: RelayTheme.spacing(8)) {
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                Text(node.name).font(RelayTheme.font(size: 12, weight: .medium))
                                    .foregroundStyle(highlighted ? RelayTheme.accent : RelayTheme.text)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                if let provider = participants.first(where: { $0.id == node.id })?.provider, !provider.isEmpty {
                                    Text(provider).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, RelayTheme.spacing(10)).frame(width: nodeWidth, height: 48, alignment: .top).padding(.top, RelayTheme.spacing(8))
                            .background(Color.clear,
                                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)))
                            .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)).stroke(highlighted ? Color.clear : Color.clear))
                    }.buttonStyle(.plain).help("\(node.name) · \(node.id.host) · \(node.id.session)")
                        .accessibilityLabel("\(node.name), \(node.id.host), inspect related messaging link")
                        .offset(x: point.x, y: point.y)
                }
            }
        }
    }
}
