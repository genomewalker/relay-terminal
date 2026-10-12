import SwiftUI

struct RelayAssistantPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var controller: RelayAssistantController
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                Text("Relay Assistant").font(RelayTheme.font(size: 14, weight: .semibold))
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button {
                    controller.cancel()
                    workspace.closeAssistant()
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close assistant")
                .accessibilityIdentifier("relay.assistant.close")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if controller.messages.isEmpty {
                            Text("Ask Relay to close a chat, recover a tab, organize panels or run a shell command.")
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        ForEach(controller.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role).font(RelayTheme.font(size: 10, weight: .semibold)).foregroundStyle(RelayTheme.textMuted)
                                Text(message.text).textSelection(.enabled)
                            }.id(message.id)
                        }
                        ForEach(controller.receipts.suffix(12)) { receipt in
                            RelayAssistantReceiptRow(receipt: receipt)
                        }
                        if let error = controller.error {
                            Text(error).foregroundStyle(Color.orange).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(14)
                }
                .onChange(of: controller.messages.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: controller.receipts.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask Relay…", text: $draft, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain)
                    .accessibilityIdentifier("relay.assistant.request")
                    .onSubmit { submit() }
                if controller.isBusy {
                    Button("Stop") { controller.cancel() }.accessibilityIdentifier("relay.assistant.stop")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send request").accessibilityIdentifier("relay.assistant.send")
                }
            }.padding(14)
            Text("On device · \(controller.availability)")
                .font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .font(RelayTheme.font(size: 12))
        .foregroundStyle(RelayTheme.text)
        .frame(width: 430, height: 530)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 5)
    }

    private func submit() {
        guard !controller.isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = draft
        draft = ""
        controller.send(request)
    }
}

private struct RelayAssistantReceiptRow: View {
    let receipt: RelayAssistantReceipt
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(receipt.action + " · " + receipt.status)
                .font(RelayTheme.font(size: 10, weight: .medium))
            Text(receipt.detail)
                .lineLimit(6)
                .font(RelayTheme.font(size: 11))
                .foregroundStyle(RelayTheme.textMuted)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }
}
