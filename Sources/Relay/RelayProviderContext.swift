import AppKit
import SwiftUI

struct RelayProviderContext: Equatable, Sendable {
    let binding: RelayAgentConversationBinding
    let usedTokens: Int?
    let limitTokens: Int?

    private struct Response: Decodable {
        struct Binding: Decodable {
            let paneId: String
            let provider: String
            let processId: Int
            let processStart: String
            let sessionId: String
            let sourceIdentity: String
        }
        struct Usage: Decodable {
            let usedTokens: Int?
            let limitTokens: Int?
        }
        let version: Int
        let binding: Binding?
        let contextUsage: Usage?
    }

    static func decode(_ data: Data, hostID: String, paneID: UUID, provider: AgentKind) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        guard response.version == 1, let source = response.binding,
              source.paneId == paneID.uuidString.lowercased(), source.provider == provider.rawValue,
              !source.sourceIdentity.isEmpty, source.sourceIdentity.utf8.count <= 80 else { return nil }
        let binding = RelayAgentConversationBinding(hostID: hostID, paneID: paneID, provider: source.provider,
            processID: source.processId, processStart: source.processStart, sessionID: source.sessionId,
            sourceIdentity: source.sourceIdentity)
        guard binding.isValid else { return nil }
        return .init(binding: binding, usedTokens: count(response.contextUsage?.usedTokens, minimum: 0),
                     limitTokens: count(response.contextUsage?.limitTokens, minimum: 1))
    }

    private static func count(_ value: Int?, minimum: Int) -> Int? {
        guard let value, value >= minimum, value < 9_007_199_254_740_992 else { return nil }
        return value
    }

    func matches(_ other: RelayAgentConversationBinding) -> Bool {
        binding == other
    }

    var label: String {
        guard let usedTokens, let limitTokens else { return Self.unknown }
        let occupancy = (Double(usedTokens) / Double(limitTokens)).formatted(.percent.precision(.fractionLength(0...1)))
        return "Context \(usedTokens.formatted()) / \(limitTokens.formatted()) · \(occupancy)"
    }

    static let unknown = "Context unknown"
}

/// One read loop per pane. A replacement waits for the old read to unwind
/// even when its window closes while another presentation is taking over.
struct RelayProviderContextDemand<Key: Equatable> {
    enum Change: Equatable {
        case none, start(Key), cancel
    }

    private var consumers: [UUID: Key] = [:]
    private var running: Key?
    private var cancelling = false

    mutating func set(_ consumer: UUID, key: Key?) { consumers[consumer] = key }

    func includes(_ key: Key?) -> Bool {
        guard let key else { return false }
        return consumers.values.contains(key)
    }

    mutating func reconcile(_ key: Key?) -> Change {
        guard !cancelling else { return .none }
        let wanted = includes(key) ? key : nil
        guard running != wanted else { return .none }
        if running != nil {
            cancelling = true
            return .cancel
        }
        guard let wanted else { return .none }
        running = wanted
        return .start(wanted)
    }

    mutating func didStop() {
        running = nil
        cancelling = false
    }
}

private struct RelayProviderContextPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var providerContextPresented: Bool {
        get { self[RelayProviderContextPresentedKey.self] }
        set { self[RelayProviderContextPresentedKey.self] = newValue }
    }
}

struct RelayProviderContextWindowReader: NSViewRepresentable {
    let pane: PaneModel
    let key: PaneModel.ProviderContextKey

    static func presentsContent(size: CGSize, presented: Bool, covered: Bool) -> Bool {
        presented && !covered && size.width > 0 && size.height > 0
    }

    @MainActor final class Coordinator {
        private let consumer = UUID()
        private weak var pane: PaneModel?
        private weak var registeredPane: PaneModel?
        private var key: PaneModel.ProviderContextKey?
        private var showing = false

        func configure(_ pane: PaneModel, key: PaneModel.ProviderContextKey) {
            guard self.pane !== pane || self.key != key else { return }
            self.pane = pane
            self.key = key
            reconcileAfterViewUpdate()
        }

        func watch(_ view: RelayWindowVisibilityView) {
            view.onChange = { [weak self] showing in self?.windowChanged(showing) }
        }

        private func windowChanged(_ showing: Bool) {
            self.showing = showing
            reconcileAfterViewUpdate()
        }

        func detach() {
            pane = nil
            key = nil
            showing = false
            reconcileAfterViewUpdate()
        }

        private func reconcileAfterViewUpdate() {
            // AppKit can report a transition inside SwiftUI's representable update.
            DispatchQueue.main.async { [self] in
                let current = self.showing ? self.pane : nil
                if self.registeredPane !== current {
                    self.registeredPane?.setProviderContextConsumer(self.consumer, key: nil)
                }
                self.registeredPane = current
                current?.setProviderContextConsumer(self.consumer, key: self.key)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RelayWindowVisibilityView {
        let view = RelayWindowVisibilityView()
        context.coordinator.watch(view)
        context.coordinator.configure(pane, key: key)
        return view
    }

    func updateNSView(_ view: RelayWindowVisibilityView, context: Context) {
        context.coordinator.configure(pane, key: key)
        view.evaluate()
    }

    static func dismantleNSView(_ view: RelayWindowVisibilityView, coordinator: Coordinator) {
        view.detach()
        coordinator.detach()
    }
}
