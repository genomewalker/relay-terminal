import Foundation
import Testing
@testable import Relay

@Test @MainActor func surfaceHTTPAdmissionUsesBothCredentialsAndExactPane() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-surface-http-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let callers = RelayCallerControl(directory: directory.appendingPathComponent("callers"))
    let issued = try await callers.register(label: "Publisher fixture", thread: nil)
    let principal = try #require(issued["caller_id"]), credential = try #require(issued["caller_token"])
    let other = try await callers.register(label: "Other fixture", thread: nil)
    let service = RelaySurfacePublication(directory: directory.appendingPathComponent("surfaces"),
        registered: { id in callers.summaries.contains { $0.id == id } }, permitted: { callers.permitted($0) })
    let pane = UUID(), host = UUID(), surface = UUID(), generation = UUID()
    let value: [String: Any] = ["paneID": pane.uuidString, "surfaceID": surface.uuidString,
        "generation": generation.uuidString, "revision": 1, "expectedRevision": 0, "operation": "snapshot",
        "owner": ["producer": "forged"], // Payload ownership is never authoritative.
        "content": ["kind": "text", "title": "", "text": "fixture", "status": "", "columns": [], "rows": []]]
    let body = try JSONSerialization.data(withJSONObject: value)
    var refreshes = 0
    func call(_ path: String = "/api/surfaces/publish", installation: String = "installation",
              caller: String? = credential, grant: Bool = true, payload: Data? = nil,
              method: String = "POST") throws -> RelaySidePanelHTTPResponse {
        var headers = ["x-relay-token": installation]
        headers["x-relay-caller-token"] = caller
        let request = RelaySidePanelHTTPRequest(method: method, path: path, headers: headers, body: payload ?? body)
        return try #require(RelaySurfaceHTTP.handle(request, installationToken: "installation",
            callerControl: callers, publication: service, layoutGranted: grant,
            resolvePane: { $0 == pane ? (pane, host) : nil }, refreshPane: { _ in refreshes += 1 }))
    }
    // A scoped caller token authorizes without the installation token; neither is a 401.
    #expect(try call(installation: "wrong", caller: nil).status == 401)
    #expect(try call(caller: nil).status == 403)
    #expect(try call(caller: "unknown").status == 403)
    #expect(try call(grant: false).status == 403)
    #expect(try call(method: "GET").status == 405)
    #expect(refreshes == 0)
    #expect(try call().status == 200)
    #expect(try call().status == 200) // Exact retry acknowledges one durable state.
    let query = try JSONSerialization.data(withJSONObject: ["paneID": pane.uuidString])
    let content = try call("/api/surfaces/content", payload: query)
    let statuses = try JSONDecoder().decode([RelaySurfacePublication.Status].self, from: content.body)
    #expect(statuses.count == 1 && statuses.first?.content?.text == "fixture")
    #expect(try call("/api/surfaces/content", caller: other["caller_token"], payload: query).body == Data("[]".utf8))
    try await callers.setPaused(id: principal, paused: true)
    #expect(try call().status == 403)
    #expect(try call("/api/surfaces/status", grant: false, payload: query).status == 200)
    #expect(try call("/api/surfaces/status", payload: Data(repeating: 32, count: 4097)).status == 400)
    #expect(callers.audit().contains { $0.outcome == "committed" })
}

@Test func surfaceHTTPParserAcceptsBoundedLargePublicationsOnly() {
    let body = String(repeating: "x", count: 220_000)
    func wire(_ path: String, _ length: Int = 220_000) -> Data {
        Data("POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n\(body)".utf8)
    }
    if case .request = RelaySidePanelHTTPRequest.parse(wire("/api/surfaces/publish")) {} else { Issue.record("Large surface body rejected") }
    #expect(RelaySidePanelHTTPRequest.parse(wire("/api/input")) == .invalid)
    #expect(RelaySidePanelHTTPRequest.parse(wire("/api/surfaces/publish", 1_048_577)) == .invalid)
}
