import AppKit
import SwiftUI

/// Recent places: the panes visited last, across tabs and workspaces, newest
/// first. Opening or browsing the list records no visit and acknowledges
/// nothing; only the final jump selects a pane (through `revealPane`).
enum RelayRecentPlaces {
    static let limit = 9

    struct Place: Identifiable, Equatable {
        let id: UUID
        let tabID: UUID
        let title: String
        /// "Workspace › Tab".
        let location: String
        let host: String
        let status: String
        let statusRole: RelayTheme.StatusRole
        let symbol: String
        let needsAttention: Bool
        let isCurrent: Bool

        var accessibilityLabel: String {
            [title, location, host, status, needsAttention ? "needs attention" : nil, isCurrent ? "current pane" : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// The active pane first, then other live panes by their last visit.
    /// Panes closed or detached since their visit are not listed.
    @MainActor static func places(for workspace: WorkspaceModel) -> [Place] {
        var order: [UUID] = []
        if let active = workspace.activePaneID { order.append(active) }
        for visit in workspace.paneVisits.visits.sorted(by: { $0.lastVisitedAt > $1.lastVisitedAt })
        where !order.contains(visit.paneID) {
            order.append(visit.paneID)
        }
        var places: [Place] = []
        for id in order {
            guard places.count < limit, let place = place(id, in: workspace) else { continue }
            places.append(place)
        }
        return places
    }

    @MainActor private static func place(_ id: UUID, in workspace: WorkspaceModel) -> Place? {
        guard let pane = workspace.panes[id], let tabID = workspace.tabID(containingPane: id),
              let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return nil }
        let owner = workspace.workspaceID(forTab: tabID).flatMap { workspace.ownership.workspace($0)?.name } ?? "Workspace"
        let tabName = tab.name.isEmpty ? "Untitled tab" : tab.name
        let fact = RelayWorkOverviewIndex.paneFact(pane, tabID: tabID, workspaceName: owner, tabName: tabName,
                                                   hidden: tab.hiddenStackPaneIDs.contains(id))
        return Place(id: id, tabID: tabID, title: pane.displayName, location: "\(owner) › \(tabName)",
                     host: pane.profile.host, status: RelayQuickNavigate.paneStatusText(pane, fact: fact),
                     statusRole: RelayQuickNavigate.paneRole(contentKind: pane.contentKind, status: fact.status),
                     symbol: RelayQuickNavigate.paneSymbol(contentKind: pane.contentKind, kind: pane.kind),
                     needsAttention: fact.status.needsUser, isCurrent: id == workspace.activePaneID)
    }
}

/// Keys while the switcher is held open.
enum RelayRecentPlacesKey: Equatable {
    case next, previous, digit(Int), confirm, cancel, released, other
}

/// Hold the binding's modifier (⌃ by default) and tap its key (Tab) to move
/// down the list, ⇧ to move up; release the modifier to go, Esc to stay.
/// A quick tap goes straight to the previous pane, before the panel shows.
@MainActor final class RelayRecentPlacesSwitcher: ObservableObject {
    @Published private(set) var places: [RelayRecentPlaces.Place] = []
    @Published private(set) var selection = 0
    /// Shown only once the modifier has been held a moment.
    @Published private(set) var isVisible = false
    private(set) var isActive = false
    private weak var workspace: WorkspaceModel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var revealTask: Task<Void, Never>?
    private var trigger = RelayCommand.recentPlaces.defaultBinding
    static let revealDelay: Duration = .milliseconds(150)

    func install(workspace: WorkspaceModel) {
        self.workspace = workspace
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil; resignObserver = nil
        cancel()
    }

    /// True when the event was the switcher's and must not reach the pane.
    private func handle(_ event: NSEvent) -> Bool {
        if !isActive {
            guard event.type == .keyDown, !event.isARepeat,
                  (event.window ?? NSApp.keyWindow)?.identifier == .relayWorkspaceWindow,
                  let pressed = RelayKeyBinding(event: event) else { return false }
            let configured = RelayKeyBindingStorage.binding(for: .recentPlaces, overrides: RelayKeyBindingStorage.load())
            let forward = pressed == configured
            let backward = !configured.shift && pressed == RelayKeyBinding(configured.key, command: configured.command,
                control: configured.control, option: configured.option, shift: true)
            guard forward || backward, let workspace else { return false }
            trigger = configured
            return begin(places: RelayRecentPlaces.places(for: workspace), backward: backward)
        }
        handle(Self.key(for: event, trigger: trigger))
        // Every key press is the switcher's while it is open, so nothing
        // typed with the modifier held reaches the terminal; modifier
        // changes always pass through.
        return event.type == .keyDown
    }

