import AppKit
import Foundation
import ImageIO

/// Live plot view state for one validated httpgd device. Owns the private Relay-native
/// bridge, the authenticated client and the change socket; every read goes
/// through the token-guarded HTTP API, and socket messages only trigger a
/// resync. Renders are latest-only and bounded; hiding the view tears down
/// everything; a visible presentation keeps its change socket while the user
/// works in another app. Fully occluded inactive windows suspend watching.
@MainActor
final class RHttpgdConnection: ObservableObject {
    private var selectionPersistenceKey: String?
    enum Phase: Equatable {
        case idle, connecting, connected, failed(String)
    }

    struct RenderKey: Equatable, Sendable {
        let id: String
        let width: Int
        let height: Int
        let zoom: Double
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "httpgd not connected"
    @Published private(set) var plotIDs: [String] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var image: NSImage?
    @Published private(set) var imageBytes: Data?
    @Published private(set) var deviceState: RHttpgdState?
    @Published private(set) var rendering = false
    @Published private(set) var socketLive = false
    /// Off while the user browses history; newest plots re-enable it.
    @Published private(set) var followsNewest = true
    /// New plot identities received while browsing history; repeated listings do not add counts.
    @Published private(set) var unseenPlotIDs: Set<String> = []
    var unseenPlotCount: Int { unseenPlotIDs.count }
    var hasStaleImage: Bool { image != nil && phase != .connected }

