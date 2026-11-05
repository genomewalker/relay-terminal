import Foundation

/// After an app update, moves this Mac's live pane workers onto the bundled
/// relayd in place (`relayd upgrade-workers`: same PID, shell and PTY), once
/// per build. Workers already on it and legacy workers that predate in-place
/// upgrade are left as they are; busy panes (mid-edit or mid-rotation) are
/// retried 10 times, 30 s apart. The receipt lists each pane's result.
/// Remote hosts do the same at the end of their relayd install.
enum RelayLocalWorkerUpgrade {
    struct Summary: Equatable {
        var counts: [String: Int] = [:]
    }

    /// Counts per result, from `relayd upgrade-workers` JSON output.
    static func summary(of output: Data) -> Summary? {
        guard let rows = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return nil }
        var summary = Summary()
        for row in rows {
            let result = row["result"] as? String ?? "unknown"
            summary.counts[result, default: 0] += 1
        }
        return summary
    }

    /// A build's receipt; once it exists, that build's upgrade has run.
    static func receiptURL(root: URL, build: String) -> URL {
        root.appendingPathComponent("upgrade-workers", isDirectory: true)
            .appendingPathComponent("build-\(build).json")
    }

    static func shouldRun(build: String?, root: URL, isolated: Bool) -> Bool {
        guard !isolated, let build, !build.isEmpty,
              build.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return !FileManager.default.fileExists(atPath: receiptURL(root: root, build: build).path)
    }

    static func runAtLaunchIfNeeded(isolated: Bool) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let root = RelayStateProfile.applicationSupportRoot
        guard shouldRun(build: build, root: root, isolated: isolated), let build else { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd")
        DispatchQueue.global(qos: .utility).async {
            run(executable: executable, build: build, root: root)
        }
    }

    static func run(executable: URL, build: String, root: URL) {
        let process = Process()
        LocalRelayProcess.configure(process)
        process.executableURL = executable
        process.arguments = ["upgrade-workers"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            RelayDiagnostics.shared.record(category: "app", name: "worker-upgrade-failed",
                                           details: ["build": build, "reason": "launch"])
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let summary = summary(of: data) else {
            // No receipt: the next launch of this build tries again.
            RelayDiagnostics.shared.record(category: "app", name: "worker-upgrade-failed",
                                           details: ["build": build, "status": String(process.terminationStatus)])
            return
        }
        let receipt = receiptURL(root: root, build: build)
        do {
            try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: receipt, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        } catch {}
        var details = ["build": build]
        for (result, count) in summary.counts { details[result] = String(count) }
        RelayDiagnostics.shared.record(category: "app", name: "worker-upgrade", details: details)
    }
}
