import Foundation
import Testing
@testable import Relay

@Test func paneLinkRequestAcceptsExactPairAndEmptyLegacyRequest() throws {
    let source = UUID(), target = UUID()
    let bytes = try JSONSerialization.data(withJSONObject: ["sourcePaneID": source.uuidString, "paneID": target.uuidString])
    let request = try JSONDecoder().decode(PaneLinkRequest.self, from: bytes)
    #expect(request.sourcePaneID == source && request.paneID == target)
    let omitted = try JSONDecoder().decode(PaneLinkRequest.self, from: Data("{}".utf8))
    #expect(omitted.sourcePaneID == nil && omitted.paneID == nil)
}

@Test func paneLinkRequestRejectsMalformedExplicitPairBeforeFallback() throws {
    let source = UUID().uuidString, target = UUID().uuidString
    let rejected: [[String: Any]] = [
        ["paneIDs": [source, target]],
        ["sourcePaneID": source], ["paneID": target],
        ["sourcePaneID": source, "paneID": NSNull()],
        ["sourcePaneID": NSNull(), "paneID": target],
        ["sourcePaneID": source, "paneID": "invalid"],
        ["sourcePaneID": source, "paneID": source],
        ["sourcePaneID": source, "paneID": target, "extra": true],
    ]
    for object in rejected {
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: PaneLinkRequest.Invalid.self) {
            try JSONDecoder().decode(PaneLinkRequest.self, from: bytes)
        }
    }
}
