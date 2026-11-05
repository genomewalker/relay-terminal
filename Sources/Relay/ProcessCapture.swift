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
        maximumBytesPerStream: Int = 64 << 20,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        readerQueue: DispatchQueue? = nil
    ) throws -> CapturedProcessOutput {
        precondition(maximumBytesPerStream > 0)
        let capturedOutput = LockedData()
        let capturedErrors = LockedData()
        let failure = CaptureFailure()
        let readers = DispatchGroup()
        try process.run()
        let deadline = DispatchTime.now() + timeout
        // Private descriptors for asking whether every writer has gone; the
        // readers may close their handles while this thread still probes.
        let outputProbe = dup(output.fileHandleForReading.fileDescriptor)
        let errorsProbe = dup(errors.fileHandleForReading.fileDescriptor)
        defer {
            if outputProbe >= 0 { close(outputProbe) }
            if errorsProbe >= 0 { close(errorsProbe) }
        }
        let cancellationTimer = shouldCancel.map { check in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler {
                if check(), process.isRunning {
                    failure.record(.readFailed("Operation cancelled"))
                    process.terminate()
                }
            }
            timer.resume()
            return timer
        }
        defer { cancellationTimer?.cancel() }
        // The caller blocks until the readers finish, so they must not wait for
        // a thread from the shared pool that blocked callers may have filled.
        func startReader(_ body: @escaping @Sendable () -> Void) {
            if let readerQueue { readerQueue.async(execute: body); return }
            let thread = Thread(block: body)
            thread.qualityOfService = .utility
            thread.start()
        }
        readers.enter()
        startReader {
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
        startReader {
            read(
                errors.fileHandleForReading,
                into: capturedErrors,
                limit: maximumBytesPerStream,
                process: process,
                failure: failure
            )
            readers.leave()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            failure.record(.timedOut(seconds: timeout))
            // Terminating the child closes its pipe ends, which unblocks a
            // writer stuck feeding stdin and lets the readers reach EOF.
            process.terminate()
        }
        if let input, let pipe = process.standardInput as? Pipe {
            let writer = pipe.fileHandleForWriting
            // The child may exit before draining stdin (auth failure, reset).
            // Ask for an error instead of SIGPIPE, and use the throwing write
            // so a broken pipe surfaces as a failure rather than an
            // uncatchable NSFileHandleOperationException.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            do {
                try writer.write(contentsOf: input)
                try writer.close()
            } catch {
                failure.record(.readFailed("Could not send input to the command: \(error.localizedDescription)"))
                try? writer.close()
            }
        }
        process.waitUntilExit()
        // A successfully exited launcher can leave a descendant holding one
        // of its pipes open. Never let diagnostics or catalog refreshes pin a
        // thread forever waiting for that unrelated process; give the readers
        // a moment, then give up. The blocked reader threads unwind on their
        // own once the descendant exits — closing the handles here would race
        // their in-flight reads (FileHandle is not safe for concurrent
        // read/close, and a freed descriptor number could be reused). The
        // locked buffers remain safe if a reader finishes after this returns.
        // A reader that has not been scheduled yet is not stuck: once no
        // writer holds either pipe, EOF is certain, so keep waiting for it
        // within the command's own deadline.
        if readers.wait(timeout: .now() + .seconds(1)) == .timedOut,
           !(writersClosed(outputProbe) && writersClosed(errorsProbe)
               && readers.wait(timeout: deadline) == .success) {
            failure.record(.readFailed("Timed out while draining subprocess output streams."))
        }
        if let failure = failure.value { throw failure }
        return CapturedProcessOutput(
            standardOutput: capturedOutput.value,
            standardError: capturedErrors.value
        )
    }

    /// True when the pipe read through `descriptor` has no writer left, so a
    /// reader is guaranteed to reach EOF after the buffered bytes.
    private static func writersClosed(_ descriptor: Int32) -> Bool {
        guard descriptor >= 0 else { return false }
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(descriptor), filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: 0, data: 0, udata: nil
        )
        var event = kevent()
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        guard kevent(queue, &change, 1, &event, 1, &immediately) == 1 else { return false }
        return event.flags & UInt16(EV_EOF) != 0
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
                        // Stop a descendant that inherited this pipe from
                        // blocking on a full buffer after its parent exits.
                        try? handle.close()
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
