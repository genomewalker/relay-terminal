import AppKit
import SwiftUI

@MainActor
final class RelayPluginManager: ObservableObject {
    static let shared = RelayPluginManager()
    @Published var installations: [String: RelayPluginStore.Installation] = [:]
    @Published var candidate: ReviewedPluginCandidate?
    @Published var error: String?
    @Published var busy = false
    @Published private(set) var reviewedInstallations: [String: ReviewedPluginCandidate] = [:]
    private let store: RelayPluginStore
    private var task: Task<Void, Never>?

    init(directory: URL? = nil) {
        let root = directory ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/Plugins", isDirectory: true)
        store = RelayPluginStore(directory: root, safeMode: RelayLaunchMode.isSafeMode)
    }

    func installBundledVPN() async {
        guard !RelayLaunchMode.isSafeMode else { return }
        do {
            guard let url = RelayResources.bundle?.url(forResource: "relay-plugin", withExtension: "json", subdirectory: "VPN") else { return }
            let candidate = try ReviewedPluginCandidate(bytes: Data(contentsOf: url), repository: "genomewalker/relay-plugin-vpn", releaseTag: "v0.1.0")
            let existing = try await store.installations()["relay.vpn"]
            if existing == nil {
                try await store.install(candidate, approvedDigest: candidate.digest)
                try await store.setEnabled("relay.vpn", true)
            }
            try await reloadInstallations()
            if installations["relay.vpn"]?.enabled == true { RelayVPNStore.shared.start() }
        } catch { self.error = "Could not load VPN plugin: " + error.localizedDescription }
    }

    func refresh() {
        perform { try await self.reloadInstallations() }
    }

    func review(repository: String, tag: String) {
        guard !busy else { return }
        candidate = nil
        perform {
            let candidate = try await RelayPluginReleaseLoader.review(repository: repository, tag: tag)
            try Task.checkCancellation()
            self.candidate = candidate
        }
    }

    func install() {
        guard let candidate else { return }
        perform {
            try await self.store.install(candidate, approvedDigest: candidate.digest)
            self.candidate = nil
            try await self.reloadInstallations()
        }
    }

