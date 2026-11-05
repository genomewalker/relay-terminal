import AppKit
import UniformTypeIdentifiers

/// Explicit data representations work across every native workspace drop target.
/// Pane headers also offer plain text for the existing pane-layout drag delegate.
enum WorkspaceDragPayload {
    static let tab = UTType(exportedAs: "dev.relay.workspace-tab", conformingTo: .data)
    static let group = UTType(exportedAs: "dev.relay.workspace-group", conformingTo: .data)
    static let pane = UTType(exportedAs: "dev.relay.workspace-pane", conformingTo: .data)

    static func provider(_ id: UUID, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        register(id, type: type, on: provider)
        return provider
    }

    @MainActor static func paneProvider(_ id: UUID, floating: Bool = false) -> NSItemProvider {
        PaneDragCoordinator.shared.paneID = id
        PaneDragCoordinator.shared.isFloating = floating
        let provider = NSItemProvider(object: id.uuidString as NSString)
        register(id, type: pane, on: provider)
        return provider
    }

    private static func register(_ id: UUID, type: UTType, on provider: NSItemProvider) {
        let data = Data(id.uuidString.lowercased().utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
    }
}
