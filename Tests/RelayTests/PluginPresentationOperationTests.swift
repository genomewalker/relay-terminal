import Testing
@testable import Relay

@Test @MainActor func pluginPresenterHideDoesNotCancelMutation() async {
    let owner = PluginPresentationOperation()
    var release: CheckedContinuation<Void, Never>?
    var cancelled: Bool?
    #expect(owner.start(retainOnHide: true) {
        await withCheckedContinuation { release = $0 }
        cancelled = Task.isCancelled
    })
    while release == nil { await Task.yield() }
    #expect(!owner.start(retainOnHide: false) { Issue.record("Duplicate helper") })
    owner.presenterHidden()
    release?.resume()
    while owner.running { await Task.yield() }
    #expect(cancelled == false)
}

@Test @MainActor func pluginPresenterHideCancelsReadAndExplicitCancelStopsWait() async {
    for retain in [false, true] {
        let owner = PluginPresentationOperation()
        var release: CheckedContinuation<Void, Never>?
        var cancelled = false
        owner.start(retainOnHide: retain) {
            await withCheckedContinuation { release = $0 }
            cancelled = Task.isCancelled
        }
        while release == nil { await Task.yield() }
        if retain { owner.cancel() } else { owner.presenterHidden() }
        release?.resume()
        while owner.running { await Task.yield() }
        #expect(cancelled)
    }
}
