import Foundation

/// A pipe read can wait for the entire lifetime of a connection. Such work
/// must not occupy libdispatch's shared worker pool: enough idle connections
/// otherwise prevent unrelated callbacks and recovery work from starting.
/// The caller still owns EOF, process cancellation, and descriptor lifetime.
enum RelayBlockingIO {
    @discardableResult
    static func start(name: String, qos: QualityOfService,
                      body: @escaping @Sendable () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
        return thread
    }
}
