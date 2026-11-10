import SwiftUI

/// Workspace conversation with a multiline composer and inspectable action progress.
struct RelayAssistantHaikuPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var harness: RelayAssistantHarness
    @ObservedObject private var entryPoints = RelayAssistantEntryPoints.shared
    @ObservedObject private var shepherd = RelayMikoShepherdCoordinator.shared
    var panelSize = CGSize(width: 560, height: 680)
    @State private var focusRequest = UUID()
    @State private var followsLatest = true
    @State private var composerHeight = RelayMikoComposerHeight.minimum
    /// Saved tasks, Shepherd delivery and the profile, collapsed below the chat by default.
    @State private var detailsExpanded: Bool
    private var draft: String {
        get { workspace.haikuAssistantDraft }
        nonmutating set { workspace.haikuAssistantDraft = newValue }
    }

    init(workspace: WorkspaceModel, harness: RelayAssistantHarness,
         panelSize: CGSize = CGSize(width: 560, height: 680), detailsInitiallyExpanded: Bool = false) {
        self.workspace = workspace
        self.harness = harness
        self.panelSize = panelSize
        _detailsExpanded = State(initialValue: detailsInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(RelayTheme.accent)
                Text("Miko").font(RelayTheme.font(size: 15, weight: .semibold))
                Spacer()
                if harness.isBusy { ProgressView().controlSize(.small).help("Miko is working") }
                Button("New chat") { harness.newChat() }
                    .buttonStyle(.plain).font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                    .disabled(harness.isBusy || harness.exchanges.isEmpty)
                    .accessibilityIdentifier("relay.assistant.new-chat")
                Menu {
                    Button { openControlCenter("Control") } label: {
                        Label("Control Center", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Open Control Center")
                    .accessibilityIdentifier("relay.assistant.control-center")
                    Button { openControlCenter("Agents") } label: {
                        Label("Sessions and health", systemImage: "heart.text.square")
                    }
                    .accessibilityLabel("Open Sessions and Health")
                    .accessibilityIdentifier("relay.assistant.sessions-health")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(RelayTheme.textMuted)
                .help("More").accessibilityLabel("More Miko actions")
                .accessibilityIdentifier("relay.assistant.more")
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close · Esc")
                    .accessibilityLabel("Close Relay assistant")
                    .accessibilityIdentifier("relay.assistant.panel-close")
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider().overlay(RelayTheme.line)
            if let notice = entryPoints.hotkeyStatus.notice {
                Text(notice).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityIdentifier("relay.assistant.hotkey-notice")
            }
            if !shepherd.reports.isEmpty {
                DisclosureGroup("Shepherd reports (\(shepherd.reports.count))") {
                    ScrollView {
                        Text(shepherd.reports.suffix(20).map(\.text).joined(separator: "\n\n"))
                            .font(RelayTheme.font(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxHeight: 180)
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let notice = harness.taskStoreNotice {
                Text(notice).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.coral)
                    .padding(.horizontal, 12).accessibilityIdentifier("relay.miko.task-store-notice")
            }
            if !harness.inbox.isEmpty {
                DisclosureGroup("Replies to Miko (\(harness.inbox.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Untrusted collaborator input; Miko never acts on it by itself.")
                                .font(RelayTheme.font(size: 9.5)).foregroundStyle(RelayTheme.coral)
                            ForEach(harness.inbox.indices, id: \.self) { index in
                                let reply = harness.inbox[index]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("From pane " + RelayAssistantActions.singleLine(String((reply["from_pane_id"] ?? "").prefix(8))))
                                        .font(RelayTheme.font(size: 10, weight: .medium))
                                    Text(RelayAssistantActions.visible(reply["text"] ?? "")).font(RelayTheme.font(size: 10.5))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .font(RelayTheme.font(size: 11))
                .padding(.horizontal, 12).padding(.bottom, 8)
                .accessibilityIdentifier("relay.assistant.inbox")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if harness.exchanges.isEmpty {
                            Text("Ask about your panes: “which panes are held and why?”, “show me the Rice Codex pane”, “zoom the build pane”.")
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        ForEach(harness.exchanges) { exchange in
                            exchangeView(exchange).id(exchange.id)
                        }
                        if let card = harness.displayedPendingCard {
                            RelayAssistantActionCardView(card: card, run: harness.runCard, cancel: harness.cancelCard)
                                .id(card.id)
                        }
                        Color.clear.frame(height: 1).id("latest")
                            .onAppear { followsLatest = true }
                            .onDisappear { followsLatest = false }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: harness.exchanges.count) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: harness.pendingCard?.id) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            Divider()
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    savedTasks
                    RelayShepherdPushStatusView()
                    profile
                }
                .frame(maxHeight: 300, alignment: .top)
            } label: {
                Text(harness.taskRows.isEmpty ? "Tasks and context" : "Tasks and context · \(harness.taskRows.count) saved")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityIdentifier("relay.miko.details")
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    RelayMikoComposer(text: $workspace.haikuAssistantDraft, canSend: !harness.isBusy,
                                      focusRequest: focusRequest, send: submit,
                                      onHeightChange: { composerHeight = $0 })
                        .frame(height: composerHeight)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("Ask Miko to work on your workspace…")
                                    .font(RelayTheme.font(size: 13)).foregroundStyle(RelayTheme.textMuted)
                                    .padding(.top, 6).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                    if harness.isBusy {
                        Button("Stop", systemImage: "stop.fill") { harness.cancel() }
                            .accessibilityIdentifier("relay.assistant.stop")
                    } else {
                        Button("Send", systemImage: "arrow.up") { submit() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("relay.assistant.send-request")
                    }
                }
                Text(harness.isBusy ? "Working · you can draft your next message" : "Enter to send · Shift Enter for a new line")
                    .font(RelayTheme.font(size: 10))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RelayTheme.elevated)

        }
        .font(RelayTheme.font(size: 12))
        .foregroundStyle(RelayTheme.text)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 5)
        // Esc cancels a waiting action card first; otherwise it closes the panel.
        .onExitCommand { if harness.pendingCard != nil { harness.cancelCard() } else { close() } }
        .onAppear { focusRequest = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .relayMikoComposerFocus)) { note in
            guard let target = note.object as? WorkspaceModel, target === workspace else { return }
            focusRequest = UUID()
        }
        .accessibilityIdentifier("relay.assistant.panel")
        // Pane names and ids in Miko's answers reveal that pane.
        .environment(\.openURL, OpenURLAction { url in
            guard let paneID = RelayMikoPaneLinks.paneID(from: url) else { return .systemAction }
            workspace.revealPane(paneID, origin: .user)
            return .handled
        })
    }

    private var paneNames: [(id: UUID, name: String)] {
        workspace.panes.values.map { (id: $0.id, name: $0.displayName) }
    }

    @ViewBuilder private func exchangeView(_ exchange: RelayAssistantExchange) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label = exchange.origin.label {
                Label("From supervisor pane “\(label)”", systemImage: "person.badge.shield.checkmark")
                    .font(RelayTheme.font(size: 10, weight: .medium)).foregroundStyle(RelayTheme.blue)
                    .accessibilityIdentifier("relay.assistant.supervisor-origin")
            }
            if case .agent(let paneID, let label) = exchange.origin {
                Label("From agent pane “\(label)” · \(paneID.uuidString.prefix(8).lowercased()) · untrusted collaborator request",
                      systemImage: "person.crop.circle.badge.questionmark")
                    .font(RelayTheme.font(size: 10, weight: .medium)).foregroundStyle(RelayTheme.coral)
                    .accessibilityIdentifier("relay.assistant.agent-origin")
            }
            Text(exchange.request).font(RelayTheme.font(size: 13, weight: .semibold)).textSelection(.enabled)
            if !exchange.toolLog.isEmpty {
                DisclosureGroup("Activity (\(exchange.toolLog.count))") {
                    ForEach(Array(exchange.toolLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                            .textSelection(.enabled)
                    }
                }
                .font(RelayTheme.font(size: 11))
            }
            if exchange.reply.isEmpty && harness.isBusy {
                Text("Working…").foregroundStyle(RelayTheme.textMuted)
            } else {
                Text(RelayMikoPaneLinks.attributed(exchange.reply, panes: paneNames))
                    .textSelection(.enabled).lineSpacing(3)
                    .foregroundStyle(exchange.failed ? RelayTheme.coral : RelayTheme.text)
            }
            ForEach(exchange.messages) { message in
                HStack(spacing: 6) {
                    Image(systemName: message.readAcknowledged ? "checkmark.message" : "paperplane")
                    Text("To " + RelayAssistantActions.q(message.recipientName) + " · " +
                         (message.readAcknowledged ? "read" :
                          RelayAssistantHarness.awaitingConfirmationStatuses.contains(message.status) ? "sent; waiting for confirmation" :
                          RelayAssistantActions.singleLine(message.status)))
                        .font(RelayTheme.font(size: 10.5)).lineLimit(1)
                    Spacer()
                    Button("Check receipt") { Task { await harness.refreshReceipt(message.id) } }
                        .buttonStyle(.plain).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                        .accessibilityIdentifier("relay.assistant.message.receipt")
                }
            }
            if exchange.undo != nil {
                Button(exchange.undone ? "Undone" : "Undo") { harness.undo(exchange.id) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(exchange.undone || harness.isBusy)
                    .accessibilityLabel("Undo navigation")
                    .accessibilityIdentifier("relay.assistant.undo")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var savedTasks: some View {
        if !harness.taskRows.isEmpty {
            DisclosureGroup("Saved tasks (\(harness.taskRows.count))") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(harness.taskRows) { task in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.objective).font(RelayTheme.font(size: 11, weight: .medium)).lineLimit(2)
                                Text(task.status == "reportedComplete" ? "Result reported · verification separate" : task.status)
                                    .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                                if !task.unresolved.isEmpty {
                                    Text("Unresolved operations: " + task.unresolved.joined(separator: ", "))
                                        .font(RelayTheme.font(size: 9, design: .monospaced))
                                        .foregroundStyle(RelayTheme.coral).textSelection(.enabled)
                                }
                                HStack {
                                    Button("Continue") { harness.continueTask(task.id) }
                                        .disabled(harness.isBusy || !task.canContinue)
                                    if task.status != "reportedComplete" && task.status != "cancelled" {
                                        Button("Cancel task") { harness.cancelSavedTask(task.id) }
                                            .disabled(harness.isBusy)
                                    }
                                }.buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                }.frame(maxHeight: 170)
            }.font(RelayTheme.font(size: 11)).padding(.horizontal, 12).padding(.bottom, 8)
                .accessibilityIdentifier("relay.miko.saved-tasks")
        }
    }

    private var profile: some View {
        DisclosureGroup("What Miko knows") {
            ScrollView {
                Text(harness.profile.map { $0.text.isEmpty ? "Nothing yet." : $0.text } ??
                     "Built when you send your first request.")
                    .font(RelayTheme.font(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            if let profile = harness.profile {
                Text("Sent with every request to the Anthropic API under your account · sha256 " + String(profile.sha256.prefix(12)))
                    .font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted)
            }
        }
        .font(RelayTheme.font(size: 11))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .accessibilityIdentifier("relay.assistant.profile")
    }

    private func submit() {
        guard !harness.isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = draft
        followsLatest = true
        draft = ""
        harness.submit(request)
    }

    private func openControlCenter(_ section: String) {
        workspace.closeHaikuAssistant()
        workspace.performancePanelSection = section
        workspace.performancePanelVisible = true
    }

    private func close() { workspace.closeHaikuAssistant() }
}

/// The exact effect of one proposed Change action. Run sends the shown request once.
struct RelayAssistantActionCardView: View {
    let card: RelayAssistantActionCard
    let run: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield").foregroundStyle(RelayTheme.coral)
                Text(card.title).font(RelayTheme.font(size: 12.5, weight: .semibold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(card.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(left / 60):" + String(format: "%02d", left % 60))
                        .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                }
            }
            Text("Tool: " + card.tool.rawValue).font(RelayTheme.font(size: 11, design: .monospaced))
            ForEach(card.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 6) {
                    Text(row.label).font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted).frame(width: 96, alignment: .leading)
                    Text(row.value).font(RelayTheme.font(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let literal = card.literal {
                Text(card.literalLabel ?? "Text").font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                ScrollView {
                    Text(literal).font(RelayTheme.font(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(RelayTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("relay.assistant.card.literal")
            }
            if let blocked = card.blockedReason {
                Label(blocked, systemImage: "lock").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                    .accessibilityIdentifier("relay.assistant.card.blocked")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("relay.assistant.card.cancel")
                Button("Run", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(card.blockedReason != nil)
                    .accessibilityLabel("Run this action once")
                    .accessibilityIdentifier("relay.assistant.card.run")
            }
        }
        .padding(10)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RelayTheme.coral.opacity(0.6)))
        .accessibilityIdentifier("relay.assistant.card")
    }
}

// Focus the existing composer without replacing a draft or sending a request.
extension Notification.Name {
    static let relayMikoComposerFocus = Notification.Name("relay.miko-composer-focus")
}
