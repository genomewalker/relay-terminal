import SwiftUI

struct RelayQuestionEvidenceView: View {
    let objective: String
    let read: @MainActor () async -> RelayQuestionEvidence.Result
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = 0
    @State private var result: RelayQuestionEvidence.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chitta evidence").font(.headline)
                Spacer()
                Button("Refresh") {
                    result = nil
                    refresh += 1
                }
                    .disabled(result == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(objective).font(.subheadline).foregroundStyle(.secondary)
            Divider()
            content
        }
        .padding(16)
        .frame(width: 560, height: 480, alignment: .topLeading)
        .accessibilityIdentifier("relay.miko.chitta-evidence")
        .task(id: refresh) {
            let observed = await read()
            if !Task.isCancelled { result = observed }
        }
    }

    @ViewBuilder private var content: some View {
        switch result {
        case nil:
            ProgressView("Reading evidence…")
        case .unattached:
            Text("This task has no saved Chitta thread attachment.")
        case .attachmentChanged:
            Text("The task’s Chitta thread is no longer attached to its original pane and host.")
        case .unavailable:
            Text("Evidence is unavailable. Freshness is unknown.")
        case .ready(let attachment, let entries, let total, let conclusions):
            Text("\(attachment.realm) / \(attachment.threadID)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if entries.isEmpty && conclusions.isEmpty {
                Text("The attached Chitta thread has no evidence entries.")
            } else {
                if total > entries.count {
                    Text("Showing the newest \(entries.count) of \(total) entries.").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conclusions) { notice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: notice.question).font(.headline)
                                Text(notice.disposition.rawValue.capitalized).font(.caption.bold())
                                Text(verbatim: notice.rationale)
                                Text("Revision \(notice.revision) · SHA-256 \(notice.evidenceSHA256)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("relay.research.conclusion." + notice.deliveryKey)
                            Divider()
                        }
                        ForEach(entries) { entry in
                            evidenceRow(entry)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.textSelection(.enabled)
            }
        }
    }

    private func evidenceRow(_ entry: RelayQuestionEvidenceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.kind == "counter" ? "Dissent" : entry.kind.capitalized).font(.caption.bold())
            Text(entry.text).font(.body)
            if let body = entry.body { Text(body).font(.callout) }
            if let assessment = entry.assessment {
                Text(assessment.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let check = entry.check {
                Text(check.outcome)
                if let command = check.command { Text(command).font(.system(.caption, design: .monospaced)) }
            }
            if let subject = entry.subject {
                Text("\(subject.host) · \(subject.checkout) · \(subject.commit)").font(.caption)
            }
            ForEach(entry.refs.indices, id: \.self) { index in
                Text(entry.refs[index].label).font(.caption)
            }
            Text("\(entry.id) · Chitta verification \(entry.verification ?? "unknown") · Freshness \(entry.freshnessLabel.lowercased())")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
