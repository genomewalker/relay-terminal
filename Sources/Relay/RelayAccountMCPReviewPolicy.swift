import Foundation

/// Render untrusted configuration names without control characters or values.
enum RelayAccountMCPReviewPolicy {
    static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
    }
    static func lines(_ preview: RelayAgentAccountMCPPreview) -> String? {
        guard preview.servers.count <= 40 else { return nil }
        var rows: [String] = []
        for server in preview.servers {
            guard safe(server.name), (server.envKeys ?? []).count <= 64, (server.headerKeys ?? []).count <= 64,
                  (server.envKeys ?? []).allSatisfy(safe), (server.headerKeys ?? []).allSatisfy(safe) else { return nil }
            let env = (server.envKeys ?? []).joined(separator: ", ")
            let headers = (server.headerKeys ?? []).joined(separator: ", ")
            var line = server.name + (server.excluded ? " (excluded)" : "")
            if !env.isEmpty { line += " · environment keys: " + env }
            if !headers.isEmpty { line += " · header keys: " + headers }
            rows.append(line)
        }
        let result = rows.isEmpty ? "No servers" : rows.joined(separator: "\n")
        return result.utf8.count <= 6000 ? result : nil
    }
}
