import Foundation
import Testing
@testable import Relay

@Test func subscriptionQuotaNativeCommandPreservesHostAndPaneArguments() {
    let panes = ["01234567-89ab-cdef-0123-456789abcdef", "literal'pane"]
    let (local, arguments) = RelaySubscriptionQuotaStore.quotaReadInvocation(profile: .local, panes: panes)
    #expect(local.lastPathComponent == "relayd")
    #expect(local.path.hasSuffix("/Contents/MacOS/relayd"))
    #expect(arguments == ["subscription-quota"] + panes)
    let remote = ConnectionProfile.sshConfigHost("quota-command-fixture.invalid")
    let (ssh, remoteArguments) = RelaySubscriptionQuotaStore.quotaReadInvocation(profile: remote, panes: panes)
    #expect(ssh.path == "/usr/bin/ssh")
    #expect(Array(remoteArguments.dropLast()) == ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + remote.sshConnectionArguments)
    #expect(remoteArguments.last == "\"$HOME/.local/bin/relayd\" 'subscription-quota' '01234567-89ab-cdef-0123-456789abcdef' 'literal'\\''pane'")
}
