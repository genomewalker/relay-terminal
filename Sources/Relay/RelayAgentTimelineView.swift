import AppKit
import Combine
import SwiftUI
import WebKit
import UniformTypeIdentifiers

private struct RelayConversationSnapshot: Decodable {
    struct Binding: Decodable {
        let paneId: String
        let provider: String
        let processId: Int
        let processStart: String
        let sessionId: String
        let sourceIdentity: String
    }
    struct Image: Decodable { let reference: String }
    struct Item: Decodable {
        let id: String
        let role: String
        let text: String
        let images: [Image]?
        let toolName: String?
        let toolStatus: String?
        let revision: UInt64
    }
    struct Control: Decodable { let lifecycle: String; let revision: String; let observedAt: String }
    struct History: Decodable { let before: UInt64?; let historical: Bool }
    let history: History?
    let control: Control?
    let version: Int
    let binding: Binding?
    let directory: String?
    let items: [Item]?
    let unbound: String?
}

@MainActor final class RelayAgentTimelineStore: ObservableObject {
    @Published private(set) var conversation = RelayAgentConversation()
    @Published private(set) var control: RelayAgentConversationControl?
    @Published private(set) var olderCursor: UInt64?
    @Published private(set) var historical = false
    private var before: UInt64?
    private var historyBinding: RelayAgentConversationBinding?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var updatedAt: Date?
    private weak var pane: PaneModel?
    private var generation = UUID()
    private var refreshPending = false
    private(set) var rootPID = 0
    var visible = true
    /// False for offline presentation (previews, snapshot tests): never reads the host.
    let live: Bool
    init(pane: PaneModel) { self.pane = pane; live = true }
    /// Presents an already-read conversation without connecting to the host.
    init(pane: PaneModel, presenting conversation: RelayAgentConversation, failure: String? = nil) {
        self.pane = pane; live = false
        self.conversation = conversation; self.failure = failure
        updatedAt = conversation.binding == nil ? nil : Date()
    }
    func stop() { visible = false; generation = UUID() }

    func showOlder() async {
        guard !busy, let cursor = olderCursor, let binding = conversation.binding else { return }
        before = cursor; historyBinding = binding; historical = true; control = nil
        await refresh()
    }
    func showLatest() async {
        guard !busy else { return }
        before = nil; historyBinding = nil; historical = false
        await refresh()
    }
    func refreshLive() async {
        guard before == nil else { return }
        await refresh()
    }
    @discardableResult
    func refresh() async -> Bool {
        guard live, visible, let pane else { return false }
        if busy { refreshPending = true; return false }
        let token = generation
        let profile = pane.profile
        let identity = pane.id
        busy = true; failure = nil
        defer {
            busy = false
            if refreshPending {
                refreshPending = false
                Task { await self.refresh() }
            }
        }
        do {
            let paneID = pane.id.uuidString.lowercased()
            let rootPID = profile.kind == .local ? Int(pane.networkForegroundPID ?? 0) : 0
            let inputRevision = pane.agentInputRevision
            var arguments = ["agent-conversation", "--pane", paneID, "--root-pid", String(rootPID)]
            if let before, let historyBinding, let sourceIdentity = historyBinding.sourceIdentity {
                arguments += ["--before", String(before), "--source-identity", sourceIdentity, "--session", historyBinding.sessionID]
            }
            let command = RelayHostExecution.daemonCommand(profile: profile, arguments: arguments)
            let result = try await RelayHostExecution.capture(profile: profile, command: command,
                timeout: 15, maximumBytes: 600 << 10)
            try Task.checkCancellation()
            guard token == generation, visible, self.pane === pane, pane.id == identity, pane.profile == profile else { return false }
            guard result.exitCode == 0 else { throw RemoteCatalogError.failed("The conversation reader could not complete on this host.") }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let snapshot = try decoder.decode(RelayConversationSnapshot.self, from: result.stdout)
            guard snapshot.version == 1 else { throw RemoteCatalogError.invalidResponse }
            if let unbound = snapshot.unbound {
                conversation.bind(nil); control = nil; failure = unbound; updatedAt = nil; return false
            }
            guard let source = snapshot.binding, source.paneId == paneID,
                  let items = snapshot.items, items.count <= 256, source.sourceIdentity.utf8.count <= 80 else { throw RemoteCatalogError.invalidResponse }
            let binding = RelayAgentConversationBinding(hostID: profile.id.uuidString,
                paneID: pane.id, provider: source.provider, processID: source.processId,
                processStart: source.processStart, sessionID: source.sessionId,
                sourceIdentity: source.sourceIdentity)
            guard binding.isValid else { throw RemoteCatalogError.invalidResponse }
            if before == nil {
                RelayRecoveryStore.shared.observeConversation(binding, profile: profile, directory: snapshot.directory)
            }
            // The reader rechecks this pane's live process incarnation and
            // provider session. Use that identity to restore classification
            // after attaching without replaying a startup banner.
            if before == nil, pane.kind == .shell {
                if binding.provider == "claude" { pane.setAgentKind(.claude) }
                else if binding.provider == "codex" { pane.setAgentKind(.codex) }
            }
            if let historyBinding, binding != historyBinding {
                throw RemoteCatalogError.failed("The conversation process changed. Return to latest to read its current session.")
            }
            olderCursor = snapshot.history?.before
            historical = snapshot.history?.historical ?? false
            // Every response is a bounded resynchronization. Provider transcripts are the durable source.
            var next = RelayAgentConversation(); next.bind(binding)
            for item in items {
                guard let role = RelayAgentConversationItem.Role(rawValue: item.role) else { continue }
                var blocks: [RelayAgentConversationItem.Block]
                if let tool = item.toolName {
                    blocks = [.tool(name: tool, status: item.toolStatus ?? "unknown", summary: item.text)]
                } else { blocks = [.markdown(item.text)] }
                for image in (item.images ?? []).prefix(16) { blocks.append(.providerImage(reference: image.reference)) }
                _ = next.receive(.init(id: item.id, turnID: nil, role: role, blocks: blocks,
                                      revision: item.revision, complete: true), binding: binding)
            }
            let dateParser = ISO8601DateFormatter(); dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let proof = snapshot.control, let observedAt = dateParser.date(from: proof.observedAt), proof.revision.utf8.count <= 128, !proof.revision.isEmpty,
               pane.agentInputRevision == inputRevision {
                let baseline = control?.binding == binding && control?.revision == proof.revision &&
                    pane.agentLastInputAt >= observedAt
                    ? control!.inputRevision : inputRevision
                control = .init(binding: binding, lifecycle: proof.lifecycle, revision: proof.revision,
                                checkedAt: Date(), observedAt: observedAt, inputRevision: baseline)
            } else { control = nil }
            conversation = next; self.rootPID = rootPID; updatedAt = Date()
            return true
        } catch is CancellationError { }
        catch {
            guard token == generation, visible, self.pane === pane, pane.id == identity, pane.profile == profile else { return false }
            // Old content is never presented as the current process after a failed binding check.
            conversation.bind(nil); control = nil; updatedAt = nil
            failure = error.localizedDescription
        }
        return false
    }
}