    func change(_ id: String, action: String) {
        perform {
            switch action {
            case "enable": try await self.store.setEnabled(id, true)
            case "disable": try await self.store.setEnabled(id, false)
            case "rollback": try await self.store.rollback(id)
            case "uninstall": try await self.store.uninstall(id)
            default: return
            }
            try await self.reloadInstallations()
            if id == "relay.vpn" {
                if self.installations[id]?.enabled == true { RelayVPNStore.shared.start() }
                else { RelayVPNStore.shared.stop() }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Fresh store read, not the Settings view's potentially stale cache.
    func controlInventory() async throws -> [PluginControlEntry] {
        let installed = try await store.installations()
        return try await Task.detached(priority: .utility) {
            try installed.sorted { $0.key < $1.key }.map { id, installation in
                let package = try installation.current.validated().package
                return PluginControlEntry(id: id, name: package.name, version: package.version,
                    enabled: installation.enabled, supportsActivation: package.supportsActivation,
                    digest: installation.current.digest,
                    permissions: package.permissions.map { $0.kind.rawValue },
                    operations: package.contributions.compactMap { $0.operation?.rawValue })
            }
        }.value
    }

    func reviewLocalManifest() {
        guard !busy else { return }
        let panel = RelayTheme.openPanel()
        panel.title = "Review local relay-plugin.json"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        candidate = nil
        perform {
            let bytes = try await Task.detached(priority: .utility) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw PluginError.invalid("Choose a regular JSON file")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: RelayPluginPackage.maximumBytes + 1) ?? Data()
            }.value
            self.candidate = try ReviewedPluginCandidate.localManifest(bytes)
        }
    }

    private func reloadInstallations() async throws {
        let installations = try await store.installations()
        // Decode and hash once per store change, never in a SwiftUI body.
        let reviewed = try await Task.detached(priority: .utility) {
            try installations.mapValues { try $0.current.validated() }
        }.value
        self.reviewedInstallations = reviewed
        self.installations = installations
    }

    func authorize(id: String, digest: String, operation: RelayPluginOperation) async throws {
        let current = try await store.installations()[id]
        guard !RelayLaunchMode.isSafeMode, let current, current.enabled,
              current.current.digest == digest else {
            throw PluginError.invalid("Plugin was disabled, updated or removed. Reopen its tool.")
        }
        let package = try current.current.validated().package
        guard package.supportsActivation,
              package.contributions.contains(where: { $0.kind == .tool && $0.operation == operation }) else {
            throw PluginError.invalid("Plugin was disabled, updated or removed. Reopen its tool.")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        task = Task {
            defer { self.busy = false; self.task = nil }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct PluginControlEntry: Encodable, Sendable {
    let id: String
    let name: String
    let version: String
    let enabled: Bool
    let supportsActivation: Bool
    let digest: String
    let permissions: [String]
    let operations: [String]
}

@MainActor
struct RelayPluginSettingsView: View {
    @ObservedObject private var manager: RelayPluginManager
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var tag = ""
    @State private var removeID: String?
    @State private var showingDigest = false

    init(manager: RelayPluginManager = .shared) {
        self.manager = manager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(18)) {
            HStack {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text("Plugins").font(RelayTheme.font(size: 21, weight: .medium))
                    Text("Tools for your workspace").foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider().overlay(RelayTheme.line)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                Text("Add from GitHub").font(.headline)
                HStack(alignment: .bottom, spacing: RelayTheme.spacing(10)) {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                        Text("Repository").font(.caption).foregroundStyle(RelayTheme.textMuted)
                        TextField("owner/repository", text: $repository)
                            .accessibilityLabel("GitHub repository")
                    }
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                        Text("Release tag").font(.caption).foregroundStyle(RelayTheme.textMuted)
                        TextField("v1.0.0", text: $tag).accessibilityLabel("Release tag")
                    }.frame(width: 110)
                    Button("Review release") {
                        showingDigest = false
                        manager.review(repository: repository, tag: tag)
                    }
                    .disabled(manager.busy || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.textFieldStyle(.roundedBorder)
                Text("Experimental. Review permissions before installing. Plugins start disabled.")
                    .font(.caption).foregroundStyle(RelayTheme.textMuted)
                Button("Review local manifest…") { manager.reviewLocalManifest() }
                    .disabled(manager.busy)
            }
            if manager.busy { HStack { ProgressView().controlSize(.small); Text("Working…"); Button("Cancel") { manager.cancel() } } }
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(RelayTheme.coral).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                    if let candidate = manager.candidate {
                        // Keep cards as explicit stacks: the native GroupBox
                        // accessibility subtree crashes Computer Use's tree
                        // transformation when this dynamic content appears.
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                            HStack {
                                Text(candidate.package.name).font(.headline)
                                Text(candidate.package.version).foregroundStyle(RelayTheme.textMuted)
                                Spacer()
                                Text("Review").font(.caption).foregroundStyle(RelayTheme.mint)
                            }
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                                Text(candidate.repository).font(.caption).foregroundStyle(RelayTheme.textMuted)
                                if candidate.releaseTag == "local-review" {
                                    Text("Local development file — not verified against a GitHub release.")
                                        .font(.caption).foregroundStyle(RelayTheme.coral)
                                }
                                Text("Requested permissions").font(.subheadline.weight(.medium))
                                if candidate.package.permissions.isEmpty {
                                    Text("No additional permissions.").foregroundStyle(RelayTheme.textMuted)
                                }
                                ForEach(candidate.package.permissions, id: \.kind) { permission in
                                    Text(permission.reason).fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Publisher unverified. Only install packages you trust.")
                                    .font(.caption).foregroundStyle(RelayTheme.textMuted)
                                Button(showingDigest ? "Hide verification details" : "Show verification details") { showingDigest.toggle() }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(RelayTheme.mint)
                                if showingDigest {
                                    Text("\(candidate.releaseTag)\nSHA-256: \(candidate.digest)\nThe digest identifies the download, not its publisher.")
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !candidate.package.supportsActivation {
                                    Text("Can be installed, but cannot be enabled: requested capabilities are not supported yet.")
                                }
                                Button("Install disabled") { manager.install() }.disabled(manager.busy)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(RelayTheme.spacing(14)).background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
                    }
                    Text("Installed (\(manager.installations.count))").font(.headline)
                    if manager.installations.isEmpty {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                            Text("No plugins installed")
                            Text("Enter a repository and release tag above to add one.")
                                .font(.caption).foregroundStyle(RelayTheme.textMuted)
                        }.padding(.vertical, RelayTheme.spacing(16))
                    }
                    ForEach(manager.installations.keys.sorted(), id: \.self) { id in
                        if let item = manager.installations[id], let candidate = manager.reviewedInstallations[id] {
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                                HStack {
                                    Text(candidate.package.name).font(.headline)
                                    Spacer()
                                    Text(item.enabled ? "Enabled" : "Disabled").font(.caption)
                                        .foregroundStyle(item.enabled ? RelayTheme.mint : RelayTheme.textMuted)
                                }
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                                    Text("\(item.current.repository) · \(candidate.package.version)")
                                        .font(.caption).foregroundStyle(RelayTheme.textMuted)
                                    if RelayLaunchMode.isSafeMode {
                                        Text("Tools are unavailable in safe mode.").font(.caption).foregroundStyle(RelayTheme.textMuted)
                                    }
                                    HStack {
                                        Button(item.enabled ? "Disable" : "Enable") { manager.change(id, action: item.enabled ? "disable" : "enable") }
                                            .disabled(!item.enabled && (RelayLaunchMode.isSafeMode || !candidate.package.supportsActivation))
                                        Button("Roll back") { manager.change(id, action: "rollback") }.disabled(item.previous == nil)
                                        Button("Uninstall…") { removeID = id }
                                    }.disabled(manager.busy)
                                    if item.enabled && !RelayLaunchMode.isSafeMode {
                                        ForEach(candidate.package.contributions, id: \.id) { entry in
                                            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                                Text(entry.title).font(.headline)
                                                Text(entry.text).textSelection(.enabled)
                                                if entry.kind == .tool { Text("Open from the workspace Plugins button.").foregroundStyle(.secondary) }
                                                if entry.kind == .link, let raw = entry.url, let url = URL(string: raw) {
                                                    Link(raw, destination: url)
                                                }
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(RelayTheme.spacing(6))
                            }.padding(.vertical, RelayTheme.spacing(10))
                            Divider().overlay(RelayTheme.line)
                        }
                    }
                }
            }
        }
        .padding(RelayTheme.spacing(24)).frame(width: 700, height: 620)
        .font(RelayTheme.font(size: 13))
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.canvas)
        .relaySurface()
        .tint(RelayTheme.accent)
        .task { manager.refresh() }
        .onDisappear { manager.cancel() }
        .alert("Uninstall plugin?", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) {
            Button("Cancel", role: .cancel) { removeID = nil }
            Button("Uninstall", role: .destructive) {
                if let id = removeID { manager.change(id, action: "uninstall") }
                removeID = nil
            }
        } message: { Text("Remove the installed and rollback packages. Project files are not changed.") }
    }
}
