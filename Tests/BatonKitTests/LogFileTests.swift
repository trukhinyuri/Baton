import Foundation
import Testing

@testable import BatonKit

@Suite("Baton's own log")
struct LogFileTests {
    private let fm = FileManager.default

    private func folder() -> URL {
        fm.temporaryDirectory.appending(path: "baton-log-\(UUID().uuidString)/Logs", directoryHint: .isDirectory)
    }

    @Test func writesTimeLevelAndPart() throws {
        let log = LogFile(folder: folder())
        defer { try? fm.removeItem(at: log.folder.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        log.append(level: .notice, category: "restart", message: "Restarted window work\nand more", at: date)
        let text = try String(contentsOf: log.current, encoding: .utf8)
        #expect(text == "\(date.formatted(.iso8601)) notice [restart] Restarted window work and more\n", "one line per entry")
        let mode = try fm.attributesOfItem(atPath: log.current.path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "private to the user")
    }

    /// Capped at maxBytes per file and keep files: the oldest lines go, the newest stay, and nothing grows past the cap.
    @Test func rotatesAtTheCap() throws {
        let log = LogFile(folder: folder(), maxBytes: 200, keep: 3)
        defer { try? fm.removeItem(at: log.folder.deletingLastPathComponent()) }
        for i in 0..<60 { log.append(level: .info, category: "sync", message: "pass \(i) wrote 3 cards") }
        let files = try fm.contentsOfDirectory(atPath: log.folder.path).filter { $0.hasPrefix("baton.log") }.sorted()
        #expect(files == ["baton.log", "baton.log.1", "baton.log.2"])
        for file in files {
            let size = try fm.attributesOfItem(atPath: log.folder.appending(path: file).path)[.size] as? Int ?? 0
            #expect(size <= 200)
        }
        let tail = log.tail(limit: 5)
        #expect(tail.count == 5)
        #expect(tail.last?.hasSuffix("pass 59 wrote 3 cards") == true)
        #expect(tail.first?.hasSuffix("pass 55 wrote 3 cards") == true, "oldest first, across the rotated files")
        #expect(!log.tail(limit: 1_000).contains { $0.hasSuffix("pass 0 wrote 3 cards") }, "the oldest file was dropped")
    }

    /// The report attaches the log's last lines after the redaction it applies to everything else.
    @Test func theReportRedactsTheLog() throws {
        let log = LogFile(folder: folder())
        defer { try? fm.removeItem(at: log.folder.deletingLastPathComponent()) }
        let token = "sk-ant-" + String(repeating: "a1B2", count: 10)
        log.append(level: .error, category: "sync", message: "Can't read /Users/robin.k/src/secret-app: denied for robin@corp.example")
        log.append(level: .error, category: "cli", message: "Rejected key \(token)")
        let facts = FeedbackReport.Facts(
            build: BuildInfo(version: "1.0.0", commit: "abc1234"), macOS: "15.1", architecture: "arm64", claudeVersion: "2.9939.4",
            windows: [], diagnostics: [], lastSync: nil, lastSyncDate: nil, errors: [], log: log.tail(limit: FeedbackReport.logLimit),
            home: "/Users/robin.k", user: "robin.k", profiles: [])
        let markdown = FeedbackReport(facts: facts).markdown
        #expect(markdown.contains("error [sync] Can't read <folder>: denied for <email-1>"))
        #expect(markdown.contains("error [cli] Rejected key <token>"))
        #expect(!markdown.contains("robin") && !markdown.contains(token) && !markdown.contains("secret-app"))
    }

    /// On a fresh Mac the data folder appears only at the first sync or `baton add`, after the log was enabled at
    /// start: the lines from then on are kept, and none before it creates the folder.
    @Test func startsWritingOnceTheDataFolderExists() throws {
        let data = fm.temporaryDirectory.appending(path: "baton-fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: data) }
        let sink = Log.Sink()
        sink.dataFolder = data
        #expect(sink.file == nil)
        #expect(!fm.fileExists(atPath: data.path))
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        sink.file?.append(level: .info, category: "add", message: "Added profile work")
        #expect(sink.file?.tail(limit: 1).first?.hasSuffix("info [add] Added profile work") == true)
        try fm.removeItem(at: data)
        #expect(sink.file == nil, "moved away while running: no line recreates it")
        #expect(!fm.fileExists(atPath: data.path))
    }

    /// The log never creates Baton's data folder: a missing one could be a folder of the earlier name that isn't
    /// reachable right now.
    @Test func neverCreatesTheDataFolder() {
        let missing = fm.temporaryDirectory.appending(path: "baton-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        Log.enableFile(in: missing)
        Log.info("test", "nothing to write into")
        #expect(!fm.fileExists(atPath: missing.path))
    }
}
