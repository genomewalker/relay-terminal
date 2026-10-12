import Foundation

protocol RelayRotationLifecycleFactory: Sendable {
    func lifecycle(enrollment: RelayRetainedRotationEnrollment,
                   capsule: Data) throws -> any RelayRotationLifecycle
}

enum RelayRotationFactoryError: Error {
    case invalidEnrollment, invalidCapsule, backendUnavailable, clientMismatch
}

/// Each builder is installed only once its physical transport is available.
/// The default factory has no builders and cannot start or retire a session.
struct RelayConfiguredRotationLifecycleFactory: RelayRotationLifecycleFactory {
    typealias Builder = @Sendable (RelayRetainedRotationEnrollment, Data) throws -> any RelayRotationLifecycle
    let codex: Builder?
    let claude: Builder?

    init(codex: Builder? = nil, claude: Builder? = nil) {
        self.codex = codex; self.claude = claude
    }

    func lifecycle(enrollment: RelayRetainedRotationEnrollment,
                   capsule: Data) throws -> any RelayRotationLifecycle {
        guard enrollment.valid else { throw RelayRotationFactoryError.invalidEnrollment }
        guard !capsule.isEmpty, capsule.count <= 65_536,
              (try? JSONSerialization.jsonObject(with: capsule)) is [String: Any] else {
            throw RelayRotationFactoryError.invalidCapsule
        }
        let builder = enrollment.client == "codex" ? codex : claude
        guard let builder else { throw RelayRotationFactoryError.backendUnavailable }
        let lifecycle = try builder(enrollment, capsule)
        guard lifecycle.client == enrollment.client else { throw RelayRotationFactoryError.clientMismatch }
        return lifecycle
    }
}
