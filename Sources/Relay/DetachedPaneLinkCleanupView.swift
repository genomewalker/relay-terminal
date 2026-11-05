import SwiftUI

struct DetachedPaneLinkCleanupView: View {
    @ObservedObject var selection: PaneLinkSelection
    let dismiss: () -> Void
    private var links: [PaneLinkMembership] { selection.cleanup.reviewed ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove detached-pane links").font(.headline)
            Text("These links include a pane that is no longer attached in Relay. Agents keep running; message receipts and link history are retained.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if links.isEmpty { Text("No detached-pane links found in the loaded records.") }
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.paneIDs.map(selection.label(for:)).joined(separator: " ↔ "))
                            Text(link.paneIDs.map { $0.uuidString.lowercased() }.joined(separator: " / "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Link " + link.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 300)
            Text("Relay checks each link again before removal and keeps links whose panes have been reattached.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { selection.cleanup.cancel(); dismiss() }
                Button("Remove \(links.count) " + (links.count == 1 ? "link" : "links"), role: .destructive) {
                    selection.confirmDetachedLinks?(); dismiss()
                }.disabled(links.isEmpty || selection.cleanupRunning)
                    .accessibilityIdentifier("relay.pane.link.confirm-detached")
            }
        }.padding(20).frame(width: 560)
    }
}
