import Foundation
import Testing
@testable import Relay

@Suite("Reviewer Accounts UX missing identity")
@MainActor
struct ReviewerAccountsUXTests {
 @Test("A pinned workspace cannot be verified when the fresh provider response has no workspace key")
 func missingPinnedWorkspaceMustNotFinish() throws {
  let started=Date()
  let object:[String:Any]=["provider":"codex","label":"personal","dir":"/fixture/.codex-personal",
   "root":"/fixture/.codex-personal","default":false,"exists":true,"logged_in":"yes","probe":"ok"]
  let status=try JSONDecoder().decode(RelayAgentAccountStatus.self,from:JSONSerialization.data(withJSONObject:object)).probed(at:started.addingTimeInterval(1))
  let usage=try JSONDecoder().decode(RelayAgentAccountUsage.self,from:Data(#"{"provider":"codex","label":"personal","status":"ok","read_at":"2026-10-18T07:00:00Z","windows":[],"email":"fixture@example.invalid","plan":"pro","identity_key":"1111aaaa1111aaaa"}"#.utf8))
  let outcome=RelayAgentLoginMonitor.outcome(status:status,checkStarted:started,freshUsage:usage,
   provider:"codex",replacing:false,replacedKey:nil,paneClosed:false,
   expected:.init(workspace:"Business",plan:"pro",key:"2222bbbb2222bbbb"))
  if case .finished = outcome {Issue.record("Sign-in finished even though its pinned workspace could not be checked")}
 }
}
