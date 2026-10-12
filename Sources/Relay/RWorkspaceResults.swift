import AppKit
import ImageIO
import SwiftUI

/// Reads bounded companion artifacts; inspecting values requires explicit approval.
struct RWorkspaceResults: View {
    let scope: PluginScope
    @ObservedObject var runtime: RemoteEditorRuntime
    @State private var path = "relay-results"
    @State private var objectName = ""
    @State private var pageOffset = 0
    @State private var helpTopic = ""
    @State private var entries: [String] = []
    @State private var text = "Connect the linked R console to show its results here."
    @State private var rows: [[String]] = []
    @State private var objects: [String] = []
    @State private var previews: [REnvironmentSnapshot.Preview] = []
    @State private var tableTotal: Int?
    @State private var activeBindings: Set<String> = []
    @State private var image: NSImage?
    @State private var artifacts = RResultArtifacts()
    @State private var notice: String?
    @State private var zoom = 1.0
    @State private var previewPartial = false
    @State private var section = "Plots"
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var readGate = RResultReadGate()
    @State private var showsFiles = false
    @State private var showsAdvanced = false
    @State private var consolePlotVersion: String?
    @State private var environmentVersion: String?
    @State private var descriptorVersion: String?
    @State private var nextPlotReconnect = Date.distantPast
    @State private var plotReconnectDelay: TimeInterval = 2
    @State private var completedRequest: String?
    @State private var displayedHelpID: String?
    @State private var objectQuery = ""
    @ObservedObject private var httpgd: RHttpgdConnection
    @ObservedObject private var plotWindow: RPlotWindow

    init(scope: PluginScope, runtime: RemoteEditorRuntime) {
        self.scope = scope
        self.runtime = runtime
        self.httpgd = runtime.rPlotConnection
        self.plotWindow = runtime.rPlotWindow
    }

    private var selectedFile: String { artifacts[section]?.path ?? "" }
    private var selectedBytes: Data? { artifacts[section]?.bytes }

    @State private var showsSource = false

    private var resultPicker: some View {
        Picker("Result view", selection: $section) {
            Text("Plots").tag("Plots")
            Text("Objects").tag("Environment")
            Text("Table").tag("Table")
            Text("Help").tag("Help")
        }.labelsHidden()
    }

    private var resultNavigation: some View {
        ViewThatFits(in: .horizontal) {
            resultPicker.pickerStyle(.segmented).frame(width: 220)
            resultPicker.pickerStyle(.menu).frame(minWidth: 80, alignment: .leading)
        }
    }

