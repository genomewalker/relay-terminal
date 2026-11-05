import AppKit
import CoreText
import Foundation

/// Register bundled terminal fonts for this process only. No system font install.
@MainActor
enum RelayBundledFonts {
    static let registered: Bool = {
        guard let bundle = RelayResources.bundle else { return false }
        for name in ["ObelMono-Regular", "ObelMono-Bold", "ObelMono-Italic", "ObelMono-BoldItalic"] {
            guard let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { return false }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { return false }
            }
        }
        return NSFont(name: "Obel Mono", size: 13.5) != nil
    }()
}
