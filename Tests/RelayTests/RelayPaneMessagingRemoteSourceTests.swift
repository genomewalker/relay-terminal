import Foundation
import Testing
@testable import Relay

@Test("A remote sender is delivered only with its own host's attestation")
func remoteSourceRequiresHostAttestation() {
    #expect(RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: false, sourceAuthentication: "unverified"))
    #expect(RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: false, sourceAuthentication: "unconfirmed"))
    // A label the broker could forge never substitutes for redemption on the source host.
    #expect(RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: false, sourceAuthentication: "kernel_verified"))
    #expect(RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: false, sourceAuthentication: ""))
    #expect(!RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: false, sourceAuthentication: "source_host_attested"))
    // Same-Mac senders keep their existing labelled path.
    #expect(!RelayPaneMessaging.rejectsUnprovenRemoteSource(sourceIsLocal: true, sourceAuthentication: "unverified"))
}

@Test("A broker-supplied proof diagnostic is decoded but never part of message identity")
func proofErrorIsDiagnosticOnly() throws {
    let source = UUID(), message = UUID()
    let decoded = try JSONDecoder().decode(RelayPaneMessaging.Request.self, from: Data(
        #"{"sourcePaneID":"\#(source)","messageID":"\#(message)","text":"hi","sourceProofError":"attest: relayd: no unique live pane owns this client"}"#.utf8))
    #expect(decoded.sourceProofError == "attest: relayd: no unique live pane owns this client")
    #expect(decoded.sourceAttestation == nil && decoded.sourceSignature == nil)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let identity = RelayPaneMessaging.Request(sourcePaneID: source, messageID: message, text: "hi")
    #expect(try encoder.encode(identity) == encoder.encode(RelayPaneMessaging.Request(
        sourcePaneID: decoded.sourcePaneID, messageID: decoded.messageID, text: decoded.text)))
}

@Test("Receipt diagnostics are bounded and single-line")
func receiptDiagnosticIsBounded() {
    let text = RelayPaneMessaging.receiptDiagnostic(String(repeating: "a\n\u{7}", count: 400))
    #expect(text.count <= 512)
    #expect(!text.contains("\n") && !text.unicodeScalars.contains { $0.value < 32 })
}
