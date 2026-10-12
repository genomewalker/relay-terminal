import SwiftUI

struct PluginGitDashboard: View {
    let files: [String]
    let selected: String
    let text: String
    let inspect: (String) -> Void
    @State private var search = ""

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: RelayTheme.spacing(14)) {
                fileList.frame(width: 210)
                Rectangle().fill(RelayTheme.line).frame(width: 1)
                inspector.frame(minWidth: 320)
            }
            VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                fileList.frame(height: 160)
                Rectangle().fill(RelayTheme.line).frame(height: 1)
                inspector
            }
        }.frame(maxHeight: .infinity)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                Text("\(files.count) changed files").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                TextField("Find file", text: $search)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                        ForEach(files.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { file in
                            Button { inspect(file) } label: {
                                Label(file, systemImage: "doc.text")
                                    .font(RelayTheme.font(size: 11)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(RelayTheme.spacing(8))
                                    .background(selected == file ? RelayTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)))
                            }.buttonStyle(.plain).accessibilityLabel("Review \(file)")
                        }
                    }
                }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                Text(selected.isEmpty ? "Worktree" : selected).font(RelayTheme.font(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if selected.isEmpty {
                    Text(files.isEmpty ? "No tracked changes in this directory." : "Select a file to review its staged and unstaged changes.")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line).font(RelayTheme.font(size: 11, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("+") ? RelayTheme.accent : line.hasPrefix("-") ? RelayTheme.coral : RelayTheme.text)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PluginProjectDashboard: View {
    let entries: [String]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                Text("Project tools").font(RelayTheme.font(size: 12, weight: .medium))
                if entries.isEmpty { Text("No supported project configuration found in this directory.").foregroundStyle(RelayTheme.textMuted) }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let lines = entry.components(separatedBy: "\n")
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                        Label(lines.first ?? "Project", systemImage: "hammer").font(RelayTheme.font(size: 12, weight: .medium))
                        Text(lines.dropFirst().joined(separator: "\n")).font(RelayTheme.font(size: 11, design: .monospaced))
                            .foregroundStyle(RelayTheme.textMuted).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(RelayTheme.spacing(12))
                        .background(RelayTheme.line.opacity(0.2), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                }
                Text("Use Run project command to review and execute a command.").font(.caption).foregroundStyle(RelayTheme.textMuted)
            }
        }
    }
}
