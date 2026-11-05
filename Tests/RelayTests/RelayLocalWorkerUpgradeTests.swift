import Foundation
import Testing
@testable import Relay

@Suite("Local worker upgrade after an app update")
struct RelayLocalWorkerUpgradeTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-worker-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fakeRelayd(in root: URL, script: String) throws -> URL {
        let url = root.appendingPathComponent("relayd")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test("Results are counted per kind")
    func summaryCountsResults() {
        let output = Data(#"[{"session_id":"a","result":"upgraded"},{"session_id":"b","result":"current"},{"session_id":"c","result":"upgraded"},{"session_id":"d","result":"legacy"}]"#.utf8)
        #expect(RelayLocalWorkerUpgrade.summary(of: output)?.counts == ["upgraded": 2, "current": 1, "legacy": 1])
        #expect(RelayLocalWorkerUpgrade.summary(of: Data("not json".utf8)) == nil)
    }

    @Test("Runs once per build, never isolated or for an unusable build number")
    func runsOncePerBuild() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RelayLocalWorkerUpgrade.shouldRun(build: "2026101631", root: root, isolated: false))
        #expect(!RelayLocalWorkerUpgrade.shouldRun(build: "2026101631", root: root, isolated: true))
        #expect(!RelayLocalWorkerUpgrade.shouldRun(build: nil, root: root, isolated: false))
        #expect(!RelayLocalWorkerUpgrade.shouldRun(build: "../x", root: root, isolated: false))
        let receipt = RelayLocalWorkerUpgrade.receiptURL(root: root, build: "2026101631")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: receipt)
        #expect(!RelayLocalWorkerUpgrade.shouldRun(build: "2026101631", root: root, isolated: false))
        #expect(RelayLocalWorkerUpgrade.shouldRun(build: "2026101632", root: root, isolated: false))
    }

    @Test("A successful run writes a private receipt with relayd's output")
    func successfulRunWritesReceipt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = #"[{"session_id":"a","result":"$1"}]"#
        let relayd = try fakeRelayd(in: root, script: "printf '%s' '" + output + "'")
        RelayLocalWorkerUpgrade.run(executable: relayd, build: "7", root: root)
        let receipt = RelayLocalWorkerUpgrade.receiptURL(root: root, build: "7")
        #expect(try String(contentsOf: receipt, encoding: .utf8) == output)
        let mode = try FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!RelayLocalWorkerUpgrade.shouldRun(build: "7", root: root, isolated: false))
    }

    @Test("A failed run leaves no receipt, so the next launch tries again")
    func failedRunIsRetried() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for script in ["echo '[]'; exit 3", "echo 'not json'"] {
            let relayd = try fakeRelayd(in: root, script: script)
            RelayLocalWorkerUpgrade.run(executable: relayd, build: "8", root: root)
            #expect(RelayLocalWorkerUpgrade.shouldRun(build: "8", root: root, isolated: false))
        }
    }

    @Test("relayd is asked to upgrade workers, nothing else")
    func passesOnlyUpgradeWorkers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relayd = try fakeRelayd(in: root, script: #"printf '[{"result":"%s"}]' "$*""#)
        RelayLocalWorkerUpgrade.run(executable: relayd, build: "9", root: root)
        let receipt = RelayLocalWorkerUpgrade.receiptURL(root: root, build: "9")
        #expect(try String(contentsOf: receipt, encoding: .utf8) == #"[{"result":"upgrade-workers"}]"#)
    }
}
