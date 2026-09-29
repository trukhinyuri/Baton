import Foundation
import Testing

@testable import BatonKit

/// Holds a database's `LOCK` from a separate process, as a Claude window opening it would.
private final class LockHolder: @unchecked Sendable {
    let process = Process(), stdout = Pipe(), stdin = Pipe()

    func hold(_ lockPath: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#, lockPath]
        process.standardOutput = stdout
        process.standardInput = stdin
        try process.run()
        var buffer = Data()
        while !buffer.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
    }

    func release() {
        guard process.isRunning else { return }
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

private func localStorageCopy() throws -> URL {
    let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture", directoryHint: .isDirectory)
    let dest = FileManager.default.temporaryDirectory.appending(path: "durability-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixture, to: dest)
    return dest
}

@Suite("Durability")
struct SessionSyncDurabilityTests {
    /// A card a crash cut short is newer than every whole copy, yet it never replaces them. It stays while its window
    /// may be writing it, and once every window is closed the newest whole copy replaces it, with a backup.
    @Test func aCardCutShortIsNeverCopied() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountA)
        let whole = #"{"sessionId":"local_x","cliSessionId":"11111111-2222-4333-8444-555555555555","title":"T"}"#
        let cut = #"{"sessionId":"local_x","cliSessionId":"11111111-2222"#
        try box.write(whole, to: a.appending(path: "local_x.json"), modified: Date().addingTimeInterval(-600))
        try box.write(cut, to: b.appending(path: "local_x.json"))
        try box.write(#"["not a card"]"#, to: b.appending(path: "local_y.json"))

        let open = try box.sync()

        #expect(box.read(a.appending(path: "local_x.json")) == whole)
        #expect(box.read(b.appending(path: "local_x.json")) == cut, "its window may still be writing it")
        #expect(!box.exists(a.appending(path: "local_y.json")), "a file that isn't a card object is never copied")
        #expect(open.changes == 0)

        let closed = try box.sync(propagateDeletions: true)

        #expect(closed.cardsWritten == 1)
        #expect(box.read(b.appending(path: "local_x.json")) == whole)
        #expect(box.read(a.appending(path: "local_x.json")) == whole)
        let backups = try FileManager.default.subpathsOfDirectory(atPath: box.paths.backupsDir.path)
        #expect(backups.contains { $0.hasSuffix("local_x.json") }, "the cut copy is kept in the backups")
        #expect(try box.sync(propagateDeletions: true).changes == 0)
    }

    @Test func everyOverwriteKept() throws {
        let box = try Sandbox()
        let file = box.main.appending(path: "claude-code-sessions/card.json")
        let other = box.work.appending(path: "claude-code-sessions/card.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        var trashed: [String] = []
        var backup = Backup(paths: box.paths, now: now)

        var saved: [Bool] = []
        for version in ["v1", "v2", "v2", "v3"] {
            try box.write(version, to: file)
            saved.append(try backup.save(file))
        }
        for version in ["w1", "v3"] {
            try box.write(version, to: other)
            saved.append(try backup.save(other))
        }

        #expect(saved == [true, true, false, true, true, false], "each distinct content is kept once")
        let kept = (FileManager.default.enumerator(at: box.paths.backupsDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        #expect(Set(kept.filter { $0.hasPrefix("v") || $0.hasPrefix("w") }) == ["v1", "v2", "v3", "w1"])
        #expect(kept.filter { $0 == "v3" }.count == 1, "the same content is stored once, whichever window it came from")

        // A day later every version is still there; two days later only the first copy of the day is.
        for (days, expectVersions) in [(1.0, true), (2.0, false)] {
            backup = Backup(paths: box.paths, now: now.addingTimeInterval(days * 86_400))
            backup.discard = {
                trashed.append($0.path); try FileManager.default.removeItem(at: $0)
            }
            backup.prune()
            let left = (FileManager.default.enumerator(at: box.paths.backupsDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.filter { $0.hasPrefix("v") || $0.hasPrefix("w") }
            #expect(Set(left) == (expectVersions ? ["v1", "v2", "v3", "w1"] : ["v1", "w1"]))
        }
        #expect(!trashed.isEmpty)
    }

    @Test func tombstoneExpires() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let old = Date().addingTimeInterval(-91 * 86_400)
        try box.write("", to: a.appending(path: "deleted_old"), modified: old)
        try box.write("", to: b.appending(path: "deleted_old"), modified: old)
        try box.write("", to: a.appending(path: "deleted_unseen"), modified: old)  // not yet in every window
        try box.write("", to: a.appending(path: "deleted_recent"))
        try box.write("", to: b.appending(path: "deleted_recent"))
        try box.write("", to: a.appending(path: "deleted_kept"), modified: old)
        try box.write("", to: b.appending(path: "deleted_kept"), modified: old)
        try box.write("card", to: b.appending(path: "local_kept.json"))  // a copy is still around somewhere

        let open = try box.sync(propagateDeletions: false)
        #expect(open.tombstonesExpired == 0, "only while no window is open")

        let report = try box.sync(propagateDeletions: true)

        #expect(report.tombstonesExpired == 1)
        #expect(!box.exists(a.appending(path: "deleted_old")) && !box.exists(b.appending(path: "deleted_old")))
        #expect(box.exists(b.appending(path: "deleted_unseen")), "spread to the window that hadn't seen it, and kept")
        #expect(box.exists(a.appending(path: "deleted_recent")))
        #expect(box.exists(a.appending(path: "deleted_kept")))
    }

    @Test func recheckInUseBeforeRename() throws {
        let dataDir = try localStorageCopy()
        var store = LocalStorage(dataDir: dataDir).store
        let holder = LockHolder()
        defer { holder.release() }
        let lockPath = store.dir.appending(path: "LOCK").path
        store.willRename = { try? holder.hold(lockPath) }
        let before = try FileManager.default.contentsOfDirectory(atPath: store.dir.path).sorted()

        #expect(throws: LocalStorageError.databaseInUse) { try store.append(put: [([0x5F], [0x01])], delete: []) }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: store.dir.path).sorted() == before,
            "a window that opened the database meanwhile gets no new log, and no temporary file is left")
    }
}

/// Reads what `LocalStorage` appends with the real LevelDB tools. Needs Homebrew leveldb; run with LEVELDB_COMPAT=1.
@Suite("LevelDB compatibility", .enabled(if: ProcessInfo.processInfo.environment["LEVELDB_COMPAT"] == "1"))
struct LevelDBCompatTests {
    @Test func realLevelDBReadsTheAppendedLog() throws {
        let dataDir = try localStorageCopy()
        let storage = LocalStorage(dataDir: dataDir)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: storage.dbDir.path))
        try storage.update(origin: "https://claude.ai", set: ["compatKey": "compat-value-✅"], remove: ["counter"])
        let added = Set(try FileManager.default.contentsOfDirectory(atPath: storage.dbDir.path)).subtracting(before)
        let log = try #require(added.first { $0.hasSuffix(".log") })

        for name in [log] + before.filter({ $0.hasSuffix(".ldb") }) {
            let tool = Process(), output = Pipe()
            tool.executableURL = URL(
                fileURLWithPath: ["/opt/homebrew/bin/leveldbutil", "/usr/local/bin/leveldbutil"]
                    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/leveldbutil")
            tool.arguments = ["dump", storage.dbDir.appending(path: name).path]
            tool.standardOutput = output
            try tool.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            tool.waitUntilExit()
            #expect(tool.terminationStatus == 0, "leveldbutil reads \(name)")
            if name == log {
                #expect(text.contains("compatKey") && text.contains("del") && text.contains("counter"), "the batch is intact: \(text)")
            }
        }
    }
}
