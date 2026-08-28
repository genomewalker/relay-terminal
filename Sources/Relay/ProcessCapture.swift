import Foundation

struct CapturedProcessOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
}

enum ProcessCaptureError: LocalizedError, Equatable {
    case outputTooLarge(limit: Int)
    case readFailed(String)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .outputTooLarge(let limit):
            "Remote command output exceeded the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) safety limit."
        case .readFailed(let reason):
            "Remote command output could not be read: \(reason)"
        case .timedOut(let seconds):
            "Remote command did not finish within \(Int(seconds.rounded())) seconds."
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count <= limit, data.count <= limit - storage.count else {
            return false
        }
        storage.append(data)
        return true
    }

    var value: Data {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

private final class CaptureFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ProcessCaptureError?

    func record(_ error: ProcessCaptureError) {
        lock.lock()
        if storage == nil { storage = error }
        lock.unlock()
    }

    var value: ProcessCaptureError? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum ProcessCapture {
    static func run(
        _ process: Process,
        output: Pipe,
        errors: Pipe,
        input: Data? = nil,
        timeout: TimeInterval = 30,
        maximumBytesPerStream: Int = 64 << 20
    ) throws -> CapturedProcessOutput {
        precondition(maximumBytesPerStream > 0)
        let capturedOutput = LockedData()
        let capturedErrors = LockedData()
        let failure = CaptureFailure()
        let readers = DispatchGroup()
        try process.run()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            read(
                output.fileHandleForReading,
                into: capturedOutput,
                limit: maximumBytesPerStream,
                process: process,
                failure: failure
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            read(
                errors.fileHandleForReading,
                into: capturedErrors,
                limit: maximumBytesPerStream,
                process: process,
                failure: failure
            )
            readers.leave()
        }
        if let input, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(input)
            try pipe.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            failure.record(.timedOut(seconds: timeout))
            process.terminate()
        }
        process.waitUntilExit()
        readers.wait()
        if let failure = failure.value { throw failure }
        return CapturedProcessOutput(
            standardOutput: capturedOutput.value,
            standardError: capturedErrors.value
        )
    }

    private static func read(
        _ handle: FileHandle,
        into destination: LockedData,
        limit: Int,
        process: Process,
        failure: CaptureFailure
    ) {
        do {
            while true {
                let result = try autoreleasepool { () throws -> Bool in
                    guard let chunk = try handle.read(upToCount: 64 << 10),
                          !chunk.isEmpty else { return false }
                    guard destination.append(chunk, limit: limit) else {
                        failure.record(.outputTooLarge(limit: limit))
                        if process.isRunning { process.terminate() }
                        return false
                    }
                    return true
                }
                guard result else {
                    if failure.value != nil { return }
                    break
                }
            }
        } catch {
            failure.record(.readFailed(error.localizedDescription))
            if process.isRunning { process.terminate() }
        }
    }
}
