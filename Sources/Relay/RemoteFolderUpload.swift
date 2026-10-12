import Foundation

struct RemoteFolderRequest: Encodable, Sendable {
    let operation: String
    let jobID: String
    var pane: String?
    var name: String?
    var path: String?
    var manifest: [RemoteFolderEntry]?
    var sourceVersion: String?
    var child: String?
    var offset: Int64?
    var data: Data?
    enum CodingKeys: String, CodingKey {
        case operation, path, offset, data
        case jobID = "job_id", pane = "upload_pane", name = "upload_name"
        case manifest = "folder_manifest", sourceVersion = "folder_source_version", child = "folder_child"
    }
}

struct RemoteFolderChildReceipt: Decodable, Sendable {
    let path: String
    let state: String
    let size: Int64
    let sha256: String
    let offset: Int64
    let prefixSHA256: String
    enum CodingKeys: String, CodingKey {
        case path, state, size, sha256, offset
        case prefixSHA256 = "prefix_sha256"
    }
}

struct RemoteFolderReceipt: Decodable, Sendable {
    let id: String
    let state: String
    let path: String?
    let manifestSHA256: String?
    let fingerprint: String?
    let pane: String?
    let sourceVersion: String?
    let committedFiles: Int
    let child: RemoteFolderChildReceipt?
    enum CodingKeys: String, CodingKey {
        case id, state, path, fingerprint, pane, child
        case manifestSHA256 = "manifest_sha256", sourceVersion = "source_version", committedFiles = "committed_files"
    }
}

struct RemoteFolderProgress: Codable, Sendable {
    let path: String
    var offset: Int64
    var prefixSHA256: String
    var committed: Bool
}

struct RemoteFolderCheckpoint: Codable, Sendable {
    var schema = 1
    let key: String
    let jobID: String
    let pane: String
    let name: String
    let parent: String
    let snapshot: RemoteFolderSnapshot
    var remotePath: String?
    var fingerprint: String?
    var state = "prepared"
    var children: [RemoteFolderProgress] = []
    var cleaned = false
}