    static func key(for event: NSEvent, trigger: RelayKeyBinding) -> RelayRecentPlacesKey {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            let held = (!trigger.control || flags.contains(.control)) && (!trigger.option || flags.contains(.option)) &&
                (!trigger.command || flags.contains(.command))
            return held ? .other : .released
        }
        switch event.keyCode {
        case 53: return .cancel
        case 36, 76: return .confirm
        case 125: return .next
        case 126: return .previous
        default: break
        }
        if RelayKeyBinding(event: event)?.key == trigger.key { return flags.contains(.shift) ? .previous : .next }
        if let digit = event.characters(byApplyingModifiers: []).flatMap(Int.init), (1...9).contains(digit) {
            return .digit(digit)
        }
        return .other
    }

    /// Opens on the previous place (the next one down), or the last when
    /// started backwards. Nothing to switch to leaves the key to the pane.
    @discardableResult
    func begin(places: [RelayRecentPlaces.Place], backward: Bool = false) -> Bool {
        guard places.count > 1 else { return false }
        self.places = places
        selection = backward ? places.count - 1 : 1
        isActive = true
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDelay)
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.isVisible = true
        }
        return true
    }

    /// True when the key was consumed. Every key is while the switcher is open.
    @discardableResult
    func handle(_ key: RelayRecentPlacesKey) -> Bool {
        guard isActive else { return false }
        switch key {
        case .next: selection = (selection + 1) % places.count
        case .previous: selection = (selection - 1 + places.count) % places.count
        case .digit(let number):
            guard number <= places.count else { return true }
            selection = number - 1
            commit()
        case .confirm, .released: commit()
        case .cancel: cancel()
        case .other: break
        }
        return true
    }

    /// Goes to the selected place if it still exists; a stale row never jumps.
    func commit() {
        guard isActive else { return }
        let place = places.indices.contains(selection) ? places[selection] : nil
        cancel()
        guard let place, let workspace, workspace.panes[place.id] != nil, !place.isCurrent else { return }
        workspace.revealPane(place.id, origin: .user)
    }

    func select(_ index: Int) {
        guard isActive, places.indices.contains(index) else { return }
        selection = index
        commit()
    }

    func cancel() {
        revealTask?.cancel()
        revealTask = nil
        isActive = false
        isVisible = false
    }

    /// Opens the panel at once, for snapshot tests.
    func showForTesting(places: [RelayRecentPlaces.Place], selection: Int) {
        self.places = places
        self.selection = selection
        isActive = true
        isVisible = true
    }
}

/// The switcher's panel, on the shared viewer bar.
struct RelayRecentPlacesPanel: View {
    @ObservedObject var switcher: RelayRecentPlacesSwitcher

    var body: some View {
        RelayViewerLayout {
            RelayViewerBar(symbol: "clock.arrow.circlepath", title: "Recent places",
                           detail: "Tab next · Shift-Tab back · release to go · Esc stays") { EmptyView() }
        } content: {
            VStack(spacing: RelayTheme.spacing(2)) {
                ForEach(Array(switcher.places.enumerated()), id: \.element.id) { index, place in
                    row(place, index: index, selected: index == switcher.selection)
                }
            }
            .padding(RelayTheme.spacing(6))
        }
        .frame(width: 600)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
            .stroke(RelayTheme.line.opacity(0.85)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent places")
        .accessibilityIdentifier("relay.recent-places")
    }

    private func row(_ place: RelayRecentPlaces.Place, index: Int, selected: Bool) -> some View {
        Button { switcher.select(index) } label: {
            HStack(spacing: RelayTheme.spacing(RelayViewerMetrics.barSpacing)) {
                Text("\(index + 1)")
                    .font(RelayViewerMetrics.identifier).foregroundStyle(RelayTheme.textFaint)
                    .frame(width: 12)
                Image(systemName: place.symbol)
                    .font(RelayViewerMetrics.meta).foregroundStyle(place.statusRole.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                    HStack(spacing: RelayTheme.spacing(5)) {
                        Text(place.title).font(RelayViewerMetrics.title).foregroundStyle(RelayTheme.text).lineLimit(1)
                        if place.isCurrent {
                            Text("current").font(RelayViewerMetrics.identifier).foregroundStyle(RelayTheme.textFaint)
                        }
                    }
                    HStack(spacing: RelayTheme.spacing(6)) {
                        Text(place.location).lineLimit(1).truncationMode(.middle)
                        Text(place.host).font(RelayViewerMetrics.identifier).lineLimit(1)
                    }
                    .font(RelayViewerMetrics.meta).foregroundStyle(RelayTheme.textFaint)
                }
                Spacer(minLength: RelayViewerMetrics.barSpacing)
                Text(place.status).font(RelayViewerMetrics.meta).foregroundStyle(place.statusRole.color).lineLimit(1)
                Circle().fill(place.needsAttention ? RelayTheme.accent : Color.clear).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RelayTheme.spacing(8)).padding(.vertical, RelayTheme.spacing(5))
            .background(selected ? RelayTheme.wash : Color.clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
            .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6))
                .strokeBorder(selected ? RelayTheme.accent.opacity(0.6) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
