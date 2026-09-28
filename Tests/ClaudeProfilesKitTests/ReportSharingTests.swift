import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Sharing a problem report")
struct ReportSharingTests {
    private func facts(logLines: Int, home: String = "/Users/robin.k") -> FeedbackReport.Facts {
        FeedbackReport.Facts(
            build: BuildInfo(version: "1.0.0", commit: "abc1234"), macOS: "Version 15.1 (Build 24B83)",
            architecture: "arm64", claudeVersion: "0.14.1",
            windows: [.init(id: "main", label: "MAIN", isMain: true, isRunning: true, isSignedIn: true)],
            diagnostics: [], lastSync: nil, lastSyncDate: nil, errors: ["Can’t open \(home)/src/app"],
            log: (0..<logLines).map { "sync: pass \($0) wrote 3 cards and left 12 alone in 41 ms" },
            home: home, user: "robin.k", profiles: [])
    }

    /// The decoded value of `name` in the URL's query.
    private func query(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @Test func issueURLUnderCap() throws {
        let short = FeedbackReport(facts: facts(logLines: 3))
        let link = short.issueLink(title: "Sync stops", description: "It stopped after I added LAB & WORK?")
        #expect(link.isComplete)
        #expect(link.url.absoluteString.hasPrefix("https://github.com/\(FeedbackReport.repository)/issues/new?template=bug_report.yml&title="))
        #expect(query("title", in: link.url) == "Sync stops")
        #expect(query("diagnostics", in: link.url) == short.markdown)
        #expect(query("what-happened", in: link.url) == "It stopped after I added LAB & WORK?")
        #expect(!link.url.absoluteString.contains("+"), "spaces and plus signs are percent-encoded")

        let long = FeedbackReport(facts: facts(logLines: 200))
        let longLink = long.issueLink(title: "", description: String(repeating: "Very long description. ", count: 600))
        #expect(!longLink.isComplete)
        let diagnostics = try #require(query("diagnostics", in: longLink.url))
        let comps = URLComponents(url: longLink.url, resolvingAgainstBaseURL: false)
        let diagnosticsEncoded = try #require(comps?.percentEncodedQueryItems?.first { $0.name == "diagnostics" }?.value)
        let whatHappenedEncoded = try #require(comps?.percentEncodedQueryItems?.first { $0.name == "what-happened" }?.value)
        #expect(diagnosticsEncoded.count + whatHappenedEncoded.count <= FeedbackReport.urlBodyLimit)
        #expect(diagnostics.hasPrefix("Claude Profiles 1.0.0 (abc1234)"))
        #expect(diagnostics.contains("attach"))
        #expect(query("title", in: longLink.url) == "Problem report")
    }

    @Test func longReportGoesToClipboardAndFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied: [String] = [], opened: [URL] = []

        let long = FeedbackReport(facts: facts(logLines: 200))
        let shared = try long.share(
            title: "", description: "Sessions vanish", saveIn: folder,
            copy: { copied.append($0) }, open: { opened.append($0) })
        let file = try #require(shared.file)
        #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(file.pathExtension == "md")
        #expect(try String(contentsOf: file, encoding: .utf8) == long.document(description: "Sessions vanish"))
        #expect(copied == [long.document(description: "Sessions vanish")])
        #expect(opened == [shared.link.url])
        #expect(query("diagnostics", in: shared.link.url)?.contains(file.lastPathComponent) == true)

        copied = []; opened = []
        let short = FeedbackReport(facts: facts(logLines: 2))
        let quick = try short.share(title: "x", description: "", saveIn: folder, copy: { copied.append($0) }, open: { opened.append($0) })
        #expect(quick.file == nil)
        #expect(copied.isEmpty)
        #expect(opened == [quick.link.url])
    }

    @Test func descriptionIsMarkedAsNotRedacted() {
        let report = FeedbackReport(facts: facts(logLines: 1))
        let text = report.document(description: "My folder /Users/robin.k/src/app broke")
        #expect(text.hasPrefix("Claude Profiles 1.0.0 (abc1234)"))
        #expect(text.contains("not redacted"))
        #expect(text.contains("/Users/robin.k/src/app broke"), "the user's own words are kept as written")
        #expect(!report.document(description: "  ").contains("not redacted"))
    }

    @Test func cliReportPassesLeakScanner() throws {
        let box = try LeakFixture()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let saved = box.root.appending(path: "out/report.md")
        var copied: [String] = [], opened: [URL] = []
        let output = try FeedbackReport.command(
            ["report", "--save", saved.path, "--open"], paths: box.paths, user: box.user,
            errors: box.errors, log: box.log, downloads: box.root,
            copy: { copied.append($0) }, open: { opened.append($0) })
        let file = try String(contentsOf: saved, encoding: .utf8)
        #expect(output.contains(file.trimmingCharacters(in: .newlines)))
        #expect(output.contains("Nothing was sent"))
        #expect(opened.count == 1)
        let url = try #require(opened.first)
        for text in [output, file, url.absoluteString.removingPercentEncoding ?? ""] + copied {
            let leaks = LeakScanner.leaks(in: text.replacingOccurrences(of: saved.path, with: ""), secrets: box.secrets)
            #expect(leaks.isEmpty, "Leaked: \(leaks)\n\n\(text)")
        }

        let printed = try FeedbackReport.command(
            ["report"], paths: box.paths, user: box.user, errors: [], log: [],
            downloads: box.root, copy: { _ in Issue.record("copied") }, open: { _ in Issue.record("opened") })
        #expect(printed.hasPrefix(BuildInfo.current.description))
        #expect(throws: FeedbackReport.CommandError.self) {
            try FeedbackReport.command(["report", "--save"], paths: box.paths, downloads: box.root, copy: { _ in }, open: { _ in })
        }
    }
}
