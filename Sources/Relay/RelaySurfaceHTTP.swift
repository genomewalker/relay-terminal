import Foundation

/// The live HTTP server and isolated fixtures share the same admission path.
@MainActor
enum RelaySurfaceHTTP {
    static func handle(_ request: RelaySidePanelHTTPRequest, installationToken: String,
                       callerControl: RelayCallerControl, publication: RelaySurfacePublication,
                       layoutGranted: Bool, resolvePane: (UUID) -> (UUID, UUID)?,
                       refreshPane: (UUID) -> Void) -> RelaySidePanelHTTPResponse? {
        guard ["/api/surfaces/publish", "/api/surfaces/status", "/api/surfaces/content"].contains(request.path) else { return nil }
        guard request.isAuthorized(token: installationToken) else {
            return .text("Unauthorized", status: 401, reason: "Unauthorized")
        }
        guard request.method == "POST" else {
            return .text("POST required", status: 405, reason: "Method Not Allowed")
        }
        guard let principal = try? callerControl.identity(token: request.headers["x-relay-caller-token"]),
              UUID(uuidString: principal) != nil else {
            return .text("Registered publisher required", status: 403, reason: "Forbidden")
        }
        if request.path != "/api/surfaces/publish" {
            guard request.body.count <= 4096,
                  let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
                  let paneID = body["paneID"].flatMap(UUID.init(uuidString:)),
                  let (id, host) = resolvePane(paneID), id == paneID else {
                return .text("Exact pane required", status: 400, reason: "Bad Request")
            }
            do {
                let statuses = try publication.read(paneID: id, hostID: host, principal: principal,
                                                    includeContent: request.path == "/api/surfaces/content")
                refreshPane(id)
                return .json(statuses)
            } catch { return .text("Surface checkpoint unavailable", status: 503, reason: "Service Unavailable") }
        }
        guard layoutGranted, callerControl.permitted(principal) else {
            try? callerControl.record(caller: principal, request: request, outcome: "blocked")
            return .text("Publisher and layout grant required", status: 403, reason: "Forbidden")
        }
        guard request.body.count <= 1_048_576,
              let value = try? JSONDecoder().decode(RelaySurfacePublication.Request.self, from: request.body),
              let (id, host) = resolvePane(value.paneID), id == value.paneID else {
            return .text("Invalid publication or pane", status: 400, reason: "Bad Request")
        }
        do { try callerControl.record(caller: principal, request: request, outcome: "admitted") }
        catch { return .text("Audit unavailable; publication not dispatched", status: 503, reason: "Service Unavailable") }
        do {
            let owner = RelaySurfaceOwner(paneID: id, host: host.uuidString, session: "caller/" + principal, producer: principal)
            try publication.publish(value, authorizedOwner: owner)
            refreshPane(id)
        } catch {
            try? callerControl.record(caller: principal, request: request, outcome: "rejected")
            return .text("Publication rejected; read current revision before retrying", status: 409, reason: "Conflict")
        }
        do { try callerControl.record(caller: principal, request: request, outcome: "committed") }
        catch { return .text("Surface committed but outcome audit failed; read status before retrying", status: 503, reason: "Service Unavailable") }
        return .json(["status": "committed", "surface_id": value.surfaceID.uuidString.lowercased(), "revision": String(value.revision)])
    }
}
