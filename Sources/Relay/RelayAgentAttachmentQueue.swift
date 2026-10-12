import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO

@MainActor final class RelayAgentAttachmentQueue: ObservableObject {
    @Published var attachments: [RelayAgentDraftAttachment] = []
    @Published private(set) var uploading: Set<UUID> = []
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var intakeFailure: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    // Only files created by this queue for raw image intake may be discarded.
    // Selected originals and published snapshots can be read by the provider later.
    private var ownedImageSources: [UUID: URL] = [:]

    func reportIntakeFailure(_ message: String) { intakeFailure = message }

    func restore(_ saved: [RelayAgentDraftAttachment]) {
        guard attachments.isEmpty else { return }
        attachments = saved
    }

    func remove(_ id: UUID) {
        generations.removeValue(forKey: id)
        tasks.removeValue(forKey: id)?.cancel()
        uploading.remove(id); failures.removeValue(forKey: id)
        attachments.removeAll { $0.id == id }
        discardOwnedImageSource(id)
    }

    func stage(_ urls: [URL]) {
        intakeFailure = nil
        for url in urls {
            guard attachments.count < 32 else { intakeFailure = "Attach up to 32 files."; break }
            guard !attachments.contains(where: { $0.sourceURL == url }) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
                  values.isRegularFile == true else {
                intakeFailure = "Choose regular files to attach."; continue
            }
            let item = RelayAgentDraftAttachment(sourceURL: url,
                kind: values.contentType?.conforms(to: .image) == true && values.contentType != .svg ? .image : .file)
            guard item.isValid else { intakeFailure = "This file path cannot be attached."; continue }
            attachments.append(item)
        }
    }

    func stageImage(_ data: Data) {
        intakeFailure = nil
        guard !data.isEmpty, data.count <= 32 << 20, attachments.count < 32,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension else {
            intakeFailure = "Could not attach this image (maximum 32 MB)."; return
        }
        let directory = RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentDraftImages", isDirectory: true)
        let url = directory.appendingPathComponent("image-" + UUID().uuidString.lowercased() + "." + ext)
        do {
            try RelayAgentAttachmentSnapshot.createPrivateDirectory(directory)
            try data.write(to: url, options: .atomic)
            SecureFiles.restrictToOwner(url)
            let item = RelayAgentDraftAttachment(sourceURL: url, kind: .image, name: "Pasted image")
            ownedImageSources[item.id] = url
            attachments.append(item)
            intakeFailure = nil
        } catch { intakeFailure = error.localizedDescription }
    }

