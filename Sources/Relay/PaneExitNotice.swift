import Foundation
import SwiftUI

/// Explains a pane whose program failed or ended soon after it started.
///
/// Relay keeps every exited pane and its final output. This decides only how
/// the end is explained: a quick or failed exit gets a danger banner that leaves
/// the output readable; any other exit keeps the existing session-ended notice.
/// Inputs are process metadata only (worker exit status and attach timing),
/// never terminal content.
struct PaneExitNotice: Equatable, Sendable {
    /// An exit sooner than this after the program started counts as a startup failure.
    static let quickExitWindow: TimeInterval = 10

    let program: String
    /// nil when the worker did not report a status; -1 is relayd's signal/wait failure.
    let exitStatus: Int?
    /// nil when Relay did not see this program start (for example a restored pane).
    let elapsed: TimeInterval?

    /// The notice for an exit, or nil when the exit is an ordinary, intentional end.
    static func decide(program: String, exitStatus: Int?, elapsed: TimeInterval?,
                       userInitiated: Bool) -> PaneExitNotice? {
        guard !userInitiated else { return nil }
        let quick = elapsed.map { $0 >= 0 && $0 < quickExitWindow } ?? false
        let failed = exitStatus.map { $0 != 0 } ?? false
        guard quick || failed else { return nil }
        return PaneExitNotice(program: program, exitStatus: exitStatus, elapsed: elapsed)
    }

    var title: String {
        let after = elapsed.map { " after \(Self.duration($0))" } ?? ""
        switch exitStatus {
        case .some(-1): return "\(program) was terminated\(after)"
        case .some(let status): return "\(program) exited with status \(status)\(after)"
        case .none: return "\(program) exited\(after)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 {
            let tenths = (seconds * 10).rounded(.down) / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))s" : String(format: "%.1fs", tenths)
        }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return whole % 3600 / 60 == 0 ? "\(whole / 3600)h" : "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    /// A short program name from the pane's launch command. An empty command
    /// starts the login shell.
    static func programName(command: String) -> String {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let skipped: Set<String> = ["exec", "env", "command", "nohup"]
        guard let token = tokens.first(where: { !skipped.contains($0) && !$0.contains("=") }) else { return "Shell" }
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? "Shell" : name
    }
}

/// Compact danger banner for a pane that failed soon after starting.
struct FailedPaneExitBanner: View {
    let notice: PaneExitNotice
    let runAgain: () -> Void
    let close: () -> Void
    let dismiss: () -> Void

    var body: some View {
        RelayBanner(role: .danger, title: notice.title, message: "The output above is kept.") {
            Button("Run again", action: runAgain)
                .buttonStyle(RelayPrimaryButtonStyle())
                .lineLimit(1).fixedSize()
                .help("Start the same command in a new session")
                .accessibilityIdentifier("relay.failed-pane.run-again")
            Button("Close pane", action: close)
                .buttonStyle(RelaySecondaryButtonStyle())
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("relay.failed-pane.close")
            RelayIconAction("Hide notice", symbol: "xmark", size: .compact, action: dismiss)
        }
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.Radius.card, style: .continuous))
        .frame(maxWidth: 560)
        .accessibilityIdentifier("relay.failed-pane.banner")
    }
}
