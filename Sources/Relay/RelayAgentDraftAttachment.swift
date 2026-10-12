import Foundation

/// An unsent file reference. A saved upload is not permission to deliver it to
/// another provider incarnation; the sender must revalidate the full binding.
struct RelayAgentDraftAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let name: String
    let kind: Kind
    var uploadedPath: String?
    var uploadedBinding: RelayAgentConversationBinding?
    var snapshot: RelayAgentAttachmentSnapshot.Record? = nil
    var nativeImageSnapshot: RelayAgentAttachmentSnapshot.Record? = nil

    enum Kind: String, Codable, Sendable { case file, image }

    init(sourceURL: URL, kind: Kind, name: String? = nil) {
        id = UUID()
        self.sourceURL = sourceURL
        self.name = name ?? sourceURL.lastPathComponent
        self.kind = kind
    }

    var isValid: Bool {
        sourceURL.isFileURL && sourceURL.path.hasPrefix("/") &&
            sourceURL.absoluteString.utf8.count <= 4096 &&
            !name.isEmpty && name.utf8.count <= 1024 &&
            Self.safePath(sourceURL.path) &&
            (uploadedPath == nil || Self.safePath(uploadedPath!)) &&
            ((uploadedPath == nil) == (uploadedBinding == nil)) &&
            (snapshot?.isValid ?? true) &&
            (nativeImageSnapshot?.isValid ?? true) &&
            (nativeImageSnapshot == nil || (kind == .image && snapshot != nil)) &&
            (uploadedBinding.map { $0.isValid && $0.hostID.utf8.count <= 1024 &&
                $0.processStart.utf8.count <= 128 && ($0.sourceIdentity?.utf8.count ?? 0) <= 1024 } ?? true)
    }

    func ready(for binding: RelayAgentConversationBinding) -> Bool {
        isValid && snapshot != nil && uploadedPath != nil && uploadedBinding == binding
    }

    private static func safePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}

struct RelayAgentStoredDraft: Equatable, Sendable {
    let text: String
    let attachments: [RelayAgentDraftAttachment]
}
