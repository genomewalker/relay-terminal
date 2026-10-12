import Foundation

/// Installed applications must never depend on the developer's build directory.
/// SwiftPM's command-line accessor searches beside the app rather than inside
/// Contents/Resources, so use the packaged bundle explicitly in an app build.
enum RelayResources {
    static let bundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL else { return nil }
            return Bundle(url: resources.appendingPathComponent("Relay_Relay.bundle"))
        }
        return Bundle.module
    }()
}
