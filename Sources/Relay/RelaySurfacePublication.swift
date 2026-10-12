import Foundation

@MainActor
final class RelaySurfacePublication {
    static let shared = RelaySurfacePublication()
    struct Request: Decodable {
        let paneID: UUID
        let surfaceID: UUID
        let generation: UUID
        let revision: UInt64
        let expectedRevision: UInt64
        let operation: RelaySurfaceEvent.Operation
        let content: RelaySurfaceContent?
    }
    private let store: RelayDurableSurfaceStore
    private let registered: (String) -> Bool
    private let permitted: (String) -> Bool
    init(directory: URL? = nil,
         registered: @escaping (String) -> Bool = { id in RelayCallerControl.shared.summaries.contains { $0.id == id } },
         permitted: @escaping (String) -> Bool = { RelayCallerControl.shared.permitted($0) }) {
        self.registered = registered
        self.permitted = permitted
        store = RelayDurableSurfaceStore(directory: directory, authorizedOwners: [], admitOwner: { owner in
            UUID(uuidString: owner.producer) != nil && UUID(uuidString: owner.host) != nil &&
                owner.session == "caller/" + owner.producer && registered(owner.producer)
        })
    }
    struct Status: Codable {
        let surfaceID: UUID
        let generation: UUID
        let revision: UInt64
        let operation: RelaySurfaceEvent.Operation
        let content: RelaySurfaceContent?
    }
    func read(paneID: UUID, hostID: UUID, principal: String, includeContent: Bool) throws -> [Status] {
        guard UUID(uuidString: principal) != nil, registered(principal) else { throw RelaySurfaceError.unauthorizedOwner }
        return try store.events().filter {
            $0.owner.paneID == paneID && $0.owner.host == hostID.uuidString &&
            $0.owner.producer == principal && $0.owner.session == "caller/" + principal
        }.map { Status(surfaceID: $0.surfaceID, generation: $0.generation,
                       revision: $0.revision, operation: $0.operation,
                       content: includeContent ? $0.content : nil) }
    }
    func publish(_ request: Request, pane: PaneModel, principal: String) throws {
        guard pane.id == request.paneID, UUID(uuidString: principal) != nil,
              permitted(principal) else { throw RelaySurfaceError.unauthorizedOwner }
        let owner = RelaySurfaceOwner(paneID: pane.id, host: pane.profile.id.uuidString,
            session: "caller/" + principal, producer: principal)
        try publish(request, authorizedOwner: owner)
        restore(pane)
    }
    func publish(_ request: Request, authorizedOwner owner: RelaySurfaceOwner) throws {
        guard request.paneID == owner.paneID, permitted(owner.producer), registered(owner.producer) else {
            throw RelaySurfaceError.unauthorizedOwner
        }
        _ = try store.publish(.init(schema: 1, surfaceID: request.surfaceID, owner: owner,
            generation: request.generation, revision: request.revision, expectedRevision: request.expectedRevision,
            operation: request.operation, content: request.content), authorizedOwner: owner)
    }
    func refresh(_ pane: PaneModel) {
        do {
            _ = try store.events()
            restore(pane)
        } catch {
            pane.durableSurfaceError = "Saved content could not be refreshed. The last view may be out of date."
        }
    }
    func restore(_ pane: PaneModel) {
        guard store.available else {
            pane.durableSurfaceError = "Saved content is unavailable."
            return
        }
        pane.durableSurfaceError = nil
        pane.durableSurfaceContents = store.snapshots.values
            .filter { $0.owner.paneID == pane.id && $0.owner.host == pane.profile.id.uuidString && registered($0.owner.producer) }
            .sorted { $0.surfaceID.uuidString < $1.surfaceID.uuidString }.map(\.content)
    }
}
