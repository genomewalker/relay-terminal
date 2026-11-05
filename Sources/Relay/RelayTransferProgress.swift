import CryptoKit
import Foundation
import SwiftUI

struct RelayTransferProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, uploading, verifying, complete, failed }
    var phase: Phase
    var name: String
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var itemIndex = 1
    var itemCount = 1
    var message: String?

    var fraction: Double? {
        guard let totalBytes, totalBytes >= 0 else { return nil }
        if phase == .complete { return 1 }
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
    var title: String {
        switch phase {
        case .preparing: "Preparing"
        case .uploading: "Uploading"
        case .verifying: "Verifying"
        case .complete: "Uploaded"
        case .failed: "Upload paused"
        }
    }
    var detail: String {
        if let message { return message }
        guard let totalBytes else { return title + "…" }
        let bytes = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(bytes) of \(total)" + (fraction.map { " · \(Int($0 * 100))%" } ?? "")
    }
}

typealias RelayTransferProgressHandler = @Sendable (RelayTransferProgress) async -> Void

/// A single sequential prefix. Resume starts fresh and reads the acknowledged
/// prefix once; new chunks extend it using the same bytes sent to the helper.
struct RelayTransferChecksum {
    private var hasher = SHA256()
    private(set) var offset: Int64 = 0
    var digest: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }

    mutating func append(_ bytes: Data) {
        hasher.update(data: bytes)
        offset += Int64(bytes.count)
    }
    mutating func advance(_ file: FileHandle, to count: Int64,
                          progress: (@Sendable (Int64) async -> Void)? = nil) async throws {
        guard count >= offset else { throw RemoteFileTransferError.invalidResponse }
        try file.seek(toOffset: UInt64(offset))
        var reportedAt = ContinuousClock.now
        while offset < count {
            try Task.checkCancellation()
            guard let bytes = try file.read(upToCount: Int(min(1 << 20, count - offset))), !bytes.isEmpty else {
                throw RemoteFileTransferError.failed("Source file is incomplete")
            }
            append(bytes)
            let now = ContinuousClock.now
            if offset == count || now - reportedAt >= .milliseconds(100) {
                await progress?(offset); reportedAt = now
            }
        }
    }
}

struct RelayTransferProgressView: View {
    let progress: RelayTransferProgress
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(progress.title + " " + progress.name).lineLimit(1)
                Spacer(minLength: 0)
                if progress.itemCount > 1 { Text("\(progress.itemIndex)/\(progress.itemCount)") }
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss upload progress")
                }
            }
            if progress.phase != .failed {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
            }
            Text(progress.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.caption).padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("relay.upload.progress")
    }
}
