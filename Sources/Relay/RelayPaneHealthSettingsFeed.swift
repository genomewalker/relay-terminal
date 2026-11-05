import AppKit
import Combine
import SwiftUI

/// Cached pane-health rows for views that must not build pane facts.
///
/// `RelayPaneHealthCoordinator.snapshot()` builds every pane's facts and so
/// reads every pane's screen through libghostty's write_screen_file action.
/// The Settings window and the Performance panel's Agents section used to call
/// it from their view bodies, and SwiftUI keeps a closed or ordered-out
/// window's hierarchy alive, so those reads continued after close. Those
/// bodies now read `value` only. It is refreshed from a facts-free source,
/// and only while the hosting window shows: on becoming visible, on a
/// coordinator revision and on a slow tick for observation ageing.
@MainActor final class RelayPaneHealthFeed<Value: Equatable>: ObservableObject, RelayVisibilityGatedFeed {
    static var tickInterval: TimeInterval { 5 }

    @Published private(set) var value: Value
    private(set) var visible = false
    private var subscriptions: [AnyCancellable] = []
    private let source: () -> Value
    private let changes: () -> AnyPublisher<Void, Never>
    private let ticks: () -> AnyPublisher<Void, Never>

    /// True while a change or tick subscription is live.
    var isRefreshing: Bool { !subscriptions.isEmpty }

    /// Re-reads the window before each refresh. A missed occlusion or
    /// visibility notification (orderOut posts no willClose) then stops the
    /// feed at its next change or tick instead of refreshing a hidden window.
    var showingCheck: (() -> Bool)?

    init(initial: Value, source: @escaping () -> Value, changes: @escaping () -> AnyPublisher<Void, Never>,
         ticks: @escaping () -> AnyPublisher<Void, Never>) {
        value = initial
        self.source = source
        self.changes = changes
        self.ticks = ticks
    }

    static func live(initial: Value, _ coordinator: RelayPaneHealthCoordinator = .shared,
                     read: @escaping (RelayPaneHealthCoordinator) -> Value) -> RelayPaneHealthFeed<Value> {
        RelayPaneHealthFeed(initial: initial,
            source: { [weak coordinator] in coordinator.map(read) ?? initial },
            // @Published emits before the new value is stored; read on the
            // next main-queue turn, after the mutation completes.
            changes: { [weak coordinator] in
                coordinator?.$revision.dropFirst().map { _ in () }.receive(on: DispatchQueue.main).eraseToAnyPublisher() ??
                    Empty().eraseToAnyPublisher()
            },
            ticks: {
                Timer.publish(every: tickInterval, tolerance: 1, on: .main, in: .common).autoconnect()
                    .map { _ in () }.eraseToAnyPublisher()
            })
    }

    func setVisible(_ showing: Bool) {
        guard showing != visible else { return }
        visible = showing
        subscriptions.removeAll()
        guard showing else { return }
        refresh()
        // The refresh's showing check can hide the feed re-entrantly.
        guard visible else { return }
        changes().sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        ticks().sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
    }

    /// An action that just changed what the window shows asks for an immediate refresh (still only while visible).
    func refreshNow() { refresh() }

    private func refresh() {
        guard visible else { return }
        if let showingCheck, !showingCheck() {
            setVisible(false)
            return
        }
        let next = source()
        if next != value { value = next }
    }
}

/// What RelayWindowVisibilityView drives.
@MainActor protocol RelayVisibilityGatedFeed: AnyObject {
    func setVisible(_ showing: Bool)
    var showingCheck: (() -> Bool)? { get set }
}

/// Settings window rows.
typealias RelayPaneHealthSettingsFeed = RelayPaneHealthFeed<[RelayPaneHealthCoordinator.HostSummary]>
extension RelayPaneHealthFeed where Value == [RelayPaneHealthCoordinator.HostSummary] {
    static func settings() -> RelayPaneHealthFeed<Value> { .live(initial: []) { $0.hostSummaries() } }
}

/// Performance panel Agents rows.
typealias RelayPaneHealthOverviewFeed = RelayPaneHealthFeed<[RelayPaneHealthCoordinator.HostOverview]>
extension RelayPaneHealthFeed where Value == [RelayPaneHealthCoordinator.HostOverview] {
    static func overview() -> RelayPaneHealthFeed<Value> { .live(initial: []) { $0.hostOverviews() } }
}

/// A window shows content when the view is attached to it, it is not
/// closing, ordered in, not miniaturized and at least partly unoccluded.
/// willClose precedes the hide inside the same close call. Closing ends when
/// the hide is seen or at the next main-queue turn (`closeFinished`), so a
/// reused Settings window shows again even if its hide notification was missed.
struct RelayWindowVisibilityTracker {
    private(set) var closing = false

    mutating func willClose() { closing = true }
    mutating func closeFinished() { closing = false }

    mutating func showing(attached: Bool, isVisible: Bool, isMiniaturized: Bool, occlusionVisible: Bool) -> Bool {
        guard attached else { closing = false; return false }
        if closing, !isVisible { closing = false; return false }
        return !closing && isVisible && !isMiniaturized && occlusionVisible
    }
}

/// Reports whether the hosting window shows. orderOut posts no willClose,
/// so it is seen through the window's `isVisible` and occlusion changes.
struct RelayWindowVisibilityReader: NSViewRepresentable {
    let feed: any RelayVisibilityGatedFeed

    func makeNSView(context: Context) -> RelayWindowVisibilityView {
        let view = RelayWindowVisibilityView()
        view.drive(feed)
        return view
    }

    func updateNSView(_ view: RelayWindowVisibilityView, context: Context) { view.drive(feed) }

    static func dismantleNSView(_ view: RelayWindowVisibilityView, coordinator: ()) { view.detach() }
}

final class RelayWindowVisibilityView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private(set) var lastReported: Bool?
    private var observers: [NSObjectProtocol] = []
    private var visibleObservation: NSKeyValueObservation?
    private(set) var tracker = RelayWindowVisibilityTracker()
    /// The window server's occlusion; replaceable where no event loop runs.
    var occlusionVisible: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(window)
    }

    private func attach(_ window: NSWindow?) {
        removeObservers()
        tracker = RelayWindowVisibilityTracker()
        guard let window else { report(false); return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tracker.willClose()
                self?.evaluate()
                DispatchQueue.main.async {
                    self?.tracker.closeFinished()
                    self?.evaluate()
                }
            }
        })
        visibleObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        evaluate()
    }

    /// Reports visibility changes to `feed` and answers its showing check.
    func drive(_ feed: any RelayVisibilityGatedFeed) {
        onChange = { [weak feed] showing in feed?.setVisible(showing) }
        feed.showingCheck = { [weak self] in self?.evaluate() ?? false }
    }

    @discardableResult func evaluate() -> Bool {
        let showing = tracker.showing(attached: window != nil, isVisible: window?.isVisible ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            occlusionVisible: window.map(occlusionVisible) ?? false)
        report(showing)
        return showing
    }

    func detach() {
        removeObservers()
        report(false)
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        visibleObservation?.invalidate()
        visibleObservation = nil
    }

    private func report(_ showing: Bool) {
        guard showing != lastReported else { return }
        lastReported = showing
        onChange?(showing)
    }
}
