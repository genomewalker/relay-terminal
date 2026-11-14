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
        let bytes = try await read(context: context, path: path, version: version, from: 0, to: size,
            failure: "Image changed or transfer was incomplete")
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
    /// Reads only the last `maxBytes` of a remote text file, verifying every chunk.
    static func text(path: String, profile: ConnectionProfile, maxBytes: Int = RelayLogTail.defaultMaxBytes) async throws -> RelayLogTail {
        let context = RelayExecutionContext(profile: profile, directory: "/")
        let stat = try await request(context: context, fields: ["operation": "file_stat", "path": path])
        guard let size = stat["size"] as? Int, size >= 0, let version = stat["version"] as? String,
              stat["directory"] as? Bool == false else { throw RemoteCatalogError.failed("Select a regular text file") }
        let bytes = try await read(context: context, path: path, version: version, from: max(0, size - maxBytes), to: size,
            failure: "Log changed or transfer was incomplete")
        return RelayLogTail(bytes: bytes, totalBytes: size)
    }
    /// Quick Look reads whole files up to this size.
    static let previewMaxBytes = 32 << 20

    /// A whole remote file for Quick Look. "~/" and relative paths are
    /// resolved by the host (relative ones against `cwd`). Every chunk is
    /// verified against the version and size from one stat.
    static func file(path: String, cwd: String?, profile: ConnectionProfile,
                     maxBytes: Int = previewMaxBytes) async throws -> Data {
        let context = RelayExecutionContext(profile: profile, directory: cwd ?? "/")
        let stat = try await request(context: context, fields: ["operation": "file_stat", "path": path])
        let (size, version) = try previewable(stat: stat, maxBytes: maxBytes)
        guard size > 0 else { return Data() }
        return try await read(context: context, path: path, version: version, from: 0, to: size,
            failure: "File changed or transfer was incomplete")
    }

    /// The size and version of a stat result Quick Look may read.
    static func previewable(stat: [String: Any], maxBytes: Int) throws -> (size: Int, version: String) {
        if stat["directory"] as? Bool == true {
            throw RemoteCatalogError.failed("Folders on a remote host can't be previewed")
        }
        guard let size = stat["size"] as? Int, size >= 0, let version = stat["version"] as? String,
              stat["directory"] as? Bool == false else {
            throw RemoteCatalogError.failed("Not a regular file")
        }
        guard size <= maxBytes else {
            throw RemoteCatalogError.failed("File is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); "
                + "Quick Look reads remote files up to \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))")
        }
        return (size, version)
    }

    private static func read(context: RelayExecutionContext, path: String, version: String, from start: Int, to size: Int,
                             failure: String) async throws -> Data {
        var bytes = Data(), offset = start
        while offset < size {
            try Task.checkCancellation()
            let chunk = try await request(context: context, fields: ["operation": "file_read", "path": path,
                "version": version, "offset": offset, "length": min(4 << 20, size-offset)])
            guard chunk["version"] as? String == version, let encoded = chunk["data"] as? String,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= size-offset,
                  chunk["next_offset"] as? Int == offset+data.count,
                  chunk["sha256"] as? String == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
                throw RemoteCatalogError.failed(failure)
            }
            bytes.append(data); offset += data.count
        }
        return bytes
    }
}
