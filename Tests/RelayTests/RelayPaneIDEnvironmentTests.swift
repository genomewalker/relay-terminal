import Foundation
import Testing
@testable import Relay

@Suite("Relay pane id environment")
struct RelayPaneIDEnvironmentTests {
    @Test func directExecPaneExportsItsOwnLowercasePaneID() {
        let pane = UUID(uuidString: "57C1DD5B-F283-4933-834B-D01625280261")!
        let environment = TerminalRuntime.directExecEnvironment(
            paneID: pane,
            base: ["RELAY_PANE_ID": "0e3d2a1c-0000-4000-8000-000000000001", "HOME": "/Users/test"]
        )
        #expect(environment["RELAY_PANE_ID"] == "57c1dd5b-f283-4933-834b-d01625280261")
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["TERM_PROGRAM"] == "relay")
    }
}
