import Foundation
import Testing
@testable import Relay

@Test("Scheduler mutations require separate capabilities and reviewed inputs")
func hpcMutationPermissions() throws {
    #expect(RelayPluginOperation.hpcSubmit.permissions == [.jobSubmit])
    #expect(RelayPluginOperation.hpcCancel.permissions == [.jobCancel])
    #expect(!RelayPluginOperation.hpcJobs.isMutation)
    let action = PluginHPCAction(id: UUID(), script: "#!/bin/bash\necho test\n")
    try action.validate(operation: .hpcSubmit, path: "")
    try action.validate(operation: .hpcCancel, path: "123")
    for id in ["", "--all", "123_4", "123,456", "123;echo bad"] {
        #expect(throws: (any Error).self) { try action.validate(operation: .hpcCancel, path: id) }
    }
    #expect(throws: (any Error).self) {
        try PluginHPCAction(id: UUID(), script: "echo no-shebang").validate(operation: .hpcSubmit, path: "")
    }
    #expect(throws: (any Error).self) {
        try PluginScope.captured(paneID: UUID(), profile: .local, directory: nil, operation: .hpcSubmit)
    }
}

@Test("HPC can use a connection without granting file tools an unknown directory")
func hpcConnectionScope() throws {
    let id = UUID()
    let scope = try PluginScope.captured(paneID: id, profile: .local, directory: nil, operation: .hpcJobs)
    #expect(scope.paneID == id)
    #expect(scope.root == "/")
    for operation in [RelayPluginOperation.artifacts, .transfers, .gitReview, .projectActions] {
        #expect(throws: (any Error).self) {
            try PluginScope.captured(paneID: id, profile: .local, directory: nil, operation: operation)
        }
    }
}

private let hpcJobs = [
    PluginHPCJob(id: "123_4", partition: "batch", name: "assembly 🧬", state: "RUNNING", elapsed: "2:04", nodes: "1", reason: "node01"),
    PluginHPCJob(id: "456", partition: "gpu", name: "train", state: "PENDING", elapsed: "0:00", nodes: "2", reason: "(Resources)")
]

@Test("HPC filtering combines state and case-insensitive search without network requests")
func hpcFiltering() {
    #expect(PluginHPCJob.filtered(hpcJobs, query: "ASSEMBLY batch", state: "RUNNING").map(\.id) == ["123_4"])
    #expect(PluginHPCJob.filtered(hpcJobs, query: "Resources", state: "").map(\.id) == ["456"])
    #expect(PluginHPCJob.filtered(hpcJobs, query: "", state: "COMPLETED").isEmpty)
    #expect(PluginHPCJob.filtered(hpcJobs, query: " \n ", state: "").count == 2)
}

@Test("HPC response detects old helpers, malformed counts and duplicate identities")
func hpcResponseValidation() throws {
    var result = PluginOperationResult(root: "/tmp", text: "", entries: [], truncated: false)
    #expect(throws: (any Error).self) { try result.validatedHPCJobs() }
    result.jobCount = 0
    #expect(try result.validatedHPCJobs().isEmpty)
    result.jobs = hpcJobs; result.jobCount = 2
    #expect(try result.validatedHPCJobs() == hpcJobs)
    result.jobCount = 10
    #expect(throws: (any Error).self) { try result.validatedHPCJobs() }
    result.truncated = true
    #expect(try result.validatedHPCJobs().count == 2)
    result.jobs = [hpcJobs[0], hpcJobs[0]]
    #expect(throws: (any Error).self) { try result.validatedHPCJobs() }
}
