import AppKit
import SwiftUI

/// The toolbar globe: the floating browser for the active pane's host.
struct WorkspaceBrowserLauncher: View {
    @ObservedObject var workspace: WorkspaceModel
    var body: some View {
        Button {
            guard let pane = workspace.activePane else { return }
            RelayBrowserController.shared.open(nil, profile: pane.profile, directory: pane.directory,
                                               near: NSApp.keyWindow)
        } label: { Image(systemName: "globe").frame(width: 30, height: 30) }
        .buttonStyle(.plain)
        .help("Browser · localhost is the active pane's host")
        .accessibilityLabel("Open browser")
        .disabled(workspace.activePane == nil)
    }
}
