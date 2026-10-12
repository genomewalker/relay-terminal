import SwiftUI
import WebKit

/// Loads only the bundled renderer. Producer input is passed as JSON data.
struct RelayRichContentView: NSViewRepresentable {
    let kind: RelaySurfaceContent.Kind
    let source: String
    var inline = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.input = input
        if let root = RelayResources.bundle?.url(forResource: "RichContent", withExtension: nil) {
            let page = root.appendingPathComponent("viewer/index.html")
            context.coordinator.page = page
            view.loadFileURL(page, allowingReadAccessTo: root)
        }
        return view
    }
    private var input: String {
        let data = try? JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "source": source, "inline": inline])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.input != input else { return }
        context.coordinator.input = input
        context.coordinator.render(view)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var page: URL?
        var input = "{}"
        var ready = false
        func render(_ view: WKWebView) {
            guard ready else { return }
            view.evaluateJavaScript("window.renderRelaySurface(\(input)); void 0", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(webView)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url == page && navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}
