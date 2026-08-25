import Foundation

struct CapturedProcessOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

enum ProcessCapture {
    static func run(
        _ process: Process,
        output: Pipe,
        errors: Pipe,
        input: Data? = nil,
        timeout: TimeInterval = 30
    ) throws -> CapturedProcessOutput {
        let capturedOutput = LockedData()
        let capturedErrors = LockedData()
        let readers = DispatchGroup()
        try process.run()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capturedOutput.set(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capturedErrors.set(errors.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        if let input, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(input)
            try pipe.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        process.waitUntilExit()
        readers.wait()
        return CapturedProcessOutput(
            standardOutput: capturedOutput.value,
            standardError: capturedErrors.value
        )
    }
}
