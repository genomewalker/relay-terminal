import Foundation
import Testing
@testable import Relay

@Test("Plugin Markdown uses inert native formatting and retains its source")
func pluginArtifactMarkdown() {
    let source = "# Title\n\n**Strong** and `code` [link](https://example.invalid)\n\n![image](https://example.invalid/image.png)"
    guard case .markdown(let original, let formatted, let partial) = PluginArtifactPreview.decode(Data(source.utf8), path: "README.md") else {
        Issue.record("Expected Markdown preview"); return
    }
    #expect(original == source)
    #expect(!partial)
    #expect(String(formatted.characters).contains("Strong"))
    #expect(String(formatted.characters).contains("Title\n\nStrong"))
    #expect(formatted.runs.allSatisfy { $0.link == nil })
}

@Test("Plugin artifact tables handle quoting and refuse malformed or wide input")
func pluginArtifactTables() {
    #expect(PluginArtifactPreview.table("name,value\r\n\"a,b\",\"two\"\"quotes\"\n", separator: ",") == [["name", "value"], ["a,b", "two\"quotes"]])
    #expect(PluginArtifactPreview.table("\"two\nlines\",x", separator: ",") == [["two\nlines", "x"]])
    #expect(PluginArtifactPreview.table("\"unterminated", separator: ",") == nil)
    #expect(PluginArtifactPreview.table("\"closed\"junk", separator: ",") == nil)
    #expect(PluginArtifactPreview.table(String(repeating: "x,", count: 33), separator: ",") == nil)
    #expect(PluginArtifactPreview.table(String(repeating: "x\n", count: 200), separator: ",")?.count == 101)
}

@Test("Plugin previews keep HTML inert and detect binary and partial UTF8")
func pluginArtifactText() {
    if case .text(let value, _) = PluginArtifactPreview.decode(Data("<script>bad()</script>".utf8), path: "a.html") {
        #expect(value == "<script>bad()</script>")
    } else { Issue.record("HTML must remain text") }
    if case .binary = PluginArtifactPreview.decode(Data([0, 1]), path: "a.txt") {} else { Issue.record("binary accepted") }
    let data = Data((String(repeating: "a", count: 128 * 1024 - 1) + "€suffix").utf8)
    if case .text(let value, let partial) = PluginArtifactPreview.decode(data, path: "a.txt") {
        #expect(partial); #expect(value.count == 128 * 1024 - 1)
    } else { Issue.record("UTF8 truncation lost preview") }
}
