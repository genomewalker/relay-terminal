import Foundation
import Testing
@testable import Relay

/// The installer publishes the Work host-channel helper link next to the
/// communication helper, so the app carrier's command finds it on every host.
@Test func relaydInstallScriptPublishesTheWorkCommunicationHelper() {
    let script = RelaydRemoteClient.installScript(expectedHash: String(repeating: "a", count: 64), architecture: "amd64")
    #expect(script.contains(#"relay_publish_link "relayd-linux-amd64" "$payload_dir/relayd-work-communication""#))
    #expect(script.contains(#"relay_publish_link "relayd-linux-amd64" "$payload_dir/relayd-communication""#))
}

/// Publishing over a hand-made link with the same target (as on dandy-07)
/// succeeds, twice, and leaves a link that resolves to the payload.
@Test func relaydInstallLinkReplacesAHandMadeLinkIdempotently() throws {
    let script = RelaydRemoteClient.installScript(expectedHash: String(repeating: "a", count: 64), architecture: "amd64")
    guard let start = script.range(of: "relay_publish_link() {\n"),
          let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex) else {
        Issue.record("relay_publish_link is missing from the install script")
        return
    }
    let function = String(script[start.lowerBound..<end.upperBound])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relayd-link-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = directory.appendingPathComponent("relayd-linux-amd64")
    try Data("payload".utf8).write(to: payload)
    let link = directory.appendingPathComponent("relayd-work-communication")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "relayd-linux-amd64")
    #if os(Linux)
    let flag = "-fT"
    #else
    let flag = "-fh"
    #endif
    let body = "set -eu\nshim_move_flag=\(flag)\npayload_dir='\(directory.path)'\n" + function +
        "relay_publish_link \"relayd-linux-amd64\" \"$payload_dir/relayd-work-communication\"\n" +
        "relay_publish_link \"relayd-linux-amd64\" \"$payload_dir/relayd-work-communication\"\n"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", body]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "relayd-linux-amd64")
    #expect(try String(contentsOf: link, encoding: .utf8) == "payload")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".relay-link.") }
    #expect(leftovers.isEmpty)
}
