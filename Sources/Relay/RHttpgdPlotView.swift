import AppKit
import SwiftUI

/// History navigation and a resize-aware live plot for one httpgd connection.
/// Every action here is a read or an explicit history edit; nothing evaluates R.
struct RHttpgdPlotView: View {
    @ObservedObject var connection: RHttpgdConnection
    var floatPlot: (() -> Void)? = nil
    var savePlot: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
            HStack(spacing: RelayTheme.spacing(8)) {
                RelayIconAction("Previous plot", symbol: "chevron.left") { connection.selectPrevious() }
                    .disabled((connection.selectedIndex ?? 0) == 0)
                    .accessibilityLabel("Previous plot")
                Text(positionText).font(.caption).monospacedDigit()
                RelayIconAction("Next plot", symbol: "chevron.right") { connection.selectNext() }
                    .disabled(connection.selectedIndex.map { $0 + 1 >= connection.plotIDs.count } ?? true)
                    .accessibilityLabel("Next plot")
                Button(connection.unseenPlotCount > 0 ? "Latest (\(connection.unseenPlotCount) new)" : "Latest") { connection.selectNewest() }.disabled(connection.followsNewest || connection.plotIDs.isEmpty)
                    .help("Show the newest plot and follow new plots")
                Spacer()
                if connection.rendering { ProgressView().controlSize(.small) }
                if let floatPlot {
                    RelayIconAction("Open plots in floating window", symbol: "arrow.up.right.square", action: floatPlot)
                }
                if let savePlot {
                    RelayIconAction("Save displayed plot…", symbol: "square.and.arrow.down", action: savePlot)
                        .disabled(connection.imageBytes == nil)
                }
                Menu("More") {
                    Button("Remove plot…") {
                        confirm("Remove this plot from httpgd history?") { await connection.removeSelected() }
                    }.disabled(connection.selectedID == nil)
                    Divider()
                    Button("Clear plot history…") {
                        confirm("Clear the entire httpgd plot history?") { await connection.clearHistory() }
                    }.disabled(connection.plotIDs.isEmpty)
                }.menuStyle(.borderlessButton).fixedSize()
                    .help("Plot history actions")

            }.controlSize(.small).font(RelayTheme.font(size: 12))
            GeometryReader { proxy in
                ZStack {
                    Color.white
                    if let image = connection.image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .accessibilityLabel(connection.hasStaleImage ? "Last httpgd plot, disconnected" : "httpgd plot")
                            .overlay(alignment: .topLeading) {
                                if connection.hasStaleImage {
                                    Text("Last plot · disconnected")
                                        .font(.caption).padding(RelayTheme.spacing(6))
                                        .background(.regularMaterial)
                                        .padding(RelayTheme.spacing(8))
                                }
                            }
                    } else {
                        Text(connection.status).font(RelayTheme.font(size: 11)).foregroundStyle(.secondary).padding(RelayTheme.spacing(8))
                    }
                }
                .onChange(of: proxy.size, initial: true) { _, size in
                    connection.setViewport(size: size, scale: NSApp?.keyWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
                }
            }
            .frame(minHeight: 120)
            Text(connection.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var positionText: String {
        if connection.hasStaleImage { return "Last plot" }
        guard let index = connection.selectedIndex else { return "No plot" }
        return "Plot \(index + 1) of \(connection.plotIDs.count)"
    }

    private func confirm(_ message: String, action: @escaping @MainActor () async -> Void) {
        let alert = RelayTheme.alert()
        alert.messageText = message
        alert.informativeText = "This changes the plot history inside the R session's httpgd device."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Continue")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { @MainActor in await action() }
    }
}
