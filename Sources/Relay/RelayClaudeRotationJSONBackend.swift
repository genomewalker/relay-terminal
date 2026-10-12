import Foundation

/// Stateless Python planning/verification operations; none may launch or type.
enum RelayClaudeRotationOperation: String, Sendable {
    case planStart = "plan_start", confirm
    case receiptPlan = "receipt_plan", delivered
    case verifyReceipt = "verify_receipt", retirePreflight = "retire_preflight"
    case retired, continuationPlan = "continuation_plan"
}

struct RelayClaudeRotationJSONBackend: Sendable {
    let exchange: @Sendable (Data) async throws -> Data

    func request(_ operation: RelayClaudeRotationOperation, arguments: Data) async throws -> Data {
        guard arguments.count <= 65536,
              var value = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              value["op"] == nil else { throw RelayRotationAdapterError.mismatchedEvidence }
        value["op"] = operation.rawValue
        let input = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard input.count <= 65536 else { throw RelayRotationAdapterError.mismatchedEvidence }
        let output = try await exchange(input)
        guard output.count <= 65536,
              let response = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              response["v"] as? Int == 1, response["ok"] is Bool,
              response["error"] == nil,
              response["ok"] as? Bool == true || operation == .retirePreflight else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return output
    }
}
