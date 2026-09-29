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

    /// Past its budget the cache returns what it reads without keeping it, and what it keeps stays kept.
    @Test func keepsNoMoreThanItsBudget() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let cache = ScanCache(limit: 100, budget: 10_000)
        let files = try (0..<5).map { i in
            let file = box.root.appending(path: "card-\(i).json")
            try Data(repeating: UInt8(ascii: "a") + UInt8(i), count: 3_000).write(to: file)
            return file
        }
        let read = { (url: URL) in try Data(contentsOf: url) }
        for (i, file) in files.enumerated() { #expect(try cache.value("data", of: file, read: read).first == UInt8(ascii: "a") + UInt8(i)) }
        #expect(cache.bytes == 9_000, "three of them fit")
        for file in files { _ = try cache.value("data", of: file, read: read) }
        #expect(cache.reads == 5 + 2, "the three kept are not read again; the two that didn't fit are")
        // A value that knows its cost is counted by it.
        #expect(try cache.value("facts", of: files[4], cost: { (n: Int) in n }, read: { _ in 500 }) == 500)
        #expect(cache.bytes == 9_500)
        // A file that is gone takes its entry with it.
        try fm.removeItem(at: files[0])
        #expect(throws: (any Error).self) { try cache.value("data", of: files[0], read: read) }
        #expect(cache.bytes == 6_500)
    }

    /// An entry nobody asked for in an hour goes, such as the card of a session that was deleted.
    @Test func forgetsWhatNobodyAskedForInAnHour() throws {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let clock = Clock()
        let cache = ScanCache(limit: 100, budget: 1 << 20, clock: { clock.now })
        let (gone, kept) = (box.root.appending(path: "gone.json"), box.root.appending(path: "kept.json"))
        try Data(count: 1_000).write(to: gone)
        try Data(count: 2_000).write(to: kept)
        let read = { (url: URL) in try Data(contentsOf: url) }
        _ = try cache.value("data", of: gone, read: read)
        _ = try cache.value("data", of: kept, read: read)
        try fm.removeItem(at: gone)  // never asked for again
        clock.now = 1_800
        _ = try cache.value("data", of: kept, read: read)
        #expect(cache.bytes == 3_000)
        clock.now = 3_700
        _ = try cache.value("data", of: kept, read: read)
        #expect(cache.bytes == 2_000, "only the entry asked for in the last hour is left")
        #expect(cache.reads == 2)
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
        #expect(try copies.dropMissing(in: box.paths.claudeProjectsDir) == 0)
    }

    /// A projects folder that can't be read says nothing about the copies: none is forgotten, and the next sync that
    /// can read it tidies up.
    @Test func anUnreadableProjectsFolderDropsNoCopy() throws {
        let box = try Sandbox()
        let projects = box.paths.claudeProjectsDir
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path)
            try? fm.removeItem(at: box.root)
        }
        let (source, copy) = ("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222")
        let copies = ContinueCopies(paths: box.paths)
        try copies.record(source: source, destination: "work", copy: copy)
        #expect(try copies.dropMissing(in: projects) == 0, "no projects folder: ~/.claude on a volume that isn't mounted")
        let project = projects.appending(path: "-Users-me-src-app", directoryHint: .isDirectory)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appending(path: "\(copy).jsonl"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        #expect(try copies.dropMissing(in: projects) == 0, "no permission")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path)
        #expect(try copies.dropMissing(in: projects) == 0, "its copy is there")
        try fm.removeItem(at: project.appending(path: "\(copy).jsonl"))
        #expect(try copies.dropMissing(in: projects) == 1, "readable, and the copy is gone")
    }
}
