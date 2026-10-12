import AppKit
import Foundation
import ImageIO
import Testing
@testable import Relay

/// Opt-in only: uses an explicitly owned, already-running remote R companion.
/// All remote operations go through the installed Relay workspace API. No SSH,
/// process launch, package installation, or session adoption occurs here.
private final class HttpgdInstalledWorkspaceRPC: @unchecked Sendable {
    private let tab: String
    private let host: String
    private let directory: String
    private let token: String
    private let session: URLSession

    init(tab: String, host: String, directory: String) throws {
        self.tab = tab; self.host = host; self.directory = directory
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/dev.relay.terminal.plist")
        let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any]
        token = try #require(preferences?["relay.side-panel-token.v1"] as? String)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }

    private func post(_ path: String, _ object: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:47471" + path)!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Relay-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RHttpgdError.invalidResponse("Installed workspace API rejected the scoped operation")
        }
        return data
    }
    func request(_ payload: Data) async throws -> Data {
        let context = try JSONSerialization.jsonObject(with: await post("/api/workspace/context", ["tab_id": tab])) as? [String: Any]
        guard context?["host"] as? String == host, context?["directory"] as? String == directory else {
            throw RHttpgdError.invalidResponse("Captured workspace context changed")
        }
        let object = try JSONSerialization.jsonObject(with: payload)
        return try await post("/api/workspace/host-request", ["tab_id": tab, "request": object])
    }
    func operation(_ object: [String: Any]) async throws -> [String: Any] {
        let response = try JSONSerialization.jsonObject(with: await request(JSONSerialization.data(withJSONObject: object))) as? [String: Any]
        guard response?["error"] == nil, let result = response?["result"] as? [String: Any] else {
            let operation = object["operation"] as? String ?? "unknown"
            let detail = (response?["error"] as? String).map { String($0.prefix(256)) } ?? "missing result"
            throw RHttpgdError.invalidResponse("Scoped remote \(operation) failed: \(detail)")
        }
        return result
    }
    func file(_ path: String) async throws -> Data {
        let stat = try await operation(["operation": "file_stat", "path": path])
        let version = try #require(stat["version"] as? String)
        let size = try #require(stat["size"] as? Int)
        guard size > 0, size < 64 << 10 else { throw RHttpgdError.oversized(64 << 10) }
        let read = try await operation(["operation": "file_read", "path": path, "version": version, "offset": 0, "length": size])
        let encoded = try #require(read["data"] as? String)
        return try #require(Data(base64Encoded: encoded))
    }
}

@Test("Real remote R device through app bridge and installed native workspace transport",
      .enabled(if: ProcessInfo.processInfo.environment["RELAY_HTTPGD_REMOTE_TAB"] != nil))
