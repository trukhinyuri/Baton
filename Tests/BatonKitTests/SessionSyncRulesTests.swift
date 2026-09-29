import Foundation
import Testing

@testable import BatonKit

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

    @Test func withheldCardsAreReportedWithRuleAndWindows() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let other = try box.pair(box.work, account: Sandbox.accountB, org: "org-2")
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        try box.write(#"{"sessionId":"local_2","cwd":"/employer/site"}"#, to: a.appending(path: "local_2.json"))
        try box.write(#"{"sessionId":"local_3","cwd":"/elsewhere"}"#, to: a.appending(path: "local_3.json"))

        let report = try box.sync()

        #expect(!box.exists(b.appending(path: "local_1.json")) && !box.exists(other.appending(path: "local_2.json")))
        #expect(report.withheldByRule == 4, "two cards, each kept out of two folders of the work window")
        let work = box.work.standardizedFileURL.path
        #expect(
            report.withheld == [
                SessionSync.WithheldCard(
                    card: "local_1.json", transcript: Sandbox.cli, folder: "/employer/app", rule: "/employer",
                    accounts: ["me@employer.example"], windows: [work]),
                SessionSync.WithheldCard(
                    card: "local_2.json", transcript: nil, folder: "/employer/site", rule: "/employer",
                    accounts: ["me@employer.example"], windows: [work]),
            ])
        let sync = SyncReport(sessions: report, cowork: CoworkSync.Report())
        #expect(sync.withheldSummary.count == 1)
        #expect(sync.withheldSummary.first?.rule == "/employer" && sync.withheldSummary.first?.sessions == 2)
        #expect(sync.withheldSummary.first?.windows == [work])
        #expect(
            sync.withheldLines(label: { $0 == work ? "WORK" : "?" }) == ["A folder rule keeps 2 sessions in …/employer out of WORK. baton rules shows it."])
        #expect(SyncReport(sessions: SessionSync.Report(), cowork: CoworkSync.Report()).withheldLines(label: { $0 }).isEmpty, "no rule, no line")
    }

    @Test func retiredByRuleIsReported() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        try box.write(Self.employerCard, to: a.appending(path: "local_1.json"))
        try box.write(Self.employerCard, to: b.appending(path: "local_1.json"))
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])

        let report = try box.sync { $0.isWindowOpen = { _ in false } }

        #expect(report.retiredByRule == 1 && report.withheldByRule == 0)
        #expect(report.withheld.map(\.card) == ["local_1.json"])
        #expect(report.withheld.first?.windows == [box.work.standardizedFileURL.path])
        #expect(report.withheld.first?.rule == "/employer")
        let lines = SyncReport(sessions: report, cowork: CoworkSync.Report()).withheldLines(label: { _ in "WORK" })
        #expect(lines == ["A folder rule keeps 1 session in …/employer out of WORK. baton rules shows it."])
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

        let report = try box.sync(propagateDeletions: true) {
            $0.dryRun = true; $0.isWindowOpen = { _ in false }
        }

        #expect(box.snapshot() == before, "a dry run writes, moves and removes nothing")
        #expect(report.cardsWritten == 3 && report.retiredByRule == 1 && report.cardsRemoved == 1 && report.archiveIndexesWritten == 1)
        let real = try box.sync(propagateDeletions: true) { $0.isWindowOpen = { _ in false } }
        #expect(
            real.cardsWritten == report.cardsWritten && real.retiredByRule == report.retiredByRule
                && real.cardsRemoved == report.cardsRemoved && real.tombstonesWritten == report.tombstonesWritten,
            "a dry run reports what a real run does")
    }

    /// A rule set on a linked folder still covers a session whose folder under it is gone, such as a deleted
    /// worktree, and a gone folder under `/private/var` still matches the rule's `/var`; case doesn't matter.
    @Test func ruleCoversAGoneFolderUnderALinkedOne() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let real = box.root.appending(path: "RealCloud/Clients/Acme", directoryHint: .isDirectory)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let dropbox = box.root.appending(path: "Dropbox")
        try fm.createSymbolicLink(at: dropbox, withDestinationURL: box.root.appending(path: "RealCloud"))
        let rule = FolderRule(folder: dropbox.appending(path: "Clients/Acme").path, accounts: ["work@example.org"])

        #expect(rule.covers(dropbox.appending(path: "Clients/Acme").path))
        #expect(rule.covers(dropbox.appending(path: "Clients/Acme/deleted-worktree/src").path), "gone, under the link")
        #expect(rule.covers(real.appending(path: "deleted-worktree").path), "gone, under the link's target")
        #expect(rule.covers(dropbox.appending(path: "clients/ACME/other").path), "case is ignored")
        #expect(!rule.covers(dropbox.appending(path: "Clients/Acme2").path))
        #expect(!rule.covers(box.root.appending(path: "Elsewhere/gone").path))
        #expect(FolderRules.allowedAccounts(for: [dropbox.appending(path: "Clients/Acme/gone").path], in: [rule])?.accounts == ["work@example.org"])

        let temporary = box.root.appending(path: "tmp-work", directoryHint: .isDirectory)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let onTmp = FolderRule(folder: temporary.path, accounts: ["work@example.org"])
        let resolved = temporary.resolvingSymlinksInPath().path
        let other = resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : "/private" + resolved
        #expect(onTmp.covers(other + "/gone/deeper"), "\(other) against \(onTmp.folder)")
        #expect(onTmp.covers(resolved + "/gone"))
    }

    /// Work reached through a link from one ruled folder into another takes both rules, so a link in a personal folder
    /// never lets a client's work continue in the personal account, nor a link in the client's folder the other way.
    @Test func aLinkIntoAnotherRuledFolderTakesBothRules() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let acme = box.root.appending(path: "Clients/acme/src", directoryHint: .isDirectory)
        let notes = box.root.appending(path: "Personal/Notes", directoryHint: .isDirectory)
        try fm.createDirectory(at: acme, withIntermediateDirectories: true)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: notes.appending(path: "acme-link"), withDestinationURL: acme.deletingLastPathComponent())
        let rules = [
            FolderRule(folder: box.root.appending(path: "Clients").path, accounts: ["client@corp.example"]),
            FolderRule(folder: notes.path, accounts: ["me@home.example"]),
        ]

        let linked = notes.appending(path: "acme-link/src").path
        #expect(Set(FolderRules.rules(for: linked, in: rules).flatMap(\.accounts)) == ["client@corp.example", "me@home.example"])
        #expect(FolderRules.allowedAccounts(for: [linked], in: rules)?.accounts == [], "no account both rules allow")
        #expect(FolderRules.allowedAccounts(for: [notes.appending(path: "acme-link/gone").path], in: rules)?.accounts == [])
        #expect(FolderRules.rules(for: notes.appending(path: "diary").path, in: rules).map(\.accounts) == [["me@home.example"]])
    }

    /// Where two rules share an account, a link between their folders leaves work with the accounts both allow, whichever
    /// way the link goes: from a strict folder into a looser one, or from a looser folder into a strict one.
    @Test func theStricterRuleWinsAcrossALinkEitherWay() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let work = box.root.appending(path: "Work", directoryHint: .isDirectory)
        let clientX = work.appending(path: "ClientX", directoryHint: .isDirectory)
        try fm.createDirectory(at: work.appending(path: "shared/repo"), withIntermediateDirectories: true)
        try fm.createDirectory(at: clientX.appending(path: "own/repo"), withIntermediateDirectories: true)
        let rules = [
            FolderRule(folder: work.path, accounts: ["work@corp.example", "client@corp.example"]),
            FolderRule(folder: clientX.path, accounts: ["client@corp.example"]),
        ]
        // From the strict folder into the looser one.
        try fm.createSymbolicLink(at: clientX.appending(path: "repo"), withDestinationURL: work.appending(path: "shared/repo"))
        // From the looser folder into the strict one.
        try fm.createSymbolicLink(at: work.appending(path: "client-repo"), withDestinationURL: clientX.appending(path: "own/repo"))

        #expect(FolderRules.allowedAccounts(for: [clientX.appending(path: "repo").path], in: rules)?.accounts == ["client@corp.example"])
        #expect(FolderRules.allowedAccounts(for: [clientX.appending(path: "repo/gone").path], in: rules)?.accounts == ["client@corp.example"])
        #expect(FolderRules.allowedAccounts(for: [work.appending(path: "client-repo").path], in: rules)?.accounts == ["client@corp.example"])
        #expect(
            FolderRules.allowedAccounts(for: [work.appending(path: "shared/repo").path], in: rules)?.accounts == ["client@corp.example", "work@corp.example"],
            "no link: the looser rule alone")
    }
}
