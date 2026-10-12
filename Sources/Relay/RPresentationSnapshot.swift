import Foundation

struct RPanelPlacement: Codable, Equatable, Sendable {
    var x: Double = 16
    var y: Double = 16
    var width: Double
    var height: Double
    var maximized: Bool = false
}

struct RExtraPresentation: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let paneID: UUID?
    let returnsToTab: Bool
    let floating: Bool
    let minimized: Bool
    let placement: RPanelPlacement?
}

struct RWorkspacePresentation: Codable, Equatable, Sendable {
    let consoleID: UUID
    let editorID: UUID
    let tabID: UUID
    let selected: Bool
    let minimized: Bool
    let placement: RPanelPlacement?
    let extras: [RExtraPresentation]
    var paneIDs: [UUID] { [consoleID, editorID] + extras.compactMap(\.paneID) }
}