    /// Uploads never type into the PTY or change the pane's working directory.
    func prepare(_ id: UUID, pane: PaneModel, binding: RelayAgentConversationBinding,
                 resume: Bool = false, bindingIsCurrent: @escaping @MainActor () -> Bool) {
        guard let item = attachments.first(where: { $0.id == id }),
              tasks[id] == nil, item.isValid, binding.isValid,
              binding.paneID == pane.id, binding.hostID == pane.profile.id.uuidString,
              pane.profile.kind == .local || pane.profile.backend == .relay else { return }
        let profile = pane.profile
        let generation = UUID()
        generations[id] = generation
        uploading.insert(id); failures.removeValue(forKey: id)
        tasks[id] = Task { @MainActor [weak self, weak pane] in
            var unpublishedSnapshot: RelayAgentAttachmentSnapshot.Record?
            var unpublishedNativeImage: RelayAgentAttachmentSnapshot.Record?
            defer {
                if let unpublishedSnapshot { try? FileManager.default.removeItem(at: unpublishedSnapshot.url) }
                if let unpublishedNativeImage { try? FileManager.default.removeItem(at: unpublishedNativeImage.url) }
                if self?.generations[id] == generation {
                    self?.tasks.removeValue(forKey: id); self?.uploading.remove(id)
                }
            }
            do {
                let directory = RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/AgentDraftAttachments", isDirectory: true)
                let snapshot: RelayAgentAttachmentSnapshot.Record
                if let saved = item.snapshot {
                    guard saved.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                          await Self.verifySnapshot(saved) else {
                        throw RemoteFileTransferError.failed("The saved attachment is unavailable or changed. Remove it and attach it again.")
                    }
                    snapshot = saved
                } else {
                    snapshot = try await RelayAgentAttachmentSnapshot.captureAsync(item.sourceURL, directory: directory)
                    unpublishedSnapshot = snapshot
                }
                let nativeImage: RelayAgentAttachmentSnapshot.Record?
                if let saved = item.nativeImageSnapshot {
                    guard saved.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                          await Self.verifySnapshot(saved) else {
                        throw RemoteFileTransferError.failed("The prepared image is unavailable or changed. Remove it and attach it again.")
                    }
                    nativeImage = saved
                } else if item.kind == .image {
                    nativeImage = try await RelayAgentImagePreparation.shared.prepare(snapshot, directory: directory)
                    unpublishedNativeImage = nativeImage
                } else { nativeImage = nil }
                try Task.checkCancellation()
                guard let self, self.generations[id] == generation,
                      let pane, pane.profile == profile, bindingIsCurrent(),
                      let index = self.attachments.firstIndex(where: { $0.id == id }) else {
                    throw RemoteFileTransferError.failed("The agent changed. Prepare this attachment again.")
                }
                var captured = self.attachments[index]
                captured.snapshot = snapshot; captured.uploadedPath = nil; captured.uploadedBinding = nil
                captured.nativeImageSnapshot = nativeImage
                self.attachments[index] = captured
                unpublishedSnapshot = nil
                unpublishedNativeImage = nil
                self.discardOwnedImageSource(id)
                let deliverySnapshot = nativeImage ?? snapshot
                let path: String
                if profile.kind == .local {
                    guard FileManager.default.isReadableFile(atPath: deliverySnapshot.url.path) else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    path = deliverySnapshot.url.path
                } else {
                    let entries = try await RemoteFileTransfer.upload([deliverySnapshot.url],
                        toPane: binding.paneID.uuidString.lowercased(), profile: profile, resume: resume)
                    guard entries.count == 1, !entries[0].directory, !entries[0].symbolicLink else {
                        throw RemoteFileTransferError.invalidResponse
                    }
                    path = entries[0].path
                }
                try Task.checkCancellation()
                guard self.generations[id] == generation,
                      pane.profile == profile, pane.id == binding.paneID,
                      bindingIsCurrent(), let index = self.attachments.firstIndex(where: { $0.id == id }) else {
                    throw RemoteFileTransferError.failed("The agent changed. Prepare this attachment again.")
                }
                var ready = self.attachments[index]
                ready.uploadedPath = path; ready.uploadedBinding = binding
                guard ready.isValid else { throw RemoteFileTransferError.invalidResponse }
                self.attachments[index] = ready
            } catch is CancellationError { }
            catch {
                if self?.generations[id] == generation { self?.failures[id] = error.localizedDescription }
            }
        }
    }

    func validateForSend(binding: RelayAgentConversationBinding) async -> Bool {
        let expected = attachments
        let directory = RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/AgentDraftAttachments", isDirectory: true)
        for item in expected {
            guard item.ready(for: binding), let snapshot = item.snapshot,
                  snapshot.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  await Self.verifySnapshot(snapshot) else {
                failures[item.id] = "The saved attachment is unavailable or changed. Remove it and attach it again."
                if let index = attachments.firstIndex(where: { $0.id == item.id }) {
                    attachments[index].uploadedPath = nil; attachments[index].uploadedBinding = nil
                }
                return false
            }
            if let nativeImage = item.nativeImageSnapshot {
                let inDirectory = nativeImage.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
                let verified = inDirectory ? await Self.verifySnapshot(nativeImage) : false
                if !verified {
                    failures[item.id] = "The prepared image is unavailable or changed. Remove it and attach it again."
                    if let index = attachments.firstIndex(where: { $0.id == item.id }) {
                        attachments[index].uploadedPath = nil; attachments[index].uploadedBinding = nil
                    }
                    return false
                }
            }
        }
        return !Task.isCancelled && attachments == expected
    }

    private static func verifySnapshot(_ snapshot: RelayAgentAttachmentSnapshot.Record) async -> Bool {
        let task = Task.detached(priority: .utility) { snapshot.verify() }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func waitForPreparation(_ id: UUID) async { await tasks[id]?.value }

    private func discardOwnedImageSource(_ id: UUID) {
        guard let url = ownedImageSources.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func cancelUploads() {
        for task in tasks.values { task.cancel() }
    }
}
