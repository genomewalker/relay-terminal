import Darwin
import Foundation
import ImageIO

/// ImageIO reads the authenticated descriptor on demand. Large compressed
/// originals need not be copied into a whole-file Data buffer for thumbnails.
enum RelayAttachmentImageSource {
    private final class Reader {
        let fd: Int32
        var failed = false
        init(fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }

    static func read<T>(_ snapshot: RelayAgentAttachmentSnapshot.Record,
                        _ body: (CGImageSource) throws -> T) throws -> T {
        try snapshot.withVerifiedFile { fd in
            let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw RelayAgentAttachmentSnapshot.Failure.unsuitable }
            let reader = Reader(fd: duplicate)
            let retained = Unmanaged.passRetained(reader)
            var callbacks = CGDataProviderSequentialCallbacks(version: 0, getBytes: { info, buffer, count in
                guard let info else { return 0 }
                let reader = Unmanaged<Reader>.fromOpaque(info).takeUnretainedValue()
                while true {
                    let n = Darwin.read(reader.fd, buffer, count)
                    if n >= 0 { return n }
                    if errno != EINTR { reader.failed = true; return 0 }
                }
            }, skipForward: { info, count in
                guard let info else { return 0 }
                let reader = Unmanaged<Reader>.fromOpaque(info).takeUnretainedValue()
                let before = lseek(reader.fd, 0, SEEK_CUR)
                let after = lseek(reader.fd, count, SEEK_CUR)
                guard before >= 0, after >= before else { reader.failed = true; return 0 }
                return after - before
            }, rewind: { info in
                guard let info else { return }
                let reader = Unmanaged<Reader>.fromOpaque(info).takeUnretainedValue()
                if lseek(reader.fd, 0, SEEK_SET) < 0 { reader.failed = true }
            }, releaseInfo: { info in
                if let info { Unmanaged<Reader>.fromOpaque(info).release() }
            })
            guard let provider = CGDataProvider(sequentialInfo: retained.toOpaque(), callbacks: &callbacks) else {
                retained.release(); throw RelayAgentAttachmentSnapshot.Failure.unsuitable
            }
            guard let source = CGImageSourceCreateWithDataProvider(provider,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw RelayAgentAttachmentSnapshot.Failure.unsuitable
            }
            let result = try body(source)
            guard !reader.failed else { throw RelayAgentAttachmentSnapshot.Failure.changed }
            return result
        }
    }
}