    private(set) var renderCount = 0
    private(set) var renderedKey: RenderKey?
    var resizeDebounce: Duration = .milliseconds(150)
    var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30)]

    private var api: (any RHttpgdAPI)?
    private var bridge: RHttpgdRelayBridge?
    private var generation = 0
    private var viewport = CGSize(width: 720, height: 576)
    private var scale = 1.0
    private var renderRequested = false
    private var renderTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var resyncAgain = false
    private var watchTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let observers = ActivationObservers()

    /// Notification tokens are removed when the connection is released.
    private final class ActivationObservers: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }

    init() {
        let center = NotificationCenter.default
        observers.tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileWatching() }
        })
        observers.tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileWatching() }
        })
        observers.tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileWatching() }
        })
    }

    deinit {
        bridge?.close()
        api?.invalidate()
    }

    var isConnected: Bool { phase == .connected }
    var selectedIndex: Int? { selectedID.flatMap { plotIDs.firstIndex(of: $0) } }

    /// Reads and validates the descriptor, opens the native bridge for SSH
    /// profiles, proves the token against `/state`, then syncs history.
    func connect(scope: PluginScope, relativeRoot: String, session: RWorkspaceSession) async {
        disconnect()
        selectionPersistenceKey = "relay.plot.selection." + session.session_id
        if let record = UserDefaults.standard.dictionary(forKey: selectionPersistenceKey!) {
            selectedID = record["id"] as? String
            followsNewest = record["follow"] as? Bool ?? true
        }
        generation += 1
        let current = generation
        phase = .connecting
        status = "Reading httpgd descriptor…"
        do {
            let response = try await PluginOperationRunner.run(.artifacts, scope: scope, path: relativeRoot + "/httpgd.json")
            guard generation == current else { return }
            guard let bytes = response.verifiedBytes else { throw PluginError.invalid("httpgd.json is missing; start httpgd from the R console") }
            let descriptor = try RHttpgdDescriptor.decode(bytes)
            let root = (response.root as NSString).appendingPathComponent(relativeRoot)
            try descriptor.validate(session: session, root: root)
            let endpoint: RHttpgdEndpoint
            if scope.profile.kind == .ssh {
                status = "Opening native plot transport…"
                let opened = try await RHttpgdRelayBridge.open(profile: scope.profile, remotePort: descriptor.port, directory: root)
                guard generation == current else { opened.close(); return }
                bridge = opened
                endpoint = opened.endpoint
            } else {
                endpoint = RHttpgdEndpoint(port: UInt16(descriptor.port))
            }
            let client = RHttpgdClient(endpoint: endpoint, token: descriptor.token)
            try await attach(api: client, label: "\(descriptor) via 127.0.0.1:\(endpoint.port)", generation: current)
        } catch is CancellationError {
            guard generation == current else { return }
            disconnect()
        } catch {
            guard generation == current else { return }
            fail(error.localizedDescription)
        }
    }

    /// Shared with tests: binds an API without a descriptor or bridge.
    func attach(api: any RHttpgdAPI, label: String, generation current: Int? = nil) async throws {
        let current = current ?? { disconnect(); return generation }()
        self.api = api
        status = "Verifying token…"
        let state = try await api.state()
        guard generation == current else { api.invalidate(); return }
        deviceState = state
        phase = .connected
        status = label
        await resync()
        guard generation == current else { return }
        startWatching()
    }

    func disconnect() {
        tearDown(retainingImage: false)
    }

    /// Transport failure retains a visibly stale bitmap; session reset clears it.
    private func tearDown(retainingImage: Bool) {
        generation += 1
        debounceTask?.cancel(); debounceTask = nil
        renderTask?.cancel(); renderTask = nil
        resyncTask?.cancel(); resyncTask = nil
        stopSocket()
        api?.invalidate(); api = nil
        bridge?.close(); bridge = nil
        plotIDs = []; selectedID = nil; deviceState = nil
        if !retainingImage { image = nil; imageBytes = nil; renderedKey = nil }
        renderRequested = false; resyncAgain = false; rendering = false
        followsNewest = true
        unseenPlotIDs = []
        if phase != .idle { phase = .idle; status = "httpgd disconnected" }
    }

    private func fail(_ message: String) {
        tearDown(retainingImage: true)
        phase = .failed(message)
        status = message
    }

    // MARK: History

    func setViewport(size: CGSize, scale: CGFloat) {
        let clamped = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        guard clamped != viewport || Double(scale) != self.scale else { return }
        viewport = clamped
        self.scale = Double(scale)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.resizeDebounce)
            guard !Task.isCancelled else { return }
            self.requestRender()
        }
    }

    func select(id: String) {
        guard plotIDs.contains(id) else { return }
        selectedID = id
        followsNewest = id == plotIDs.last
        if followsNewest { unseenPlotIDs = [] }
        else { unseenPlotIDs.remove(id) }
        if let key = selectionPersistenceKey {
            UserDefaults.standard.set(["id": id, "follow": followsNewest], forKey: key)
        }
        requestRender()
    }

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        select(id: plotIDs[index - 1])
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < plotIDs.count else { return }
        select(id: plotIDs[index + 1])
    }

    func selectNewest() {
        guard let last = plotIDs.last else { return }
        select(id: last)
    }

    /// Re-lists immediately before removing: httpgd removes the newest plot
    /// when given an unknown id, so a stale id must never reach it.
    func removeSelected() async {
        guard let api, let id = selectedID else { return }
        let current = generation
        do {
            let fresh = try await api.plots(limit: RHttpgdLimits.historyEntries)
            guard generation == current else { return }
            guard fresh.ids.contains(id) else { status = RHttpgdError.unknownPlot.localizedDescription; await resync(); return }
            let state = try await api.remove(id: id)
            guard generation == current else { return }
            deviceState = state
            await resync()
        } catch { report(error) }
    }

    func clearHistory() async {
        guard let api else { return }
        let current = generation
        do {
            let state = try await api.clear()
            guard generation == current else { return }
            deviceState = state
            await resync()
        } catch { report(error) }
    }

    /// Authoritative refresh through the token-guarded API; coalesced.
    func resync() async {
        if let running = resyncTask { resyncAgain = true; await running.value; return }
        let current = generation
        let task = Task<Void, Never> { [weak self] in
            guard let self, self.generation == current, !Task.isCancelled else { return }
            // All waiters await the whole coalesced refresh, including changes
            // admitted while an earlier listing was in flight.
            defer { if self.generation == current { self.resyncTask = nil } }
            repeat {
                self.resyncAgain = false
                await self.performResync()
            } while self.generation == current && self.resyncAgain && !Task.isCancelled
        }
        resyncTask = task
        await task.value
    }

    private func performResync() async {
        guard let api else { return }
        let current = generation
        do {
            let listing = try await api.plots(limit: RHttpgdLimits.historyEntries)
            guard generation == current else { return }
            deviceState = listing.state
            let previous = selectedID
            let arrived = Set(listing.ids).subtracting(plotIDs)
            plotIDs = listing.ids
            if followsNewest || previous.map({ !listing.ids.contains($0) }) ?? true {
                selectedID = listing.ids.last
                followsNewest = true
            }
            if followsNewest {
                unseenPlotIDs = []
            } else {
                unseenPlotIDs.formUnion(arrived)
                unseenPlotIDs.formIntersection(listing.ids)
                if let selectedID { unseenPlotIDs.remove(selectedID) }
            }
            if let key = selectionPersistenceKey, let id = selectedID {
                UserDefaults.standard.set(["id": id, "follow": followsNewest], forKey: key)
            }
            if listing.ids.isEmpty {
                image = nil; imageBytes = nil; renderedKey = nil
                status = "httpgd connected · no plots yet"
            } else {
                status = "httpgd connected · \(listing.ids.count) plot\(listing.ids.count == 1 ? "" : "s")"
                requestRender()
            }
        } catch {
            guard generation == current else { return }
            report(error)
        }
    }

    // MARK: Rendering

    private var currentKey: RenderKey? {
        guard let selectedID else { return nil }
        let zoom = min(max(scale, 1), 3)
        let width = Int((viewport.width * zoom).rounded())
        let height = Int((viewport.height * zoom).rounded())
        return RenderKey(id: selectedID,
                         width: min(max(width, RHttpgdLimits.minimumDimension), RHttpgdLimits.maximumDimension),
                         height: min(max(height, RHttpgdLimits.minimumDimension), RHttpgdLimits.maximumDimension),
                         zoom: zoom)
    }

    /// One render in flight; later requests collapse into a single follow-up
    /// using whatever selection and viewport are current when it starts.
    func requestRender() {
        guard api != nil else { return }
        renderRequested = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.renderTask = nil; self.rendering = false }
            while self.renderRequested, !Task.isCancelled {
                self.renderRequested = false
                await self.renderCurrent()
            }
        }
    }

    private func renderCurrent() async {
        guard let api, let key = currentKey else { return }
        if key == renderedKey, image != nil { return }
        let current = generation
        rendering = true
        do {
            let bytes = try await api.render(id: key.id, width: key.width, height: key.height, zoom: key.zoom)
            guard generation == current, !Task.isCancelled else { return }
            renderCount += 1
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: RHttpgdLimits.maximumDimension,
                  ] as CFDictionary) else { throw RHttpgdError.invalidResponse("undecodable PNG") }
            image = NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / key.zoom, height: Double(cg.height) / key.zoom))
            imageBytes = bytes
            renderedKey = key
        } catch is CancellationError {
        } catch {
            guard generation == current else { return }
            if case RHttpgdError.unknownPlot = error { await resync() } else { report(error) }
        }
    }

    // MARK: Change notifications

    /// Tests run without an activated NSApplication.
    var watchesWhileInactive = false
    // Presentation lifetime owns the connection; application activation alone
    // must not freeze visible plots while the user works in an agent app.
    var applicationIsActive: () -> Bool = { NSApp?.isActive ?? false }
    var presentationIsVisible: () -> Bool = {
        NSApp?.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) ?? false
    }
    private var shouldWatch: Bool { watchesWhileInactive || applicationIsActive() || presentationIsVisible() }

    private func startWatching() {
        guard watchTask == nil, api != nil, shouldWatch else { return }
        let current = generation
        watchTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.generation == current, let api = self.api else { return }
                if let bridge = self.bridge, !bridge.isRunning {
                    self.fail("The native plot transport ended: \(bridge.diagnostic)")
                    return
                }
                guard let socket = api.makeWebSocket() else { self.watchTask = nil; return }
                self.socket = socket
                socket.resume()
                let outcome = await self.receiveLoop(socket)
                guard self.generation == current, !Task.isCancelled else { return }
                self.socketLive = false
                if outcome { failures = 0 }
                guard failures < self.reconnectDelays.count else {
                    self.fail("Lost the httpgd connection after repeated retries. Reconnect when R is available.")
                    return
                }
                try? await Task.sleep(for: self.reconnectDelays[failures])
                failures += 1
                guard !Task.isCancelled, self.generation == current else { return }
                await self.resync()
            }
        }
    }

    /// Returns true when at least one message arrived before the socket dropped.
    private func receiveLoop(_ socket: URLSessionWebSocketTask) async -> Bool {
        var received = false
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                received = true
                socketLive = true
                switch message {
                case .string(let text): guard text.utf8.count <= 4096 else { continue }
                case .data(let data): guard data.count <= 4096 else { continue }
                @unknown default: continue
                }
                // Hint only: the unauthenticated socket echoes anything a peer sends.
                await resync()
            }
        } catch {}
        return received
    }

    private func stopSocket() {
        watchTask?.cancel(); watchTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketLive = false
    }

    func reconcileWatching() {
        guard phase == .connected else { return }
        guard shouldWatch else { stopSocket(); return }
        guard watchTask == nil else { return }
        startWatching()
        // Changes accumulated while fully occluded must be listed even if the
        // device emits no new notification after the window becomes visible.
        Task { [weak self] in await self?.resync() }
    }

    private func report(_ error: Error) {
        if case RHttpgdError.unauthorized = error { fail(error.localizedDescription); return }
        if case RHttpgdError.unreachable = error, let bridge {
            if !bridge.isRunning {
                fail("The native plot transport ended: \(bridge.diagnostic)"); return
            }
            if !bridge.diagnostic.isEmpty {
                status = "Native plot stream failed: " + bridge.diagnostic; return
            }
        }
        status = error.localizedDescription
    }
}
