import Foundation
import Testing
@testable import Relay

@Suite("Native conversation presentation")
struct RelayNativeItemPresentationTests {
    private func item(_ role: String, _ text: String) -> RelayNativeItem {
        RelayNativeItem(id: "fixture", role: role, text: text, tool: nil, status: nil, sequence: 1, truncated: nil)
    }

    @Test func roleAndSourceArePreserved() {
        let source = "# Result\n```swift\nlet x = 1\n```\n🧬"
        for role in ["assistant", "user", "tool", "system", "unknown"] {
            let presentation = RelayNativeItemPresentation(item: item(role, source))
            #expect(presentation.isAssistant == (role == "assistant"))
            #expect(Array(presentation.preview.utf8) == Array(source.utf8))
            #expect(!presentation.isPreviewLimited)
        }
    }

    @Test func unfinishedFenceAndLargeMessageAreSafe() {
        let source = "Before\n```swift\nlet x = 1"
        let presentation = RelayNativeItemPresentation(item: item("assistant", source))
        #expect(RelayAgentMarkdownBlocks.split(presentation.preview) == [.markdown(source)])
        let huge = String(repeating: "a", count: 200_000)
        let large = RelayNativeItemPresentation(item: item("assistant", huge))
        #expect(large.isPreviewLimited)
        #expect(large.preview.utf8.count <= RelayNativeItemPresentation.maximumPreviewBytes)
        #expect(Array(large.item.text.utf8) == Array(huge.utf8))
        #expect(!RelayNativeItemPresentation(item: item("tool", huge)).isPreviewLimited)
        let unicode = String(repeating: "a", count: 65_535) + "🧬suffix"
        let cut = RelayNativeItemPresentation(item: item("assistant", unicode))
        #expect(cut.preview.utf8.count == 65_535)
        #expect(Array(cut.item.text.utf8) == Array(unicode.utf8))
    }
}
