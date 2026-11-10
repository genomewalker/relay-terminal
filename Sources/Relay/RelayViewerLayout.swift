import SwiftUI

/// One layout for every viewer shown in a pane or in its own window (View
/// CLI conversation first): the same header row, spacing, type and colours
/// as the pane header (`ConnectionPath`), so a viewer reads as part of the
/// pane instead of a second app with its own chrome.
enum RelayViewerMetrics {
    /// The pane header's row height.
    static func barHeight(compact: Bool) -> CGFloat { compact ? 28 : 34 }
    static let barPadding: CGFloat = 12
    static let barSpacing: CGFloat = 8
    static let iconSize: CGFloat = 24

    /// The pane name's weight and size in the pane header.
    static let title = RelayTheme.font(size: 11.5, weight: .medium)
    /// Secondary text (host, directory) in the pane header.
    static let meta = RelayTheme.font(size: 11, weight: .medium)
    /// Identifiers (the short pane id) in the pane header.
    static let identifier = RelayTheme.font(size: 10, weight: .medium, design: .monospaced)
    /// The pane header's icon controls.
    static let icon = RelayTheme.font(size: 9.5, weight: .medium)
    /// The pane header's close glyph, drawn last on the right of every bar.
    static let closeSymbol = "xmark"
}

/// A viewer's header row: a symbol and title, faint metadata, trailing
/// controls, then close, always last on the right, at the pane header's
/// height, inset and icon size. Every in-window viewer uses this bar, so its
/// close button is in the same place everywhere.
struct RelayViewerBar<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    /// Identifiers read best monospaced; a sentence ("You're caught up") does not.
    var detailMonospaced: Bool
    var detailColor: Color
    var close: (() -> Void)?
    var closeLabel: String
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, title: String, detail: String? = nil, detailMonospaced: Bool = true,
         detailColor: Color = RelayTheme.textFaint, close: (() -> Void)? = nil, closeLabel: String = "Close",
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.detailMonospaced = detailMonospaced
        self.detailColor = detailColor
        self.close = close
        self.closeLabel = closeLabel
        self.trailing = trailing
    }

    var body: some View {
        frame {
            Image(systemName: symbol)
                .font(RelayViewerMetrics.icon)
                .foregroundStyle(RelayTheme.textFaint)
                .accessibilityHidden(true)
            Text(title)
                .font(RelayViewerMetrics.title)
                .foregroundStyle(RelayTheme.text)
                .lineLimit(1)
                .layoutPriority(2)
            if let detail {
                Text(detail)
                    .font(detailMonospaced ? RelayViewerMetrics.identifier : RelayViewerMetrics.meta)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: RelayViewerMetrics.barSpacing)
        } trailing: {
            trailing()
        }
    }

    private func frame<Leading: View, Controls: View>(@ViewBuilder leading: @escaping () -> Leading,
                                                      @ViewBuilder trailing: @escaping () -> Controls) -> some View {
        RelayViewerBarFrame(close: close, closeLabel: closeLabel, leading: leading, trailing: trailing)
    }
}

/// The bar's frame for a viewer with its own leading content (a floating
/// pane's drag handle): the pane header's height, inset and background,
/// trailing controls, then close last on the right.
struct RelayViewerBarFrame<Leading: View, Trailing: View>: View {
    var close: (() -> Void)?
    var closeLabel: String = "Close"
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: RelayTheme.spacing(RelayViewerMetrics.barSpacing)) {
            leading()
            trailing()
            if let close {
                RelayViewerIconButton(title: closeLabel, symbol: RelayViewerMetrics.closeSymbol, action: close)
                    .focusEffectDisabled()
                    .help(closeLabel)
                    .accessibilityIdentifier("relay.viewer.close")
            }
        }
        .padding(.horizontal, RelayTheme.spacing(RelayViewerMetrics.barPadding))
        .frame(height: RelayViewerMetrics.barHeight(compact: preferences.compactInterface))
        .background(RelayTheme.canvas)
    }
}

extension RelayViewerBar where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, detailMonospaced: Bool = true,
         detailColor: Color = RelayTheme.textFaint, close: (() -> Void)? = nil, closeLabel: String = "Close") {
        self.init(symbol: symbol, title: title, detail: detail, detailMonospaced: detailMonospaced,
                  detailColor: detailColor, close: close, closeLabel: closeLabel) { EmptyView() }
    }
}

/// A strip under the bar for paging or notices, inset like the bar.
struct RelayViewerStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: RelayTheme.spacing(RelayViewerMetrics.barSpacing)) { content() }
            .font(RelayViewerMetrics.meta)
            .foregroundStyle(RelayTheme.textMuted)
            .padding(.horizontal, RelayTheme.spacing(RelayViewerMetrics.barPadding))
            .frame(minHeight: RelayViewerMetrics.barHeight(compact: true))
    }
}

/// An icon control sized and coloured like the pane header's.
struct RelayViewerIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(RelayViewerMetrics.icon)
                .frame(width: RelayViewerMetrics.iconSize, height: RelayViewerMetrics.iconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(RelayViewerIconButtonStyle())
        .accessibilityLabel(title)
    }
}

/// A menu's icon label sized like the bar's icon buttons.
struct RelayViewerMenuLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(RelayViewerMetrics.icon)
            .foregroundStyle(RelayTheme.textMuted)
            .frame(width: RelayViewerMetrics.iconSize, height: RelayViewerMetrics.iconSize)
            .contentShape(Rectangle())
    }
}

struct RelayViewerIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? RelayTheme.text : RelayTheme.textMuted)
            .opacity(enabled ? 1 : 0.4)
            .background(configuration.isPressed ? RelayTheme.wash : .clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)))
    }
}

/// Bar, one hairline, then the viewer's content on the pane's canvas.
struct RelayViewerLayout<Bar: View, Content: View>: View {
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            bar()
            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
            content()
        }
        .background(RelayTheme.canvas)
    }
}
