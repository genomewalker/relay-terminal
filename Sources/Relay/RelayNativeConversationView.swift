import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keep the provider's source intact while bounding rich-text parsing and layout.
struct RelayNativeItemPresentation {
    static let maximumPreviewBytes = 65_536
    let item: RelayNativeItem
    var isAssistant: Bool { item.role == "assistant" }
    var isPreviewLimited: Bool { isAssistant && item.text.utf8.count > Self.maximumPreviewBytes }
    var preview: String {
        guard isPreviewLimited else { return item.text }
        var prefix = item.text.utf8.prefix(Self.maximumPreviewBytes)
        while !prefix.isEmpty {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix = prefix.dropLast()
        }
        return ""
    }
}

struct RelayNativeDraft: Equatable {
    var text: String
    var images: [String]
    func shouldClear(current: Self, outcome: RelayNativeActionOutcome) -> Bool {
        outcome == .sent && current == self
    }
}

struct RelayNativeConversationView: View {
    @StateObject private var conversation: RelayNativeConversation
    @State private var text = ""
    @State private var images: [String] = []
    @State private var observation = UUID()
    @State private var pendingDraft: RelayNativeDraft?
    private let observeLive: Bool
    init(binding: RelayNativeBinding) {
        _conversation = StateObject(wrappedValue: RelayNativeConversation(binding: binding))
        observeLive = true
    }
    /// Offline presentation/export uses the same native view without connecting.
    init(conversation: RelayNativeConversation, observeLive: Bool) {
        _conversation = StateObject(wrappedValue: conversation)
        self.observeLive = observeLive
    }
    private var unavailable: Bool {
        conversation.busy || conversation.failure != nil || conversation.uncertainAction != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(conversation.binding.identity.provider == "codex" ? "Codex" : "Claude").font(.headline)
                        Text(conversation.binding.account.label).font(.caption).foregroundStyle(.secondary)
                        if let snapshot = conversation.snapshot, !snapshot.model.isEmpty {
                            Text(snapshot.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let cwd = conversation.snapshot?.cwd {
                        Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if let snapshot = conversation.snapshot {
                    HStack(spacing: 5) {
                        if snapshot.phase == "running" { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                        Text(snapshot.phase == "running" ? "Working" : snapshot.phase.capitalized)
                        if snapshot.phase == "running", let step = currentStep {
                            RelayNativeStepLabel(step: step.title).id(step.id)
                        }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RelayAgentDesign.wash, in: Capsule())
                } else { ProgressView().controlSize(.small) }
                Button("Reconnect", systemImage: "arrow.clockwise") { observation = UUID() }
                    .labelStyle(.iconOnly).help("Read the same worker without replaying actions")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            if conversation.snapshot?.phase == "exited" {
                HStack {
                    Text("Saved conversation. The original worker is no longer connected.").font(.callout)
                    Spacer()
                    Button("Resume in new pane", action: resume)
                }.padding(12)
            }
            Divider()
            if let failure = conversation.failure {
                let shown = RelayConversationErrorText.userFacing(failure)
                HStack(alignment: .top) {
                    Image(systemName: RelayTheme.StatusRole.warning.symbol).foregroundStyle(RelayTheme.StatusRole.warning.color)
                    Text(shown.message).textSelection(.enabled)
                    Spacer()
                    if let raw = shown.detail { RelayErrorDetails(raw: raw) }
                }.font(.callout).padding(12).background(RelayTheme.StatusRole.warning.color.opacity(0.1))
                    .help(shown.detail ?? "")
            }
            if conversation.uncertainAction != nil {
                HStack {
                    Text("Action outcome is unconfirmed. It will not be sent again.").font(.callout)
                    Spacer()
                    Button("Check receipt") {
                        Task {
                            let outcome = await conversation.inspectReceipt()
                            if let draft = pendingDraft {
                                clearDraftIfSent(draft, outcome: outcome)
                                if outcome == .sent || outcome == .rejected { pendingDraft = nil }
                            }
                        }
                    }.disabled(conversation.busy)
                }.padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if (conversation.snapshot?.olderBefore ?? 0) > 0 {
                            Button("Load earlier messages") { Task { await conversation.loadOlder() } }
                        }
                        let shown = items
                        let live = liveIDs(shown)
                        ForEach(shown) { item in
                            RelayNativeMessageRow(item: item, live: live.contains(item.id)).id(item.id)
                        }
                        ForEach(conversation.snapshot?.requests ?? []) { request in
                            RelayNativeRequestView(request: request, disabled: unavailable ||
                                !(conversation.snapshot?.capabilities.respond ?? false)) { decision, answers in
                                Task { await conversation.act(kind: "respond", request: request, decision: decision, answers: answers) }
                            }
                        }
                        Color.clear.frame(height: 1).id("native-bottom")
                    }.frame(maxWidth: RelayAgentDesign.columnWidth).frame(maxWidth: .infinity)
                        .padding(.horizontal, 20).padding(.vertical, 24)
                }
                .onChange(of: conversation.snapshot?.items.last?.id) { _, _ in
                    proxy.scrollTo("native-bottom", anchor: .bottom)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    HStack {
                        Text("\(images.count) image\(images.count == 1 ? "" : "s") attached").font(.caption)
                        Button("Remove") { images = [] }
                    }
                }
                TextEditor(text: $text).font(.body).frame(height: 76)
                    .scrollContentBackground(.hidden).padding(.horizontal, 4)
                    .accessibilityLabel("Message")
                HStack {
                    Button("Attach image", systemImage: "paperclip", action: selectImages)
                        .disabled(unavailable || images.count >= 4)
                    Spacer()
                    if conversation.snapshot?.capabilities.interrupt == true {
                        Button(conversation.snapshot?.capabilities.interruptScope == "session" ? "Interrupt Claude" : "Stop turn", systemImage: "stop.fill") {
                            Task { await conversation.act(kind: "interrupt") }
                        }.disabled(unavailable)
                    }
                    if conversation.snapshot?.capabilities.steer == true {
                        Button("Steer") { submit("steer") }
                            .disabled(unavailable || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
                    }
                    Button("Send", systemImage: "arrow.up") { submit("send") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(unavailable || !(conversation.snapshot?.capabilities.send ?? false) ||
                            (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                }
            }.padding(12).background(RelayAgentDesign.composerFill, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(RelayAgentDesign.stroke))
                .frame(maxWidth: RelayAgentDesign.columnWidth).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .task(id: observation) { if observeLive { await conversation.observe() } }
    }
    /// Unanswered trailing calls while the turn is running.
    private func liveIDs(_ items: [RelayNativeItem]) -> Set<String> {
        let indices = RelayToolPresentation.liveIndices(statuses: items.map { $0.role == "tool" ? $0.status ?? "" : nil },
                                                        active: conversation.snapshot?.phase == "running")
        return Set(indices.map { items[$0].id })
    }
    /// The latest live call, for the header ("Using Bash · 12 s").
    private var currentStep: (id: String, title: String)? {
        let shown = items
        let live = liveIDs(shown)
        guard let item = shown.last(where: { live.contains($0.id) }) else { return nil }
        return (item.id, RelayToolPresentation(tool: item.tool ?? "", text: item.text).name)
    }
    private var items: [RelayNativeItem] {
        let current = conversation.snapshot?.items ?? []
        let known = Set(current.map(\.id))
        return conversation.older.filter { !known.contains($0.id) } + current
    }
    private func resume() {
        guard let workspace = RelayAgentAccountDirectory.shared.workspace,
              let paneID = UUID(uuidString: conversation.binding.identity.pane) else { return }
        Task {
            if let refusal = await workspace.startNativeAgentInNewTab(conversation.binding.account,
                besidePane: paneID, resuming: conversation.binding) {
                conversation.failure = refusal
            }
        }
    }
    private func submit(_ kind: String) {
        let draft = RelayNativeDraft(text: text, images: images)
        Task {
            let outcome = await conversation.act(kind: kind, text: draft.text, images: draft.images)
            clearDraftIfSent(draft, outcome: outcome)
            if outcome == .uncertain { pendingDraft = draft }
        }
    }
    private func clearDraftIfSent(_ draft: RelayNativeDraft, outcome: RelayNativeActionOutcome) {
        if draft.shouldClear(current: RelayNativeDraft(text: text, images: images), outcome: outcome) {
            text = ""; images = []
        }
    }
    private func selectImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = Array(panel.urls.prefix(4 - images.count))
            Task { @MainActor in
                do {
                    for url in urls {
                        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let count = attributes.fileSize, count <= 4 << 20 else {
                            throw RelayNativeService.Failure.refused("Images must be at most 4 MB.")
                        }
                        images.append(try await conversation.upload(Data(contentsOf: url)))
                    }
                } catch { conversation.failure = error.localizedDescription }
            }
        }
    }
}

private struct RelayNativeMessageRow: View {
    let item: RelayNativeItem
    var live = false
    private var presentation: RelayNativeItemPresentation { .init(item: item) }

    var body: some View {
        if item.role == "tool" {
            RelayNativeToolCard(item: item, live: live)
        } else {
            message
        }
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.role == "user" { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(item.role.capitalized).font(.caption.weight(.semibold))
                    if let tool = item.tool { Text(tool).font(.caption.monospaced()) }
                    Spacer(minLength: 8)
                    if let status = item.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }.foregroundStyle(.secondary)
                if presentation.isAssistant {
                    RelayAgentProse(axID: "native.message." + item.id, source: presentation.preview)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if presentation.isPreviewLimited {
                        HStack {
                            Text("Long message: showing the first 64 KB.").font(.caption).foregroundStyle(.secondary)
                            Button("Copy full message") { RelayAgentClipboard.copy(item.text) }
                        }
                    }
                } else {
                    Text(item.text).font(.body)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.truncated == true { Text("Display truncated").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(item.role == "assistant" ? 2 : 12)
            .background(item.role == "user" ? Color.accentColor.opacity(0.09) :
                (item.role == "assistant" ? Color.clear : RelayAgentDesign.wash),
                in: RoundedRectangle(cornerRadius: 12))
            if item.role != "user" { Spacer(minLength: 0).frame(width: 0) }
        }.frame(maxWidth: .infinity, alignment: item.role == "user" ? .trailing : .leading)
    }
}

/// One tool call: "Bash · git status", its state, and bounded output.
private struct RelayNativeToolCard: View {
    let item: RelayNativeItem
    private let state: RelayToolState
    private let presentation: RelayToolPresentation

    init(item: RelayNativeItem, live: Bool) {
        self.item = item
        state = RelayToolState(status: item.status ?? "", live: live)
        presentation = RelayToolPresentation(tool: item.tool ?? "", text: item.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(presentation.title).font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                RelayToolStateBadge(state: state)
            }
            if !presentation.lines.isEmpty {
                RelayToolOutputView(axID: "native.tool." + item.id, presentation: presentation, failed: state == .failed)
            }
            if item.truncated == true { Text("Display truncated").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(RelayAgentDesign.wash, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if state == .failed {
                RoundedRectangle(cornerRadius: 12).strokeBorder(state.role.color.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title + ", " + state.spoken)
    }
}

/// "Using Bash · 12 s", counted from when this view first showed the step.
private struct RelayNativeStepLabel: View {
    let step: String
    @State private var shownAt = Date()
    var body: some View {
        TimelineView(.periodic(from: shownAt, by: 1)) { context in
            Text("· Using " + step + " · " + RelayToolPresentation.elapsed(context.date.timeIntervalSince(shownAt)))
                .monospacedDigit()
        }
    }
}

private struct RelayNativeRequestView: View {
    let request: RelayNativeRequest
    let disabled: Bool
    let respond: (String, [String: [String]]) -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            if !request.detail.isEmpty { Text(request.detail).font(.callout.monospaced()).textSelection(.enabled) }
            if request.kind == "approval" {
                HStack {
                    Button("Allow once") { respond("allow", [:]) }.buttonStyle(.borderedProminent)
                    Button("Deny") { respond("deny", [:]) }
                }
            } else {
                ForEach(request.questions ?? []) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.text).font(.callout.bold())
                        ForEach(question.options ?? []) { option in
                            Toggle(isOn: Binding(
                                get: { selected[question.id, default: []].contains(option.id) },
                                set: { value in
                                    if question.multiple != true { selected[question.id] = [] }
                                    if value { selected[question.id, default: []].insert(option.id) }
                                    else { selected[question.id, default: []].remove(option.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                        if let detail = option.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.toggleStyle(.checkbox)
                        }
                        if question.secret == true {
                            SecureField("Your answer", text: answerBinding(question.id))
                        } else {
                            TextField("Your answer", text: answerBinding(question.id))
                        }
                    }
                }
                Button("Submit answers") { respond("", answers) }
                    .buttonStyle(.borderedProminent).disabled(answers.count != request.questions?.count)
            }
            if request.responding { Text("Response submitted; waiting for provider").font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .disabled(disabled || request.responding)
    }
    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { freeText[id, default: ""] }, set: { freeText[id] = $0 })
    }
    private var answers: [String: [String]] {
        var values: [String: [String]] = [:]
        for question in request.questions ?? [] {
            var answer = (question.options ?? []).filter { selected[question.id, default: []].contains($0.id) }.map(\.id)
            let other = freeText[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !other.isEmpty {
                if question.multiple == true { answer.append(other) } else { answer = [other] }
            }
            if !answer.isEmpty { values[question.id] = answer }
        }
        return values
    }
}
