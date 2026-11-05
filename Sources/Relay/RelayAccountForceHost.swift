import Foundation

/// App-owned transport for a captured execution context. Generic MCP host
/// operations do not expose these calls. The caller must retain and recheck
/// the same context and pane lease before committing.
enum RelayAccountForceHost {
    static func preview(context: RelayExecutionContext, selection: RelayAccountForceSelection) async throws -> RelayAccountForcePreview {
        guard let request = selection.previewRequest else { throw RelayHostRPCError.invalidRequest }
        let result = try await RelayHostFiles.request(context: context, fields: request)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard let preview = RelayAccountForcePreview.fromHostResult(data, host: context.host, selection: selection) else {
            throw RelayHostRPCError.invalidRequest
        }
        return preview
    }

    /// Only accept a payload constructed by the immutable reviewed preview.
    /// A transport error is uncertain; the caller must not retry this action.
    static func commit(context: RelayExecutionContext, preview: RelayAccountForcePreview, actionID: UUID) async throws -> String {
        guard context.host == preview.host, let request = preview.commitRequest(actionID: actionID) else {
            throw RelayHostRPCError.invalidRequest
        }
        let result = try await RelayHostFiles.request(context: context, fields: request)
        guard let status = result["status"] as? String, ["exited", "blocked", "unknown"].contains(status) else {
            throw RelayHostRPCError.invalidRequest
        }
        return status
    }
}