    private var executionSummary: String {
        guard let source = runtime.rExecutedSource else { return "" }
        let name = source.replacingOccurrences(of: "Executed source: ", with: "")
            .components(separatedBy: " · ").first ?? "Provided code"
        return "Last execution: " + name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
            HStack(spacing: RelayTheme.spacing(8)) {
                resultNavigation
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                Button("Pause agents") { runtime.pauseMCPAnalysis() }
                    .help("Pauses managed agent execution. Does not stop R or prevent agent file edits.")
                Button("Interrupt R") { runtime.interruptRRun() }
                    .help("Pause agent execution and request interruption of the linked R run")
                RelayIconAction("R options", symbol: "slider.horizontal.3") { showsAdvanced.toggle() }
            }.buttonStyle(.borderless)
            if runtime.rExecutedSource != nil {
                Button { showsSource.toggle() } label: {
                    HStack(spacing: RelayTheme.spacing(6)) {
                        Text(executionSummary).lineLimit(1).truncationMode(.middle)
                        Text("Details").foregroundStyle(Color.accentColor)
                    }.font(.caption)
                }.buttonStyle(.plain)
                    .accessibilityLabel(executionSummary + ", source details")
                    .popover(isPresented: $showsSource) {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                            Text("Last execution").font(.headline)
                            Text(runtime.rExecutedSource ?? "").textSelection(.enabled)
                            Text(runtime.rSessionStatus).textSelection(.enabled)
                            Text("This describes the latest submitted code; it is not verified provenance for the selected plot.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open execution receipt") {
                                showsSource = false
                                if let request = runtime.rLastRequest {
                                    load(runtime.rArtifactRelative + "/" + request + "/result.json")
                                }
                            }.disabled(runtime.rLastRequest == nil || busy)
                        }.padding(RelayTheme.spacing(16)).frame(width: 340)
                    }
            }
            if runtime.rSession == nil {
                HStack {
                    if runtime.rSetupInFlight { ProgressView().controlSize(.small) }
                    Text(runtime.rSetupInFlight ? "Connecting R…" : "Use an idle R console to connect this workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    RelayIconAction("Connect R", symbol: "link") {
                        runtime.requestRSetup()
                    }.disabled(runtime.rSetupInFlight)
                        .help("Connect from an idle R prompt with empty input. Installs no packages.")
                }
            }
            if showsAdvanced {
            DisclosureGroup("Connection details") {
            Text(runtime.rSessionStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Connect R and plots…") { runtime.requestRSetup() }
            HStack {
                Button("Refresh R session") { runtime.refreshRSession() }
                Button("Latest receipt") {
                    if let request = runtime.rLastRequest { load(runtime.rArtifactRelative + "/" + request + "/result.json") }
                }.disabled(runtime.rLastRequest == nil || busy)
                Button("Latest artifacts") {
                    if let request = runtime.rLastRequest { load(runtime.rArtifactRelative + "/" + request) }
                }.disabled(runtime.rLastRequest == nil || busy)
            }
            }
            }
            if let notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { self.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss R message")
                }
            }
            if section == "Table" {
                HStack {
                    TextField("R object name", text: $objectName)
                    RelayIconAction("Open table", symbol: "tablecells") { requestTable() }.disabled(objectName.isEmpty || runtime.rSession == nil)
                }
                if let tableTotal {
                    Text("\(tableTotal) rows · \(rows.first?.count ?? 0) columns · first \(max(0, rows.count - 1)) rows")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if section == "Plots", showsAdvanced {
                DisclosureGroup("Plot connection") {
                HStack {
                    Button("Start httpgd…") {
                        do {
                            guard let session = runtime.rSession else { return }
                            try runtime.requestREvaluation(try RWorkspaceCommand.httpgdStart(session: session, root: session.artifact_root))
                            runtime.rLivePlotsEnabled = true
                            descriptorVersion = nil
                            text = "Live plots requested. After approval, Relay connects automatically."
                        } catch { text = error.localizedDescription }
                    }
                    .disabled(runtime.rSession?.supportsHttpgd != true)
                    .help(runtime.rSession?.httpgd_installed == false
                          ? "httpgd is not installed in that R library. Install it yourself; Relay never installs packages."
                          : "Review starting a loopback-only httpgd device in the linked R console")
                    Button(httpgd.isConnected ? "Disconnect httpgd" : "Connect httpgd") {
                        if httpgd.isConnected {
                            runtime.rLivePlotsEnabled = false; httpgd.disconnect()
                        } else {
                            runtime.rLivePlotsEnabled = true; descriptorVersion = nil; connectHttpgd()
                        }
                    }
                    .disabled(runtime.rSession?.supportsHttpgd != true || httpgd.phase == .connecting)
                    Button("Stop httpgd…") {
                        runtime.rLivePlotsEnabled = false
                        httpgd.disconnect()
                        do { try runtime.requestREvaluation(RWorkspaceCommand.httpgdStop()) }
                        catch { text = error.localizedDescription }
                    }.disabled(runtime.rSession?.supportsHttpgd != true)
                }
                if !httpgd.isConnected {
                    HStack {
                        Button("Enable console plots…") {
                            do {
                                guard let session = runtime.rSession else { return }
                                try runtime.requestREvaluation("relay_r_console_start(\(try RWorkspaceCommand.quote(session.artifact_root)))")
                            } catch { text = error.localizedDescription }
                        }.disabled(runtime.rSession?.capabilities.contains("console_plots") != true)
                        Button("Latest console plot") { load(runtime.rArtifactRelative + "/console-latest.png") }.disabled(busy)
                        Button("Stop capture…") {
                            do { try runtime.requestREvaluation("relay_r_console_stop()") }
                            catch { text = error.localizedDescription }
                        }.disabled(runtime.rSession?.capabilities.contains("console_plots") != true)
                    }
                    Text("httpgd shows live history and redraws on resize through a private loopback forward. Console snapshot capture is the fallback; starting either one replaces the other. Existing plots are not imported.").font(.caption)
                }
                }
            } else if section == "Environment" {
                TextField("Find an object", text: $objectQuery)
                    .textFieldStyle(.roundedBorder)
            } else if section == "Help" {
                HStack {
                    TextField("Installed R help topic", text: $helpTopic)
                    RelayIconAction("Open R help", symbol: "questionmark.circle") { requestHelp() }.disabled(helpTopic.isEmpty || runtime.rSession == nil || busy)
                }
            }
            if !(section == "Plots" && httpgd.phase != .idle), !selectedFile.isEmpty, section != "Environment" {
                HStack {
                    Text((selectedFile as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(selectedFile)
                    Spacer()
                    if section == "Plots", image != nil {
                        Slider(value: $zoom, in: 0.25...4).frame(width: 100)
                            .accessibilityLabel("Plot zoom")
                        Button("100%") { zoom = 1 }
                    }
                    RelayIconAction("Save copy…", symbol: "square.and.arrow.down") { saveCopy() }.disabled(selectedBytes == nil || busy)
                }
            }
            if section == "Table", previewPartial { Text("Partial preview — Save copy preserves the complete artifact.").font(.caption).foregroundStyle(.secondary) }
            if showsAdvanced {
            DisclosureGroup("Saved files", isExpanded: $showsFiles) {
            HStack {
                TextField("Result folder relative to project", text: $path)
                    .textFieldStyle(.roundedBorder).disabled(busy)
                RelayIconAction("Refresh saved files", symbol: "arrow.clockwise") { load(path) }.disabled(busy)
                RelayIconAction("Open parent folder", symbol: "arrow.up") {
                    let parent = (path as NSString).deletingLastPathComponent
                    load(parent == "." ? "" : parent)
                }.disabled(busy || path.isEmpty)
            }
                List(entries, id: \.self) { entry in
                    Button(entry) { load(entry) }.buttonStyle(.plain).disabled(busy)
                }.frame(height: 100)
            }
            }
            if section == "Plots", httpgd.phase != .idle {
                if plotWindow.detached {
                    VStack(spacing: RelayTheme.spacing(10)) {
                        Text("Plots are open in a separate window").foregroundStyle(.secondary)
                        RelayIconAction("Dock plots back", symbol: "arrow.down.right.and.arrow.up.left") { plotWindow.close() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RHttpgdPlotView(connection: httpgd, floatPlot: {
                        plotWindow.show(connection: httpgd, title: runtime.rSession?.host ?? "R")
                    }, savePlot: {
                        saveCopy(bytes: httpgd.imageBytes, name: "httpgd-plot-\((httpgd.selectedIndex ?? 0) + 1).png")
                    }).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                        if section == "Plots", let image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: min(image.size.width, 800) * zoom,
                                       height: min(image.size.width, 800) * image.size.height / max(image.size.width, 1) * zoom)
                                .background(Color.white)
                                .accessibilityLabel("Saved R plot")
                        } else if section == "Table", !rows.isEmpty {
                            RelaySurfaceView(content: .table(rows, title: objectName))
                        } else if section == "Environment", !objects.isEmpty {
                            Text("Object names update after commands. Values are inspected only on request.").foregroundStyle(.secondary)
                            ForEach(Array(objects.filter { objectQuery.isEmpty || $0.localizedCaseInsensitiveContains(objectQuery) }.enumerated()), id: \.offset) { _, name in
                                Button(String(name.prefix(512)) + (activeBindings.contains(name) ? " (active binding)" : "")) {
                                    objectName = name; pageOffset = 0; section = "Table"; requestTable()
                                }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, RelayTheme.spacing(5))
                                    .disabled(activeBindings.contains(name))
                            }
                        } else {
                            Text(emptyText).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }.font(RelayTheme.font(size: 12)).padding(RelayTheme.spacing(6))
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(RelayTheme.spacing(10))
        .controlSize(.small).font(RelayTheme.font(size: 12))
        .frame(minHeight: 180, maxHeight: .infinity, alignment: .top)
        // Hiding the dock releases the forward, socket and rendered bitmap.
        .onDisappear {
            readGate.invalidate(); task?.cancel(); busy = false
            plotWindow.dockVisible = false
            if !plotWindow.detached { httpgd.disconnect() }
        }
        .onChange(of: runtime.rHelpRequestID) { _, _ in
            showRequestedHelp()
        }
        .onChange(of: runtime.rSession?.session_id) { _, _ in
            plotWindow.close()
            readGate.invalidate(); task?.cancel(); task = nil; busy = false
            httpgd.disconnect()
            image = nil; rows = []; objects = []; previews = []; tableTotal = nil; activeBindings = []
            entries = []; artifacts = RResultArtifacts(); notice = nil
            consolePlotVersion = nil; environmentVersion = nil
            descriptorVersion = nil; completedRequest = nil
            previewPartial = false; zoom = 1; pageOffset = 0
            objectName = ""; objectQuery = ""; helpTopic = ""
            path = runtime.rArtifactRelative
            text = "Waiting for results from the linked R session."
            task = Task { await refreshPublishedResults() }
        }
        .onAppear {
            if !runtime.rHelpTopic.isEmpty { showRequestedHelp() }
            plotWindow.dockVisible = true
            path = runtime.rArtifactRelative
            descriptorVersion = nil
            // Read the saved identity on demand; never source code or poll R.
            runtime.refreshRSession()
        }
        .task {
            // Metadata only, never R execution. SwiftUI cancels this task when
            // the dock disappears. Visible results remain live while the user
            // works in an agent app; fully occluded windows do not poll.
            while !Task.isCancelled {
                if NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }),
                   runtime.rResultsScope == scope {
                    runtime.refreshRSession()
                    await refreshPublishedResults()
                }
                if (section == "Plots" || section == "Environment"), !busy,
                   !(section == "Plots" && httpgd.phase != .idle),
                   NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }),
                   runtime.rSession?.capabilities.contains(section == "Plots" ? "console_plots" : "environment_updates") == true {
                    let requestedSection = section
                    let readGeneration = readGate.generation
                    let plotPath = runtime.rArtifactRelative + (section == "Plots" ? "/console-latest.png" : "/environment.json")
                    do {
                        let response = try await PluginOperationRunner.run(.transfers, scope: scope,
                            path: plotPath, transfer: PluginTransferRequest(mode: "stat"))
                        try Task.checkCancellation()
                        guard readGate.accepts(readGeneration) else { continue }
                        if let info = response.transfer, info.size <= 8 << 20,
                           info.version != (requestedSection == "Plots" ? consolePlotVersion : environmentVersion), section == requestedSection, !busy {
                            load(plotPath, consoleVersion: info.version)
                        }
                    } catch is CancellationError { return }
                    catch { /* No plot yet or temporarily disconnected; manual refresh shows errors. */ }
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private var emptyText: String {
        guard runtime.rSession != nil else { return "Connect R to display plots and browse objects from the linked console." }
        switch section {
        case "Plots": return "Run plot(1) in the linked R console. New plots appear here automatically after plot capture is connected."
        case "Table": return "Choose an object in Objects, or enter its name above."
        case "Environment": return "No objects in the latest snapshot. Names update after R commands."
        default: return text
        }
    }

    /// Reads already-published artifacts only. Does not evaluate R or start a device.
    private func refreshPublishedResults() async {
        let generation = readGate.generation
        guard let session = runtime.rSession else { return }
        do {
            let response = try await PluginOperationRunner.run(.artifacts, scope: scope,
                path: runtime.rArtifactRelative + "/help.json")
            guard readGate.accepts(generation), !Task.isCancelled else { return }
            if let bytes = response.verifiedBytes, bytes.count <= 2 << 20,
               let record = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               record["session_id"] as? String == session.session_id,
               let id = record["id"] as? String, id != displayedHelpID,
               let help = record["text"] as? String {
                displayedHelpID = id
                section = "Help"
                text = help
                notice = nil
            }
        } catch { /* No console help has been requested yet. */ }
        if section == "Plots", runtime.rLivePlotsEnabled, session.supportsHttpgd,
           httpgd.phase == .idle || { if case .failed = httpgd.phase { return true }; return false }() {
            do {
                let metadata = try await PluginOperationRunner.run(.transfers, scope: scope,
                    path: runtime.rArtifactRelative + "/httpgd.json", transfer: PluginTransferRequest(mode: "stat"))
                try Task.checkCancellation()
                guard readGate.accepts(generation) else { return }
                if let info = metadata.transfer, info.size <= 65536,
                   info.version != descriptorVersion || Date() >= nextPlotReconnect {
                    descriptorVersion = info.version
                    await httpgd.connect(scope: scope, relativeRoot: runtime.rArtifactRelative, session: session)
                    if httpgd.isConnected {
                        plotReconnectDelay = 2
                        nextPlotReconnect = .distantPast
                    } else {
                        nextPlotReconnect = Date().addingTimeInterval(plotReconnectDelay)
                        plotReconnectDelay = min(plotReconnectDelay * 2, 60)
                    }
                }
            } catch { /* Missing descriptor means no live device has been approved yet. */ }
        }
        guard !Task.isCancelled, readGate.accepts(generation), !busy,
              let request = runtime.rLastRequest, request != completedRequest else { return }
        let root = runtime.rArtifactRelative + "/" + request
        do {
            let response = try await PluginOperationRunner.run(.artifacts, scope: scope, path: root + "/result.json")
            try Task.checkCancellation()
            guard readGate.accepts(generation), runtime.rLastRequest == request,
                  let bytes = response.verifiedBytes else { return }
            let receipt = try JSONDecoder().decode(RExecutionSnapshot.self, from: bytes)
            guard receipt.request_id == request, receipt.session_id == session.session_id,
                  ["completed", "error", "interrupted"].contains(receipt.status) else { return }
            if let id = UUID(uuidString: request) { runtime.noteRCompletion(id, status: receipt.status) }
            completedRequest = request
            notice = nil
            if let artifact = receipt.displayArtifact {
                load(root + "/" + artifact)
            } else {
                text = receipt.error ?? receipt.text ?? "R request \(receipt.status)."
                if receipt.error != nil || receipt.text != nil { section = "Help" }
            }
        } catch { /* No receipt is not a reason to repeat execution. */ }
    }

    private func load(_ requested: String, consoleVersion: String? = nil) {
        guard !busy else { return }
        busy = true
        let readGeneration = readGate.generation
        task = Task { @MainActor in
            defer { if readGate.accepts(readGeneration) { busy = false } }
            do {
                let result = try await PluginOperationRunner.run(.artifacts, scope: scope, path: requested)
                try Task.checkCancellation()
                guard readGate.accepts(readGeneration) else { return }
                if let bytes = result.verifiedBytes {
                    if requested.lowercased().hasSuffix(".png") {
                        // Decode to a bounded thumbnail, never an arbitrarily large bitmap.
                        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 1600
                              ] as CFDictionary) else { throw PluginError.invalid("Cannot decode plot") }
                        image = NSImage(cgImage: cg, size: .zero); section = "Plots"
                        zoom = 1
                        if let consoleVersion { consolePlotVersion = consoleVersion }
                    } else if case .table(let values, let partial) = PluginArtifactPreview.decode(bytes, path: requested) {
                        rows = values; section = "Table"
                        previewPartial = partial
                    } else if requested.hasSuffix("result.json") {
                        let receipt = try JSONDecoder().decode(RExecutionSnapshot.self, from: bytes)
                        guard receipt.request_id == runtime.rLastRequest,
                              receipt.session_id == runtime.rSession?.session_id else {
                            throw PluginError.invalid("Result belongs to another R request/session. Browse its artifacts explicitly.")
                        }
                        text = "R request \(receipt.request_id)\nStatus: \(receipt.status)\n" + (receipt.error ?? receipt.text ?? "Open Latest artifacts for plots, tables and environment names.")
                        section = "Help"
                    } else if requested.hasSuffix("environment.json") {
                        let snapshot = try JSONDecoder().decode(REnvironmentSnapshot.self, from: bytes)
                        if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                           let sessionID = object["session_id"] as? String,
                           sessionID != runtime.rSession?.session_id {
                            throw PluginError.invalid("Environment belongs to another R session. Reconnect before inspecting it.")
                        }
                        guard snapshot.objects.count <= 500,
                              snapshot.objects.allSatisfy({ $0.name.utf8.count <= 4096 }) else { throw PluginError.invalid("Environment snapshot exceeds display limits") }
                        objects = snapshot.objects.map { $0.name }
                        previews = snapshot.previews ?? []
                        activeBindings = Set(snapshot.objects.filter(\.active_binding).map(\.name))
                        section = "Environment"
                        if let consoleVersion { environmentVersion = consoleVersion }
                    } else {
                        text = String(decoding: bytes.prefix(128 * 1024), as: UTF8.self)
                        section = "Help"
                    }
                    artifacts.store(section: section, path: requested, bytes: bytes)
                    notice = nil
                } else {
                    entries = result.entries
                    path = requested
                }
            } catch is CancellationError { }
            catch {
                guard readGate.accepts(readGeneration) else { return }
                notice = error.localizedDescription
            }
        }
    }

    private func requestTable() {
        guard let preview = previews.first(where: { $0.name == objectName }) else {
            rows = []; tableTotal = nil
            notice = "No safe preview published for this object. Lazy bindings and custom objects are not evaluated automatically."
            return
        }
        rows = [preview.columns] + preview.rows
        tableTotal = preview.total_rows
        previewPartial = false
        notice = nil
    }

    private func requestHelp() {
        busy = true
        let generation = readGate.generation
        runtime.requestREditorTool("help", code: "", topic: helpTopic) { result in
            guard readGate.accepts(generation) else { return }
            busy = false
            switch result {
            case .success(let json):
                if let data = json.data(using: .utf8),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let help = value["text"] as? String {
                    text = help; notice = nil
                }
            case .failure(let error): notice = error.localizedDescription
            }
        }
    }

    private func showRequestedHelp() {
        guard !runtime.rHelpTopic.isEmpty else { return }
        section = "Help"
        helpTopic = runtime.rHelpTopic
        runtime.rHelpTopic = ""
        requestHelp()
    }

    private func connectHttpgd() {
        guard let session = runtime.rSession, let scope = runtime.rResultsScope else {
            text = "Refresh the R session before connecting httpgd"; return
        }
        let relative = runtime.rArtifactRelative
        Task { @MainActor in await httpgd.connect(scope: scope, relativeRoot: relative, session: session) }
    }

    private func saveCopy() {
        saveCopy(bytes: selectedBytes, name: (selectedFile as NSString).lastPathComponent)
    }

    private func saveCopy(bytes: Data?, name: String) {
        guard let bytes else { return }
        let panel = RelayTheme.savePanel()
        panel.nameFieldStringValue = name
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        try bytes.write(to: destination, options: .atomic)
                    }.value
                } catch { text = error.localizedDescription }
            }
        }
    }
}

