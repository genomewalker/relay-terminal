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

/// The app runs the peer helper from peer-network/, which no install updated:
/// dandy-07 kept a September helper that missed an account, so remote
/// discovery could not find the target pane. The install now links it to the
/// bundled helper and keeps a hand-placed file as a backup.
@Test func relaydInstallLinksThePeerNetworkHelperToTheBundledOne() throws {
    let script = RelaydRemoteClient.installScript(expectedHash: String(repeating: "a", count: 64), architecture: "amd64")
    guard let start = script.range(of: "relay_publish_link() {\n"),
          let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex),
          let backup = script.range(of: "if [ -f \"$peer_dir/relay-peer-link\" ]"),
          let publish = script.range(of: "relay_publish_link \"../bin/relay-peer-link-linux-amd64\" \"$peer_dir/relay-peer-link\"\n") else {
        Issue.record("peer-network publication is missing from the install script")
        return
    }
    #expect(script.contains(#"mkdir -p "$peer_dir""#))
    #expect(script.contains(#""$payload_dir/relay-peer-link" "$peer_dir/relay-peer-link"; do"#))
    let function = String(script[start.lowerBound..<end.upperBound])
    let block = String(script[backup.lowerBound..<publish.upperBound])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-peer-" + UUID().uuidString)
    let bin = root.appendingPathComponent("bin"), peer = root.appendingPathComponent("peer-network")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("bundled".utf8).write(to: bin.appendingPathComponent("relay-peer-link-linux-amd64"))
    let helper = peer.appendingPathComponent("relay-peer-link")
    try Data("hand-placed".utf8).write(to: helper)
    #if os(Linux)
    let flag = "-fT"
    #else
    let flag = "-fh"
    #endif
    let body = "set -eu\nshim_move_flag=\(flag)\npayload_dir='\(bin.path)'\npeer_dir='\(peer.path)'\n" + function + block + block
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", body]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: helper.path) == "../bin/relay-peer-link-linux-amd64")
    #expect(try String(contentsOf: helper, encoding: .utf8) == "bundled")
    #expect(try String(contentsOf: peer.appendingPathComponent("relay-peer-link.before-install"), encoding: .utf8) == "hand-placed")
}
