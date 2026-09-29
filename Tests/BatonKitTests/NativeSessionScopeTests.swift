import Foundation
import Testing

@testable import BatonKit

@Suite("Native Project and Remote Control scope")
struct NativeSessionScopeTests {
    // These are the fields of a local worker spawned by a new Claude Project, including its server bridge.
    static let worker =
        #"{"sessionId":"local_worker","title":"Project worker","cwd":"/shared/repo","originCwd":"/shared/repo","bridgeSessionIds":["session_bridge"],"remoteControlSpawn":{"ccrSessionId":"session_ccr","folder":"/shared/repo","projectThreadChild":true,"rcChild":true}}"#
    static let ordinary =
        #"{"sessionId":"local_ordinary","title":"Normal local session","cwd":"/shared/repo","bridgeSessionIds":["session_existing_bridge"],"remoteControlAutoEligible":true}"#

    static let stripped =
        #"{"sessionId":"local_worker","title":"Project worker","cwd":"/shared/repo","originCwd":"/shared/repo"}"#

    @Test func markedCardReachableStaysWithItsWindow() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA, org: "org-a")
        let same = try box.pair(box.work, account: Sandbox.accountA, org: "org-a")
        let otherAccount = try box.pair(box.work, account: Sandbox.accountB, org: "org-a")
        let otherOrg = try box.pair(box.work, account: Sandbox.accountA, org: "org-b")
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        try box.write(Self.ordinary, to: a.appending(path: "local_ordinary.json"))
        try box.write(
            #"{"v":1,"archived":["local_worker","local_ordinary"]}"#,
            to: a.appending(path: "archived-sessions.idx"))
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, org: "org-a", folders: ["/shared"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.accountBoundCards == 1)
        #expect(report.ambiguousAccountBoundCards == 0 && report.releasedRemoteControlCards == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        for pair in [same, otherAccount, otherOrg] {
            #expect(!box.exists(pair.appending(path: "local_worker.json")), "not shared, not even within its account")
        }
        #expect(
            box.read(otherOrg.appending(path: "local_ordinary.json")) == Self.ordinary,
            "bridgeSessionIds by itself does not prevent an ordinary local session being continued")
        #expect(
            box.read(otherAccount.appending(path: "local_ordinary.json"))
                == #"{"sessionId":"local_ordinary","title":"Normal local session","cwd":"/shared/repo"}"#,
            "another account gets the session without the Remote Control fields of this one")
        for pair in [otherAccount, otherOrg] {
            let index = try #require(SettingsSync.readJSON(pair.appending(path: "archived-sessions.idx")))
            #expect(index["archived"] as? [String] == ["local_ordinary"])
        }
        let scopes = try SessionSync.NativeScopeState.load(from: box.paths.stateDir.appending(path: "code-native-session-scopes.json"))
        #expect(scopes.version == 2 && scopes.scopes == ["local_worker.json": ["\(Sandbox.accountA)/org-a"]])
        #expect(try box.sync(propagateDeletions: true).changes == 0)
    }

    @Test func markedCardNotReachableIsSharedWithoutRemoteControlKeys() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB, org: "org-2")
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        // Remote Control serves another folder, and another account serves this one: neither reaches the card here.
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/elsewhere"])
        try box.serveRemoteControl(box.work, account: Sandbox.accountB, folders: ["/shared/repo"])

        let report = try box.sync()

        #expect(report.releasedRemoteControlCards == 1 && report.accountBoundCards == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker, "the marked card itself is never edited")
        #expect(box.read(same.appending(path: "local_worker.json")) == Self.stripped, "the same account gets it without the keys too")
        #expect(box.read(b.appending(path: "local_worker.json")) == Self.stripped)
        #expect(try box.sync().changes == 0)
    }

    @Test func markedCardLiveInWindowStaysThere() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let worker = Self.worker.replacingOccurrences(of: #""title""#, with: #""cliSessionId":"\#(Sandbox.cli)","title""#)
        try box.write(worker, to: a.appending(path: "local_worker.json"))
        var sync = SessionSync(paths: box.paths, dataDirs: [box.main, box.work])
        sync.liveSessionIDs = []
        let main = box.main.standardizedFileURL.path
        sync.liveWindows = { [Sandbox.cli: [main]] }

        let report = try sync.run(propagateDeletions: false)

        #expect(report.accountBoundCards == 1 && report.releasedRemoteControlCards == 0)
        #expect(!box.exists(b.appending(path: "local_worker.json")))

        // Live in another window than the one with the marked copy: that doesn't reach it.
        let work = box.work.standardizedFileURL.path
        sync.liveWindows = { [Sandbox.cli: [work]] }
        #expect(try sync.run(propagateDeletions: false).releasedRemoteControlCards == 1)
        #expect(box.exists(b.appending(path: "local_worker.json")))
    }

    @Test func markedInSeveralWindowsOwnerIsTheReachableOne() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let third = try box.pair(box.work, account: Sandbox.accountB, org: "org-3")
        let newer = Self.worker.replacingOccurrences(of: "Project worker", with: "Edited in another window")
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"), modified: Date().addingTimeInterval(-60))
        try box.write(newer, to: b.appending(path: "local_worker.json"))
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/shared/repo"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.accountBoundCards == 1 && report.ambiguousAccountBoundCards == 0)
        #expect(report.cardsWritten == 0 && report.cardsRemoved == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker, "the owner's card is never edited")
        #expect(box.read(b.appending(path: "local_worker.json")) == newer, "an existing copy elsewhere is left as it is")
        #expect(!box.exists(third.appending(path: "local_worker.json")))
    }

    @Test func markedInSeveralNoneReachableIsOrdinaryEverywhere() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let fresh = try box.pair(box.work, account: Sandbox.accountA, org: "new-org")
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"), modified: Date().addingTimeInterval(-60))
        try box.write(Self.worker, to: b.appending(path: "local_worker.json"))

        let report = try box.sync(propagateDeletions: true)

        #expect(report.releasedRemoteControlCards == 1 && report.accountBoundCards == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(box.read(b.appending(path: "local_worker.json")) == Self.worker)
        #expect(box.read(fresh.appending(path: "local_worker.json")) == Self.stripped)
    }

    @Test func markedInSeveralTwoReachableLeavesAllCopiesAndDoctorNamesIt() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let fresh = try box.pair(box.work, account: Sandbox.accountA, org: "new-org")
        let old = Date().addingTimeInterval(-60)
        let newer = Self.worker.replacingOccurrences(of: "Project worker", with: "Edited in another window")
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"), modified: old)
        try box.write(newer, to: b.appending(path: "local_worker.json"))
        try box.write("", to: b.appending(path: "deleted_worker"))
        try box.write(#"{"v":1,"archived":["local_worker"]}"#, to: b.appending(path: "archived-sessions.idx"))
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/shared/repo"])
        try box.serveRemoteControl(box.work, account: Sandbox.accountB, folders: ["/shared"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.ambiguousAccountBoundCards == 1)
        #expect(report.cardsWritten == 0 && report.cardsRemoved == 0 && report.tombstonesWritten == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(box.read(b.appending(path: "local_worker.json")) == newer)
        #expect(SyncFolders.modificationDate(a.appending(path: "local_worker.json")) == old)
        #expect(!box.exists(fresh.appending(path: "local_worker.json")))
        #expect(!box.exists(a.appending(path: "archived-sessions.idx")))
        let scopes = try SessionSync.NativeScopeState.load(from: box.paths.stateDir.appending(path: "code-native-session-scopes.json"))
        #expect(scopes.scopes.isEmpty, "an ambiguous card has no owner to remember")

        let owners = SessionSync.owners(dataDirs: [box.main, box.work], paths: box.paths, live: { [:] })
        #expect(owners["local_worker.json"] == .ambiguous(dataDirs: [box.main, box.work].map(\.standardizedFileURL.path).sorted()))
        #expect(SessionSync.owner(of: "local_worker", in: owners) == owners["local_worker.json"])
        let lines = SessionSync.ambiguityLines(owners: owners, dataDirs: [box.main, box.work], label: { $0 == box.main ? "MAIN" : "WORK" })
        #expect(lines == ["“Project worker” is reachable by Remote Control in MAIN and WORK, so Baton leaves its copies alone."])
    }

    @Test func markedCopyIsNeverEditedOrReplaced() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        // The newest copy lost its marker in another window; the marked copy stays as it is.
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"), modified: Date().addingTimeInterval(-60))
        try box.write(#"{"title":"marker lost in another writer"}"#, to: b.appending(path: "local_worker.json"))

        let report = try box.sync(propagateDeletions: true)

        #expect(report.releasedRemoteControlCards == 1)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(box.read(b.appending(path: "local_worker.json")) == #"{"title":"marker lost in another writer"}"#)
    }

    @Test func copiesNeverCarryRemoteControlSpawnProjectThreadChildRcChildBridgeSessionIds() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let topLevel =
            #"{"sessionId":"local_top","title":"Top-level marks","cwd":"/repo","projectThreadChild":true,"rcChild":true,"bridgeSessionIds":["session_bridge"],"model":"m"}"#
        try box.write(topLevel, to: a.appending(path: "local_top.json"))
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))

        _ = try box.sync()

        for pair in [same, b] {
            for name in ["local_top.json", "local_worker.json"] {
                let copy = try #require(SettingsSync.readJSON(pair.appending(path: name)))
                for key in ["remoteControlSpawn", "projectThreadChild", "rcChild", "bridgeSessionIds"] {
                    #expect(copy[key] == nil, "\(key) in \(name)")
                }
            }
        }
        #expect(box.read(b.appending(path: "local_top.json")) == #"{"sessionId":"local_top","title":"Top-level marks","cwd":"/repo","model":"m"}"#)
        #expect(SessionSync.accountFields.isSuperset(of: ["projectThreadChild", "rcChild", "bridgeSessionIds"]))
    }

    @Test func scopeFileV1IsPrunedSavedAsV2AndBackedUp() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        try box.write(Self.ordinary, to: a.appending(path: "local_ordinary.json"))
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/shared/repo"])
        let state = box.paths.stateDir.appending(path: "code-native-session-scopes.json")
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        let v1 =
            #"{"scopes":{"local_gone.json":["x\/y"],"local_ordinary.json":["\#(Sandbox.accountA)\/org-1","\#(Sandbox.accountB)\/org-1"],"local_worker.json":["\#(Sandbox.accountA)\/org-1","\#(Sandbox.accountB)\/org-1"]},"version":1}"#
        try box.write(v1, to: state)

        let report = try box.sync(propagateDeletions: true)

        let saved = try SessionSync.NativeScopeState.load(from: state)
        #expect(saved.version == 2)
        #expect(saved.scopes == ["local_worker.json": ["\(Sandbox.accountA)/org-1"]], "only this run's owners are kept")
        #expect(report.backedUp >= 1)
        let backups = NativeForkCarry.files(under: box.paths.backupsDir).filter { $0.hasSuffix("code-native-session-scopes.json") }
        #expect(backups.count == 1)
        #expect(backups.first.flatMap { box.read(box.paths.backupsDir.appending(path: $0)) } == v1)
        #expect(box.exists(b.appending(path: "local_ordinary.json")), "a card v1 remembered is no longer held back")
        #expect(!box.exists(b.appending(path: "local_worker.json")))
        #expect(try box.sync(propagateDeletions: true).changes == 0)
        #expect(NativeForkCarry.files(under: box.paths.backupsDir).filter { $0.hasSuffix("code-native-session-scopes.json") }.count == 1)
    }

    @Test func foreignTombstoneCannotDeleteAProjectWorker() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        try box.write("", to: b.appending(path: "deleted_local_worker"))
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/shared/repo"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.cardsRemoved == 0 && report.tombstonesWritten == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(!box.exists(a.appending(path: "deleted_local_worker")))
    }

    @Test func workerTombstonePropagatesOnlyWithinTheKnownScope() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let foreign = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: same.appending(path: "local_worker.json"))
        try box.write("", to: a.appending(path: "deleted_worker"))
        try box.serveRemoteControl(box.work, account: Sandbox.accountA, folders: ["/shared/repo"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.cardsRemoved == 1)
        #expect(box.exists(same.appending(path: "deleted_worker")))
        #expect(!box.exists(foreign.appending(path: "deleted_worker")))
        #expect(try box.sync(propagateDeletions: true).changes == 0)
        #expect(
            !box.exists(foreign.appending(path: "deleted_worker")),
            "scope survives after all native worker cards are gone")
    }

    /// A worker stays with its own card and marker: a card dated after the marker doesn't retire it.
    @Test func workerMadeAfterItsMarkerIsStillDeleted() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let worker = Self.worker.replacingOccurrences(of: #""title""#, with: #""createdAt":\#(now),"indexedAt":\#(now),"title""#)
        try box.write(worker, to: same.appending(path: "local_worker.json"))
        try box.write(String(now - 3_600_000), to: a.appending(path: "deleted_worker"))
        try box.serveRemoteControl(box.work, account: Sandbox.accountA, folders: ["/shared/repo"])

        let report = try box.sync(propagateDeletions: true)

        #expect(report.cardsRemoved == 1 && report.tombstonesRetired == 0)
        #expect(box.exists(a.appending(path: "deleted_worker")) && box.exists(same.appending(path: "deleted_worker")))
    }

    @Test func unreadableCardDoesNotTriggerDeletionOfOtherSessions() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.ordinary, to: b.appending(path: "local_ordinary.json"))
        // A name shaped like a card but unreadable as a file previously fell through as an absent card.
        try FileManager.default.createDirectory(at: a.appending(path: "local_unreadable.json"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try box.sync(propagateDeletions: true) }
        #expect(box.read(b.appending(path: "local_ordinary.json")) == Self.ordinary)
        #expect(box.exists(a.appending(path: "local_unreadable.json")))
    }

    @Test func corruptScopeMemoryFailsClosed() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        let state = box.paths.stateDir.appending(path: "code-native-session-scopes.json")
        try box.write(#"{"version":99,"scopes":{}}"#, to: state)

        #expect(throws: (any Error).self) { try box.sync(propagateDeletions: true) }
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(!box.exists(b.appending(path: "local_worker.json")))
        #expect(box.read(state) == #"{"version":99,"scopes":{}}"#)
    }
}
