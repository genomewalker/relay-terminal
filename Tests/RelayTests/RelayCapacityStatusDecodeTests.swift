import Foundation
import Testing
@testable import Relay

/// Pane bc08e46f (2026-11-19): every switch to personal was held with "The host
/// response could not be verified". The move reads capacity_status first; this is
/// that read's reply from the Mac's relayd for a pane that is not enrolled and
/// whose native evidence is incomplete.
@Suite("capacity_status replies from relayd decode")
struct RelayCapacityStatusDecodeTests {
    @Test func aNotEnrolledPaneWithIncompleteEvidenceDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("CapacityFixtures/status-not-enrolled-evidence-unavailable.json")
        let data = try Data(contentsOf: url)
        let status = try RelayCapacityManagement.decode(data, requestID: "capacity-9c3e5a32-2d4f-4b70-8c83-0000000000a1")
        #expect(status.state == "native_evidence_unavailable")
        #expect(!status.managed && !status.ready)
    }
}

@Suite("capacity action refusals from relayd keep their reason")
struct RelayCapacityRefusalDecodeTests {
    /// The installed relayd's exact reply to a manual move on bc08e46f.
    @Test func aManualMoveRefusalNamesWhatHeldIt() throws {
        let data = Data(#"{"error":"native capacity source/model evidence incomplete","request_id":"capacity-9c3e5a32-2d4f-4b70-8c83-000000000000"}"#.utf8)
        do {
            _ = try RelayCapacityManagement.decode(data, requestID: "capacity-9c3e5a32-2d4f-4b70-8c83-000000000000")
            Issue.record("a refusal decoded as a status")
        } catch let failure as RelayHostRotationRPC.Failure {
            #expect(failure.localizedDescription == "native capacity source/model evidence incomplete")
        }
    }
}

extension RelayCapacityRefusalDecodeTests {
    /// relayd's node answers a host request it could not run (all 64 request
    /// slots busy, or the handler failed) with `"result": null` beside the
    /// error. That named refusal must reach the user, not "could not be verified".
    @Test(arguments: ["host account RPC capacity reached", "invalid capacity envelope"])
    func aNodeRefusalWithANullResultKeepsItsReason(_ message: String) throws {
        let data = Data(#"{"request_id":"capacity-9c3e5a32-2d4f-4b70-8c83-000000000000","error":"\#(message)","result":null}"#.utf8)
        do {
            _ = try RelayCapacityManagement.decode(data, requestID: "capacity-9c3e5a32-2d4f-4b70-8c83-000000000000")
            Issue.record("a refusal decoded as a status")
        } catch let failure as RelayHostRotationRPC.Failure {
            #expect(failure.localizedDescription == message)
        }
    }
}

extension RelayCapacityRefusalDecodeTests {
    @Test func anErrorBesideARealResultStaysUnverified() {
        let data = Data(#"{"request_id":"capacity-9c3e5a32-2d4f-4b70-8c83-000000000000","error":"x","result":{"v":1}}"#.utf8)
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            _ = try RelayCapacityManagement.decode(data, requestID: "capacity-9c3e5a32-2d4f-4b70-8c83-000000000000")
        }
        do { _ = try RelayCapacityManagement.decode(data, requestID: "capacity-9c3e5a32-2d4f-4b70-8c83-000000000000") }
        catch { #expect(error.localizedDescription == RelayHostRotationRPC.Failure.invalidResponse.localizedDescription) }
    }
}
