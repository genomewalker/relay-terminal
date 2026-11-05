import SwiftUI

/// File navigation remains an explicit host-bound native/editor capability.
/// It never runs inside the generic web browser's WebKit configuration.
struct WorkspaceFileNavigationButton: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var plugins = RelayPluginManager.shared
    var body: some View {
        Menu {
            if let pane = workspace.activePane {
                Text(pane.profile.kind == .local ? "This Mac" : pane.profile.user + "@" + pane.profile.host)
                Text(pane.directory ?? "Working directory not reported")
                Button("Browse and edit files…") { workspace.openEditorForActive() }
                    .disabled(pane.directory == nil || (pane.profile.kind == .ssh && pane.profile.backend != .relay))
                Divider()
                ForEach(transferTools, id: \.id) { tool in
                    Button(tool.title) { NotificationCenter.default.post(name: .relayShowPlugin, object: tool.id) }
                }
                Text("Upload: drop local files onto the destination terminal; review host and folder first.")
            }
        } label: { Image(systemName: "folder").frame(width: 30, height: 30) }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .help("Files · browse, edit and transfer on the active host")
        .accessibilityLabel("Files on the active host")
    }
    private var transferTools: [(id: String, title: String)] {
        plugins.installations.keys.sorted().flatMap { id in
            guard plugins.installations[id]?.enabled == true,
                  let package = plugins.reviewedInstallations[id]?.package else { return [(id: String, title: String)]() }
            return package.contributions.compactMap { entry in
                guard entry.kind == .tool, entry.operation == .transfers else { return nil }
                return (id: id + ":" + entry.id, title: entry.title)
            }
        }
    }
}

struct WorkspaceFileOriginBar: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var runtime: RemoteEditorRuntime
    @ObservedObject private var plugins = RelayPluginManager.shared
    @StateObject private var transfer = PluginTransferPresentation()
    @State private var download: DownloadTarget?
    private struct DownloadTarget: Identifiable {
        let id = UUID()
        let stamp: PluginTransferStamp
    }
    private var transferTool: (id: String, digest: String)? {
        for id in plugins.installations.keys.sorted() {
            if plugins.installations[id]?.enabled == true,
               let reviewed = plugins.reviewedInstallations[id],
               reviewed.package.contributions.contains(where: { $0.kind == .tool && $0.operation == .transfers }) {
                return (id, reviewed.digest)
            }
        }
        return nil
    }
    var body: some View {
        HStack(spacing: 8) {
            Label(pane.profile.kind == .local ? "This Mac" : pane.profile.user + "@" + pane.profile.host,
                  systemImage: pane.profile.kind == .local ? "desktopcomputer" : "server.rack")
            Text(runtime.directoryPath.isEmpty ? (pane.directory ?? "Directory unavailable") : runtime.directoryPath)
                .lineLimit(1).textSelection(.enabled)
            Spacer()
            Button("Save to host") { runtime.requestSave() }.disabled(!runtime.isDirty || runtime.isBusy)
            Button("Download copy…") {
                guard let tool = transferTool, let path = runtime.currentPath,
                      let scope = try? PluginScope.captured(paneID: pane.id, profile: pane.profile,
                                                           directory: runtime.workspacePath, operation: .transfers),
                      let relative = WorkspaceFilePath.relative(path, root: scope.root) else { return }
                download = DownloadTarget(stamp: PluginTransferStamp(pluginID: tool.id, digest: tool.digest, scope: scope, path: relative))
            }.disabled(runtime.currentPath == nil || transferTool == nil)
            .help("Explicit, resumable, verified transfer from this host to a chosen Mac destination")
        }
        .font(.caption)
        .padding(8)
        .background(RelayTheme.surface)
        .onDisappear { transfer.pause() }
        .sheet(item: $download, onDismiss: { transfer.pause() }) { target in
            VStack(alignment: .leading, spacing: 12) {
                Text("Download from \(target.stamp.scope.profile.kind == .local ? "This Mac" : target.stamp.scope.profile.user + "@" + target.stamp.scope.profile.host)").font(.headline)
                Text(target.stamp.scope.root).font(.caption.monospaced()).textSelection(.enabled)
                PluginTransferView(stamp: target.stamp, authorize: {
                    // Reuse the existing digest/grant gate and exact captured scope.
                    try await plugins.authorize(id: target.stamp.pluginID, digest: target.stamp.digest, operation: .transfers)
                    guard pane.profile == target.stamp.scope.profile else { throw PluginError.invalid("The originating host changed") }
                }, presentation: transfer)
                Button("Done") { transfer.pause(); download = nil }
            }.padding(16).frame(minWidth: 480)
        }
    }
}