struct RelayAgentTimelineView: View {
    @ObservedObject var pane: PaneModel
    @StateObject private var store: RelayAgentTimelineStore
    @ObservedObject private var composerState: PaneComposerState
    @ObservedObject private var attachmentQueue: RelayAgentAttachmentQueue
    @State private var atBottom = true
    @State private var unseen = false
    @State private var showingHeldResolution = false
    @FocusState private var composerFocused: Bool
    // Search reads only the bound, already-loaded items. It never touches the draft.
    @State private var searching = false
    @State private var query = ""
    @State private var matchIDs: [String] = []
    @State private var currentMatch: String?
    @State private var searchJump = 0
    @FocusState private var searchFocused: Bool
    /// The tool call Agent details asked for, outlined until the next request.
    @State private var focusedItem: String?
    init(pane: PaneModel, store: RelayAgentTimelineStore? = nil) {
        self.pane = pane; _store = StateObject(wrappedValue: store ?? RelayAgentTimelineStore(pane: pane))
        _composerState = ObservedObject(wrappedValue: pane.composerState)
        _attachmentQueue = ObservedObject(wrappedValue: pane.composerState.attachmentQueue)
    }
    private var draft: String {
        get { composerState.draft }
        nonmutating set { composerState.draft = newValue }
    }
    private var draftRestored: Bool { composerState.restored }
    private var submitting: Bool {
        get { composerState.submitting }
        nonmutating set { composerState.submitting = newValue }
    }
    private var submitted: Bool {
        get { composerState.submitted }
        nonmutating set { composerState.submitted = newValue }
    }
    private var nativeDeliveryHeld: Bool {
        get { composerState.nativeDeliveryHeld }
        nonmutating set { composerState.nativeDeliveryHeld = newValue }
    }
    private var stopRequested: Bool {
        get { composerState.stopRequested }
        nonmutating set { composerState.stopRequested = newValue }
    }
    private var submissionStatus: String? {
        get { composerState.submissionStatus }
        nonmutating set { composerState.submissionStatus = newValue }
    }
    var body: some View {
        RelayViewerLayout {
            header
        } content: {
            if searching { searchBar }
            if store.olderCursor != nil || store.historical {
                RelayViewerStrip {
                    Text(store.historical ? "Earlier messages · live updates paused" : "Latest messages")
                    Spacer()
                    if store.olderCursor != nil {
                        Button("Earlier") { Task { await store.showOlder() } }
                            .buttonStyle(RelayAgentQuietButtonStyle()).disabled(store.busy)
                    }
                    if store.historical {
                        Button("Return to latest") { Task { await store.showLatest() } }
                            .buttonStyle(RelayAgentQuietButtonStyle()).disabled(store.busy)
                    }
                }
                Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .task {
            composerState.restoreIfNeeded(hostID: draftHostID, paneID: pane.id)
            store.visible = true; await store.refresh()
        }
        .onChange(of: composerFocused) { _, focused in pane.runtime.conversationComposerOwnsFocus = focused }
        .onDisappear {
            pane.runtime.conversationComposerOwnsFocus = false
            if !draft.isEmpty || !attachmentQueue.attachments.isEmpty { persistDraft(immediate: true) }
            store.stop()
        }
        .onChange(of: draft) { old, text in
            // An empty value is persisted only when the user emptied a real draft, so an
            // unreadable store (empty restore) can never delete what is on disk.
            if draftRestored && !submitted && (!text.isEmpty || !old.isEmpty) { persistDraft() }
        }
        .onChange(of: attachmentQueue.attachments) { _, _ in
            if draftRestored && !submitted { persistDraft() }
        }
        .onChange(of: pane.lastCompletedAgentTurn) { _, _ in
            Task { await store.refreshLive() }
        }
        .onChange(of: store.control) { _, control in
            if submitted || stopRequested, let control, control.lifecycle == "quiet",
               control.observedAt > pane.agentLastInputAt,
               control.inputRevision == pane.agentInputRevision {
                submitted = false
                stopRequested = false
                submissionStatus = nil
            }
        }
        // Follow the original process's activity notifications. Coalesce bursts
        // without starting a timer or a second provider session.
        .onReceive(pane.objectWillChange.throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)) { _ in
            Task { await store.refreshLive() }
        }
        .onChange(of: store.conversation.binding) { _, _ in closeSearch() }
        .onChange(of: contentSignature) { _, _ in if searching { updateMatches(keepCurrent: true) } }
        .onChange(of: query) { _, _ in updateMatches(keepCurrent: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            if let window = event.object as? NSWindow, window.identifier?.rawValue == "relay.agent." + pane.id.uuidString, !store.visible {
                store.visible = true; Task { await store.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if let window = event.object as? NSWindow, window.identifier?.rawValue == "relay.agent." + pane.id.uuidString {
                if !draft.isEmpty || !attachmentQueue.attachments.isEmpty { persistDraft(immediate: true) }
                store.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if !draft.isEmpty || !attachmentQueue.attachments.isEmpty { persistDraft(immediate: true) }
        }
    }

    // MARK: Header

    /// Inside a pane the pane header above already names the pane and shows
    /// its status, so the bar says what this view is; in its own window it
    /// carries the pane's name and status itself.
    static func headerTitle(paneName: String, inPane: Bool) -> String { inPane ? "Conversation" : paneName }

    static func bindingDetail(_ binding: RelayAgentConversationBinding?, busy: Bool) -> String {
        if let binding {
            return binding.provider.capitalized + " · PID " + String(binding.processID) + " · " + String(binding.sessionID.prefix(12))
        }
        return busy ? "Reading the conversation source…" : "Not bound to a conversation"
    }

    private var header: some View {
        let inPane = pane.nativeConversationVisible
        // In a pane, closing returns to its terminal and leaves the agent
        // running; a separate window closes with its own window controls.
        return RelayViewerBar(symbol: "text.bubble",
                              title: Self.headerTitle(paneName: pane.displayName, inPane: inPane),
                              detail: Self.bindingDetail(store.conversation.binding, busy: store.busy),
                              close: inPane ? { returnToTerminal() } : nil,
                              closeLabel: "Close conversation and return to the terminal; the agent keeps running") {
            if !inPane, pane.phase == .active, let status = pane.headerStatus {
                RelayTimelineActivity(status: status.text, detail: pane.headerActivityDetail,
                                      since: pane.agentActivities.last?.occurredAt)
            }
            if store.busy { ProgressView().controlSize(.mini) }
            if let date = store.updatedAt {
                Text(date, style: .time).font(RelayViewerMetrics.identifier).foregroundStyle(RelayTheme.textFaint)
                    .help("Last read from the provider transcript")
            }
            RelayViewerIconButton(title: "Find in conversation", symbol: "magnifyingglass") { openSearch() }
                .disabled(store.conversation.items.isEmpty).help("Find in conversation (⌘F)")
                .accessibilityIdentifier("relay.agent.search.open")
                .keyboardShortcut("f", modifiers: .command)
            RelayViewerIconButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await store.refresh() } }
                .disabled(store.busy).help("Read the conversation again")
                .accessibilityIdentifier("relay.agent.refresh")
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func returnToTerminal() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pane.nativeConversationVisible = false }
    }

    // MARK: Content states

    @ViewBuilder private var content: some View {
        if let error = store.failure {
            let shown = RelayConversationErrorText.userFacing(error)
            if let raw = shown.detail {
                stateView(symbol: "exclamationmark.triangle", title: "Conversation not loaded", detail: shown.message,
                          note: nil, retry: true, rawDetail: raw)
            } else {
                stateView(symbol: "link.badge.plus", title: "Not bound to a conversation", detail: error,
                          note: "Relay binds only to the exact provider session of this pane's process. The terminal is unaffected.",
                          retry: true)
            }
        } else if store.conversation.binding == nil {
            if store.busy {
                VStack(spacing: RelayTheme.spacing(10)) {
                    ProgressView().controlSize(.small)
                    Text("Reading the conversation source…").font(RelayTheme.font(size: 12)).foregroundStyle(RelayAgentDesign.secondaryInk)
                }
            } else {
                stateView(symbol: "text.bubble", title: "No conversation read yet", detail: nil, note: nil, retry: true)
            }
        } else if store.conversation.items.isEmpty {
            stateView(symbol: "text.bubble", title: "No messages yet",
                      detail: "This session has no user or assistant messages to show.", note: nil, retry: false)
        } else {
            transcript
        }
    }

    private func stateView(symbol: String, title: String, detail: String?, note: String?, retry: Bool,
                           rawDetail: String? = nil) -> some View {
        VStack(spacing: RelayTheme.spacing(8)) {
            Image(systemName: symbol).font(RelayTheme.font(size: 22, weight: .light)).foregroundStyle(RelayAgentDesign.tertiaryInk)
            Text(title).font(RelayTheme.font(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(RelayTheme.font(size: 12)).foregroundStyle(RelayAgentDesign.secondaryInk)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            if let note {
                Text(note).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk).multilineTextAlignment(.center)
            }
            if let rawDetail { RelayErrorDetails(raw: rawDetail) }
            if retry {
                Button("Try again") { Task { await store.refresh() } }
                    .buttonStyle(RelayAgentPrimaryButtonStyle()).disabled(store.busy).padding(.top, RelayTheme.spacing(4))
                    .accessibilityIdentifier("relay.agent.retry")
            }
        }
        .frame(maxWidth: 380).padding(RelayTheme.spacing(24))
    }

    // MARK: Transcript

    /// Changes whenever an item is added or revised, without hashing message bodies.
    private var contentSignature: [UInt64] {
        store.conversation.items.suffix(4).map(\.revision) + [UInt64(store.conversation.items.count)]
    }

    /// Unanswered trailing calls while the pane's agent is working.
    private var liveToolIndices: Set<Int> {
        let statuses = store.conversation.items.map { item -> String? in
            guard item.role == .tool, case .tool(_, let status, _)? = item.blocks.first else { return nil }
            return status
        }
        return RelayToolPresentation.liveIndices(statuses: statuses, active: pane.phase == .active && !store.historical)
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // The reader supplies a bounded page (256 items / 512 KiB).
                    // Lay that page out deterministically: macOS lazy-stack
                    // placement can spin when scrolling directly to the end of
                    // variable-height transcript rows on first presentation.
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                        notices
                        let live = liveToolIndices
                        ForEach(Array(store.conversation.items.enumerated()), id: \.element.id) { index, item in
                            RelayAgentMessageView(pane: pane, item: item, live: live.contains(index))
                                .background(searchMark(for: item.id))
                                .background(focusMark(for: item.id))
                                .padding(.top, item.role == .user && index > 0
                                    ? max(0, RelayAgentDesign.turnSpacing - RelayTheme.spacing(12)) : 0)
                                .id(item.id)
                        }
                        // Keep the destination beside its fully measured message
                        // rows so the initial end position has no estimated heights.
                        Color.clear.frame(height: 1).id(Self.endAnchor)
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: RelayAgentBottomKey.self,
                                                       value: marker.frame(in: .named(Self.space)).maxY)
                            })
                    }
                    .frame(maxWidth: RelayAgentDesign.columnWidth)
                    .padding(.horizontal, RelayAgentDesign.gutter).padding(.vertical, RelayTheme.spacing(18))
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(RelayAgentBottomKey.self) { maxY in
                    let near = maxY - viewport.size.height <= RelayAgentDesign.nearBottom
                    if near != atBottom { atBottom = near }
                    if near { unseen = false }
                }
                .onAppear {
                    proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                    applyFocus(proxy)
                }
                .onChange(of: pane.conversationFocus) { _, _ in applyFocus(proxy) }
                .onChange(of: store.conversation.items.count) { _, _ in applyFocus(proxy) }
                .onChange(of: searchJump) { _, _ in
                    guard let target = currentMatch else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: contentSignature) { _, _ in
                    // Follow new output only when the reader is already at the end.
                    if atBottom { proxy.scrollTo(Self.endAnchor, anchor: .bottom) } else { unseen = true }
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        Button { unseen = false; withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.endAnchor, anchor: .bottom) } } label: {
                            Label(unseen ? "New messages" : "Jump to latest", systemImage: "arrow.down")
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .padding(.horizontal, RelayTheme.spacing(10)).frame(height: 24)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(RelayAgentDesign.stroke))
                        }
                        .buttonStyle(.plain).padding(.bottom, RelayTheme.spacing(10))
                        .accessibilityIdentifier("relay.agent.jump-latest")
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if pane.pendingAgentApprovals > 0 {
            RelayAgentNotice(symbol: "hand.raised", text: "Approval requested. Answer it in the original terminal.", tint: .orange)
        }
        if pane.activeSubagents > 0 {
            RelayAgentNotice(symbol: "person.2", text: "\(pane.activeSubagents) active subagent\(pane.activeSubagents == 1 ? "" : "s")")
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Image(systemName: "magnifyingglass").font(RelayTheme.font(size: 11)).foregroundStyle(RelayAgentDesign.tertiaryInk)
            TextField("Find in conversation", text: $query)
                .textFieldStyle(.plain).font(RelayTheme.font(size: 12))
                .focused($searchFocused)
                .onSubmit { step(1) }
                .onExitCommand { closeSearch() }
                .accessibilityLabel("Find in conversation")
                .accessibilityIdentifier("relay.agent.search.field")
            Text(searchCountText)
                .font(RelayAgentDesign.meta).monospacedDigit().foregroundStyle(RelayAgentDesign.tertiaryInk)
                .accessibilityLabel(searchCountAccessibility)
                .accessibilityIdentifier("relay.agent.search.count")
            Button("Previous match", systemImage: "chevron.up") { step(-1) }
                .buttonStyle(RelayAgentQuietButtonStyle()).labelStyle(.iconOnly)
                .disabled(matchIDs.isEmpty).help("Previous match (⇧⌘G)")
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityIdentifier("relay.agent.search.previous")
            Button("Next match", systemImage: "chevron.down") { step(1) }
                .buttonStyle(RelayAgentQuietButtonStyle()).labelStyle(.iconOnly)
                .disabled(matchIDs.isEmpty).help("Next match (↩ or ⌘G)")
                .keyboardShortcut("g", modifiers: .command)
                .accessibilityIdentifier("relay.agent.search.next")
            Button("Close search", systemImage: "xmark") { closeSearch() }
                .buttonStyle(RelayAgentQuietButtonStyle()).labelStyle(.iconOnly)
                .help("Close (Esc)")
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("relay.agent.search.close")
        }
        .padding(.horizontal, RelayTheme.spacing(10)).frame(height: 30)
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { acceptAttachmentDrop($0) }
        .background(RelayAgentDesign.composerFill, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)).strokeBorder(searchFocused ? Color.primary.opacity(0.20) : Color.primary.opacity(0.10)))
        .padding(.horizontal, RelayTheme.spacing(RelayViewerMetrics.barPadding)).padding(.vertical, RelayTheme.spacing(8))
    }

    private var searchCountText: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if matchIDs.isEmpty { return "No matches" }
        guard let currentMatch, let index = matchIDs.firstIndex(of: currentMatch) else { return "\(matchIDs.count) found" }
        return "\(index + 1) of \(matchIDs.count)"
    }

    private var searchCountAccessibility: String {
        searchCountText.isEmpty ? "No search" : searchCountText.replacingOccurrences(of: " found", with: " matching messages")
    }

    @ViewBuilder private func focusMark(for id: String) -> some View {
        if id == focusedItem {
            RoundedRectangle(cornerRadius: RelayAgentDesign.radius)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                .padding(-6)
        }
    }

    /// Scrolls to the call a step in Agent details names. Waits while the
    /// page is still empty; gives up quietly (staying at the end) when the
    /// loaded page does not hold that call.
    private func applyFocus(_ proxy: ScrollViewProxy) {
        guard let focus = pane.conversationFocus, !store.conversation.items.isEmpty else { return }
        pane.conversationFocus = nil
        guard let target = focus.target(in: store.conversation.items) else { return }
        focusedItem = target
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
    }

    @ViewBuilder private func searchMark(for id: String) -> some View {
        if searching, id == currentMatch {
            RoundedRectangle(cornerRadius: RelayAgentDesign.radius)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: RelayAgentDesign.radius))
                .padding(-6)
        } else if searching, matchIDs.contains(id) {
            RoundedRectangle(cornerRadius: RelayAgentDesign.radius).fill(RelayAgentDesign.wash).padding(-6)
        }
    }

    private func openSearch() {
        searching = true
        searchFocused = true
        updateMatches(keepCurrent: true)
    }

    private func closeSearch() {
        searching = false
        query = ""
        matchIDs = []
        currentMatch = nil
    }

    /// Case- and diacritic-insensitive match over bounded, already-loaded source text.
    private func updateMatches(keepCurrent: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searching, !needle.isEmpty, needle.count <= 256 else { matchIDs = []; currentMatch = nil; return }
        matchIDs = store.conversation.items.compactMap { item in
            let text = String(RelayAgentMessageView.plainText(item.blocks).prefix(262_144))
            return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : item.id
        }
        if keepCurrent, let currentMatch, matchIDs.contains(currentMatch) { return }
        currentMatch = nil
    }

    private func step(_ direction: Int) {
        guard !matchIDs.isEmpty else { return }
        let next: Int
        if let currentMatch, let index = matchIDs.firstIndex(of: currentMatch) {
            next = (index + direction + matchIDs.count) % matchIDs.count
        } else {
            next = direction > 0 ? 0 : matchIDs.count - 1
        }
        currentMatch = matchIDs[next]
        searchJump &+= 1
    }

    private static let space = "relay.agent.transcript"
    private static let endAnchor = "relay.agent.transcript.end"

    // MARK: Composer

    /// Drafts are scoped to this host profile and pane, matching the conversation binding's host.
    private var draftHostID: String { pane.profile.id.uuidString }

    private var attachmentsReady: Bool {
        attachmentQueue.attachments.isEmpty || (store.conversation.binding.map { binding in
            attachmentQueue.attachments.allSatisfy { $0.ready(for: binding) }
        } ?? false)
    }

    private var composedMessage: String {
        var lines: [String] = []
        var imageIndex = 0
        for item in attachmentQueue.attachments {
            var metadata = ["name": item.name]
            if item.kind == .image {
                imageIndex += 1
                metadata["image"] = String(imageIndex)
            } else if let path = item.uploadedPath { metadata["path"] = path }
            else { continue }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(metadata), let text = String(data: data, encoding: .utf8) { lines.append(text) }
        }
        guard !lines.isEmpty else { return draft }
        return draft + (draft.isEmpty ? "" : "\n\n") + "Attachments (image numbers match the attached images; read files at their paths):\n" + lines.joined(separator: "\n")
    }

    private func persistDraft(immediate: Bool = false) {
        composerState.persist(hostID: draftHostID, paneID: pane.id, immediate: immediate)
    }

    private var attachmentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachmentQueue.attachments) { item in
                HStack(spacing: 8) {
                    RelayAgentAttachmentPreview(attachment: item, pane: pane)
                    VStack(alignment: .leading) {
                        Text(item.name).lineLimit(1)
                        if item.nativeImageSnapshot != nil {
                            Text("Prepared as PNG · up to 4096 px · first frame").font(RelayAgentDesign.meta)
                        }
                        if let failure = attachmentQueue.failures[item.id] {
                            Text(failure).font(RelayAgentDesign.meta).lineLimit(2)
                        }
                    }
                    Spacer()
                    if attachmentQueue.uploading.contains(item.id) {
                        if let progress = attachmentQueue.progress[item.id] {
                            RelayTransferProgressView(progress: progress).frame(width: 200)
                        } else { ProgressView().controlSize(.small) }
                    }
                    else if let binding = store.conversation.binding, !item.ready(for: binding) {
                        Button(attachmentQueue.failures[item.id] == nil ? "Prepare" : "Retry") {
                            prepareAttachment(item.id, resume: attachmentQueue.failures[item.id] != nil)
                        }.buttonStyle(RelayAgentQuietButtonStyle())
                    }
                    Button { attachmentQueue.remove(item.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(RelayAgentQuietButtonStyle()).accessibilityLabel("Remove " + item.name)
                }.disabled(submitting || submitted)
            }
        }.font(RelayAgentDesign.meta).padding(10)
    }

    private func prepareAttachment(_ id: UUID, resume: Bool = false) {
        guard let binding = store.conversation.binding else { return }
        attachmentQueue.prepare(id, pane: pane, binding: binding, resume: resume) {
            store.conversation.binding == binding
        }
    }

    private func stageAttachments(_ urls: [URL]) {
        guard !submitting, !submitted else { return }
        submissionStatus = nil
        attachmentQueue.stage(urls)
        for item in attachmentQueue.attachments {
            if let binding = store.conversation.binding, !item.ready(for: binding) { prepareAttachment(item.id) }
        }
    }

    private func chooseAttachments() {
        let profile = pane.profile
        let binding = store.conversation.binding
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK, pane.profile == profile, store.conversation.binding == binding else { return }
            stageAttachments(panel.urls)
        }
    }

    private func acceptAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !submitting, !submitted else { return false }
        let profile = pane.profile
        let binding = store.conversation.binding
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    Task { @MainActor in
                        guard !submitting, !submitted, pane.profile == profile,
                              store.conversation.binding == binding else { return }
                        guard let url, url.isFileURL else {
                            attachmentQueue.reportIntakeFailure("Could not read this file. Choose it with the attachment button.")
                            return
                        }
                        stageAttachments([url])
                    }
                }
            } else if let type = [UTType.png, .tiff, .image].first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    Task { @MainActor in
                        guard !submitting, !submitted, pane.profile == profile,
                              store.conversation.binding == binding else { return }
                        guard let data else {
                            attachmentQueue.reportIntakeFailure("Could not read this image. Choose it with the attachment button.")
                            return
                        }
                        submissionStatus = nil
                        attachmentQueue.stageImage(data)
                        for item in attachmentQueue.attachments {
                            if let binding, !item.ready(for: binding) { prepareAttachment(item.id) }
                        }
                    }
                }
            }
        }
        return accepted
    }

    private var sendDisabled: Bool {
        (pane.profile.kind != .local && pane.profile.backend != .relay) || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentQueue.attachments.isEmpty) ||
            composedMessage.utf8.count > 65536 || !attachmentsReady || nativeDeliveryHeld ||
            submitting || submitted || store.busy || store.conversation.binding == nil ||
            store.control?.lifecycle != "quiet" || store.control?.inputRevision != pane.agentInputRevision ||
            (store.control?.observedAt ?? .distantPast) <= pane.agentLastInputAt || pane.pendingAgentApprovals > 0
    }

    private var composerHint: String {
        if let submissionStatus { return submissionStatus }
        if let failure = attachmentQueue.intakeFailure { return failure }
        if !attachmentQueue.uploading.isEmpty { return "Preparing attached files…" }
        if nativeDeliveryHeld { return "Attachments remain in the original terminal. Review and send there." }
        if !attachmentsReady { return "Prepare attached files for the current agent before sending." }
        if pane.profile.kind != .local && pane.profile.backend != .relay { return "Use the original terminal; this connection has no verified pane transport." }
        if store.conversation.binding == nil { return "Sending needs an exact conversation binding." }
        if pane.pendingAgentApprovals > 0 { return "Answer the pending approval in the original terminal first." }
        if store.control == nil { return "Authenticated lifecycle is unavailable on this host. Use the original terminal." }
        if store.control?.lifecycle == "stop_observed" { return "Waiting for the agent to confirm it is idle." }
        if store.control?.inputRevision != pane.agentInputRevision { return "Waiting for a new authenticated idle state after terminal input." }
        if (store.control?.observedAt ?? .distantPast) <= pane.agentLastInputAt { return "Waiting for authenticated idle confirmation after the last input or reconnect." }
        switch store.control?.lifecycle {
        case "active": return "The agent is working. Send when it confirms idle."
        case "needs_input": return "The agent is waiting for input in the original terminal."
        case "exited": return "The agent process has exited. Nothing can be sent."
        case "quiet": break
        default: return "Agent state is not confirmed yet."
        }
        if composedMessage.utf8.count > 65536 { return "Message is too long." }
        return "Sends through the original terminal · ⌘↩"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            if !attachmentQueue.attachments.isEmpty { attachmentList }
            if nativeDeliveryHeld {
                Button("Resolve submission…") { showingHeldResolution = true }
                    .buttonStyle(RelayAgentQuietButtonStyle())
                    .padding(.horizontal, RelayTheme.spacing(10))
                    .padding(.top, RelayTheme.spacing(8))
                    .accessibilityIdentifier("relay.agent.resolve-held-submission")
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Message the running agent")
                        .font(RelayAgentDesign.prose).foregroundStyle(RelayAgentDesign.tertiaryInk)
                        .padding(.horizontal, RelayTheme.spacing(5)).padding(.vertical, RelayTheme.spacing(1)).allowsHitTesting(false)
                }
                TextEditor(text: $composerState.draft)
                    .font(RelayAgentDesign.prose)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(minHeight: 44, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Message to the existing agent")
                    .accessibilityIdentifier("relay.agent.composer")
                    .disabled(submitting || submitted)
                    .onPasteCommand(of: [UTType.fileURL, UTType.image]) { _ = acceptAttachmentDrop($0) }
            }
            .padding(.horizontal, RelayTheme.spacing(10)).padding(.top, RelayTheme.spacing(10))
            HStack(spacing: RelayTheme.spacing(8)) {
                Button { chooseAttachments() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(RelayAgentQuietButtonStyle())
                    .accessibilityLabel("Attach files")
                    .disabled(submitting || submitted)
                Text(composerHint).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk).lineLimit(2)
                Spacer(minLength: 8)
                if submitted || nativeDeliveryHeld {
                    Button("Return to terminal") {
                        pane.nativeConversationVisible = false
                        pane.runtime.view.window?.makeKeyAndOrderFront(nil)
                    }
                        .buttonStyle(RelayAgentQuietButtonStyle())
                        .accessibilityIdentifier("relay.agent.return-to-terminal")
                }
                if submitting { ProgressView().controlSize(.small) }
                if store.control?.lifecycle == "active" {
                    Button("Stop") { interrupt() }
                        .buttonStyle(RelayAgentQuietButtonStyle())
                        .accessibilityIdentifier("relay.agent.stop")
                        .disabled(submitting || stopRequested || pane.pendingAgentApprovals > 0)
                }
                Button("Send") { submit() }
                    .buttonStyle(RelayAgentPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("relay.agent.send")
                    .disabled(sendDisabled)
            }
            .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(8))
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { acceptAttachmentDrop($0) }
        .confirmationDialog("Resolve the submission in the original terminal", isPresented: $showingHeldResolution, titleVisibility: .visible) {
            Button("Enable Send and keep draft") {
                nativeDeliveryHeld = false
                submissionStatus = "Draft retained. Review it before sending again."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check whether the message was submitted, and clear any pending input. Enabling Send keeps this draft. Edit or clear it if the message was already sent.")
        }
        .background(RelayAgentDesign.composerFill, in: RoundedRectangle(cornerRadius: RelayAgentDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: RelayAgentDesign.radius)
            .strokeBorder(composerFocused ? Color.primary.opacity(0.20) : Color.primary.opacity(0.10)))
        .frame(maxWidth: RelayAgentDesign.columnWidth)
        .padding(.horizontal, RelayAgentDesign.gutter).padding(.top, RelayTheme.spacing(6)).padding(.bottom, RelayTheme.spacing(14))
        .frame(maxWidth: .infinity)
    }
    private func interrupt() {
        guard let binding = store.conversation.binding, !submitting, !stopRequested else { return }
        let inputRevision = pane.agentInputRevision
        submitting = true
        Task { @MainActor in
            defer { submitting = false }
            guard await store.refresh(), pane.agentInputRevision == inputRevision,
                  store.conversation.binding == binding, store.failure == nil,
                  let control = store.control,
                  pane.runtime.interruptConversation(paneID: pane.id, rootPID: store.rootPID, control: control) else {
                submissionStatus = "Not stopped. Refresh the agent state or use the original terminal."
                return
            }
            stopRequested = true
            submissionStatus = "Stop requested once. Waiting for the agent to confirm it is idle."
            Task { await store.refreshLive() }
        }
    }

    private func submit() {
        guard !sendDisabled, let binding = store.conversation.binding else { return }
        let message = composedMessage
        let attachmentSnapshot = attachmentQueue.attachments
        let inputRevision = pane.agentInputRevision
        submitting = true
        Task { @MainActor in
            defer { submitting = false }
            guard await attachmentQueue.validateForSend(binding: binding),
                  attachmentQueue.attachments == attachmentSnapshot,
                  pane.agentInputRevision == inputRevision,
                  await store.refresh(),
                  pane.agentInputRevision == inputRevision,
                  store.conversation.binding == binding, store.failure == nil,
                  let control = store.control else {
                submissionStatus = "Not sent. Check the attached files and the original terminal."
                return
            }
            let images = attachmentSnapshot.filter { $0.kind == .image }.compactMap(\.uploadedPath)
            let result = await pane.runtime.sendConversationPrompt(message, imagePaths: images,
                paneID: pane.id, rootPID: store.rootPID, control: control) {
                    guard attachmentQueue.attachments == attachmentSnapshot,
                          await attachmentQueue.validateForSend(binding: binding),
                          await store.refresh(), store.failure == nil,
                          attachmentQueue.attachments == attachmentSnapshot,
                          store.conversation.binding == binding else { return nil }
                    return store.control
                }
            switch result {
            case .notSent:
                submissionStatus = "Not sent. Check the original terminal is ready and its prompt is empty."
                return
            case .stagedOnly:
                nativeDeliveryHeld = true
                submissionStatus = "Input may remain in the original terminal. No submit was attempted; review it there."
                return
            case .submissionUncertain:
                nativeDeliveryHeld = true
                submissionStatus = "Submission outcome is unknown. Check the original terminal before sending again."
                return
            case .submitted: break
            }
            submitted = true
            // Confirmed submission is the only path that discards the stored draft on purpose.
            RelayAgentDraftStore.shared.remove(hostID: draftHostID, paneID: pane.id)
            draft = ""
            for item in attachmentQueue.attachments { attachmentQueue.remove(item.id) }
            submissionStatus = "Submitted once. Waiting for a completed turn; reconnect never resends it."
        }
    }
}

