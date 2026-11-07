import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Relay

// Clients authenticate with a scoped caller token; registering and pausing
// callers is a hardware click in the Relay app, never an HTTP call.
@MainActor private func containmentFixture() async throws -> (RelayCallerControl, id: String, token: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-containment-" + UUID().uuidString)
    let control = RelayCallerControl(directory: dir)
    let issued = try await control.register(label: "Fixture", thread: nil)
    return (control, try #require(issued["caller_id"]), try #require(issued["caller_token"]), dir)
}

private func request(_ path: String, installation: String? = nil, caller: String? = nil) -> RelaySidePanelHTTPRequest {
    var headers: [String: String] = [:]
    if let installation { headers["x-relay-token"] = installation }
    if let caller { headers["x-relay-caller-token"] = caller }
    return RelaySidePanelHTTPRequest(method: "POST", path: path, headers: headers, body: Data("{}".utf8))
}

@Test @MainActor func callerTokenAloneAuthorizesAndIsAttributedToThatCaller() async throws {
    let f = try await containmentFixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
    let r = request("/api/host/request", caller: f.token)
    #expect(f.0.authorizes(r, installationToken: "inst"))
    #expect(try f.0.identity(token: r.headers["x-relay-caller-token"]) == f.id)
    // Unknown caller token and no credentials are refused.
    #expect(!f.0.authorizes(request("/api/host/request", caller: "nope"), installationToken: "inst"))
    #expect(!f.0.authorizes(request("/api/host/request"), installationToken: "inst"))
    // The caller token does not need to match, or even exist for, the installation check.
    #expect(!f.0.authorizes(request("/api/host/request", installation: "wrong"), installationToken: "inst"))
}

@Test @MainActor func installationTokenOnlyIsLegacyUnattributedAndHonorsLegacyPause() async throws {
    let f = try await containmentFixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
    let r = request("/api/host/request", installation: "inst")
    #expect(f.0.authorizes(r, installationToken: "inst"))
    let identity = try f.0.identity(token: r.headers["x-relay-caller-token"])
    #expect(identity == "legacy-unattributed")
    #expect(f.0.permitted(identity))
    try await f.0.setPaused(id: "legacy-unattributed", paused: true)
    #expect(!f.0.permitted(identity))
    // A registered caller is unaffected by the legacy pause.
    #expect(f.0.permitted(f.id))
}

@Test @MainActor func bothHeadersResolveToTheCaller() async throws {
    let f = try await containmentFixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
    let r = request("/api/host/request", installation: "inst", caller: f.token)
    #expect(f.0.authorizes(r, installationToken: "inst"))
    #expect(try f.0.identity(token: r.headers["x-relay-caller-token"]) == f.id)
    // Pausing legacy does not pause the caller; pausing the caller does.
    try await f.0.setPaused(id: "legacy-unattributed", paused: true)
    #expect(f.0.permitted(f.id))
    try await f.0.setPaused(id: f.id, paused: true)
    #expect(!f.0.permitted(f.id))
}

@Test func callerRegistrationAndControlPathsAreAdministrativeWhateverTheCredentials() {
    #expect(RelayCallerControl.isAdministrativePath("/api/callers/register"))
    #expect(RelayCallerControl.isAdministrativePath("/api/callers/control"))
    #expect(!RelayCallerControl.isAdministrativePath("/api/callers"))
    #expect(!RelayCallerControl.isAdministrativePath("/api/callers/audit"))
}

@Test @MainActor func registrationAndPauseRequireAHardwareOrigin() async throws {
    let f = try await containmentFixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
    let before = f.0.summaries.count
    await #expect(throws: (any Error).self) { try await f.0.register(label: "Forged", thread: nil, origin: .synthesized) }
    await #expect(throws: (any Error).self) { try await f.0.setPaused(id: "legacy-unattributed", paused: true, origin: .synthesized) }
    #expect(f.0.summaries.count == before)
    #expect(f.0.permitted("legacy-unattributed"))
    let issued = try await f.0.register(label: "Real click", thread: nil, origin: .hardware)
    #expect(issued["caller_token"] != nil)
    try await f.0.setPaused(id: "legacy-unattributed", paused: true, origin: .hardware)
    #expect(!f.0.permitted("legacy-unattributed"))
}

@Test func userActionOriginUsesTheKeyEventRuleForClicksAndKeys() throws {
    // Same classifier: a mouse click this process posts is synthesized for every source state.
    for state in [CGEventSourceStateID.hidSystemState, .combinedSessionState, .privateState] {
        let down = try #require(CGEvent(mouseEventSource: CGEventSource(stateID: state), mouseType: .leftMouseDown,
                                        mouseCursorPosition: .zero, mouseButton: .left))
        #expect(RelayKeyEventOrigin.ofUserAction(NSEvent(cgEvent: down)) == .synthesized)
        // Documented limit: forged hardware source fields read as hardware.
        down.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(RelayKeyEventOrigin.ofUserAction(NSEvent(cgEvent: down)) == .hardware)
        // Tagged user data is synthesized even with a hardware PID.
        down.setIntegerValueField(.eventSourceUserData, value: 7)
        #expect(RelayKeyEventOrigin.ofUserAction(NSEvent(cgEvent: down)) == .synthesized)
    }
    let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
    key.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    #expect(RelayKeyEventOrigin.ofUserAction(NSEvent(cgEvent: key)) == .hardware)
    // Non-click events and no event are refused; the rule itself is the key rule.
    let move = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
    move.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    #expect(RelayKeyEventOrigin.ofUserAction(NSEvent(cgEvent: move)) == .synthesized)
    #expect(RelayKeyEventOrigin.ofUserAction(nil) == .synthesized)
}
