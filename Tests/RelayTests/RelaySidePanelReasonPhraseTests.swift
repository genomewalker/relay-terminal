import Foundation
import Testing
@testable import Relay

// U-K2: channel refusals carried "Conflict" for every non-403 status, so the
// Keychain-pending refusal went out as "503 Conflict".
@Suite struct RelaySidePanelReasonPhraseTests {
    @Test func statusesCarryTheirStandardReasonPhrase() {
        let expected: [Int: String] = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                                        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                                        500: "Internal Server Error", 503: "Service Unavailable"]
        for (status, phrase) in expected {
            #expect(RelaySidePanelHTTPResponse.reasonPhrase(for: status) == phrase)
        }
    }

    @Test func channelRefusalsUseTheReasonOfTheirStatus() throws {
        let body: [String: Any] = ["error": "fixture"]
        func line(_ status: Int) throws -> String {
            let response = try RelaySidePanelHTTPResponse.channelReply(status: status, value: body)
            #expect(response.status == status)
            return String(decoding: response.wireData.prefix { $0 != 0x0D }, as: UTF8.self)
        }
        #expect(try line(503) == "HTTP/1.1 503 Service Unavailable")
        #expect(try line(409) == "HTTP/1.1 409 Conflict")
        #expect(try line(403) == "HTTP/1.1 403 Forbidden")
        #expect(try line(200) == "HTTP/1.1 200 OK")
        let reply = try RelaySidePanelHTTPResponse.channelReply(status: 503, value: body)
        #expect(reply.contentType == "application/json; charset=utf-8")
        #expect((try JSONSerialization.jsonObject(with: reply.body) as? [String: String]) == ["error": "fixture"])
    }
}
