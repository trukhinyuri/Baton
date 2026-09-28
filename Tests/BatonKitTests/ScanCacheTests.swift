import Foundation
import Testing

@testable import BatonKit

@Suite("Reading less on an idle refresh")
struct ScanCacheTests {
    private let fm = FileManager.default

    @Test func readsAFileAgainOnlyOnceItChanged() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let cache = ScanCache()
        let file = box.root.appending(path: "card.json")
        try Data("one".utf8).write(to: file)
        let read = { (url: URL) in try String(contentsOf: url, encoding: .utf8) }
        #expect(try cache.value("text", of: file, read: read) == "one")
        #expect(try cache.value("text", of: file, read: read) == "one")
        #expect(cache.reads == 1, "the second read came from memory")
        // Same size, same modification date set back by hand: the change time and inode still differ.
        let modified = try #require(SyncFolders.modificationDate(file))
        try Data("two".utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(try cache.value("text", of: file, read: read) == "two")
        #expect(cache.reads == 2)
        #expect(try cache.value("other", of: file) { _ in 7 } == 7, "another kind of read is kept apart")
        try fm.removeItem(at: file)
        #expect(throws: (any Error).self) { try cache.value("text", of: file, read: read) }
    }

    /// A fixture of many cards and transcripts: the first sync and Continue list read them all, an idle one reads
    /// none, and a change reads only what changed. Prints the times for the record.
    @Test func anIdleRefreshReadsNothing() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (cardsPerWindow, transcriptLines) = (300, 100)
        let a = try box.pair(box.main, account: Sandbox.accountA)
        _ = try box.pair(box.work, account: Sandbox.accountB)
        let project = box.paths.claudeProjectsDir.appending(path: "-Users-me-src-app", directoryHint: .isDirectory)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let record = String(repeating: "x", count: 160)
        for i in 0..<cardsPerWindow {
            let session = String(format: "00000000-0000-4000-8000-%012d", i)
            try Data(#"{"title":"Session \#(i)","cliSessionId":"\#(session)","cwd":"/Users/me/src/app"}"#.utf8)
                .write(to: a.appending(path: "local_\(i).json"))
            let lines = (0..<transcriptLines).map {
                #"{"type":"user","timestamp":"2026-09-28T10:00:\#(String(format: "%02d", $0 % 60)).000Z","text":"\#(record)"}"#
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appending(path: "\(session).jsonl"))
        }

        func refresh(_ cache: ScanCache) throws -> (seconds: Double, conversations: Int) {
            var sync = SessionSync(paths: box.paths, dataDirs: [box.main, box.work])
            sync.cache = cache
            sync.liveSessionIDs = []
            let start = Date()
            try sync.run(propagateDeletions: false)
            let found = ConversationIndex.scan(paths: box.paths, windows: [("main", box.main), ("work", box.work)], cache: cache)
            return (Date().timeIntervalSince(start), found.count)
        }

        let cache = ScanCache()
        let first = try refresh(cache)
        _ = try refresh(cache)  // reads the copies the first sync wrote into the second window
        let readsFirst = cache.reads
        // The same idle refresh as before this cache (everything read again), then with it.
        let fresh = ScanCache()
        let before = try refresh(fresh)
        let idle = try refresh(cache)
        #expect(first.conversations == cardsPerWindow && idle.conversations == cardsPerWindow)
        let idleReads = cache.reads - readsFirst
        #expect(idleReads == 0, "an idle refresh reads no card and no transcript again")

        // One transcript grows: only it is read again.
        let handle = try FileHandle(forWritingTo: project.appending(path: String(format: "00000000-0000-4000-8000-%012d.jsonl", 7)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","timestamp":"2026-09-28T11:00:00.000Z"}"#.utf8 + [10]))
        try handle.close()
        _ = try refresh(cache)
        #expect(cache.reads == readsFirst + 1)

        print(
            "ScanCache measurement: \(cardsPerWindow * 2) cards (\(cardsPerWindow) shared into a second window), \(cardsPerWindow) transcripts of \(transcriptLines) lines; "
                + String(
                    format: "idle refresh without the cache %.3f s (%d file reads), with it %.3f s (%d file reads)", before.seconds, fresh.reads, idle.seconds,
                    idleReads))
    }

    /// An entry of continue-copies.json whose copy has no transcript any more is dropped at the next sync.
    @Test func aStaleCopyEntryGoesAtTheNextSync() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let project = box.paths.claudeProjectsDir.appending(path: "-Users-me-src-app", directoryHint: .isDirectory)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let (source, kept, gone) = ("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333")
        for id in [source, kept] { try Data("{}\n".utf8).write(to: project.appending(path: "\(id).jsonl")) }
        let copies = ContinueCopies(paths: box.paths)
        try copies.record(source: source, destination: "work", copy: kept)
        try copies.record(source: source, destination: "lab", copy: gone)

        _ = try ProfileManager(paths: box.paths).syncSessions()

        let text = try String(contentsOf: copies.file, encoding: .utf8)
        #expect(text.contains(kept))
        #expect(!text.contains(gone), "its copy is gone")
        #expect(try copies.dropMissing(transcripts: ConversationIndex.transcriptFiles(in: box.paths.claudeProjectsDir)) == 0)
    }
}
