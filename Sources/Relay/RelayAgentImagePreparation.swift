import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keep the exact captured original and create a provider-readable PNG only
/// for raster formats outside the common PNG/JPEG/GIF/WebP contract.
actor RelayAgentImagePreparation {
    static let shared = RelayAgentImagePreparation()

    func prepare(_ snapshot: RelayAgentAttachmentSnapshot.Record, directory: URL) throws -> RelayAgentAttachmentSnapshot.Record? {
        let bytes = try snapshot.verifiedData()
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw RemoteFileTransferError.failed("This image could not be decoded. Export it as PNG or JPEG and attach it again.")
        }
        if [UTType.png, .jpeg, .gif, .webP].contains(type) { return nil }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw RemoteFileTransferError.failed("This image could not be converted. Export it as PNG or JPEG and attach it again.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RelayAgentAttachmentSnapshot.Failure.unsuitable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), Int64(data.length) <= RemoteFileTransfer.maximumBytes else {
            throw RelayAgentAttachmentSnapshot.Failure.tooLarge
        }
        try Task.checkCancellation()
        let temporary = directory.appendingPathComponent("conversion-" + UUID().uuidString.lowercased() + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try (data as Data).write(to: temporary, options: [.atomic])
        SecureFiles.restrictToOwner(temporary)
        return try RelayAgentAttachmentSnapshot.capture(temporary, directory: directory)
    }
}
