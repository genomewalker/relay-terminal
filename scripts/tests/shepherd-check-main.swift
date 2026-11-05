import Foundation

@main struct ShepherdCheckMain {
    static func main() {
        do { try run() } catch { print("SHEPHERD FAILURE: \(error)"); exit(1) }
    }
    static func run() throws {
        var failures: [String] = []
        func check(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch { failures.append(name + ": " + String(describing: error)) }
        }
        check("changes") { try RelayShepherdChecks.smoke() }
        check("push smoke and recurrence") { try RelayShepherdPushChecks.smoke() }
        check("push authorization") { print("SH2 push authorization cases=\(try RelayShepherdPushChecks.authorization())") }
        check("budget") { try RelayShepherdChecks.budget() }
        check("authorization") {
            let names = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
            let auth = try RelayShepherdChecks.authorization(catalog: names.compactMap { $0["name"] as? String })
            print("SHEPHERD authorization states=\(auth)")
        }
        if !CommandLine.arguments.contains("--smoke") {
            check("bounded budget") { print("SHEPHERD bounded model budget length=4 states=\(try RelayShepherdChecks.boundedBudget())") }
            check("bounded report") { print("SHEPHERD bounded length=4 panes<=3 states=\(try RelayShepherdChecks.bounded())") }
            check("push bounded") { print("SH2 push bounded visits=\(try RelayShepherdPushChecks.bounded())") }
            check("push fuzz") { try RelayShepherdPushChecks.fuzz() }
            check("fuzz") { try RelayShepherdChecks.fuzz() }
        }
        guard failures.isEmpty else { throw RelayShepherdChecks.Failure(description: failures.joined(separator: "\n")) }
        print("SHEPHERD PASS")
    }
}
