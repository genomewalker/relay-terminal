import AppKit
import SwiftUI

// Visual language adapted from Monocode (https://github.com/hardbeat920/monocode,
// commit 5c00fe2, MIT License, Copyright (c) 2026 Nick): content-derived ink at
// small opacities, a quiet centred transcript column, compact disclosure rows.
// Only the design values are adapted; no Monocode source code is included.

/// Shared tokens for the native agent conversation.
enum RelayAgentDesign {
    // Ink: every surface is the content colour at a low opacity, so light and dark follow the system.
    static let stroke = RelayTheme.stroke
    static let wash = RelayTheme.wash
    static let bubble = RelayTheme.bubble
    static let codeFill = RelayTheme.codeFill
    static let composerFill = RelayTheme.composerFill
    static let secondaryInk = RelayTheme.textMuted
    static let tertiaryInk = RelayTheme.textFaint
    static let failureInk = RelayTheme.red

    // Type. Prose stays readable; tool output and code are denser.
    static let prose = RelayTheme.body
    static let proseLineSpacing: CGFloat = 4
    static let mono = RelayTheme.code
    static let monoLineSpacing: CGFloat = 4
    static let meta = RelayTheme.caption
    static let label = RelayTheme.label

    // Layout.
    static let columnWidth: CGFloat = RelayTheme.contentWidth
    static let gutter: CGFloat = RelayTheme.spacing(RelayTheme.gutter)
    static let turnSpacing: CGFloat = 22
    static let blockSpacing: CGFloat = 8
    static let radius: CGFloat = RelayTheme.cornerRadius(8)
    static let nearBottom: CGFloat = 16
    static let userLineClamp = 4
    static let codeCollapseLines = 24
}

/// A compact row that reveals detail below it, keeping the hover wash while open.
struct RelayAgentDisclosureRow<Label: View, Detail: View>: View {
    /// Stable accessibility identifier for the toggle; unique per item and block.
    let axID: String
    @Binding var open: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var detail: () -> Detail
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            Button { open.toggle() } label: {
                HStack(spacing: RelayTheme.spacing(6)) {
                    label()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(RelayTheme.font(size: 10, weight: .semibold))
                        .foregroundStyle(RelayAgentDesign.tertiaryInk)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, RelayTheme.spacing(6)).padding(.vertical, RelayTheme.spacing(4))
                .background(open || hovering ? RelayAgentDesign.wash : .clear,
                            in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier(axID + ".disclosure")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { detail().padding(.leading, RelayTheme.spacing(22)) }
        }
        .animation(.easeOut(duration: 0.12), value: open)
    }
}

// Compatibility names; the app-wide template owns the actual controls.
typealias RelayAgentPrimaryButtonStyle = RelayPrimaryButtonStyle
typealias RelayAgentQuietButtonStyle = RelayQuietButtonStyle

/// One-line notice shown above the transcript, e.g. an approval waiting in the terminal.
struct RelayAgentNotice: View {
    let symbol: String
    let text: String
    var tint: Color = RelayAgentDesign.secondaryInk
    var body: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Image(systemName: symbol).font(RelayTheme.font(size: 11, weight: .semibold))
            Text(text).font(RelayTheme.font(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(6))
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
    }
}

enum RelayAgentClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