actor RemoteFolderUpload {
    typealias Fetch = @Sendable (RemoteFolderRequest) async throws -> RemoteFolderReceipt
    private let source: URL
    private let pane: String
    private let key: String
    private let store: RemoteUploadStore
    private var checkpoint: RemoteFolderCheckpoint?
    private var running = false
    private var poisoned = false

    init(source: URL, pane: String, profile: ConnectionProfile, root: URL? = nil) throws {
        self.source = source; self.pane = pane
        key = RemoteFolderSource.digest(Data(("folder:" + (try RemoteUpload.identity(source: source, pane: pane, profile: profile))).utf8))
        let directory = root ?? RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/FolderUploads")
        store = try RemoteUploadStore(key: key, root: directory, maximumCheckpointBytes: 8 << 20)
        checkpoint = try store.read()
        if let saved = checkpoint {
            try RemoteFolderSource.validate(saved.snapshot)
            let empty = RemoteFolderSource.digest(Data())
            var progressPaths = Set<Data>()
            let expectedPath = saved.parent == "/" ? "/" + saved.name : saved.parent + "/" + saved.name
            guard saved.schema == 1, saved.key == key, saved.pane == pane,
                  saved.jobID.range(of: "^folder-[0-9a-f-]{36}$", options: .regularExpression) != nil,
                  saved.parent.hasPrefix("/"), !saved.parent.contains("\0"), !saved.name.isEmpty,
                  saved.name.utf8.count <= 240, !saved.name.contains("/"), !saved.name.contains("\\"), !saved.name.contains("\0"), saved.name != ".", saved.name != "..",
                  saved.remotePath == nil || RemoteFolderSource.exact(saved.remotePath!,expectedPath),
                  saved.fingerprint == nil || saved.fingerprint!.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                  saved.state == "prepared" || saved.remotePath != nil && saved.fingerprint != nil,
                  !saved.cleaned || saved.state == "committed",
                  saved.snapshot.entries.count <= 1024, saved.snapshot.totalBytes >= 0, saved.snapshot.totalBytes <= 1 << 30,
                  RemoteFolderSource.digest(RemoteFolderSource.canonicalManifest(saved.snapshot.entries)) == saved.snapshot.manifestSHA256,
                  ["prepared", "receiving", "committing", "committed"].contains(saved.state),
                  saved.children.count <= saved.snapshot.entries.count, saved.children.allSatisfy({ progress in
                      progressPaths.insert(Data(progress.path.utf8)).inserted &&
                      saved.snapshot.entries.contains { entry in
                          RemoteFolderSource.exact(entry.path, progress.path) && entry.kind == "file" && progress.offset >= 0 && progress.offset <= (entry.size ?? -1) && (!progress.committed || progress.offset == entry.size && progress.prefixSHA256 == entry.sha256)
                      } && progress.prefixSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && (progress.offset > 0 || progress.prefixSHA256 == empty)
                  }) else { throw RemoteFileTransferError.failed("Invalid folder upload checkpoint") }
        }
    }

    func hasCheckpoint() -> Bool { checkpoint != nil }

    private func save(_ saved: RemoteFolderCheckpoint) throws {
        do { try store.save(saved); checkpoint = saved }
        catch { poisoned = true; throw error }
    }

    private func accept(_ receipt: RemoteFolderReceipt, saved: inout RemoteFolderCheckpoint) throws {
        let expectedPath = saved.parent == "/" ? "/" + saved.name : saved.parent + "/" + saved.name
        guard receipt.id == saved.jobID, receipt.pane == saved.pane,
              receipt.sourceVersion == saved.snapshot.sourceVersion, receipt.manifestSHA256 == saved.snapshot.manifestSHA256,
              let path = receipt.path, RemoteFolderSource.exact(path, expectedPath),
              saved.remotePath == nil || RemoteFolderSource.exact(saved.remotePath!, path),
              let fingerprint = receipt.fingerprint, fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              saved.fingerprint == nil || saved.fingerprint == fingerprint,
              ["receiving", "committing", "committed"].contains(receipt.state),
              saved.state != "committing" || receipt.state != "receiving",
              saved.state != "committed" || receipt.state == "committed" else { throw RemoteFileTransferError.invalidResponse }
        let fileCount = saved.snapshot.entries.filter { $0.kind == "file" }.count
        guard receipt.committedFiles >= 0, receipt.committedFiles <= fileCount,
              receipt.state != "committed" || receipt.committedFiles == fileCount else { throw RemoteFileTransferError.invalidResponse }
        saved.remotePath = path; saved.fingerprint = fingerprint; saved.state = receipt.state
        try save(saved)
    }

    private func acceptChild(_ receipt: RemoteFolderReceipt, entry: RemoteFolderEntry, file: FileHandle,
                             tree: RemoteFolderSource, saved: inout RemoteFolderCheckpoint) throws -> RemoteFolderChildReceipt {
        guard let child = receipt.child, RemoteFolderSource.exact(child.path, entry.path), child.size == entry.size,
              child.sha256 == entry.sha256, child.offset >= 0, child.offset <= child.size,
              ["pending", "receiving", "publishing", "committed"].contains(child.state),
              child.state != "pending" || child.offset == 0,
              child.state != "publishing" || child.offset == child.size && child.prefixSHA256 == child.sha256,
              receipt.state != "committed" || child.state == "committed",
              child.state != "committed" || child.offset == child.size && child.prefixSHA256 == child.sha256 else {
            throw RemoteFileTransferError.invalidResponse
        }
        let old = saved.children.first { RemoteFolderSource.exact($0.path, entry.path) }
        guard child.offset >= (old?.offset ?? 0), old?.committed != true || child.state == "committed",
              try RemoteFolderSource.hash(file, count: child.offset) == child.prefixSHA256 else { throw RemoteFileTransferError.invalidResponse }
        try tree.checkFile(file, entry: entry, snapshot: saved.snapshot)
        try accept(receipt, saved: &saved)
        let progress = RemoteFolderProgress(path: entry.path, offset: child.offset, prefixSHA256: child.prefixSHA256, committed: child.state == "committed")
        if let index = saved.children.firstIndex(where: { RemoteFolderSource.exact($0.path, entry.path) }) { saved.children[index] = progress }
        else { saved.children.append(progress) }
        try save(saved)
        return child
    }

    func upload(resume: Bool, destination: String?, fetch: Fetch) async throws -> RemoteFileEntry {
        guard !running, !poisoned else { throw RemoteFileTransferError.failed("Folder upload is busy or must be reopened") }
        if checkpoint != nil, !resume { throw RemoteFileTransferError.recoveryAvailable }
        running = true; defer { running = false }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let tree = try RemoteFolderSource(source: source)
        let snapshot = try tree.snapshot()
        let existing = checkpoint != nil
        let parent = checkpoint?.parent ?? destination
        guard let parent, parent.hasPrefix("/"), !parent.contains("\0"),
              parent == "/" || !parent.hasSuffix("/"), !(parent as NSString).pathComponents.contains(".."),
              !(parent as NSString).pathComponents.contains(".") else { throw RemoteFileTransferError.failed("Exact folder destination required") }
        var saved = checkpoint ?? RemoteFolderCheckpoint(key: key, jobID: "folder-" + UUID().uuidString.lowercased(),
                                                        pane: pane, name: source.lastPathComponent, parent: parent, snapshot: snapshot)
        guard saved.snapshot.sourceVersion == snapshot.sourceVersion, saved.snapshot.manifestSHA256 == snapshot.manifestSHA256 else {
            throw RemoteFileTransferError.failed("Folder source changed; forget the saved upload before starting again")
        }
        try save(saved)
        let request = existing && saved.state != "prepared"
            ? RemoteFolderRequest(operation: "file_folder_status", jobID: saved.jobID)
            : RemoteFolderRequest(operation: "file_folder_begin", jobID: saved.jobID, pane: pane, name: saved.name, path: saved.parent,
                                  manifest: saved.snapshot.entries, sourceVersion: saved.snapshot.sourceVersion)
        var group = try await fetch(request)
        try accept(group, saved: &saved)
        if group.state == "receiving" {
            for entry in saved.snapshot.entries where entry.kind == "file" {
                try Task.checkCancellation()
                let file = try tree.openFile(entry, snapshot: saved.snapshot)
                defer { try? file.close() }
                var response = try await fetch(RemoteFolderRequest(operation: "file_folder_status", jobID: saved.jobID, child: entry.path))
                var child = try acceptChild(response, entry: entry, file: file, tree: tree, saved: &saved)
                while ["pending", "receiving"].contains(child.state), child.offset < child.size {
                    try Task.checkCancellation(); try tree.checkFile(file, entry: entry, snapshot: saved.snapshot)
                    try file.seek(toOffset: UInt64(child.offset))
                    guard let bytes = try file.read(upToCount: Int(min(4 << 20, child.size - child.offset))), !bytes.isEmpty else { throw RemoteFileTransferError.invalidResponse }
                    try tree.checkFile(file, entry: entry, snapshot: saved.snapshot)
                    let expectedOffset = child.offset + Int64(bytes.count)
                    response = try await fetch(RemoteFolderRequest(operation: "file_folder_chunk", jobID: saved.jobID, child: entry.path, offset: child.offset, data: bytes))
                    child = try acceptChild(response, entry: entry, file: file, tree: tree, saved: &saved)
                    guard child.offset == expectedOffset else { throw RemoteFileTransferError.invalidResponse }
                }
                if child.state != "committed" {
                    try Task.checkCancellation(); try tree.checkFile(file, entry: entry, snapshot: saved.snapshot)
                    response = try await fetch(RemoteFolderRequest(operation: "file_folder_file_commit", jobID: saved.jobID, child: entry.path))
                    child = try acceptChild(response, entry: entry, file: file, tree: tree, saved: &saved)
                }
                guard child.state == "committed" else { throw RemoteFileTransferError.invalidResponse }
            }
        }
        let finalSnapshot = try tree.snapshot()
        guard finalSnapshot.sourceVersion == saved.snapshot.sourceVersion, finalSnapshot.manifestSHA256 == saved.snapshot.manifestSHA256 else {
            throw RemoteFileTransferError.failed("Folder source changed; forget the saved upload before starting again")
        }
        if saved.state != "committed" {
            try Task.checkCancellation()
            group = try await fetch(RemoteFolderRequest(operation: "file_folder_commit", jobID: saved.jobID))
            try accept(group, saved: &saved)
        }
        guard saved.state == "committed", let path = saved.remotePath else { throw RemoteFileTransferError.invalidResponse }
        if !saved.cleaned {
            let cleanup = try await fetch(RemoteFolderRequest(operation: "file_folder_cleanup", jobID: saved.jobID))
            try accept(cleanup, saved: &saved)
            saved.cleaned = true; try save(saved)
        }
        return RemoteFileEntry(name: saved.name, path: path, directory: true, symbolicLink: false, size: saved.snapshot.totalBytes, modificationNS: 0)
    }

    func discard(fetch: Fetch) async throws {
        guard !running, !poisoned else { throw RemoteFileTransferError.failed("Pause the folder upload before forgetting it") }
        guard let saved = checkpoint else { return }
        running = true; defer { running = false }
        let receipt = try await fetch(RemoteFolderRequest(operation: "file_folder_cancel", jobID: saved.jobID))
        let expectedPath = saved.parent == "/" ? "/" + saved.name : saved.parent + "/" + saved.name
        guard receipt.id == saved.jobID, ["cancelled", "committed"].contains(receipt.state),
              receipt.path == nil || RemoteFolderSource.exact(receipt.path!,expectedPath),
              receipt.fingerprint == nil || saved.fingerprint == nil || receipt.fingerprint == saved.fingerprint,
              receipt.pane == nil || receipt.pane == pane, receipt.sourceVersion == nil || receipt.sourceVersion == saved.snapshot.sourceVersion,
              receipt.manifestSHA256 == nil || receipt.manifestSHA256 == saved.snapshot.manifestSHA256 else { throw RemoteFileTransferError.invalidResponse }
        let cleanup = try await fetch(RemoteFolderRequest(operation: "file_folder_cleanup", jobID: saved.jobID))
        guard cleanup.id == saved.jobID, cleanup.state == receipt.state, cleanup.fingerprint == receipt.fingerprint,
              cleanup.path == receipt.path else { throw RemoteFileTransferError.invalidResponse }
        do { try store.remove(); checkpoint = nil }
        catch { poisoned = true; throw error }
    }
}
