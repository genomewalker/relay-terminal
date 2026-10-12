import AppKit
import Testing
import WebKit
@testable import Relay

@MainActor
@Test("Real WebKit editor lays out, edits, and undoes across diff views")
func realWebKitEditorLifecycle() async throws {
    let pane = PaneModel(profile: .sshConfigHost("editor-test"), contentKind: .editor)
    let web = pane.editorRuntime.webView
    web.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let index = root.appendingPathComponent("Sources/Relay/Resources/Editor/index.html")
    web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    var ready = false
    for _ in 0..<100 {
        ready = (try? await web.evaluateJavaScript("typeof monaco !== 'undefined' && !!monaco.editor && typeof window.relayOpenDocument === 'function'")) as? Bool == true
        if ready { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ready)
    guard ready else { return }
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'test',path:'/tmp/test.swift',content:'let value = 1',language:'swift'})")
    _ = try await web.evaluateJavaScript("window.relayLayout()")
    let size = try await web.evaluateJavaScript("JSON.stringify({width:editor.getLayoutInfo().width,height:editor.getLayoutInfo().height,lines:document.querySelectorAll('.view-line').length})") as? String
    let data = try #require(size?.data(using: .utf8))
    let layout = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
    #expect((layout["width"] ?? 0) > 0)
    #expect((layout["height"] ?? 0) > 0)
    #expect((layout["lines"] ?? 0) > 0)
    _ = try await web.evaluateJavaScript("editor.executeEdits('test',[{range:currentModel.getFullModelRange(),text:'let value = 2'}]);editor.pushUndoStop();window.relayToggleLocalDiff();window.relayUndo(false)")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "let value = 1")
    _ = try await web.evaluateJavaScript("window.relayUndo(true)")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "let value = 2")
    for size in [NSSize(width: 320, height: 200), NSSize(width: 1200, height: 800), NSSize(width: 620, height: 410)] {
        web.setFrameSize(size)
        _ = try await web.evaluateJavaScript("window.relayLayout()")
        #expect(try await web.evaluateJavaScript("diffEditor.getModifiedEditor().getLayoutInfo().height > 0") as? Bool == true)
        #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "let value = 2")
    }
    _ = try await web.evaluateJavaScript("window.relayToggleLocalDiff();window.relayUndo(false)")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "let value = 1")
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'r-test',path:'/tmp/test.R',content:'x <- 1\\nprint(x)',language:'r'})")
    #expect(try await web.evaluateJavaScript("currentModel.getLanguageId()") as? String == "r")
    #expect(try await web.evaluateJavaScript("editor.getAction('relay.runRSelection').isSupported()") as? Bool == true)
    let capture = EditorRunCapture()
    web.configuration.userContentController.removeScriptMessageHandler(forName: "relay")
    web.configuration.userContentController.add(capture, name: "relay")
    _ = try await web.evaluateJavaScript("editor.setPosition({lineNumber:2,column:1});editor.getAction('relay.runRSelection').run();void 0")
    for _ in 0..<20 where capture.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(capture.messages.last?["code"] as? String == "print(x)")
    #expect(capture.messages.last?["documentID"] as? String == "r-test")
    capture.messages.removeAll()
    _ = try await web.evaluateJavaScript("editor.setSelection({startLineNumber:1,startColumn:1,endLineNumber:2,endColumn:9});editor.getAction('relay.runRSelection').run();void 0")
    for _ in 0..<20 where capture.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(capture.messages.last?["code"] as? String == "x <- 1\nprint(x)")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 1\nprint(x)")
    #expect(try await web.evaluateJavaScript("editor.getAction('relay.r.format').isSupported()") as? Bool == true)
    #expect(try await web.evaluateJavaScript("editor.getAction('relay.r.lint').isSupported()") as? Bool == true)
    capture.messages.removeAll()
    _ = try await web.evaluateJavaScript("editor.setPosition({lineNumber:2,column:3});editor.getAction('relay.r.help').run();void 0")
    for _ in 0..<20 where capture.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(capture.messages.last?["type"] as? String == "rHelp")
    #expect(capture.messages.last?["topic"] as? String == "print")
    #expect(capture.messages.last?["documentID"] as? String == "r-test")
    _ = try await web.evaluateJavaScript("editor.setSelection(currentModel.getFullModelRange());void 0")
    // A headless WebKit view cannot keep a native focus-tracked menu open. Verify
    // the secondary press is consumed and preserves the existing code selection.
    #expect(try await web.evaluateJavaScript("""
      (() => {
        const surface = editor.getDomNode(), rect = surface.getBoundingClientRect();
        const point = editor.getScrolledVisiblePosition({lineNumber:1,column:2});
        const x = rect.left + point.left + 1, y = rect.top + point.top + 5;
        const node = document.elementFromPoint(x,y);
        const event = new MouseEvent('mousedown', {button:2,clientX:x,clientY:y,bubbles:true,cancelable:true});
        node.dispatchEvent(event);
        return event.defaultPrevented && editor.getSelection().equalsRange(currentModel.getFullModelRange());
      })()
      """) as? Bool == true)
    _ = try await web.evaluateJavaScript("window.relayPaste('wrong', 'stale-document');void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 1\nprint(x)")
    _ = try await web.evaluateJavaScript("editor.setSelection(currentModel.getFullModelRange());window.relayPaste('plot(1)', 'r-test');void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "plot(1)")
    _ = try await web.evaluateJavaScript("editor.trigger('test','undo',{});void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 1\nprint(x)")
    _ = try await web.evaluateJavaScript("window.relayApplyRTool('format',{text:'x <- 2'});void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 2")
    _ = try await web.evaluateJavaScript("editor.trigger('test','undo',{});void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 1\nprint(x)")
    _ = try await web.evaluateJavaScript("window.relayApplyRTool('lint',{diagnostics:[{line:1,column:2,message:'Spacing',type:'style'}]});void 0")
    #expect(try await web.evaluateJavaScript("monaco.editor.getModelMarkers({owner:'relay-r'}).length") as? Int == 1)
    // Exercise the actual Monaco suggestion widget, not only a mocked provider.
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'r-complete',path:'/tmp/complete.R',content:'plo',language:'r'});editor.setPosition({lineNumber:1,column:4});editor.trigger('test','editor.action.triggerSuggest',{});void 0")
    var completionVisible = false
    for _ in 0..<50 {
        completionVisible = (try? await web.evaluateJavaScript("Array.from(document.querySelectorAll('.suggest-widget .monaco-list-row')).some(row => row.textContent.includes('plot'))")) as? Bool == true
        if completionVisible { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(completionVisible)
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "plo")
    _ = try await web.evaluateJavaScript("window.relayOpenDocument({documentID:'recovery-test',path:'/tmp/recovery.R',content:'x <- 1',recoveredContent:'x <- 2',language:'r'});void 0")
    #expect(try await web.evaluateJavaScript("currentModel.getValue()") as? String == "x <- 2")
    #expect(try await web.evaluateJavaScript("lastDirty") as? Bool == true)
    #expect(try await web.evaluateJavaScript("savedText") as? String == "x <- 1")
    web.stopLoading()
}

@MainActor
private final class EditorRunCapture: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String, ["runCode", "rHelp"].contains(type) else { return }
        messages.append(body)
    }
}
