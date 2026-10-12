import Foundation
import Testing
@testable import Relay

@Test("Plugin folder responses stay within the requested directory")
func pluginDirectoryEnvelope() throws {
    var response = PluginOperationResult(root: "/project", text: "Files", entries: ["src/code.swift", "src/tests/"], truncated: false, directory: "src")
    for operation in [RelayPluginOperation.artifacts, .transfers] {
        try response.validateEnvelope(operation: operation, path: "src/")
    }
    for entry in ["../secret", "src/../secret", "src/deep/file", "/secret", "src/"] {
        response.entries = [entry]
        #expect(throws: (any Error).self) { try response.validateEnvelope(operation: .artifacts, path: "src") }
    }
    response.entries = []
    #expect(throws: (any Error).self) { try response.validateEnvelope(operation: .gitReview, path: "src") }
    #expect(throws: (any Error).self) { try response.validateEnvelope(operation: .artifacts, path: "other") }
    response.content = ""
    #expect(throws: (any Error).self) { try response.validateEnvelope(operation: .artifacts, path: "src") }
}
