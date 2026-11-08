import SwiftUI

/// Compact chrome with the same discoverable name for pointer and assistive use.
struct RelayIconAction: View {
    /// Button side length. `legacy` keeps today's 30 pt until call sites move to `regular`.
    enum Size {
        case regular, compact, legacy

        var side: CGFloat {
            switch self {
            case .regular: RelayTheme.Control.height
            case .compact: RelayTheme.Control.compactIcon
            case .legacy: 30
            }
        }
    }

    let title: String
    let symbol: String
    let size: Size
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, size: Size = .legacy, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(RelayTheme.font(size: size == .compact ? 11 : 12, weight: .medium))
                .frame(width: size.side, height: size.side)
                .contentShape(Rectangle())
                .background(hovering ? RelayTheme.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(size == .compact ? 6 : 8),
                                                 style: .continuous))
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
