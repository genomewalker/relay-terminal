import AppKit
import Foundation

/// Explicit terminal editor input. Text is pasted without Return; a key is
/// translated by the native terminal, including application/kitty modes.
struct RelayTerminalEditRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let token: UUID
    let action: String
    let text: String?
    let key: String?
    let modifiers: [String]?

    private enum CodingKeys: String, CodingKey {
        case instance, requestID, action, text, key, modifiers
        case token = "proofID"
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 64 << 10,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["instance", "requestID", "proofID", "action", "text", "key", "modifiers"]),
              !object.values.contains(where: { $0 is NSNull }),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
    var isValid: Bool {
        let flags = modifiers ?? []
        guard Set(flags).count == flags.count, Set(flags).isSubset(of: ["shift", "control", "option"]) else { return false }
        switch action {
        case "insert_text":
            guard key == nil, flags.isEmpty, let text, !text.isEmpty, text.utf8.count <= 8192 else { return false }
            return !text.unicodeScalars.contains { ($0.value < 32 && $0.value != 9 && $0.value != 10) || (0x7f...0x9f).contains($0.value) }
        case "key": return text == nil && key.flatMap { RelayTerminalEditKey(rawValue: $0) } != nil
        default: return false
        }
    }
    var nativeModifiers: NSEvent.ModifierFlags {
        (modifiers ?? []).reduce(into: NSEvent.ModifierFlags()) { result, value in
            switch value { case "shift": result.insert(.shift); case "control": result.insert(.control)
            case "option": result.insert(.option); default: break }
        }
    }
}

enum RelayTerminalEditKey: String, CaseIterable {
    case escape, enter, tab, backspace, delete, left, right, up, down, home, end, page_up, page_down
    case a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z
    case zero = "0", one = "1", two = "2", three = "3", four = "4", five = "5", six = "6", seven = "7", eight = "8", nine = "9", space
    var native: (code: UInt16, characters: String) {
        let alpha: [String: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
        if let code = alpha[rawValue] { return (code, rawValue) }
        switch self {
        case .escape: return (53, "\u{1b}")
        case .enter: return (36, "\r")
        case .tab: return (48, "\t")
        case .backspace: return (51, "\u{7f}")
        case .space: return (49, " ")
        case .delete: return (117, String(UnicodeScalar(NSDeleteFunctionKey)!))
        case .left: return (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .right: return (124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .up: return (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .down: return (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .home: return (115, String(UnicodeScalar(NSHomeFunctionKey)!))
        case .end: return (119, String(UnicodeScalar(NSEndFunctionKey)!))
        case .page_up: return (116, String(UnicodeScalar(NSPageUpFunctionKey)!))
        case .page_down: return (121, String(UnicodeScalar(NSPageDownFunctionKey)!))
        default: preconditionFailure("Every alphanumeric key has a native keycode")
        }
    }
}

/// Request IDs remain single-use for this app instance. Receipt reads never
/// reserve a new operation. An uncertain or in-flight dispatch is not retried.
struct RelayTerminalEditReceipts {
    enum Admission: Equatable { case admitted, replay(String), conflict, full }
    private struct Entry { let pane: UUID; let request: RelayTerminalEditRequest; var status: String }
    private var entries: [UUID: Entry] = [:]
    var capacity = 256
    mutating func begin(pane: UUID, request: RelayTerminalEditRequest) -> Admission {
        if let entry = entries[request.requestID] {
            return entry.pane == pane && entry.request == request ? .replay(entry.status) : .conflict
        }
        guard entries.count < capacity else { return .full }
        entries[request.requestID] = Entry(pane: pane, request: request, status: "dispatching")
        return .admitted
    }
    mutating func finish(_ id: UUID, status: String) { entries[id]?.status = status }
    func status(pane: UUID, id: UUID) -> String? { entries[id].flatMap { $0.pane == pane ? $0.status : nil } }
}

