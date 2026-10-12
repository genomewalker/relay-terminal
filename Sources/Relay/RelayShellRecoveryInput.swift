import Foundation

struct RelayShellRecoveryInput: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let text: String
    let workerPID: Int
    let workerStart: String
    let shellPID: Int
    let shellStart: String

    var isValid: Bool {
        workerPID > 1 && shellPID > 1 &&
        UInt64(workerStart) != nil && UInt64(shellStart) != nil &&
        !text.isEmpty && text.utf8.count <= 16_384 &&
        text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}
