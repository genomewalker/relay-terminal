import AppKit
import CryptoKit
import ImageIO

enum RelayHostFiles {
    static func request(context: RelayExecutionContext, fields: [String: Any]) async throws -> [String: Any] {
        var input = fields
        input["request_id"] = "rpc-" + UUID().uuidString.lowercased()
        input["cwd"] = context.directory
        let bytes = try await RelayNodeTransportPool.shared.request(profile: context.profile,
            payload: JSONSerialization.data(withJSONObject: input))
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw RelayHostRPCError.invalidRequest }
        if let error = response["error"] as? String { throw RemoteCatalogError.failed(error) }
        guard let result = response["result"] as? [String: Any] else { throw RelayHostRPCError.invalidRequest }
        return result
    }
    static func image(context: RelayExecutionContext, path: String, preserveFormat: Bool = false) async throws -> Data {
        let stat = try await request(context: context, fields: ["operation": "file_stat", "path": path])
        guard let size = stat["size"] as? Int, size > 0, size <= 32 << 20,
              let version = stat["version"] as? String, stat["directory"] as? Bool == false else {
            throw RemoteCatalogError.failed("Select an image file no larger than 32 MiB")
        }
        var bytes = Data(), offset = 0
        while offset < size {
            try Task.checkCancellation()
            let chunk = try await request(context: context, fields: ["operation": "file_read", "path": path,
                "version": version, "offset": offset, "length": min(4 << 20, size-offset)])
            guard chunk["version"] as? String == version, let encoded = chunk["data"] as? String,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= size-offset,
                  chunk["next_offset"] as? Int == offset+data.count,
                  chunk["sha256"] as? String == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
                throw RemoteCatalogError.failed("Image changed or transfer was incomplete")
            }
            bytes.append(data); offset += data.count
        }
        if preserveFormat { return bytes }
        let captured = bytes
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(captured as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw RemoteCatalogError.failed("File is not a supported image")
            }
            return png
        }.value
    }
}
