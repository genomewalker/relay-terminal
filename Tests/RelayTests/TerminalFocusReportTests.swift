import Foundation
import Testing
@testable import Relay

@Test func terminalFocusReportsAreIdentifiedAndDeliveredWithoutClassifyingKeysOrPastes() {
    let reports = [
        ("\u{001B}[I", "focus_in"), ("\u{001B}[O", "focus_out"),
        ("\u{001B}[O\u{001B}[I", "focus_multiple"),
        ("\u{001B}[I\u{001B}[I\u{001B}[O", "focus_multiple")
    ]
    for (text, name) in reports {
        let data = Data(text.utf8)
        #expect(TerminalFocusReport.name(data) == name)
        for filtering in [false, true] {
            #expect(TerminalWriteForwardingPolicy.shouldForward(data, filteringDeviceResponses: filtering))
        }
    }
    for text in ["", "a", "\u{001B}[A", "\u{001B}[Ia", "\u{001B}[O\u{001B}[Ia", "\u{001B}[O\u{001B}[", "\u{001B}[I\u{001B}[A", "\u{001B}[200~\u{001B}[I\u{001B}[201~", "\u{001B}", "[I"] {
        #expect(TerminalFocusReport.name(Data(text.utf8)) == nil)
    }
}

@Test func terminalInputDiagnosticsUseOnlyReportCategories() {
    for (text, expected) in [
        ("\u{001B}[O\u{001B}[I", "focus_multiple"),
        ("\u{001B}[?1;2c", "device_response"),
        ("\u{001B}[<35;12;4M", "mouse_motion"),
        ("\u{001B}[<51;12;4M", "mouse_motion"),
        ("\u{001B}[<64;12;4M", "mouse_wheel"),
        ("\u{001B}[<81;12;4M", "mouse_wheel"),
        ("\u{001B}[<32;12;4M", "mouse_button"),
        ("\u{001B}[<0;12;4M", "mouse_button"),
        ("\u{001B}[<35;12;4Mtext", "none"),
        ("\u{001B}[<35;12;M", "none"),
        ("\u{001B}[<35;;12;4M", "none"),
        ("private draft", "none")
    ] {
        #expect(TerminalInputDiagnosticReport.name(Data(text.utf8)) == expected)
    }
}
