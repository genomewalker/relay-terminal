import Foundation

/// Additive bridge for the authenticated Miko harness. Registration belongs to
/// the shared integration patch. Mutations must remain Change-tier actions:
/// proposal captures these exact bytes, approved execution calls execute once.
@MainActor enum RelayNativeMikoBridge {
    struct Prepared {
        let paneID: UUID
        let paneObject: ObjectIdentifier
        let binding: RelayNativeBinding
        let body: Data
        let mutating: Bool
        let controlInstance: UUID
    }

    static let readOperations: Set<String> = ["snapshot", "receipt"]
    static let mutationOperations: Set<String> = ["action", "image"]

    static func validate(_ data: Data, identity: RelayNativeIdentity, actionID: UUID?) throws -> Data {
        guard data.count <= 6 << 20,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = body["operation"] as? String,
              readOperations.union(mutationOperations).contains(operation) else {
            throw RelayNativeService.Failure.invalid
        }
        let allowed: Set<String>
        switch operation {
        case "snapshot": allowed = ["operation", "before", "afterRevision", "waitMillis"]
        case "receipt": allowed = ["operation", "receiptId"]
        case "image": allowed = ["operation", "imageData"]
        default: allowed = ["operation", "action"]
        }
        guard Set(body.keys).isSubset(of: allowed) else {
            throw RelayNativeService.Failure.refused("Native request includes unsupported fields.")
        }
        if operation == "action" {
            guard let actionID, var action = body["action"] as? [String: Any],
                  let kind = action["kind"] as? String,
                  ["send", "steer", "interrupt", "respond"].contains(kind),
                  Set(action.keys).isSubset(of: ["kind", "turnId", "text", "images", "requestId", "decision", "answers"]) else {
                throw RelayNativeService.Failure.invalid
            }
            action["id"] = actionID.uuidString.lowercased()
            action["identity"] = ["pane": identity.pane, "instance": identity.instance, "provider": identity.provider]
            let encoded = try JSONSerialization.data(withJSONObject: action, options: [.sortedKeys])
            guard encoded.count <= 128 << 10 else { throw RelayNativeService.Failure.invalid }
            body["action"] = action
        } else if operation == "image" {
            guard let encoded = body["imageData"] as? String, let image = Data(base64Encoded: encoded),
                  !image.isEmpty, image.count <= 4 << 20 else { throw RelayNativeService.Failure.invalid }
        } else if operation == "receipt" {
            guard let id = body["receiptId"] as? String, UUID(uuidString: id) != nil else {
                throw RelayNativeService.Failure.invalid
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func prepare(pane: PaneModel, body: Data, actionID: UUID? = nil,
                        executor: any RelayAssistantActionExecutor,
                        registry: RelayNativeRegistry = .shared) throws -> Prepared {
        guard let controlInstance = executor.instance, let binding = registry.binding(for: pane) else {
            throw RelayNativeService.Failure.refused("This pane has no native conversation binding.")
        }
        let validated = try validate(body, identity: binding.identity, actionID: actionID)
        let object = try JSONSerialization.jsonObject(with: validated) as! [String: Any]
        return Prepared(paneID: pane.id, paneObject: ObjectIdentifier(pane), binding: binding,
            body: validated, mutating: mutationOperations.contains(object["operation"] as! String),
            controlInstance: controlInstance)
    }

    // Pure fence used by the actual execute path and exhaustive bounded tests.
    static func permits(mutating: Bool, inputGranted: Bool, samePane: Bool, sameBinding: Bool, sameControl: Bool = true) -> Bool {
        samePane && sameBinding && sameControl && (!mutating || inputGranted)
    }

    static func execute(_ prepared: Prepared, workspace: WorkspaceModel,
                        executor: any RelayAssistantActionExecutor,
                        registry: RelayNativeRegistry = .shared,
                        transport: (@MainActor (RelayNativeBinding, [String: Any]) async throws -> RelayNativeResponse)? = nil) async throws -> RelayNativeResponse {
        guard let pane = workspace.panes[prepared.paneID],
              permits(mutating: prepared.mutating, inputGranted: executor.permits(.input),
                  samePane: ObjectIdentifier(pane) == prepared.paneObject,
                  sameBinding: registry.binding(for: pane) == prepared.binding,
                  sameControl: executor.instance == prepared.controlInstance) else {
            throw RelayNativeService.Failure.refused("Native target or input authorization changed; nothing was sent.")
        }
        guard let body = try JSONSerialization.jsonObject(with: prepared.body) as? [String: Any] else {
            throw RelayNativeService.Failure.invalid
        }
        // The stable action ID is part of Prepared, never generated at execution.
        // The host worker durably claims it before provider I/O. No retry here.
        if let transport { return try await transport(prepared.binding, body) }
        return try await RelayNativeService.call(prepared.binding, body: body)
    }

    struct PreparedLaunch {
        let actionID: UUID
        let paneID: UUID
        let paneObject: ObjectIdentifier
        let profile: ConnectionProfile
        let account: RelayAgentAccount
        let resume: RelayNativeBinding?
        let controlInstance: UUID
    }
    static func prepareLaunch(actionID: UUID, account: RelayAgentAccount, pane: PaneModel,
                              resuming: Bool = false, executor: any RelayAssistantActionExecutor,
                              registry: RelayNativeRegistry = .shared,
                              directory: RelayAgentAccountDirectory = .shared) throws -> PreparedLaunch {
        guard let instance = executor.instance, account.isValid,
              directory.account(for: pane.profile, provider: account.provider,
                  label: account.label) == account else { throw RelayNativeService.Failure.invalid }
        let resume = resuming ? registry.binding(for: pane) : nil
        guard !resuming || resume != nil else { throw RelayNativeService.Failure.invalid }
        return PreparedLaunch(actionID: actionID, paneID: pane.id, paneObject: ObjectIdentifier(pane),
            profile: pane.profile, account: account, resume: resume, controlInstance: instance)
    }
    static func permitsLaunch(createGranted: Bool, inputGranted: Bool, sameSource: Bool,
                              sameAccount: Bool, sameControl: Bool) -> Bool {
        createGranted && inputGranted && sameSource && sameAccount && sameControl
    }
    static func launch(_ prepared: PreparedLaunch, workspace: WorkspaceModel,
                       executor: any RelayAssistantActionExecutor,
                       registry: RelayNativeRegistry = .shared,
                       directory: RelayAgentAccountDirectory = .shared,
                       transport: (@MainActor (PreparedLaunch, WorkspaceModel) async throws -> Void)? = nil,
                       capabilityProbe: (@MainActor (ConnectionProfile) async throws -> Void)? = nil,
                       authorization: @escaping @MainActor () -> Bool = { true },
                       onSubmit: @escaping @MainActor () -> Void = {}) async throws {
        let authorized: @MainActor () -> Bool = {
            guard !Task.isCancelled, authorization(), let pane = workspace.panes[prepared.paneID] else { return false }
            return permitsLaunch(createGranted: executor.permits(.create), inputGranted: executor.permits(.input),
                  sameSource: ObjectIdentifier(pane) == prepared.paneObject && pane.profile == prepared.profile &&
                      (prepared.resume == nil || registry.binding(for: pane) == prepared.resume),
                  sameAccount: directory.account(for: pane.profile,
                      provider: prepared.account.provider, label: prepared.account.label) == prepared.account,
                  sameControl: executor.instance == prepared.controlInstance)
        }
        guard authorized() else {
            throw RelayNativeService.Failure.refused("Native launch target, account or authorization changed.")
        }
        if let transport {
            onSubmit()
            try await transport(prepared, workspace)
            return
        }
        if let refusal = await workspace.startNativeAgentInNewTab(prepared.account, besidePane: prepared.paneID,
            launchID: prepared.actionID, resuming: prepared.resume,
            authorization: authorized, capabilityProbe: capabilityProbe, onSubmit: onSubmit) {
            throw RelayNativeService.Failure.refused(refusal)
        }
    }
}
