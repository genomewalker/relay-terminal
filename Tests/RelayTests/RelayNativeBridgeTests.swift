import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import Relay

@MainActor final class RelayNativeBridgeTests: XCTestCase {
    private let identity = RelayNativeIdentity(pane: "pane", instance: "instance", provider: "codex")

    func testActionIdentityComesFromBinding() throws {
        let id = UUID()
        let raw = Data(#"{"operation":"action","action":{"kind":"send","text":"hello"}}"#.utf8)
        let encoded = try RelayNativeMikoBridge.validate(raw, identity: identity, actionID: id)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? [String: Any])
        XCTAssertEqual(action["id"] as? String, id.uuidString.lowercased())
        let owner = try XCTUnwrap(action["identity"] as? [String: String])
        XCTAssertEqual(owner, ["pane": "pane", "instance": "instance", "provider": "codex"])
        XCTAssertThrowsError(try RelayNativeMikoBridge.validate(
            Data(#"{"operation":"action","action":{"kind":"send","text":"hello","identity":{"pane":"other"}}}"#.utf8),
            identity: identity, actionID: id))
        XCTAssertThrowsError(try RelayNativeMikoBridge.validate(raw, identity: identity, actionID: nil))
    }

    func testUnknownRoleAndOperationRejected() {
        for raw in [
            #"{"operation":"snapshot","actor":"miko"}"#,
            #"{"operation":"shutdown"}"#,
            #"{"operation":"image","imageData":"not base64!"}"#,
            #"{"operation":"receipt","receiptId":"../outside"}"#,
            #"{"operation":"action","action":{"kind":"terminate"}}"#,
        ] {
            XCTAssertThrowsError(try RelayNativeMikoBridge.validate(Data(raw.utf8), identity: identity, actionID: UUID()))
        }
    }

    func testAuthorityAllTwoActorInterleavings() {
        var explored = 0
        func walk(_ granted: Bool, _ samePane: Bool, _ sameBinding: Bool, _ depth: Int) {
            explored += 1
            let actual = RelayNativeMikoBridge.permits(mutating: true, inputGranted: granted,
                samePane: samePane, sameBinding: sameBinding)
            XCTAssertEqual(actual, granted && samePane && sameBinding)
            XCTAssertEqual(RelayNativeMikoBridge.permits(mutating: false, inputGranted: granted,
                samePane: samePane, sameBinding: sameBinding), samePane && sameBinding)
            guard depth < 5 else { return }
            for operation in 0..<8 {
                switch operation {
                case 0: walk(true, samePane, sameBinding, depth + 1)
                case 1: walk(false, samePane, sameBinding, depth + 1)
                case 2: walk(granted, false, sameBinding, depth + 1)
                case 3: walk(granted, true, sameBinding, depth + 1)
                case 4: walk(granted, samePane, false, depth + 1)
                case 5: walk(granted, samePane, true, depth + 1)
                default: // actors A and B attempt the same production gate.
                    walk(granted, samePane, sameBinding, depth + 1)
                }
            }
        }
        walk(false, true, true, 0)
        XCTAssertEqual(explored, 37_449)
        print("native Miko fence: bound=5 operations=8 actors=2 nodes=37449; trusted executor grant and kernel-bound host RPC")
    }

    func testControlIncarnationAndLaunchAuthority() {
        XCTAssertFalse(RelayNativeMikoBridge.permits(mutating: true, inputGranted: true,
            samePane: true, sameBinding: true, sameControl: false))
        for mask in 0..<32 {
            let create = mask & 1 != 0
            let input = mask & 2 != 0
            let source = mask & 4 != 0
            let account = mask & 8 != 0
            let control = mask & 16 != 0
            XCTAssertEqual(RelayNativeMikoBridge.permitsLaunch(createGranted: create, inputGranted: input,
                sameSource: source, sameAccount: account, sameControl: control), mask == 31)
        }
    }

    /// Deterministic Swift parser fuzz target. Override RELAY_NATIVE_FUZZ_SEED
    /// to explore another reproducible stream; fixed regression seeds stay here.
    func testNativeBridgeSeededFuzz() throws {
        var random = UInt64(ProcessInfo.processInfo.environment["RELAY_NATIVE_FUZZ_SEED"] ?? "") ?? 0x45ad91
        func next() -> UInt64 {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            return random
        }
        let actionID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let seeds = [
            #"{"operation":"snapshot"}"#,
            #"{"operation":"receipt","receiptId":"00000000-0000-4000-8000-000000000002"}"#,
            #"{"operation":"action","action":{"kind":"send","text":"hello"}}"#,
            #"{"operation":"action","actor":"user","action":{"kind":"send"}}"#,
            #"{"operation":"image","imageData":"eA=="}"#,
            #"{"operation":"snapshot","before":0}"#,
            #"{"operation":"action","action":{"kind":"respond","answers":{"q":["A","B"]}}}"#,
        ]
        for index in 0..<4096 {
            var input = Array(seeds[index % seeds.count].utf8)
            if index >= seeds.count {
                let changes = Int(next() % 5)
                for _ in 0..<changes {
                    guard !input.isEmpty else { break }
                    let offset = Int(next() % UInt64(input.count))
                    switch next() % 3 {
                    case 0: input[offset] = UInt8(next() % 128)
                    case 1: input.remove(at: offset)
                    default: input.insert(UInt8(next() % 128), at: offset)
                    }
                }
            }
            guard let encoded = try? RelayNativeMikoBridge.validate(Data(input), identity: identity, actionID: actionID) else { continue }
            XCTAssertLessThanOrEqual(encoded.count, 6 << 20)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(body["actor"])
            XCTAssertNil(body["identity"])
            XCTAssertTrue(["snapshot", "receipt", "action", "image"].contains(body["operation"] as? String ?? ""))
            if let action = body["action"] as? [String: Any] {
                XCTAssertEqual(action["id"] as? String, actionID.uuidString.lowercased())
                XCTAssertEqual(action["identity"] as? [String: String],
                    ["pane": "pane", "instance": "instance", "provider": "codex"])
            }
            let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            XCTAssertEqual(canonical, encoded)
        }
    }
    func testNativeConversationRendersContent() throws {
        _ = NSApplication.shared
        let provider = ProcessInfo.processInfo.environment["RELAY_NATIVE_PREVIEW_PROVIDER"] == "claude" ? "claude" : "codex"
        let identity = RelayNativeIdentity(pane: "pane", instance: "instance", provider: provider)
        let binding = RelayNativeBinding(identity: identity, profile: .local,
            account: .init(provider: provider, label: "work", dir: ""))
        let model = RelayNativeConversation(binding: binding)
        let body: [String: Any] = [
            "version": 1, "identity": ["pane": "pane", "instance": "instance", "provider": provider],
            "sessionId": "preview-session", "turnId": "preview-turn", "cwd": "/workspace/research",
            "model": provider == "claude" ? "Claude" : "GPT-6.1", "phase": "waiting", "revision": 5,
            "items": [
                ["id": "u1", "role": "user", "text": "Check the analysis and explain any changes.", "sequence": 1],
                ["id": "a1", "role": "assistant", "text": "## Findings\nI found one inconsistent sample label.\n\n```swift\nlet label = \"sample_07\"\n```\nThe source data stays intact.", "sequence": 2],
                ["id": "t1", "role": "tool", "tool": "File changes", "text": "analysis/labels.json\n- sample_07_old\n+ sample_07", "status": "waiting", "sequence": 3],
            ],
            "requests": [
                ["id": "r1", "kind": "approval", "turnId": "preview-turn", "title": "Apply file changes",
                 "detail": "Update analysis/labels.json", "responding": false],
                ["id": "r2", "kind": "question", "turnId": "preview-turn", "title": "Your input is needed",
                 "detail": "", "responding": false, "questions": [
                    ["id": "q1", "text": "Which summary should I prepare?", "multiple": false,
                     "options": [["id": "brief", "label": "Brief summary", "description": "Findings and key limitations."],
                                 ["id": "detailed", "label": "Detailed review", "description": "Methods, evidence and suggested edits."]]],
                 ]],
            ],
            "capabilities": ["send": false, "steer": false, "interrupt": true, "interruptScope": "turn",
                "respond": true, "maintenance": false, "scheduledTasks": "unknown", "maintenanceReason": "Unavailable"],
        ]
        model.snapshot = try JSONDecoder().decode(RelayNativeSnapshot.self,
            from: JSONSerialization.data(withJSONObject: body))
        let width = CGFloat(Double(ProcessInfo.processInfo.environment["RELAY_NATIVE_PREVIEW_WIDTH"] ?? "820") ?? 820)
        let host = NSHostingView(rootView: RelayNativeConversationView(conversation: model, observeLive: false)
            .frame(width: width, height: 1000).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RELAY_NATIVE_PREVIEW_DARK"] == "1" ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 3, "native conversation rendered a blank surface")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["RELAY_NATIVE_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

}
