import Foundation
func mustRefuse(_ action: () throws -> Void) throws {
    do { try action(); fatalError("unexpectedly accepted") } catch is Investigation.Failure {}
}
let finding = Investigation.Finding(claim: "claim", evidence: "git object")
let counter = Investigation.Finding(claim: "contradicted", evidence: "independent check")
var b = try Investigation(coordinator: "lead", assignments: [("one","ancestry"),("two","equivalence")])
try mustRefuse { try b.submit(finding, at: 0, from: "one") }
try mustRefuse { try b.respond(0, from: "two") }
try b.respond(0, from: "one", refusal: "outside my scope")
try mustRefuse { try b.followUp(for: 0, from: "lead", investigator: "three", question: "recheck") }
try b.respond(1, from: "two")
try b.submit(finding, at: 1, from: "two")
try b.submit(finding, at: 1, from: "two")
try mustRefuse { try b.review(1, from: "two", confirmed: true, check: finding) }
try b.review(1, from: "lead", confirmed: false, check: counter)
try b.followUp(for: 1, from: "lead", investigator: "three", question: "recheck raw object")
try b.respond(2, from: "three")
try b.submit(counter, at: 2, from: "three")
try b.review(2, from: "lead", confirmed: true, check: counter)
precondition(!b.complete && b.assignments[0].phase == .refused && b.assignments[1].phase == .disputed)
try mustRefuse { try b.followUp(for: 0, from: "lead", investigator: "four", question: "extra round") }
print("refusal, wrong owner, duplicate return, disputed evidence, bounded follow-up, unresolved branch: PASS")
