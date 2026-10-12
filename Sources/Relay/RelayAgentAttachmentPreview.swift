import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Serialize decoding so a draft containing many large images cannot allocate
/// all of their compressed input buffers at once. Only thumbnails reach the UI.
private actor RelayAgentAttachmentThumbnailer {
    static let shared = RelayAgentAttachmentThumbnailer()

    func render(_ snapshot: RelayAgentAttachmentSnapshot.Record) -> Data? {
        guard let bytes = try? snapshot.verifiedData(), !Task.isCancelled,
              let source = CGImageSourceCreateWithData(bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
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

struct RelayAgentAttachmentPreview: View {
    let attachment: RelayAgentDraftAttachment
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityLabel(attachment.kind == .image ? "Image preview" : "Attached file")
        .task(id: attachment.snapshot) {
            thumbnail = nil
            guard attachment.kind == .image, let snapshot = attachment.snapshot else { return }
            let data = await RelayAgentAttachmentThumbnailer.shared.render(snapshot)
            guard !Task.isCancelled, let data else { return }
            thumbnail = NSImage(data: data)
        }
    }
}
