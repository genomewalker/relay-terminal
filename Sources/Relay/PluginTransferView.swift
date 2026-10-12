import AppKit
import SwiftUI
import CryptoKit

struct PluginTransferStamp: Equatable {
    let pluginID: String
    let digest: String
    let scope: PluginScope
    let path: String
    var persistenceKey: String {
        let values = [pluginID, digest, scope.paneID.uuidString, scope.profile.id.uuidString,
                      scope.profile.kind.rawValue, scope.profile.host, scope.profile.user,
                      String(scope.profile.port), String(scope.profile.usesSSHConfig),
                      scope.profile.command, scope.root, path]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PluginTransferSaveRequest {
    let stamp: PluginTransferStamp
    let generation: UInt64
    let download: PluginTransferDownload
}

@MainActor final class PluginTransferPresentation: ObservableObject {
    @Published private(set) var completed: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var message = "Downloads in bounded chunks. Saved progress can be resumed after reopening Relay."
    private var download: PluginTransferDownload?
    private var task: Task<Void, Never>?
    private var stamp: PluginTransferStamp?
    private(set) var generation: UInt64 = 0

    func configure(_ next: PluginTransferStamp) {
        guard stamp != next else { return }
        pause()
        generation &+= 1
        stamp = next; download = nil; completed = 0; total = 0; ready = false
        busy = false; task = nil
        message = "Downloads in bounded chunks. Saved progress can be resumed after reopening Relay."
    }

    func start(stamp: PluginTransferStamp,
               authorize: @escaping @MainActor @Sendable () async throws -> Void) {
        configure(stamp)
        guard !busy else { return }
        let operationGeneration = generation
        busy = true
        task = Task { @MainActor [self] in
            defer {
                if generation == operationGeneration { busy = false; task = nil }
            }
            do {
                try await authorize()
                try Task.checkCancellation()
                if download == nil { download = try PluginTransferDownload(persistenceKey: stamp.persistenceKey) }
                guard let download else { return }
                _ = try await download.download(fetch: { request in
                    try await authorize()
                    try Task.checkCancellation()
                    let response = try await PluginOperationRunner.run(.transfers, scope: stamp.scope, path: stamp.path, transfer: request)
                    try await authorize()
                    try Task.checkCancellation()
                    return response
                }, progress: { count, size in
                    await MainActor.run {
                        guard self.generation == operationGeneration else { return }
                        self.completed = count; self.total = size
                    }
                })
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                ready = true; message = "Complete. Chunk checksums and final SHA-256 verified."
            } catch is CancellationError {
                if generation == operationGeneration { message = "Paused. Resume continues from the last verified chunk." }
            } catch {
                if generation == operationGeneration { message = error.localizedDescription }
            }
        }
    }

    func pause() { task?.cancel() }

    func discard() {
        guard !busy else { return }
        guard let stamp else { return }
        let operationGeneration = generation
        busy = true
        task = Task { @MainActor [self] in
            defer { if generation == operationGeneration { busy = false; task = nil } }
            do {
                let current = try download ?? PluginTransferDownload(persistenceKey: stamp.persistenceKey, discardExisting: true)
                try await current.discard()
                guard generation == operationGeneration else { return }
                download = nil; completed = 0; total = 0; ready = false
                message = "Partial copy discarded."
            } catch { if generation == operationGeneration { message = error.localizedDescription } }
        }
    }

    func saveRequest() -> PluginTransferSaveRequest? {
        guard let stamp, let download, ready, !busy else { return nil }
        return PluginTransferSaveRequest(stamp: stamp, generation: generation, download: download)
    }

    func save(_ request: PluginTransferSaveRequest, to destination: URL,
              authorize: @escaping @MainActor @Sendable () async throws -> Void) {
        guard stamp == request.stamp, generation == request.generation,
              download === request.download, ready, !busy else { return }
        let operationGeneration = request.generation
        busy = true
        task = Task { @MainActor [self] in
            defer {
                if generation == operationGeneration { busy = false; task = nil }
            }
            do {
                try await authorize()
                try Task.checkCancellation()
                guard stamp == request.stamp, generation == request.generation,
                      download === request.download else { throw CancellationError() }
                try await request.download.save(to: destination)
                if generation == operationGeneration {
                    message = "Saved verified copy to \(destination.lastPathComponent)."
                }
            } catch {
                if generation == operationGeneration { message = error.localizedDescription }
            }
        }
    }
}

struct PluginTransferView: View {
    let stamp: PluginTransferStamp
    let authorize: @MainActor @Sendable () async throws -> Void
    @ObservedObject var presentation: PluginTransferPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            Text(stamp.path).font(.headline).textSelection(.enabled)
            Text(presentation.message).font(.caption).textSelection(.enabled)
            if presentation.total > 0 {
                ProgressView(value: Double(presentation.completed), total: Double(presentation.total))
                Text("\(ByteCountFormatter.string(fromByteCount: presentation.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: presentation.total, countStyle: .file))")
            }
            HStack {
                if presentation.busy {
                    Button("Pause") { presentation.pause() }
                } else if presentation.ready {
                    Button("Save verified copy…") { save() }
                } else {
                    Button(presentation.completed == 0 ? "Allow download / resume" : "Resume") {
                        presentation.start(stamp: stamp, authorize: authorize)
                    }
                }
                Button("Discard partial copy") { presentation.discard() }
                    .disabled(presentation.busy)
            }
        }.padding(RelayTheme.spacing(8))
        .task { presentation.configure(stamp) }
    }

    private func save() {
        guard let request = presentation.saveRequest() else { return }
        let panel = RelayTheme.savePanel()
        panel.nameFieldStringValue = (request.stamp.path as NSString).lastPathComponent
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            presentation.save(request, to: destination, authorize: authorize)
        }
    }
}