/// Keep exports bound to their visible result, rather than the last tab to refresh.
/// Contents are already bounded by the artifact reader; one artifact per view.
struct RResultArtifacts {
    struct Artifact { let path: String; let bytes: Data }
    private var values: [String: Artifact] = [:]
    subscript(section: String) -> Artifact? { values[section] }
    mutating func store(section: String, path: String, bytes: Data) {
        guard ["Plots", "Table", "Environment", "Help"].contains(section) else { return }
        values[section] = Artifact(path: path, bytes: bytes)
    }
}

struct REnvironmentSnapshot: Decodable {
    struct Preview: Decodable {
        let name: String
        let total_rows: Int
        let columns: [String]
        let rows: [[String]]
    }
    struct Object: Decodable {
        let name: String
        let active_binding: Bool
    }
    let total: Int
    let objects: [Object]
    var previews: [Preview]? = nil
}

struct RExecutionSnapshot: Decodable {
    let request_id: String
    let session_id: String?
    let status: String
    let text: String?
    let error: String?
    var plots: [String]? = nil
    var table: Table? = nil
    struct Table: Decodable { let artifact: String? }
    var displayArtifact: String? {
        guard status == "completed" else { return nil }
        if table?.artifact == "table.csv" { return "table.csv" }
        return plots?.last(where: { $0.range(of: "^plot-[0-9]+\\.png$", options: .regularExpression) != nil })
    }
}
