import AppKit
import SwiftUI
import ImageIO

enum PluginToolPresentationStyle { case sheet, dock, overlay, floating }

/// Scope is captured when this sheet opens. Switching tabs cannot retarget work.
struct RelayPluginToolsView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var manager: RelayPluginManager
    @ObservedObject private var chrome: WorkspaceChrome
    private let presentationStyle: PluginToolPresentationStyle
    init(workspace: WorkspaceModel, manager: RelayPluginManager = .shared,
         presentation: PluginToolPresentation, chrome: WorkspaceChrome,
         presentationStyle: PluginToolPresentationStyle = .sheet) {
        self.workspace = workspace
        self.manager = manager
        self.chrome = chrome
        self.presentationStyle = presentationStyle
        _session = ObservedObject(wrappedValue: presentation)
    }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session: PluginToolPresentation
    @State private var presenterID = UUID()
    @State private var ownsPresentation = false
    @State private var queueResult: PluginOperationResult?
    @State private var historyResult: PluginOperationResult?
    @State private var showingHistory = false
    @State private var queueDigest: String?
    @State private var allQueueUsers = false
    @State private var gitFiles: [String] = []
    @State private var queueUser = ""
    @State private var inspectedJob: String?
    @State private var showSchedulerAction = false
    @State private var reviewedRequest: PluginReviewedRequest?
    private var operationLifetime: PluginPresentationOperation { session.operationLifetime }
    private var capturedPane: (id: UUID, profile: ConnectionProfile, directory: String?)? {
        get { session.capturedPane }
        nonmutating set { session.capturedPane = newValue }
    }
    private var selection: String {
        get { session.selection }
        nonmutating set { session.selection = newValue }
    }
    private var path: String {
        get { session.path }
        nonmutating set { session.path = newValue }
    }
    private var entrySearch: String {
        get { session.entrySearch }
        nonmutating set { session.entrySearch = newValue }
    }
    private var logStream: String {
        get { session.logStream }
        nonmutating set { session.logStream = newValue }
    }
    private var batchScript: String {
        get { session.batchScript }
        nonmutating set { session.batchScript = newValue }
    }
    private var projectCommand: String {
        get { session.projectCommand }
        nonmutating set { session.projectCommand = newValue }
    }
    private var actionConfirmation: String {
        get { session.actionConfirmation }
        nonmutating set { session.actionConfirmation = newValue }
    }
    private var reviewingAction: Bool {
        get { session.reviewingAction }
        nonmutating set { session.reviewingAction = newValue }
    }
    private var mutationAttempted: Bool {
        get { session.mutationAttempted }
        nonmutating set { session.mutationAttempted = newValue }
    }
    private var selectedJobFromList: String? {
        get { session.selectedJobFromList }
        nonmutating set { session.selectedJobFromList = newValue }
    }
    private var result: PluginOperationResult? {
        get { cacheDisplayAllowed ? session.result : nil }
        nonmutating set { session.result = newValue }
    }
    private var fileBytes: Data? {
        get { cacheDisplayAllowed ? session.fileBytes : nil }
        nonmutating set { session.fileBytes = newValue }
    }
    private var transferPath: String? {
        get { session.transferPath }
        nonmutating set { session.transferPath = newValue }
    }
    private var imagePreview: NSImage? {
        get { session.imagePreview }
        nonmutating set { session.imagePreview = newValue }
    }
    private var textPreview: String? {
        get { session.textPreview }
        nonmutating set { session.textPreview = newValue }
    }
    private var markdownPreview: AttributedString? {
        get { session.markdownPreview }
        nonmutating set { session.markdownPreview = newValue }
    }
    private var showMarkdownSource: Bool {
        get { session.showMarkdownSource }
        nonmutating set { session.showMarkdownSource = newValue }
    }
    private var tablePreview: [[String]]? {
        get { session.tablePreview }
        nonmutating set { session.tablePreview = newValue }
    }
    private var previewPartial: Bool {
        get { session.previewPartial }
        nonmutating set { session.previewPartial = newValue }
    }
    private var agentSnapshot: PluginAgentSnapshot? {
        get { session.agentSnapshot }
        nonmutating set { session.agentSnapshot = newValue }
    }
    private var error: String? {
        get { session.error }
        nonmutating set { session.error = newValue }
    }
    private var busy: Bool {
        get { session.busy }
        nonmutating set { session.busy = newValue }
    }
    private var showingManager: Bool {
        get { session.showingManager }
        nonmutating set { session.showingManager = newValue }
    }

    private struct Tool: Identifiable {
        let id: String
        let pluginID: String
        let digest: String
        let title: String
        let operation: RelayPluginOperation
    }

    private var tools: [Tool] {
        guard !RelayLaunchMode.isSafeMode else { return [] }
        return manager.installations.sorted(by: { $0.key < $1.key }).flatMap { id, installation -> [Tool] in
            guard installation.enabled, let package = manager.reviewedInstallations[id]?.package else { return [] }
            return package.contributions.compactMap { entry in
                guard entry.kind == .tool, let operation = entry.operation else { return nil }
                return Tool(id: id + ":" + entry.id, pluginID: id, digest: installation.current.digest, title: entry.title, operation: operation)
            }
        }
    }

    private var scope: PluginScope? {
        guard let capturedPane, let tool = tools.first(where: { $0.id == selection }) else { return nil }
        return try? PluginScope.captured(paneID: capturedPane.id, profile: capturedPane.profile,
                                        directory: capturedPane.directory, operation: tool.operation)
    }

    private var selectedTool: Tool? { tools.first(where: { $0.id == selection }) }
    private var hasUnfinishedWork: Bool {
        busy || reviewingAction || mutationAttempted || selectedTool?.operation.isMutation == true
    }
    private func destination(for operation: RelayPluginOperation) -> ContextDestination {
        switch operation {
        case .gitReview: .changes
        case .hpcJobs, .hpcAccounting, .hpcDetails, .hpcLogs, .hpcSubmit, .hpcCancel: .jobs
        case .rWorkspace: .rWorkspace
        case .agentActivity: .participant
        default: .files
        }
    }
    private var cacheDisplayAllowed: Bool {
        guard chrome.visible, chrome.presentationActive,
              session.cacheValidated, let stamp = session.resultStamp,
              let tool = selectedTool, tool.pluginID == stamp.pluginID,
              tool.digest == stamp.digest, tool.operation == stamp.operation,
              scope == stamp.scope else { return false }
        return true
    }
    private var currentReview: PluginReviewedRequest? {
        guard let tool = selectedTool, let scope else { return nil }
        return PluginReviewedRequest(pluginID: tool.pluginID, digest: tool.digest,
            operation: tool.operation, scope: scope, path: path,
            script: tool.operation == .projectRun ? projectCommand : batchScript)
    }
    private var confirmationMatches: Bool {
        guard let tool = selectedTool else { return false }
        return actionConfirmation == (tool.operation == .projectRun ? "RUN" : tool.operation == .hpcSubmit ? "SUBMIT" : path) && !actionConfirmation.isEmpty
    }

    var body: some View {
        Group {
            if ownsPresentation {
                if let tool = selectedTool, tool.operation == .vpn {
                    RelayVPNPanel(workspace: workspace, pluginID: tool.pluginID, digest: tool.digest)
                } else if presentationStyle == .overlay && !showSchedulerAction {
                    hpcDashboard
                } else {
                    ownedContent
                }
            } else {
                VStack(spacing: RelayTheme.spacing(12)) {
                    Text("Plugin tools are already open or opening.")
                    Button("Done") { dismiss() }
                }.padding(RelayTheme.spacing(22))
            }
        }
        .task {
            guard session.claimPresenter(presenterID) else { return }
            ownsPresentation = true
            chrome.setDraft(hasUnfinishedWork)
            chrome.resumePresentation()
            manager.refresh()
            if capturedPane == nil, selectedTool?.operation != .vpn { error = "Reopen tools from a terminal pane." }
            await revalidateCache()
            if presentationStyle == .overlay, let tool = tools.first(where: { $0.operation == .hpcJobs }) {
                selection = tool.id
                session.selectionChanged(by: presenterID)
                run()
            }
            if presentationStyle == .floating, let tool = selectedTool,
               [.artifacts, .transfers, .agentActivity, .gitReview, .projectActions].contains(tool.operation) {
                run()
            }
        }
        .onDisappear {
            guard ownsPresentation else { return }
            // A following dock may mount its new pane before this old owner
            // disappears. Do not suspend the new pane's presentation lease.
            if chrome.anchor?.paneID == capturedPane?.id {
                chrome.setDraft(false)
                chrome.suspendPresentation()
            }
            session.releasePresenter(presenterID)
            ownsPresentation = false
        }
        .onChange(of: selection) { _, _ in
            // Dashboard navigation resets synchronously before starting the request.
            if presentationStyle != .overlay || showSchedulerAction {
                session.selectionChanged(by: presenterID)
                if let tool = selectedTool, [.artifacts, .transfers, .agentActivity, .gitReview, .projectActions].contains(tool.operation) {
                    if tool.operation == .gitReview { gitFiles = [] }
                    run()
                }
            }
        }
        .onChange(of: tools.map { $0.id + $0.digest }) { _, _ in
            guard presentationStyle == .overlay, ownsPresentation, !busy,
                  queueResult == nil, !showingHistory,
                  let tool = tools.first(where: { $0.operation == .hpcJobs }) else { return }
            selection = tool.id
            session.selectionChanged(by: presenterID)
            run()
        }
        .onChange(of: hasUnfinishedWork) { _, unfinished in
            guard ownsPresentation, chrome.anchor?.paneID == capturedPane?.id else { return }
            chrome.setDraft(unfinished)
        }
    }

    private func refreshQueue() {
        guard !busy, let tool = tools.first(where: { $0.operation == .hpcJobs }) else { return }
        showingHistory = false; selection = tool.id; inspectedJob = nil
        session.selectionChanged(by: presenterID); run()
    }

    private var hpcDashboard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                Text(scope?.profile.host ?? capturedPane?.profile.host ?? "Connection")
                    .font(RelayTheme.font(size: 12, weight: .medium)).foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Toggle("All users", isOn: $allQueueUsers).toggleStyle(.checkbox).disabled(busy || showingHistory)
                TextField("Username", text: $queueUser).frame(width: 105).disabled(busy || showingHistory)
                    .onSubmit { refreshQueue() }
                if busy { ProgressView().controlSize(.small) }
                Button(showingHistory ? "Live queue" : "Refresh", systemImage: "arrow.clockwise") {
                    guard let tool = tools.first(where: { $0.operation == .hpcJobs }) else { return }
                    showingHistory = false
                    selection = tool.id
                    session.selectionChanged(by: presenterID)
                    inspectedJob = nil
                    run()
                }.disabled(busy)
                Button("History", systemImage: "clock") {
                    guard let tool = tools.first(where: { $0.operation == .hpcAccounting }) else { return }
                    showingHistory = true
                    if historyResult != nil { return }
                    selection = tool.id; path = ""; inspectedJob = nil
                    session.selectionChanged(by: presenterID); run()
                }.disabled(busy)
                ForEach(tools.filter { $0.operation == .hpcSubmit || $0.operation == .hpcCancel }) { tool in
                    Button {
                        selection = tool.id
                        if tool.operation == .hpcCancel, let inspectedJob { path = inspectedJob }
                        showSchedulerAction = true
                    } label: {
                        Label(tool.title, systemImage: tool.operation == .hpcSubmit ? "paperplane" : "stop.circle")
                    }.help(tool.title).disabled(busy)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(RelayTheme.red).textSelection(.enabled) }
            if !showingHistory, let queueResult {
                PluginHPCResources(cluster: queueResult.cluster, diagnostic: queueResult.clusterError)
            }
            HStack(alignment: .top, spacing: RelayTheme.spacing(16)) {
                if showingHistory {
                    PluginHPCAccountingView(records: historyResult?.accounting ?? [], summary: historyResult?.text ?? "Loading accounting…", inspect: { selectJob($0, operation: .hpcAccounting) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let queueResult, queueDigest == tools.first(where: { $0.operation == .hpcJobs })?.digest {
                    PluginHPCJobsView(jobs: queueResult.jobs ?? [], total: queueResult.jobCount ?? 0,
                                      truncated: queueResult.truncated,
                                      inspectJob: { selectJob($0, operation: .hpcDetails) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack { Spacer(); Text(busy ? "Loading jobs…" : "Refresh to load jobs").foregroundStyle(RelayTheme.textMuted); Spacer() }
                        .frame(maxWidth: .infinity)
                }
                Rectangle().fill(RelayTheme.line).frame(width: 1)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                    if let inspectedJob {
                        HStack {
                            Text("Job \(inspectedJob)").font(RelayTheme.font(size: 13, weight: .medium))
                            Spacer()
                            Button { selectJob(inspectedJob, operation: .hpcDetails) } label: {
                                Label("Details", systemImage: "info.circle")
                            }.labelStyle(.iconOnly).help("Details").disabled(busy)
                            Button { selectJob(inspectedJob, operation: .hpcAccounting) } label: {
                                Label("Accounting / statistics", systemImage: "chart.bar")
                            }.labelStyle(.iconOnly).help("Accounting / statistics").disabled(busy)
                            Button { logStream = "stdout"; selectJob(inspectedJob, operation: .hpcLogs) } label: {
                                Label("Standard output", systemImage: "doc.text")
                            }.labelStyle(.iconOnly).help("Standard output").disabled(busy)
                            Button { logStream = "stderr"; selectJob(inspectedJob, operation: .hpcLogs) } label: {
                                Label("Standard error", systemImage: "exclamationmark.bubble")
                            }.labelStyle(.iconOnly).help("Standard error").disabled(busy)
                        }
                        ScrollView {
                            if let result, cacheDisplayAllowed, result.jobCount == nil {
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                                    if let detail = result.jobDetail { PluginHPCDetailView(detail: detail) }
                                    if let records = result.accounting { PluginHPCStatisticsView(records: records) }
                                    Text(result.text).font(RelayTheme.font(size: 11, design: .monospaced)).textSelection(.enabled)
                                    if result.truncated { Text("Latest 64 KiB only").font(.caption).foregroundStyle(RelayTheme.textMuted) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            } else if busy { Text("Loading…").foregroundStyle(RelayTheme.textMuted) }
                        }
                    } else {
                        Spacer()
                        Text("Select a job to see details").font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                        Spacer()
                    }
                }.frame(width: 340, alignment: .leading).frame(maxHeight: .infinity)
            }
        }.padding(RelayTheme.spacing(14))
        .onChange(of: allQueueUsers) { _, _ in refreshQueue() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !showingHistory && !busy && inspectedJob == nil { refreshQueue() }
            }
        }
        .sheet(isPresented: $session.showingManager) { RelayPluginSettingsView() }
    }

    private var ownedContent: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                if presentationStyle == .overlay {
                    Button("Back to jobs", systemImage: "chevron.left") {
                        showSchedulerAction = false
                        if let tool = tools.first(where: { $0.operation == .hpcJobs }) { selection = tool.id }
                    }.disabled(busy || reviewingAction)
                }
                Text(presentationStyle == .overlay ? "Scheduler action" : (selectedTool?.title ?? "Workspace tools")).font(RelayTheme.font(size: 13, weight: .medium))
                Spacer()
                if presentationStyle != .floating {
                    Button("Manage plugins…") { showingManager = true }
                        .disabled(busy || mutationAttempted)
                }
                if presentationStyle == .dock {
                    RelayIconAction("Close plugin tools", symbol: "xmark") { chrome.hide() }
                        .keyboardShortcut(.cancelAction)
                } else if presentationStyle == .sheet {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            if let scope {
                Text("\(scope.profile.kind == .ssh ? scope.profile.host : "This Mac") · \(capturedPane?.directory ?? "connection-wide")")
                    .font(.caption.monospaced()).textSelection(.enabled)
                if selectedTool?.operation.isMutation == true {
                    Text("Review this action before running it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if tools.isEmpty { Text("Install and enable a tool package in Settings → Plugins first.") }
            if presentationStyle == .dock || presentationStyle == .sheet {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RelayTheme.spacing(6)) {
                    ForEach(tools) { tool in
                        Button { selection = tool.id } label: {
                            Text(tool.title).font(RelayTheme.font(size: 11, weight: selection == tool.id ? .medium : .regular))
                                .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(7))
                                .background(selection == tool.id ? RelayTheme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                                .foregroundStyle(selection == tool.id ? RelayTheme.text : RelayTheme.textMuted)
                        }.buttonStyle(.plain).accessibilityLabel("Open \(tool.title)")
                    }
                }
            }.disabled(busy || mutationAttempted)
            }
            if !selection.isEmpty && scope == nil {
                Text("This tool needs a reported working directory. Return to a shell prompt and reopen the panel.")
                    .foregroundStyle(.secondary)
            }
            if let tool = tools.first(where: { $0.id == selection }), tool.operation == .artifacts || tool.operation == .transfers {
                TextField("Relative file or folder path (empty for project root)", text: $session.path).disabled(busy)
                if tool.operation == .transfers { Text("For a folder, end the path with /. Files open the resumable downloader.").font(.caption) }
            }
            if let tool = tools.first(where: { $0.id == selection }), tool.operation == .hpcAccounting || tool.operation == .hpcDetails || tool.operation == .hpcLogs {
                TextField("Job ID (one job or array task, e.g. 123_4)", text: $session.path).disabled(busy)
                if tool.operation == .hpcLogs {
                    Picker("Log", selection: $session.logStream) {
                        Text("Standard output").tag("stdout")
                        Text("Standard error").tag("stderr")
                    }.disabled(busy)
                    Text("Reads the last 64 KiB of the scheduler-reported log inside the job directory. No live polling.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let tool = selectedTool, tool.operation.isMutation {
                if tool.operation == .projectRun {
                    Text("Review argv, environment and timeout. Runs with your full user privileges in the displayed directory, without shell expansion or inherited environment. Default PATH: /usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin; LC_ALL=C. This is not a sandbox.").font(.caption)
                    TextEditor(text: $session.projectCommand).font(RelayTheme.font(.body, design: .monospaced)).frame(height: 160)
                        .disabled(busy || mutationAttempted)
                } else if tool.operation == .hpcSubmit {
                    Text("Review the full script, including #SBATCH resource requests. Uses the displayed working directory and --export=NIL; load required modules/environment in the script.").font(.caption)
                    TextEditor(text: $session.batchScript).font(RelayTheme.font(.body, design: .monospaced)).frame(height: 160)
                        .disabled(busy || mutationAttempted)
                } else {
                    TextField("Exact job ID to cancel (no arrays)", text: $session.path).disabled(busy || mutationAttempted)
                }
                TextField(tool.operation == .projectRun ? "Type RUN to confirm the command and host" : tool.operation == .hpcSubmit ? "Type SUBMIT to confirm the script and host" : "Type the job ID again to confirm cancellation", text: $session.actionConfirmation)
                    .disabled(busy || mutationAttempted)
                Text("If the connection fails, inspect the target before creating another action. Closing this panel does not undo or reliably stop a dispatched action.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if selectedTool?.operation.isMutation == true {
                    Button("Review action…") {
                        reviewedRequest = currentReview
                        reviewingAction = reviewedRequest != nil
                    }
                        .disabled(busy || scope == nil || !confirmationMatches || mutationAttempted)
                    if mutationAttempted && !busy {
                        Button("New reviewed action") {
                            reviewedRequest = nil
                            session.beginNewMutationReview()
                        }
                    }
                } else {
                    Button(selectedTool?.operation == .rWorkspace ? "Activate in this tab" : "Refresh", systemImage: "arrow.clockwise") { run() }.disabled(busy || scope == nil || selection.isEmpty)
                }
                if busy {
                    ProgressView().controlSize(.small)
                    RelayIconAction("Cancel operation", symbol: "xmark") { operationLifetime.cancel() }
                }
                if fileBytes != nil {
                    RelayIconAction("Back to folder", symbol: "arrow.up") {
                        guard let result else { return }
                        run(requestPath: result.text.split(separator: "/").dropLast().joined(separator: "/"))
                    }.disabled(busy)
                    RelayIconAction("Save copy…", symbol: "square.and.arrow.down") { saveCopy() }.disabled(busy)
                }
                if selectedTool?.operation == .gitReview, result != nil, !path.isEmpty {
                    RelayIconAction("Open working file in editor", symbol: "square.and.pencil") { openReviewedFile() }.disabled(busy)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let transferPath, let scope, let tool = selectedTool, tool.operation == .transfers {
                let stamp = PluginTransferStamp(pluginID: tool.pluginID, digest: tool.digest,
                                                scope: scope, path: transferPath)
                PluginTransferView(stamp: stamp, authorize: {
                    try await manager.authorize(id: tool.pluginID, digest: tool.digest, operation: .transfers)
                    guard workspace.panes[scope.paneID] != nil else {
                        throw PluginError.invalid("The originating pane is no longer available")
                    }
                }, presentation: session.transferPresentation)
                .id(tool.digest + scope.paneID.uuidString + transferPath)
            }
            if selectedTool?.operation == .gitReview, let result {
                PluginGitDashboard(files: gitFiles, selected: path, text: result.text, inspect: { run(requestPath: $0) })
            } else if selectedTool?.operation == .projectActions, let result {
                PluginProjectDashboard(entries: result.entries)
            } else if let agentSnapshot, result != nil {
                PluginAgentActivityView(snapshot: agentSnapshot)
            } else if let result, let count = result.jobCount {
                Text(result.text).font(.caption).foregroundStyle(.secondary)
                PluginHPCJobsView(jobs: result.jobs ?? [], total: count, truncated: result.truncated,
                    inspectJob: tools.contains(where: { $0.operation == .hpcDetails }) ? { selectJob($0, operation: .hpcDetails) } : nil,
                    inspectLog: tools.contains(where: { $0.operation == .hpcLogs }) ? { selectJob($0, operation: .hpcLogs) } : nil)
            } else {
            ScrollView {
                if let result {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                        if let detail = result.jobDetail {
                            Text(detail.summary).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                            if result.truncated { Text("Partial log: latest 64 KiB only.").foregroundStyle(.orange) }
                        }
                        if result.directory == nil {
                            Text(result.text).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        if !result.entries.isEmpty {
                            TextField("Filter these results", text: $session.entrySearch)
                                .textFieldStyle(.roundedBorder)
                        }
                        if let directory = result.directory {
                            HStack {
                                Text(directory.isEmpty ? "Project root" : directory).font(.headline)
                                Spacer()
                                if !directory.isEmpty {
                                    Button("Up one folder") {
                                        let parent = directory.split(separator: "/").dropLast().joined(separator: "/")
                                        run(requestPath: parent)
                                    }.disabled(busy)
                                }
                            }
                            Text("\(result.entries.count) items").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                        }
                        ForEach(Array(result.entries.filter { entrySearch.isEmpty || $0.localizedCaseInsensitiveContains(entrySearch) }.enumerated()), id: \.offset) { _, entry in
                            if let tool = tools.first(where: { $0.id == selection }), tool.operation == .artifacts || tool.operation == .transfers || tool.operation == .gitReview {
                                Button {
                                    run(requestPath: entry)
                                } label: {
                                    HStack {
                                        Image(systemName: entry.hasSuffix("/") ? "folder" : "doc").foregroundStyle(RelayTheme.textMuted)
                                        Text(entry).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted)
                                    }.font(RelayTheme.font(size: 12)).padding(.vertical, RelayTheme.spacing(6)).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(busy)
                            } else {
                                Text(entry).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        if result.truncated && result.jobCount == nil && result.jobDetail == nil { Text("Partial results: 500 directory entries, 100 agents or 128 KiB of text maximum.").foregroundStyle(.orange) }
                        if let bytes = fileBytes {
                            if let image = imagePreview {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                                    .accessibilityLabel("Preview of \(result.text)")
                            } else if let rows = tablePreview {
                                ScrollView(.horizontal) {
                                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                            GridRow {
                                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                                    Text(cell).font(RelayTheme.font(.caption, design: .monospaced)).textSelection(.enabled)
                                                }
                                            }
                                        }
                                    }
                                }
                                if previewPartial { Text("Partial table: at most 100 rows / 128 KiB. Save copy preserves the full file.") }
                            } else if let text = textPreview {
                                if let markdown = markdownPreview {
                                    Toggle("Show Markdown source", isOn: $session.showMarkdownSource)
                                    if showMarkdownSource {
                                        Text(text).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                                    } else {
                                        Text(markdown).font(.body).textSelection(.enabled)
                                    }
                                } else {
                                    Text(text).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                                }
                                if bytes.count > 128 * 1024 { Text("Preview limited to 128 KiB; Save copy preserves the full file.") }
                            } else { Text("Binary file · \(bytes.count) bytes · use Save copy.") }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            }
        }
        .padding(presentationStyle == .sheet ? 22 : 14)
        .frame(width: presentationStyle == .sheet ? (selection.isEmpty ? 520 : 760) : nil,
               height: presentationStyle == .sheet ? (selection.isEmpty ? 240 : 620) : nil,
               alignment: .topLeading)
        .sheet(isPresented: $session.showingManager) {
            RelayPluginSettingsView()
        }
        .confirmationDialog("Confirm action", isPresented: $session.reviewingAction, titleVisibility: .visible) {
            Button(selectedTool?.operation == .projectRun ? "Run reviewed command" : selectedTool?.operation == .hpcSubmit ? "Submit reviewed script" : "Cancel the specified job", role: .destructive) {
                guard confirmationMatches, let reviewedRequest,
                      reviewedRequest == currentReview else {
                    error = "The action changed. Review it again before running."
                    return
                }
                run(action: PluginHPCAction(id: UUID(), script: reviewedRequest.script))
            }
            Button("Go back", role: .cancel) {}
        } message: {
            Text("Host: \(scope?.profile.host ?? "This Mac")\nDirectory: \(scope?.root ?? "unknown")\n\(selectedTool?.operation == .projectRun ? "Execute the exact command object shown above with your full privileges. Project code can change files and access the network." : selectedTool?.operation == .hpcSubmit ? "Submit the script shown above. Its #SBATCH directives request resources and it executes as you." : "Cancel job " + path + ". This cannot be undone.")")
        }

    }

    private func selectJob(_ id: String, operation: RelayPluginOperation) {
        guard !busy, let tool = tools.first(where: { $0.operation == operation }) else { return }
        selectedJobFromList = id
        selection = tool.id
        session.selectionChanged(by: presenterID)
        path = id
        if presentationStyle == .overlay {
            inspectedJob = id
            run()
        }
    }

    private func revalidateCache() async {
        guard let stamp = session.resultStamp,
              let lease = session.presentationLease(for: presenterID) else { return }
        do {
            try await manager.authorize(id: stamp.pluginID, digest: stamp.digest, operation: stamp.operation)
            try Task.checkCancellation()
            guard workspace.panes[stamp.scope.paneID]?.profile == stamp.scope.profile else { return }
            session.validateCache(stamp, lease: lease)
        } catch { self.error = "Cached result unavailable: " + error.localizedDescription }
    }

    private func run(action: PluginHPCAction? = nil, requestPath: String? = nil) {
        guard ownsPresentation, !busy, let scope, let tool = tools.first(where: { $0.id == selection }) else { return }
        guard let presentationLease = session.presentationLease(for: presenterID) else { return }
        if let requestPath {
            path = requestPath
            if tool.operation != .gitReview { entrySearch = "" }
        }
        let isMutation = tool.operation.isMutation
        if isMutation {
            guard !mutationAttempted, let action else { return }
            do { try action.validate(operation: tool.operation, path: path) }
            catch { self.error = error.localizedDescription; return }
        }
        let requestedPath = path
        let requestedStream = logStream
        chrome.reveal(destination(for: tool.operation), initial: nil)
        let readTicket = isMutation ? nil : chrome.beginRead()
        guard isMutation || readTicket != nil else { return }
        let accepted = operationLifetime.start(retainOnHide: isMutation) {
            defer { busy = false }
            do {
                try await manager.authorize(id: tool.pluginID, digest: tool.digest, operation: tool.operation)
                try Task.checkCancellation()
                guard let pane = workspace.panes[scope.paneID] else {
                    throw PluginError.invalid("The originating pane is no longer available")
                }
                if let readTicket { guard chrome.accepts(readTicket) else { throw CancellationError() } }
                if tool.operation == .rWorkspace {
                    guard pane.profile == scope.profile else {
                        throw PluginError.invalid("Open an R console on the captured execution host first")
                    }
                    guard workspace.arrangeRWorkspace(consoleID: scope.paneID) else {
                        throw PluginError.invalid(workspace.operationError ?? "Could not open the R workspace.")
                    }
                    dismiss()
                    return
                }
                if tool.operation == .transfers, !requestedPath.isEmpty, !requestedPath.hasSuffix("/") {
                    transferPath = requestedPath
                    return
                }
                let response: PluginOperationResult
                if tool.operation == .agentActivity {
                    agentSnapshot = PluginAgentSnapshot(agents: pane.subagents, events: pane.agentActivities, plans: pane.taskPlans)
                    response = PluginOperationResult(root: scope.root,
                        text: "\(pane.kind.label) · \(pane.phase)\nSnapshot of existing Relay events; approvals remain in the agent CLI.",
                        entries: [], truncated: pane.subagents.count > 100)
                } else {
                    if let readTicket { guard chrome.accepts(readTicket) else { throw CancellationError() } }
                    response = try await PluginOperationRunner.run(tool.operation, scope: scope, path: requestedPath, stream: requestedStream, action: action, allUsers: allQueueUsers, queueUser: queueUser.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                try Task.checkCancellation()
                // Revalidate before disclosing a result after an update/revocation.
                try await manager.authorize(id: tool.pluginID, digest: tool.digest, operation: tool.operation)
                try Task.checkCancellation()
                if let readTicket { guard chrome.accepts(readTicket) else { throw CancellationError() } }
                if let bytes = response.verifiedBytes {
                    let preview = await Task.detached(priority: .utility) { Self.previewImageData(bytes) }.value
                    let document = await Task.detached(priority: .utility) { PluginArtifactPreview.decode(bytes, path: response.text) }.value
                    try Task.checkCancellation()
                    try await manager.authorize(id: tool.pluginID, digest: tool.digest, operation: tool.operation)
                    try Task.checkCancellation()
                    if let readTicket { guard chrome.accepts(readTicket) else { throw CancellationError() } }
                    fileBytes = bytes
                    imagePreview = preview.flatMap { NSImage(data: $0) }
                    if imagePreview == nil {
                        switch document {
                        case .text(let text, let partial): textPreview = text; previewPartial = partial
                        case .markdown(let source, let formatted, let partial):
                            textPreview = source; markdownPreview = formatted; previewPartial = partial
                        case .table(let rows, let partial): tablePreview = rows; previewPartial = partial
                        case .binary: break
                        }
                    }
                }
                let stamp = PluginResultStamp(requestID: UUID(), pluginID: tool.pluginID,
                    digest: tool.digest, operation: tool.operation, scope: scope, resource: requestedPath)
                session.stampResult(stamp)
                result = response
                if tool.operation == .gitReview, requestedPath.isEmpty { gitFiles = response.entries }
                if presentationStyle == .overlay, tool.operation == .hpcAccounting, requestedPath.isEmpty { historyResult = response }
                if presentationStyle == .overlay, tool.operation == .hpcJobs {
                    queueResult = response
                    queueDigest = tool.digest
                }
                session.validateCache(stamp, lease: presentationLease)
            } catch is CancellationError { error = tool.operation.isMutation ? "Stopped waiting. The action may have happened; inspect the target before creating another request." : "Cancelled" }
            catch {
                let message = error.localizedDescription
                self.error = (tool.operation.isMutation ? "Inspect the target before retrying this action. " : "") + message
                if tool.operation.isHPC, message.contains("not installed or not available on this host's PATH") {
                    let dialog = RelayTheme.alert()
                    dialog.messageText = "No Slurm available"
                    dialog.informativeText = "Slurm is not installed or available in the login environment on \(scope.profile.host)."
                    dialog.addButton(withTitle: "OK")
                    dialog.runModal()
                }
            }
        }
        guard accepted else { return }
        busy = true
        if isMutation { mutationAttempted = true }
        error = nil; result = nil; fileBytes = nil; imagePreview = nil
        textPreview = nil; tablePreview = nil; previewPartial = false
        agentSnapshot = nil; markdownPreview = nil; showMarkdownSource = false
        transferPath = nil
    }

    private func saveCopy() {
        guard cacheDisplayAllowed, let bytes = fileBytes, let result,
              let stamp = session.resultStamp else { return }
        guard let exportTicket = chrome.beginExport() else { return }
        let scope = stamp.scope
        let panel = RelayTheme.savePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: result.text).lastPathComponent
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    // Review can stay open while another window disables/updates the package.
                    try await manager.authorize(id: stamp.pluginID, digest: stamp.digest, operation: stamp.operation)
                    try Task.checkCancellation()
                    guard chrome.acceptsExport(exportTicket) else { throw CancellationError() }
                    guard let pane = workspace.panes[scope.paneID], pane.profile == scope.profile else {
                        throw PluginError.invalid("The originating pane is no longer available")
                    }
                    try await Task.detached(priority: .utility) { try bytes.write(to: destination, options: .atomic) }.value
                } catch is CancellationError {
                    self.error = "Save cancelled because the originating pane or tool context changed. Choose Save copy again."
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func openReviewedFile() {
        guard let tool = selectedTool, tool.operation == .gitReview,
              let scope, let result, result.entries.contains(path) else { return }
        let selectedPath = path
        guard let readTicket = chrome.beginRead() else { return }
        let accepted = operationLifetime.start(retainOnHide: false) {
            defer { busy = false }
            do {
                try await manager.authorize(id: tool.pluginID, digest: tool.digest, operation: .gitReview)
                try Task.checkCancellation()
                guard chrome.accepts(readTicket) else { throw CancellationError() }
                guard let pane = workspace.panes[scope.paneID], pane.profile == scope.profile else {
                    throw PluginError.invalid("The originating pane is no longer available")
                }
                let absolutePath = try scope.editorPath(selectedPath)
                guard chrome.accepts(readTicket) else { throw CancellationError() }
                workspace.openRemoteFile(RemoteFileOpenRequest(
                    profile: scope.profile,
                    parentSessionID: scope.paneID.uuidString.lowercased(),
                    request: EditorOpenRequest(paths: [absolutePath], diff: false)))
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
        if accepted { busy = true }
    }

    nonisolated private static func previewImageData(_ data: Data) -> Data? {
        // ImageIO downsamples instead of allocating an unbounded full-size bitmap.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
