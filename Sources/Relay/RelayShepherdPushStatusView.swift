import SwiftUI

@MainActor struct RelayShepherdPushStatusView: View {
    @ObservedObject var push: RelayShepherdPushController = .shared
    var body: some View {
        DisclosureGroup("Shepherd pane delivery") {
            ScrollView {
                Text(push.statusText).font(RelayTheme.font(size: 10.5, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }
}
