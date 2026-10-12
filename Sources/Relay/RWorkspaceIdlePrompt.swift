import Foundation

/// Automatic bootstrap is deliberately narrower than explicit user input.
/// A generic `>` can be a shell continuation; only an empty radian prompt is
/// recognised without an already established companion identity.
enum RWorkspaceIdlePrompt {
    static func accepts(_ viewport: String?) -> Bool {
        guard let viewport, let line = viewport.split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        return line.trimmingCharacters(in: .whitespaces).range(
            of: #"^(\[(ins|nav)\]\s*)?r\$>\s*$"#, options: .regularExpression
        ) != nil
    }
}
