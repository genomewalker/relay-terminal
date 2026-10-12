import Foundation

/// An omitted pair may use the selected two-pane tab. Explicit input must
/// identify both panes exactly; malformed input must never select a fallback.
struct PaneLinkRequest: Decodable {
    let sourcePaneID: UUID?
    let paneID: UUID?

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static let source = Key(stringValue: "sourcePaneID")!
        static let target = Key(stringValue: "paneID")!
    }

    enum Invalid: Error, LocalizedError {
        case pair
        var errorDescription: String? {
            "Choose two distinct pane IDs using sourcePaneID and paneID."
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard values.allKeys.allSatisfy({ ["sourcePaneID", "paneID"].contains($0.stringValue) }) else {
            throw Invalid.pair
        }
        guard !values.allKeys.isEmpty else {
            sourcePaneID = nil
            paneID = nil
            return
        }
        guard values.contains(.source), values.contains(.target),
              let source = try? values.decode(UUID.self, forKey: .source),
              let target = try? values.decode(UUID.self, forKey: .target),
              source != target else { throw Invalid.pair }
        sourcePaneID = source
        paneID = target
    }
}
