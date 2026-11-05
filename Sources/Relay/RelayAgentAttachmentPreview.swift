import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Serialize decoding so a draft containing many large images cannot allocate
/// all of their compressed input buffers at once. Only thumbnails reach the UI.
private actor RelayAgentAttachmentThumbnailer {
    static let shared = RelayAgentAttachmentThumbnailer()

    func render(_ snapshot: RelayAgentAttachmentSnapshot.Record) -> Data? {
        return try? RelayAttachmentImageSource.read(snapshot) { source in
        guard !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
        return output as Data
        }
    }
}

struct RelayAgentAttachmentPreview: View {
    let attachment: RelayAgentDraftAttachment
    var pane: PaneModel? = nil
    @State private var thumbnail: NSImage?

    /// Previews the captured, digest-verified snapshot (what will be sent), never the mutable
    /// source; the draft itself is untouched.
    private var previewKind: RelayFilePreviewKind? {
        guard attachment.snapshot != nil else { return nil }
        return RelayFilePreviewKind.from(path: attachment.name) ?? (attachment.kind == .image ? .image : nil)
    }

    var body: some View {
        Button {
            guard let pane, let previewKind, let snapshot = attachment.snapshot else { return }
            pane.openAttachmentPreview(snapshot: snapshot, name: attachment.name, kind: previewKind)
        } label: {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: attachment.kind == .image ? "photo" : previewKind?.symbol ?? "doc")
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pane == nil || previewKind == nil)
        .help(previewKind == nil ? attachment.name : "Preview " + attachment.name)
        .accessibilityLabel(previewKind == nil ? "Attached file " + attachment.name : "Preview " + attachment.name)
        .accessibilityIdentifier("relay.file-card")
        .task(id: attachment.snapshot) {
            thumbnail = nil
            guard attachment.kind == .image, let snapshot = attachment.snapshot else { return }
            let data = await RelayAgentAttachmentThumbnailer.shared.render(snapshot)
            guard !Task.isCancelled, let data else { return }
            thumbnail = NSImage(data: data)
        }
    }
}
