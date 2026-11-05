import CryptoKit
import Foundation
import Testing
@testable import Relay

@MainActor private final class MPSurfaceFixture {
    let root: URL
    let callers: RelayCallerControl
    let publication: RelaySurfacePublication
    let peer: String
    let pane = UUID(), host = UUID(), surface = UUID(), peerSurface = UUID(), generation = UUID()

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-surfaces-" + UUID().uuidString)
        callers = RelayCallerControl(directory: root.appendingPathComponent("callers"))
        let issued = try await callers.register(label: "Peer", thread: nil)
        peer = try #require(issued["caller_token"])
        let callers = self.callers
        publication = RelaySurfacePublication(directory: root.appendingPathComponent("surfaces"),
            registered: { callers.isRegisteredPublisher($0) }, permitted: { callers.permitted($0) })
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func call(role: String, read: Bool = false, grant: Bool = true, validToken: Bool = true) throws -> RelaySidePanelHTTPResponse {
        var headers = ["x-relay-token": validToken ? "installation-fixture" : "wrong"]
        if role == "peer" || role == "miko-with-caller" { headers["x-relay-caller-token"] = peer }
        if role == "forged" { headers["x-relay-miko"] = "true" }
        let payload: [String: Any] = read ? ["paneID": pane.uuidString] : [
            "paneID": pane.uuidString, "surfaceID": (role == "peer" ? peerSurface : surface).uuidString, "generation": generation.uuidString,
            "revision": 1, "expectedRevision": 0, "operation": "snapshot",
            "content": ["kind": "markdown", "title": "", "text": role == "miko" ? "miko" : "peer", "status": "", "columns": [], "rows": []],
            "producer": RelayCallerControl.assistantPublisher]
        let request = RelaySidePanelHTTPRequest(method: "POST", path: read ? "/api/surfaces/content" : "/api/surfaces/publish",
            headers: headers, body: try JSONSerialization.data(withJSONObject: payload))
        return try #require(RelaySurfaceHTTP.handle(request, installationToken: "installation-fixture", callerControl: callers,
            publication: publication, layoutGranted: grant, assistantIdentity: role == "miko" || role == "miko-with-caller",
            resolvePane: { $0 == self.pane ? (self.pane, self.host) : nil }, refreshPane: { _ in }))
    }
    func assertOwnership() throws {
        let native = try publication.read(paneID: pane, hostID: host, principal: RelayCallerControl.assistantPublisher, includeContent: true)
        #expect(native.allSatisfy { $0.content?.text == "miko" })
        let peerID = try callers.identity(token: peer)
        let other = try publication.read(paneID: pane, hostID: host, principal: peerID, includeContent: true)
        #expect(other.allSatisfy { $0.content?.text == "peer" })
    }
}

@Suite("Miko surface parity", .serialized)
@MainActor struct RelayMikoSurfaceParityTests {
    @Test func nativePublisherBoundaryMatrix() async throws {
        var states = 0
        for role in ["miko", "peer", "forged", "miko-with-caller"] {
            for valid in [false, true] { for layout in [false, true] { for paused in [false, true] {
                let f = try await MPSurfaceFixture(); defer { f.close() }
                try await f.callers.setPaused(id: "legacy-unattributed", paused: paused)
                let response = try f.call(role: role, grant: layout, validToken: valid)
                let expected: Int
                if !valid { expected = 401 }
                else if role == "forged" || role == "miko-with-caller" || (role == "miko" && paused) || !layout { expected = 403 }
                else { expected = 200 }
                #expect(response.status == expected, "role=\(role) layout=\(layout) paused=\(paused) valid=\(valid)")
                try f.assertOwnership()
                states += 1
            }}}
        }
        #expect(states == 32)
        print("MP surface boundary: 32 real-handler states; installation credential, internal origin, caller credential, layout, pause, ownership")
    }

    @Test func boundedTwoPublisherSequences() async throws {
        var states = 0
        // All sequences of length 3 over two publishers' read/write/forgery
        // operations and user pause/resume, for both layout-grant states.
        for grant in [false, true] { for encoded in 0..<343 {
            let f = try await MPSurfaceFixture(); defer { f.close() }
            var n = encoded, paused = false
            for _ in 0..<3 {
                let operation = n % 7; n /= 7
                switch operation {
                case 0:
                    #expect(try f.call(role: "miko", grant: grant).status == (grant && !paused ? 200 : 403))
                case 1:
                    #expect(try f.call(role: "miko", read: true, grant: grant).status == (paused ? 403 : 200))
                case 2:
                    #expect(try f.call(role: "peer", read: true, grant: grant).status == 200)
                case 3:
                    #expect(try f.call(role: "forged", grant: grant).status == 403)
                case 4: paused = true; try await f.callers.setPaused(id: "legacy-unattributed", paused: true)
                case 5: paused = false; try await f.callers.setPaused(id: "legacy-unattributed", paused: false)
                default: #expect(try f.call(role: "peer", grant: grant).status == (grant ? 200 : 403))
                }
                try f.assertOwnership()
                states += 1
            }
        }}
        #expect(states == 2058)
        print("MP surface bounded: alphabet=7 depth=3 grants=2 sequences=686 transitions=2058; no cross-owner reads/writes, no external native principal, pause and layout hold")
    }

    @Test func reservedPrincipalNeverHasAnExternalCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-reserved-principal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data("forged-credential".utf8)).map { String(format: "%02x", $0) }.joined()
        // Even an imported/colliding registration must not mint the reserved
        // native actor. This path goes through the actual credential decoder.
        let disk: [String: Any] = ["callers": [["id": RelayCallerControl.assistantPublisher, "label": "forged", "tokenHash": hash, "paused": false]],
                                   "audit": [], "legacyPaused": false]
        try JSONSerialization.data(withJSONObject: disk).write(to: root.appendingPathComponent("caller-control-v1.json"))
        let callers = RelayCallerControl(directory: root)
        #expect(callers.available)
        #expect(throws: (any Error).self) { try callers.identity(token: "forged-credential") }
        #expect(try callers.identity(token: nil) == "legacy-unattributed")
    }
}
