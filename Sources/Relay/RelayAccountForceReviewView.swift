import SwiftUI

/// Presents one host-produced immutable preview. The caller retains the
/// preview and one action ID; this view never sends a host request itself.
struct RelayAccountForceReviewView: View {
    let preview: RelayAccountForcePreview
    let run: () -> Void
    let cancel: () -> Void
    @State private var reviewed = false

    private var rows: [(String, String)] {
        [
            ("Host", RelayAccountForcePreview.quoted(preview.host)),
            ("Pane", preview.paneID.uuidString.lowercased()),
            ("Provider", preview.provider),
            ("Conversation", RelayAccountForcePreview.quoted(preview.sessionID)),
            ("Provider PID / start", "\(preview.providerPID) / \(preview.providerStart)"),
            ("Selected PID / start", "\(preview.blockerPID) / \(preview.blockerStart)"),
            ("Command digest", preview.commandDigest)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review selected process").font(.headline)
            Text("Relay will send one terminate signal to this process. Its identity can change between the final check and the signal on some hosts. It may not exit immediately; the account move will wait for verification.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.0) { label, value in
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Text("Full argument list").font(.caption).foregroundStyle(.secondary)
                    Text(preview.displayedCommand ?? "Invalid preview")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 180, idealHeight: 320)
            Toggle("I reviewed the host, process and full argument list", isOn: $reviewed)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Terminate selected process", action: run)
                    .disabled(!reviewed || !preview.isValid)
            }
        }.padding().frame(minWidth: 520, idealWidth: 680)
    }
}
