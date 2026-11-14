import Foundation
import Testing
@testable import Relay

@Suite struct RelayQuickLookTests {
    private let remote = ConnectionProfile(name: "quicklook", kind: .ssh, host: "quicklook.invalid", backend: .relay)

    @Test func extractsURLsAndPathsInReadingOrder() {
        let screen = """
        Wrote /home/kbd606/project/out/report.pdf and ~/notes/todo.md.
        See [the docs](https://example.org/guide?x=1) and (https://example.org/guide?x=1).
        Changed Sources/Relay/RelayQuickLook.swift:42:7 and ./scripts/run.sh, ../data/table.tsv
        and/or 2026/11/14 km/h /review /tmp
        logs: "/var/log/app.log", /home/kbd606/project/out/report.pdf
        """
        #expect(RelayQuickLookLinks.extract(text: screen) == [
            .path("/home/kbd606/project/out/report.pdf"),
            .path("~/notes/todo.md"),
            .web(URL(string: "https://example.org/guide?x=1")!),
            .path("Sources/Relay/RelayQuickLook.swift"),
            .path("./scripts/run.sh"),
            .path("../data/table.tsv"),
            .path("/var/log/app.log"),
        ])
    }

    @Test func providerCommandRowsAndLimitAreRespected() {
        #expect(RelayQuickLookLinks.extract(text: "/review - review changes in /tmp/x.diff").isEmpty)
        let many = (0..<80).map { "/data/file\($0).txt" }.joined(separator: " ")
        #expect(RelayQuickLookLinks.extract(text: many).count == RelayQuickLookLinks.defaultLimit)
        #expect(RelayQuickLookLinks.extract(text: many, limit: 3).count == 3)
    }

    @Test func wordUnderAClickedColumn() {
        let line = "  open /srv/a.log or https://example.org now"
        #expect(RelayQuickLookLinks.target(in: line, column: 9) == .path("/srv/a.log"))
        #expect(RelayQuickLookLinks.target(in: line, column: 22) == .web(URL(string: "https://example.org")!))
        #expect(RelayQuickLookLinks.target(in: line, column: 4) == nil) // "open" is not a target
        #expect(RelayQuickLookLinks.target(in: line, column: 1) == nil) // whitespace
        #expect(RelayQuickLookLinks.target(in: line, column: 200) == nil)
    }

    @Test func hoveredLinksFromGhosttyAndRelay() {
        let encoded = TerminalLinkResolver.link(forRemotePath: "/home/kbd606/run/plot.png")
        #expect(RelayQuickLookLinks.target(fromLink: encoded) == .path("/home/kbd606/run/plot.png"))
        let file = TerminalLinkResolver.link(forRemotePath: "/home/kbd606/run/log.txt")
        #expect(RelayQuickLookLinks.target(fromLink: file) == .path("/home/kbd606/run/log.txt"))
        #expect(RelayQuickLookLinks.target(fromLink: "https://example.org/a") == .web(URL(string: "https://example.org/a")!))
        #expect(RelayQuickLookLinks.target(fromLink: "mailto:someone@example.org") == nil)
    }

    @Test func localPathsResolveAgainstHomeAndFolder() {
        let home = "/Users/someone"
        let resolve = { (path: String, cwd: String?) in
            RelayQuickLookItem.resolve(.path(path), location: .local(cwd: cwd), home: home)?.source
        }
        #expect(resolve("~/a/b.txt", nil) == .localFile("/Users/someone/a/b.txt"))
        #expect(resolve("/etc/hosts", nil) == .localFile("/etc/hosts"))
        #expect(resolve("./x/y.md", "/Users/someone/proj") == .localFile("/Users/someone/proj/x/y.md"))
        #expect(resolve("../y.md", "/Users/someone/proj") == .localFile("/Users/someone/y.md"))
        #expect(resolve("src/z.swift", nil) == nil) // no known folder: not guessed
        #expect(RelayQuickLookItem.resolve(.path("src/z.swift"), location: .local(cwd: "/w"), home: home)?.openLink == "/w/src/z.swift")
    }

    @Test func remotePathsAreResolvedByTheHost() {
        let item = RelayQuickLookItem.resolve(.path("out/r.pdf"), location: .remote(remote, cwd: "/home/u/p"))
        #expect(item?.source == .remoteFile(remote, path: "out/r.pdf", cwd: "/home/u/p"))
        #expect(item?.openLink == "/home/u/p/out/r.pdf")
        #expect(item?.subtitle == "quicklook.invalid · out/r.pdf")
        #expect(RelayQuickLookItem.resolve(.path("~/r.pdf"), location: .remote(remote, cwd: nil))?.source
            == .remoteFile(remote, path: "~/r.pdf", cwd: nil))
        #expect(RelayQuickLookItem.resolve(.path("out/r.pdf"), location: .remote(remote, cwd: nil)) == nil)
        #expect(RelayQuickLookItem.resolve(.path("/a/b.txt"), location: .unreadable) == nil)
        let web = URL(string: "https://example.org/x")!
        #expect(RelayQuickLookItem.resolve(.web(web), location: .unreadable)?.source == .web(web))
    }

    @Test func browserWrapsAndCountsPosition() throws {
        let items = ["/a.txt", "/b.txt", "/c.txt"].compactMap {
            RelayQuickLookItem.resolve(.path($0), location: .local(cwd: nil))
        }
        #expect(RelayQuickLookBrowser(items: []) == nil)
        var browser = try #require(RelayQuickLookBrowser(items: items, start: 2))
        #expect(browser.position == "3 of 3" && browser.current.title == "c.txt")
        browser.next()
        #expect(browser.index == 0)
        browser.previous()
        #expect(browser.index == 2)
        #expect(try #require(RelayQuickLookBrowser(items: items, start: 99)).index == 2)
        #expect(try #require(RelayQuickLookBrowser(items: [items[0]])).position == "")
    }

    @Test func stagedCopiesAreNamedSafelyAndRemoved() throws {
        #expect(RelayQuickLookStaging.sanitizedName("/x/y/report.final.pdf") == "report.final.pdf")
        #expect(RelayQuickLookStaging.sanitizedName("/x/.hidden.txt") == "hidden.txt")
        #expect(RelayQuickLookStaging.sanitizedName("/x/a\u{1B}[31mb.log") == "a[31mb.log")
        #expect(RelayQuickLookStaging.sanitizedName("/x/") == "x")
        #expect(RelayQuickLookStaging.sanitizedName("/") == "file")
        let long = String(repeating: "n", count: 300) + ".csv"
        let shortened = RelayQuickLookStaging.sanitizedName("/d/" + long)
        #expect(shortened.count <= 120 && shortened.hasSuffix(".csv"))

        let staging = try RelayQuickLookStaging()
        let first = try staging.write(Data("one".utf8), remotePath: "/h/same.txt")
        let second = try staging.write(Data("two".utf8), remotePath: "/other/same.txt")
        #expect(first != second && first.lastPathComponent == "same.txt")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        let mode = try FileManager.default.attributesOfItem(atPath: staging.directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        staging.remove()
        #expect(!FileManager.default.fileExists(atPath: staging.directory.path))
    }

    @Test func remoteFilesAreBoundedAndNeverFolders() throws {
        let ok = try RelayHostFiles.previewable(stat: ["size": 10, "version": "v1", "directory": false], maxBytes: 100)
        #expect(ok.size == 10 && ok.version == "v1")
        #expect(throws: (any Error).self) {
            try RelayHostFiles.previewable(stat: ["size": 4096, "version": "v1", "directory": true], maxBytes: 100)
        }
        #expect(throws: (any Error).self) {
            try RelayHostFiles.previewable(stat: ["size": 101, "version": "v1", "directory": false], maxBytes: 100)
        }
        #expect(throws: (any Error).self) {
            try RelayHostFiles.previewable(stat: ["size": 10, "directory": false], maxBytes: 100)
        }
        #expect(RelayHostFiles.previewMaxBytes == 32 << 20)
    }

    @Test func commandYIsTheUniqueDefault() {
        let binding = RelayCommand.quickLookVisible.defaultBinding
        #expect(binding == RelayKeyBinding("y", command: true))
        #expect(RelayCommand.allCases.filter { $0.defaultBinding == binding } == [.quickLookVisible])
        #expect(RelayCommand.quickLookVisible.section == "Panes")
    }

    @Test func clickedCellComesFromTheGridNotTheCursor() {
        let cell = { (x: CGFloat, y: CGFloat) in
            RelayQuickLookLinks.cell(at: CGPoint(x: x, y: y), origin: CGPoint(x: 4, y: 4), cellSize: CGSize(width: 8, height: 16))
        }
        #expect(cell(4, 4).map { [$0.row, $0.column] } == [0, 0])
        #expect(cell(4 + 8 * 9 + 7, 4 + 16 * 2 + 1).map { [$0.row, $0.column] } == [2, 9])
        #expect(cell(3, 10) == nil)
        #expect(RelayQuickLookLinks.cell(at: .init(x: 10, y: 10), origin: .zero, cellSize: .zero) == nil)
    }

    @Test func leftoverStagingFromAQuitIsRemoved() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("rqlt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stale = parent.appendingPathComponent(RelayQuickLookStaging.prefix + "old")
        let unrelated = parent.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let staging = try RelayQuickLookStaging(parent: parent)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: staging.directory.path))
    }
}
