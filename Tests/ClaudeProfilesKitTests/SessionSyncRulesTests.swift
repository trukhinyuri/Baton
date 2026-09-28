import Foundation
import Testing
@testable import ClaudeProfilesKit

extension Sandbox {
    /// Leaves the account's claude.ai profile in the window's IndexedDB, the way `DesktopData.email` finds it.
    func setEmail(_ email: String, in dataDir: URL, account: String) throws {
        let idb = dataDir.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: idb, withIntermediateDirectories: true)
        try write("uuid\"$\(account)\"\remail_address\"\u{0e}\(email)\"", to: idb.appending(path: "000003.log"))
    }

    func sync(propagateDeletions: Bool = false, _ configure: (inout SessionSync) -> Void) throws -> SessionSync.Report {
        var sync = SessionSync(paths: paths, dataDirs: [main, work])
        sync.liveSessionIDs = []
        configure(&sync)
        return try sync.run(propagateDeletions: propagateDeletions)
    }

    /// Every file under the sandbox with its bytes and date, to show that a run changed nothing.
    func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = walker?.nextObject() as? URL {
            let path = String(url.path.dropFirst(root.path.count))
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                result[path] = "link " + target
            } else if let data = try? Data(contentsOf: url) {
                let modified = SyncFolders.modificationDate(url)?.timeIntervalSince1970 ?? 0
                result[path] = "\(modified) " + data.base64EncodedString()
            } else {
                result[path] = "dir"
            }
        }
        return result
    }
}

@Suite("Folder rules in sharing")
struct SessionSyncRulesTests {
    static let employerCard = #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/employer/app","originCwd":"/employer/app"}"#

    @Test func ruleCoveredCardStaysOutOfForbiddenAccount() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        try box.write(#"{"sessionId":"local_2","cwd":"/elsewhere"}"#, to: a.appending(path: "local_2.json"))

        let report = try box.sync()

        #expect(!box.exists(b.appending(path: "local_1.json")), "a rule-covered card is not shared into an account the rule does not allow")
        #expect(box.read(a.appending(path: "local_1.json")) == Self.employerCard)
        #expect(box.exists(b.appending(path: "local_2.json")), "work outside the rule is shared as before")
        #expect(report.withheldByRule == 1)
        #expect(try box.sync().changes == 0)
    }

    /// The audit probe as it was written: neither window has a known email.
    @Test func ruleCoveredCardIsNotSharedWhenNoEmailIsKnown() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        _ = try box.sync()
        #expect(!box.exists(b.appending(path: "local_1.json")))
        #expect(box.exists(a.appending(path: "local_1.json")), "the only copy is never retired")
    }

    @Test func unknownEmailFailsClosed() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example", "Second@Employer.example"])
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))

        _ = try box.sync()
        #expect(!box.exists(b.appending(path: "local_1.json")), "an account whose email can't be read counts as not allowed")

        try box.setEmail("second@employer.example", in: box.work, account: Sandbox.accountB)
        _ = try box.sync()
        #expect(box.exists(b.appending(path: "local_1.json")), "shared once the email is known and allowed, whatever its case")
    }

    @Test func retiresOnlyInClosedWindowWithBackup() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        // Shared before the rule existed; a second card has no allowed copy anywhere.
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        try box.write(Self.employerCard, to: b.appending(path: "local_1.json"))
        try box.write(#"{"sessionId":"local_3","cwd":"/employer/other"}"#, to: b.appending(path: "local_3.json"))
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        try FolderRules(paths: box.paths).set("/employer/other", accounts: ["boss@employer.example"])

        let open = try box.sync { $0.isWindowOpen = { _ in true } }
        #expect(open.retiredByRule == 0)
        #expect(box.exists(b.appending(path: "local_1.json")), "a running window's cards are never removed")

        let closed = try box.sync { $0.isWindowOpen = { _ in false } }
        #expect(closed.retiredByRule == 1)
        #expect(!box.exists(b.appending(path: "local_1.json")))
        #expect(box.exists(b.appending(path: "local_3.json")), "a copy is retired only when an allowed copy exists")
        #expect(box.exists(a.appending(path: "local_1.json")))
        #expect(!box.exists(b.appending(path: "deleted_1")), "retiring is not deleting: no tombstone")
        let backups = FileManager.default.enumerator(atPath: box.paths.backupsDir.path)?.allObjects as? [String] ?? []
        #expect(backups.contains { $0.hasSuffix("local_1.json") }, "the retired copy is backed up")
        #expect(try box.sync { $0.isWindowOpen = { _ in false } }.changes == 0)
    }

    @Test func unreadableRulesStopsSync() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"one"}"#, to: a.appending(path: "local_1.json"))
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        try box.write("{", to: FolderRules(paths: box.paths).file)

        #expect(throws: ProfileError.self) { try box.sync() }
        #expect(!box.exists(b.appending(path: "local_1.json")), "nothing is shared past a rule that can't be read")
    }

    @Test func dryRunWritesNothing() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        try box.write(Self.employerCard, to: b.appending(path: "local_1.json"))
        try box.write(#"{"title":"two"}"#, to: a.appending(path: "local_2.json"))
        try box.write(#"{"title":"old"}"#, to: b.appending(path: "local_4.json"), modified: Date().addingTimeInterval(-600))
        try box.write(#"{"title":"new"}"#, to: a.appending(path: "local_4.json"))
        try box.write("", to: a.appending(path: "deleted_5"))
        try box.write("card", to: b.appending(path: "local_5.json"))
        try box.write(#"{"v":1,"archived":["s1"]}"#, to: a.appending(path: "archived-sessions.idx"))
        let scratch = box.main.path + "/scratch-workspaces/\(Sandbox.accountA)/org-1/abc"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try box.write(#"{"cwd":"\#(scratch)","originCwd":"\#(scratch)"}"#, to: a.appending(path: "local_6.json"))
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        let before = box.snapshot()

        let report = try box.sync(propagateDeletions: true) { $0.dryRun = true; $0.isWindowOpen = { _ in false } }

        #expect(box.snapshot() == before, "a dry run writes, moves and removes nothing")
        #expect(report.cardsWritten == 3 && report.retiredByRule == 1 && report.cardsRemoved == 1 && report.archiveIndexesWritten == 1)
        let real = try box.sync(propagateDeletions: true) { $0.isWindowOpen = { _ in false } }
        #expect(real.cardsWritten == report.cardsWritten && real.retiredByRule == report.retiredByRule
                && real.cardsRemoved == report.cardsRemoved && real.tombstonesWritten == report.tombstonesWritten,
                "a dry run reports what a real run does")
    }
}