/// "Working · Using Bash · 12 s" beside the header; elapsed counts from the
/// pane's latest activity event.
private struct RelayTimelineActivity: View {
    let status: String
    let detail: String?
    let since: Date?
    var body: some View {
        HStack(spacing: RelayTheme.spacing(5)) {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            TimelineView(.periodic(from: since ?? Date(), by: 1)) { context in
                Text(([status] + [detail, since.map { RelayToolPresentation.elapsed(context.date.timeIntervalSince($0)) }]
                    .compactMap { $0 }).joined(separator: " · "))
                    .monospacedDigit()
            }
        }
        .font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.secondaryInk).lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("relay.agent.activity")
    }
}

/// The raw diagnostic behind a plain error sentence, kept selectable for support.
struct RelayErrorDetails: View {
    let raw: String
    @State private var open = false
    var body: some View {
        VStack(spacing: RelayTheme.spacing(4)) {
            Button(open ? "Hide details" : "Details") { open.toggle() }
                .buttonStyle(RelayAgentQuietButtonStyle())
                .accessibilityIdentifier("relay.agent.error-details")
            if open {
                Text(raw).font(RelayAgentDesign.mono).foregroundStyle(RelayAgentDesign.secondaryInk)
                    .textSelection(.enabled).multilineTextAlignment(.leading)
            }
        }
        .help(raw)
    }
}

private struct RelayAgentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