@MainActor
func httpgdRemoteNativeLiveDevice() async throws {
    let environment = ProcessInfo.processInfo.environment
    let tab = try #require(environment["RELAY_HTTPGD_REMOTE_TAB"])
    let host = try #require(environment["RELAY_HTTPGD_REMOTE_HOST"])
    let directory = try #require(environment["RELAY_HTTPGD_REMOTE_CWD"])
    let root = try #require(environment["RELAY_HTTPGD_REMOTE_ROOT"])
    let fixture = try HttpgdInstalledWorkspaceRPC(tab: tab, host: host, directory: directory)
    let session = try JSONDecoder().decode(RWorkspaceSession.self, from: await fixture.file(root + "/session.json"))
    let descriptor = try RHttpgdDescriptor.decode(await fixture.file(root + "/httpgd.json"))
    try descriptor.validate(session: session, root: root)
    let bridge = try await RHttpgdRelayBridge.open(profile: .sshConfigHost(host), remotePort: descriptor.port,
                                                  directory: root, rpc: { try await fixture.request($0) })
    print("REMOTE_R_NATIVE_CAPACITY: \(bridge.connectionLimit)")
    defer { print("REMOTE_R_BRIDGE_DIAGNOSTIC: running=\(bridge.isRunning), \(bridge.diagnostic)"); bridge.close() }
    let wrong = RHttpgdClient(endpoint: bridge.endpoint, token: String(repeating: "00", count: 32))
    await #expect(throws: RHttpgdError.unauthorized) { try await wrong.state() }
    wrong.invalidate()
    let client = RHttpgdClient(endpoint: bridge.endpoint, token: descriptor.token)
    let connection = RHttpgdConnection()
    connection.watchesWhileInactive = true
    defer { connection.disconnect(); client.invalidate() }
    do {
    let direct = try await client.plots(limit: 20)
    print("REMOTE_R_DIRECT_LISTING_COUNT: \(direct.ids.count)")
    try await connection.attach(api: client, label: "real remote R via installed native transport")
    print("REMOTE_R_CONNECTION_DIAGNOSTIC: \(connection.phase), \(connection.status)")
    let initial = connection.plotIDs.count
    try #require(initial >= 2 && connection.selectedID == connection.plotIDs.last)
    connection.setViewport(size: CGSize(width: 320, height: 240), scale: 2)
    for _ in 0..<200 where connection.renderedKey?.width != 640 || connection.rendering { try await Task.sleep(for: .milliseconds(50)) }
    let image = try #require(connection.imageBytes)
    let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    try #require(properties[kCGImagePropertyPixelWidth] as? Int == 640)
    try #require(properties[kCGImagePropertyPixelHeight] as? Int == 480)
    connection.setViewport(size: CGSize(width: 500, height: 200), scale: 1)
    for _ in 0..<200 where connection.renderedKey?.width != 500 || connection.rendering { try await Task.sleep(for: .milliseconds(50)) }
    let resized = try #require(connection.imageBytes)
    let source2 = try #require(CGImageSourceCreateWithData(resized as CFData, nil))
    let properties2 = try #require(CGImageSourceCopyPropertiesAtIndex(source2, 0, nil) as? [CFString: Any])
    try #require(properties2[kCGImagePropertyPixelWidth] as? Int == 500)
    try #require(properties2[kCGImagePropertyPixelHeight] as? Int == 200)
    let upid = connection.deviceState?.upid
    _ = try await fixture.operation(["operation": "file_write", "job_id": "httpgd-trigger-" + UUID().uuidString.lowercased(),
                                     "path": root + "/new-plot", "version": "missing", "data": ""])
    for _ in 0..<240 where connection.plotIDs.count < initial + 1 { try await Task.sleep(for: .milliseconds(50)) }
    try #require(connection.plotIDs.count == initial + 1 && connection.followsNewest && connection.socketLive)
    try #require(connection.deviceState?.upid != upid && connection.selectedID == connection.plotIDs.last)
    connection.selectPrevious()
    for _ in 0..<200 where connection.renderedKey?.id != connection.selectedID || connection.rendering { try await Task.sleep(for: .milliseconds(50)) }
    try #require(connection.renderedKey?.id == connection.selectedID && !connection.followsNewest)
    connection.selectNewest()
    let removingID = connection.selectedID ?? "nil"
    print("REMOTE_R_REMOVAL_BEFORE: owned=\(bridge.connectionCount), rejected=\(bridge.rejectedConnectionCount), rendering=\(connection.rendering)")
    await connection.removeSelected()
    print("REMOTE_R_REMOVAL_STATUS: id=\(removingID), status=\(connection.status), stateHsize=\(connection.deviceState?.hsize ?? -1), viewCount=\(connection.plotIDs.count), owned=\(bridge.connectionCount), rejected=\(bridge.rejectedConnectionCount), native=\(bridge.diagnostic)")
    let removedListing = try await client.plots(limit: 20)
    print("REMOTE_R_REMOVAL_DIAGNOSTIC: id=\(removingID), status=\(connection.status), stateHsize=\(connection.deviceState?.hsize ?? -1), viewCount=\(connection.plotIDs.count), serverIDs=\(removedListing.ids), native=\(bridge.diagnostic)")
    try #require(connection.plotIDs.count == initial)
    try #require(bridge.rejectedConnectionCount == 0)
    try #require(bridge.connectionCount <= bridge.connectionLimit)
    try #require(!connection.status.contains(descriptor.token))
    connection.disconnect()
    try #require(connection.phase == .idle && connection.imageBytes == nil && !connection.socketLive)
    await bridge.closeAndWait()
    try #require(!bridge.isRunning)
    print("REMOTE_R_NATIVE_APP_ACCEPTANCE: session identity, token guard, resize, history, notification, removal, teardown verified")
    } catch {
        connection.disconnect()
        await bridge.closeAndWait()
        throw error
    }
}


