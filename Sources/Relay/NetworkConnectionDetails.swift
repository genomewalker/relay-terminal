import SwiftUI

struct NetworkConversationTurn: Equatable {
    let occurredAt: Date
    let speaker: String
    let text: String?
}

struct NetworkConnectionEndpoint: Identifiable {
    let id: String
    let name: String
    let host: String
    let turn: NetworkConversationTurn?
    let openSession: (() -> Void)?
}

struct NetworkConnectionDetails: View {
    let status: String
    let endpoints: [NetworkConnectionEndpoint]
    let lastReceipt: String
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
            HStack {
                Text(status).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.mint)
                Spacer()

            }
            ForEach(endpoints) { endpoint in endpointView(endpoint) }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                Text("Last link message").foregroundStyle(RelayTheme.text)
                Text(lastReceipt).foregroundStyle(RelayTheme.textMuted)
            }.font(RelayTheme.font(size: 11))
        }
    }

    private func endpointView(_ endpoint: NetworkConnectionEndpoint) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
            HStack {
                Text(endpoint.name).font(RelayTheme.font(size: 12, weight: .medium)).textSelection(.enabled)
                Spacer()
                if let open = endpoint.openSession { Button(action: open) { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(RelayTheme.textMuted).accessibilityLabel("Open session \(endpoint.name)") }
            }
            if let turn = endpoint.turn {
                HStack {
                    Text("\(turn.speaker) / \(endpoint.host)")
                    Spacer()
                    Text(turn.occurredAt, format: .dateTime.hour().minute())
                }.font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                if let text = turn.text, !text.isEmpty {
                    Text(text).font(RelayTheme.font(size: 12)).lineLimit(expanded.contains(endpoint.id) ? nil : 2).textSelection(.enabled)
                    Button(expanded.contains(endpoint.id) ? "Less" : "More") {
                        if expanded.contains(endpoint.id) { expanded.remove(endpoint.id) } else { expanded.insert(endpoint.id) }
                    }.buttonStyle(.plain).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.accent)
                } else {
                    Text("Turn text was not provided by this session.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No completed turn observed by Relay.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
