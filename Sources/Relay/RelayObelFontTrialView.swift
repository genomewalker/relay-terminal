import SwiftUI

struct RelayObelFontTrialView: View {
    @ObservedObject var preferences: RelayPreferences
    var body: some View {
        if RelayBundledFonts.registered {
            HStack {
                if preferences.fontFamily == "Obel Mono", preferences.obelTrialPreviousFamily != nil {
                    Button("Undo Obel Mono trial") { preferences.undoObelFontTrial() }
                } else if preferences.fontFamily != "Obel Mono" {
                    Button("Try Obel Mono") { preferences.beginObelFontTrial() }
                }
            }.buttonStyle(.link).font(.caption)
                .help("Optional terminal font. Your previous font can be restored with Undo.")
        }
    }
}