private actor HttpgdLateFINFixture {
    nonisolated let writeStarted: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Data, Never>?
    private let scope = String(repeating: "a", count: 32)
    init() {
        let pair = AsyncStream<Void>.makeStream()
        writeStarted = pair.stream; started = pair.continuation
    }
    func request(_ data: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operation = request["operation"] as? String
        if operation == "loopback_write" {
            return await withCheckedContinuation { pending = $0; started.yield(()) }
        }
        var result: [String: Any] = ["scope_id": scope, "proxy_id": request["proxy_id"] ?? "", "state": "open"]
        if operation == "loopback_caps" { result["state"] = "ready" }
        if operation == "loopback_read" { result["data"] = ""; result["next_offset"] = 0; result["eof"] = true }
        if operation == "loopback_close" { result["state"] = "closed" }
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }
    func finishWrite() {
        let response = Data(#"{"error":"loopback stream unavailable; do not replay input"}"#.utf8)
        pending?.resume(returning: response); pending = nil
    }
}

@Test("Late local FIN after upstream EOF does not fail or replay the retired stream")
func httpgdNativeLateFINAfterEOF() async throws {
    let fixture = HttpgdLateFINFixture()
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "/captured/root", port: 60347,
                                    rpc: { try await fixture.request($0) })
    try await stream.start()
    let write = Task { try await stream.write(Data(), closeInput: true) }
    var started = fixture.writeStarted.makeAsyncIterator()
    _ = await started.next()
    let (data, ended) = try await stream.read()
    #expect(data.isEmpty && ended)
    await fixture.finishWrite()
    try await write.value
    await stream.close()
}


