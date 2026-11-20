import Foundation

// Replay adapter. Writes only the requested new task in a Miko journal.
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: rounds PILOT.json NEW-JOURNAL.json") }
struct Run: Decodable {
    struct Branch: Decodable { let model: String; let answers: [String: Bool]; let verified: Bool }
    let branches: [Branch]
    let sources: [String: String]
}
let pilot = try JSONDecoder().decode(Run.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let url = URL(fileURLWithPath: args[2])
let engine = try RelayMikoTaskEngine(url: url)
let task = "release-inclusion"
try engine.create(id: task, objective: "Check release inclusion by ancestry and patch equivalence", scope: "Frozen Git tree", checklist: [.init(id: "verify", text: "Verify both Git checks")])
var board = try Investigation(coordinator: "lead", assignments: [("sol", "Is the commit an ancestor?"), ("opus", "Is the patch equivalent?")])
func persist() throws {
    try engine.checkpoint(taskID: task, text: "Release inclusion review", completedItemIDs: board.complete ? ["verify"] : [], payload: JSONEncoder().encode(board))
}
try persist()
for (i, key) in ["A","B"].enumerated() {
    let branch = pilot.branches[i]
    guard let answer = branch.answers[key], let source = pilot.sources[key] else { fatalError("missing branch evidence") }
    // Process return is mapped to acceptance by this local replay fixture only.
    try board.respond(i, from: branch.model)
    try board.submit(.init(claim: String(answer), evidence: source), at: i, from: branch.model)
    try board.review(i, from: "lead", confirmed: branch.verified, check: .init(claim: "Compared to Git exit and patch sign", evidence: source))
    try persist()
}
let restored = try RelayMikoTaskEngine(url: url)
let payload = restored.snapshot.tasks[task]!.checkpointPayload!
let saved = try JSONDecoder().decode(Investigation.self, from: payload)
precondition(saved.complete)
print(String(decoding: payload, as: UTF8.self))
