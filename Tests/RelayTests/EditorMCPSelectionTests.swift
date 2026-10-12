import AppKit
import Foundation
import Testing
import WebKit
@testable import Relay

@Test @MainActor func mcpSelectionRejectsChangedDocumentAndReturnsExactCode() async throws {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    let web = pane.editorRuntime.webView
    web.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let index = root.appendingPathComponent("Sources/Relay/Resources/Editor/index.html")
    web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    var ready = false
    for _ in 0..<100 {
        ready = (try? await web.evaluateJavaScript("typeof monaco === 'object' && typeof window.relaySelectForMCP === 'function'")) as? Bool == true
        if ready { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ready)
    guard ready else { return }
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'mcp-test',path:'/tmp/test.R',content:'x <- 1\\nprint(x)',language:'r'})")
    let request: [String: Any] = ["documentID":"mcp-test", "expectedContent":"x <- 1\nprint(x)",
        "range":["startLineNumber":2,"startColumn":1,"endLineNumber":2,"endColumn":9]]
    let data = try JSONSerialization.data(withJSONObject: request)
    let script = "window.relaySelectForMCP(\(String(decoding: data, as: UTF8.self)))"
    _ = try await web.evaluateJavaScript("editor.setPosition({lineNumber:1,column:2})")
    let selection = try #require(try await web.evaluateJavaScript(script) as? [String: Any])
    #expect(try await web.evaluateJavaScript("editor.getPosition().lineNumber") as? Int == 1)
    #expect(try await web.evaluateJavaScript("editor.getPosition().column") as? Int == 2)
    #expect(selection["code"] as? String == "print(x)")
    _ = try await web.evaluateJavaScript("editor.getModel().setValue('x <- 2\\nprint(x)')")
    do {
        _ = try await web.evaluateJavaScript(script)
        Issue.record("Accepted a selection after the live document changed")
    } catch { /* Expected: stale native mirror must not select or execute different code. */ }

    let edit: [String: Any] = ["documentID": "mcp-test", "expectedContent": "x <- 2\nprint(x)",
        "range": ["startLineNumber": 1, "startColumn": 1, "endLineNumber": 1, "endColumn": 7],
        "text": "x <- 'λ'", "save": false]
    let editData = try JSONSerialization.data(withJSONObject: edit)
    let editScript = "window.relayEditForMCP(\(String(decoding: editData, as: UTF8.self)))"
    #expect(try await web.evaluateJavaScript(editScript) as? String == "x <- 'λ'\nprint(x)")
    do {
        _ = try await web.evaluateJavaScript(editScript)
        Issue.record("Accepted a stale editor replacement")
    } catch { /* Expected: the live model changed. */ }
    _ = try await web.evaluateJavaScript("window.relayUndo(false)")
    #expect(try await web.evaluateJavaScript("editor.getModel().getValue()") as? String == "x <- 2\nprint(x)")
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'disk-test',path:'/tmp/test.R',content:'x <- 1',language:'r'})")
    #expect(try await web.evaluateJavaScript("window.relayRefreshFromDisk({documentID:'disk-test',expectedContent:'x <- 1',content:'x <- 42 // λ'})") as? Bool == true)
    #expect(try await web.evaluateJavaScript("editor.getModel().getValue()") as? String == "x <- 42 // λ")
    _ = try await web.evaluateJavaScript("editor.executeEdits('test', [{range:editor.getModel().getFullModelRange(),text:'unsaved'}])")
    #expect(try await web.evaluateJavaScript("window.relayRefreshFromDisk({documentID:'disk-test',expectedContent:'x <- 42 // λ',content:'external'})") as? Bool == false)
    #expect(try await web.evaluateJavaScript("editor.getModel().getValue()") as? String == "unsaved")
    #expect(try await web.evaluateJavaScript("window.relayRefreshFromDisk({documentID:'other',expectedContent:'unsaved',content:'external'})") as? Bool == false)
}