private actor HttpgdCloseReceiptFixture {
    nonisolated let closeStarted: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Data, Never>?
    private var cancelledRequests: [Bool] = []
    private let scope = String(repeating: "b", count: 32)
    init() {
        let pair = AsyncStream<Void>.makeStream()
        closeStarted = pair.stream; started = pair.continuation
    }
    func request(_ data: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operation = request["operation"] as? String
        if operation == "loopback_close" {
            cancelledRequests.append(Task.isCancelled)
            return await withCheckedContinuation { pending = $0; started.yield(()) }
        }
        let result: [String: Any] = ["scope_id": scope, "proxy_id": request["proxy_id"] ?? "",
                                    "state": operation == "loopback_caps" ? "ready" : "open"]
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }
    func finishClose() {
        pending?.resume(returning: Data(#"{"result":{"state":"closed"}}"#.utf8)); pending = nil
    }
    func observedCancellation() -> [Bool] { cancelledRequests }
}

@Test("Cancelled pipe closure submits one independent close RPC and awaits its receipt")
@MainActor
func httpgdNativeCancelledCloseReceipt() async throws {
    let fixture = HttpgdCloseReceiptFixture()
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "/captured/root", port: 60347,
                                    rpc: { try await fixture.request($0) })
    try await stream.start()
    let first = Task { await stream.close() }
    first.cancel() // MainActor task has not started yet.
    var started = fixture.closeStarted.makeAsyncIterator()
    _ = await started.next()
    let second = Task { await stream.close() }
    await fixture.finishClose()
    await first.value; await second.value
    #expect(await fixture.observedCancellation() == [false])
}


private actor HttpgdCoalescedHistoryFixture: RHttpgdAPI {
    nonisolated let oldListingStarted: AsyncStream<Void>
    nonisolated let freshListingStarted: AsyncStream<Void>
    nonisolated let removalStarted: AsyncStream<Void>
    private let oldSignal: AsyncStream<Void>.Continuation
    private let freshSignal: AsyncStream<Void>.Continuation
    private let removalSignal: AsyncStream<Void>.Continuation
    private var oldWait: CheckedContinuation<Void, Never>?
    private var freshWait: CheckedContinuation<Void, Never>?
    private var ids = ["1", "2"]
    private var calls = 0
    init() {
        let old = AsyncStream<Void>.makeStream(), fresh = AsyncStream<Void>.makeStream(), removed = AsyncStream<Void>.makeStream()
        oldListingStarted = old.stream; oldSignal = old.continuation
        freshListingStarted = fresh.stream; freshSignal = fresh.continuation
        removalStarted = removed.stream; removalSignal = removed.continuation
    }
    func state() async throws -> RHttpgdState { RHttpgdState(upid: calls, hsize: ids.count, active: true) }
    func plots(limit: Int) async throws -> RHttpgdPlotList {
        calls += 1
        let listing = RHttpgdPlotList(state: RHttpgdState(upid: calls, hsize: ids.count, active: true), ids: ids)
        if calls == 2 { await withCheckedContinuation { oldWait = $0; oldSignal.yield(()) } }
        // Call 3 is the required pre-removal identity check. Hold only the
        // authoritative listing after removal and the old in-flight refresh.
        if calls == 4 { await withCheckedContinuation { freshWait = $0; freshSignal.yield(()) } }
        return listing
    }
    func render(id: String, width: Int, height: Int, zoom: Double) async throws -> Data { Data() }
    func remove(id: String) async throws -> RHttpgdState {
        ids.removeAll { $0 == id }; removalSignal.yield(())
        return RHttpgdState(upid: calls + 1, hsize: ids.count, active: true)
    }
    func clear() async throws -> RHttpgdState { ids = []; return RHttpgdState(upid: calls + 1, hsize: 0, active: true) }
    nonisolated func makeWebSocket() -> URLSessionWebSocketTask? { nil }
    nonisolated func invalidate() {}
    func releaseOld() { oldWait?.resume(); oldWait = nil }
    func releaseFresh() { freshWait?.resume(); freshWait = nil }
}

@Test("Plot removal awaits a coalesced authoritative history refresh")
@MainActor
func httpgdCoalescedRefreshWaitsForRemoval() async throws {
    let fixture = HttpgdCoalescedHistoryFixture()
    let connection = RHttpgdConnection()
    defer { connection.disconnect() }
    try await connection.attach(api: fixture, label: "coalesced history fixture")
    var oldStarted = fixture.oldListingStarted.makeAsyncIterator()
    var freshStarted = fixture.freshListingStarted.makeAsyncIterator()
    var removed = fixture.removalStarted.makeAsyncIterator()
    let refresh = Task { await connection.resync() }
    _ = await oldStarted.next()
    var removalFinished = false
    let removal = Task { await connection.removeSelected(); removalFinished = true }
    _ = await removed.next()
    await Task.yield()
    await fixture.releaseOld()
    _ = await freshStarted.next()
    // The new listing is held deliberately: removal cannot return yet.
    try await Task.sleep(for: .milliseconds(50))
    #expect(!removalFinished)
    await fixture.releaseFresh()
    await refresh.value; await removal.value
    #expect(removalFinished && connection.plotIDs == ["1"])
}
