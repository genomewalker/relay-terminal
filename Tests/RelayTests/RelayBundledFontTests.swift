import AppKit
import Testing
@testable import Relay

@MainActor @Test func bundledObelFontHasTerminalCharactersAndDoesNotChangeDefault() throws {
    #expect(RelayBundledFonts.registered)
    let font = try #require(NSFont(name: "Obel Mono", size: 13.5))
    #expect(font.isFixedPitch)
    for scalar in "0O1Il{}[]()<>$@#%&+-_=|;:.,abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars {
        #expect(font.coveredCharacterSet.contains(scalar))
    }
    let name = "relay-font-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("Menlo", forKey: "relay.settings.font-family")
    let preferences = RelayPreferences(defaults: defaults)
    #expect(preferences.fontFamily == "Menlo")
    preferences.beginObelFontTrial()
    #expect(preferences.fontFamily == "Obel Mono")
    #expect(preferences.resolvedFontFamily == "Obel Mono")
    #expect(preferences.obelTrialPreviousFamily == "Menlo")
    preferences.beginObelFontTrial()
    let restored = RelayPreferences(defaults: defaults)
    restored.undoObelFontTrial()
    #expect(restored.fontFamily == "Menlo")
    #expect(restored.obelTrialPreviousFamily == nil)
    restored.beginObelFontTrial()
    restored.fontFamily = "Courier"
    restored.undoObelFontTrial()
    #expect(restored.fontFamily == "Courier")
}
