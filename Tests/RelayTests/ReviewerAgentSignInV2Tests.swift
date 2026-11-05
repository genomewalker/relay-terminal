import Foundation
import Testing
@testable import Relay

@Suite("Reviewer v2 sign-in security contracts", .serialized)
struct ReviewerAgentSignInV2Tests {
 func home() throws -> URL {
  let home=FileManager.default.temporaryDirectory.appendingPathComponent("reviewer-signin-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  return home
 }
 func run(home:URL,id:String,script:String) throws -> Int32 {
  let p=Process()
  p.executableURL=URL(fileURLWithPath:"/bin/sh")
  p.arguments=["-c",script]
  p.environment=["HOME":home.path,"RELAY_SIGNIN_ID":id,"PATH":"/usr/bin:/bin"]
  p.standardOutput=FileHandle.nullDevice
  p.standardError=FileHandle.nullDevice
  try p.run();p.waitUntilExit();return p.terminationStatus
 }
 let authURL="https://claude.com/cai/oauth/authorize?state=FIXTUREONLY"
 @Test("A predictable helper temporary path must not follow a symlink")
 func helperTempSymlink() throws {
  let h=try home();defer{try? FileManager.default.removeItem(at:h)}
  let dir=h.appendingPathComponent(".relay/signin")
  try RelayAgentSignIn.installHelper(in:dir)
  let precious=h.appendingPathComponent("precious")
  try Data("KEEP".utf8).write(to:precious)
  let id=UUID().uuidString.lowercased()
  let script=#"ln -s "$HOME/precious" "$HOME/.relay/signin/.$RELAY_SIGNIN_ID.$$"; exec "$HOME/.relay/signin/relay-signin-browser" 'https://claude.com/cai/oauth/authorize?state=FIXTUREONLY'"#
  _=try run(home:h,id:id,script:script)
  let data=try String(contentsOf:precious,encoding:.utf8)
  #expect(data=="KEEP","helper followed its pre-existing temporary symlink and overwrote the target")
 }
 @Test("A pre-existing helper temporary file cannot leave the URL world-readable")
 func helperTempPermissions() throws {
  let h=try home();defer{try? FileManager.default.removeItem(at:h)}
  let dir=h.appendingPathComponent(".relay/signin")
  try RelayAgentSignIn.installHelper(in:dir)
  let id=UUID().uuidString.lowercased()
  let script=#": > "$HOME/.relay/signin/.$RELAY_SIGNIN_ID.$$"; chmod 0644 "$HOME/.relay/signin/.$RELAY_SIGNIN_ID.$$"; exec "$HOME/.relay/signin/relay-signin-browser" 'https://claude.com/cai/oauth/authorize?state=FIXTUREONLY'"#
  _=try run(home:h,id:id,script:script)
  let url=dir.appendingPathComponent(id+".url")
  if FileManager.default.fileExists(atPath:url.path){
   let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
   #expect((attributes[.posixPermissions] as? Int)==0o600,"helper reused a public temporary file")
  }
 }
 @Test("The helper must reject IDs that its consumer will never accept")
 func invalidHelperID() throws {
  let h=try home();defer{try? FileManager.default.removeItem(at:h)}
  let dir=h.appendingPathComponent(".relay/signin")
  try RelayAgentSignIn.installHelper(in:dir)
  let status=try run(home:h,id:"deadbeef",script:#"exec "$HOME/.relay/signin/relay-signin-browser" 'https://claude.com/cai/oauth/authorize?state=FIXTUREONLY'"#)
  #expect(status != 0,"helper accepted a non-UUID ID")
  #expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("deadbeef.url").path),"unconsumable authorization URL was stored")
 }
 @Test("The consumer must refuse a hand-off with public permissions")
 func consumerPermissions() throws {
  let h=try home();defer{try? FileManager.default.removeItem(at:h)}
  let dir=h.appendingPathComponent(".relay/signin")
  try RelayAgentSignIn.installHelper(in:dir)
  let id=UUID().uuidString.lowercased(), file=dir.appendingPathComponent(id+".url")
  try Data(authURL.utf8).write(to:file)
  try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
  #expect(RelayAgentSignIn.takeURL(id:id,in:dir)==nil,"consumer accepted a world-readable authorization hand-off")
 }
 @Test("A hand-off cannot be returned repeatedly if unlink fails")
 func unlinkFailure() throws {
  let h=try home();let dir=h.appendingPathComponent(".relay/signin")
  defer{try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path);try? FileManager.default.removeItem(at:h)}
  try RelayAgentSignIn.installHelper(in:dir)
  let id=UUID().uuidString.lowercased(), file=dir.appendingPathComponent(id+".url")
  try Data(authURL.utf8).write(to:file)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
  try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:dir.path)
  let first=RelayAgentSignIn.takeURL(id:id,in:dir)
  let second=RelayAgentSignIn.takeURL(id:id,in:dir)
  #expect(first==nil || second==nil,"the same sign-in hand-off was returned twice after unlink failed")
 }
 @Test("Every accepted code-state shape must be redacted, including in diagnostics")
 func shortStateRedaction() {
  let value="AbCdEfGh123_-#x"
  #expect(RelayAgentSignIn.validClaudeCode(value))
  #expect(!RelayAgentSignIn.redact(value).contains(value),"accepted code-state value remains in redacted text")
  #expect(!RelayDiagnostics.redact(value).contains(value),"accepted code-state value remains in exported diagnostics")
 }
 @Test("A warning or shell command containing the paste phrase is not a login prompt")
 func falsePastePrompt() {
  #expect(!RelayAgentSignIn.awaitsCode("Login complete; do not paste code here again"))
  #expect(!RelayAgentSignIn.awaitsCode("$ echo 'paste code here'"))
 }
 @Test("A documentation link in hostile pane output must not become the sign-in URL")
 func documentationURLInjection() {
  let viewport="Enter code ABCD-12345\nFor background: https://claude.com/blog"
  #expect(RelayAgentLoginURL.find(in:viewport)==nil,"a non-authentication URL was selected for automatic sign-in presentation")
 }
}
