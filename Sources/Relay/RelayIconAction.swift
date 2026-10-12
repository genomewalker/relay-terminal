import SwiftUI

/// Compact chrome with the same discoverable name for pointer and assistive use.
struct RelayIconAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(RelayTheme.font(size: 12, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(hovering ? RelayTheme.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Menu labels share the rail button's geometry rather than AppKit defaults.
struct RelayToolbarMenuIcon: View {
    let symbol: String
    let title: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(RelayTheme.font(size: 12, weight: .medium))
            .frame(width: 30, height: 30, alignment: .center)
            .contentShape(Rectangle())
            .background(hovering ? RelayTheme.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
    }
}
