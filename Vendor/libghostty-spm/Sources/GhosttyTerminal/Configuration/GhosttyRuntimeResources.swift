import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// App bundles copy SwiftPM assets into Contents/Resources. Never evaluate
    /// Bundle.module in that case: its generated fallback embeds a build path
    /// which can block on File Provider or disappear after distribution.
    private static func resourceURL(_ name: String) -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL else { return nil }
            let packaged = resources.appendingPathComponent("GhosttyKit_GhosttyTerminal.bundle", isDirectory: true)
            let wrapped = packaged.appendingPathComponent("Contents/Resources", isDirectory: true)
            let root = FileManager.default.fileExists(atPath: wrapped.path) ? wrapped : packaged
            let url = root.appendingPathComponent(name, isDirectory: true)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: nil)
    }
    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        resourceURL("Ghostty")
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        resourceURL("terminfo")
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
