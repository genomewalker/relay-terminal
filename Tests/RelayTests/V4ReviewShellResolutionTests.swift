import Foundation
import Testing
@testable import Relay

@Suite("Revision 4 independent shell resolution")
@MainActor struct V4ReviewShellResolutionTests {
    @Test("Default Codex account must keep Relay's managed shim after an environment reorders PATH")
    func defaultLaunchMustKeepManagedShim() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("relay-v4-shell-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Ported: the managed marker sits where relayd installs the shims
        // (~/.local/share/relay/shims), the file the pinned command names.
        let shim=root.appendingPathComponent(".local/share/relay/shims"), other=root.appendingPathComponent("environment")
        for (directory,marker) in [(shim,"managed"),(other,"unmanaged")] {
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            let file=directory.appendingPathComponent("codex")
            try Data(("#!/bin/sh\nprintf '"+marker+":%s\\n' \"${CODEX_HOME+set}\"\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        }
        let account=RelayAgentAccount(provider:"codex",label:"work",dir:"")
        let script="function codex { command '"+shim.appendingPathComponent("codex").path+"' \"$@\"; }\nexport PATH='"+other.path+":/usr/bin:/bin'\n"+account.launchCommand("codex")
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/bash");p.arguments=["--noprofile","--norc","-c",script]
        p.environment=["HOME":root.path,"PATH":shim.path+":/usr/bin:/bin","CODEX_HOME":"/synthetic/personal"]
        let pipe=Pipe();p.standardOutput=pipe;try p.run();p.waitUntilExit()
        let output=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        #expect(p.terminationStatus==0)
        #expect(output=="managed:","The actual default launch command bypassed the managed function and used a PATH executable")
    }
}
