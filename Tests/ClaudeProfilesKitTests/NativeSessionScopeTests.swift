import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Native Project and Remote Control scope")
struct NativeSessionScopeTests {
    // These are the fields of a local worker spawned by a new Claude Project, including its server bridge.
    static let worker =
        #"{"sessionId":"local_worker","title":"Project worker","cwd":"/shared/repo","originCwd":"/shared/repo","bridgeSessionIds":["session_bridge"],"remoteControlSpawn":{"ccrSessionId":"session_ccr","folder":"/shared/repo","projectThreadChild":true,"rcChild":true}}"#
    static let ordinary =
        #"{"sessionId":"local_ordinary","title":"Normal local session","cwd":"/shared/repo","bridgeSessionIds":["session_existing_bridge"],"remoteControlAutoEligible":true}"#

    @Test func projectWorkerOnlyFollowsTheSameAccountAndOrganization() throws {
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

        let report = try box.sync(propagateDeletions: true)

        #expect(report.accountBoundCards == 1)
        #expect(report.ambiguousAccountBoundCards == 0)
        #expect(box.read(same.appending(path: "local_worker.json")) == Self.worker)
        #expect(
            box.read(otherOrg.appending(path: "local_ordinary.json")) == Self.ordinary,
            "bridgeSessionIds by itself does not prevent an ordinary local session being continued")
        #expect(
            box.read(otherAccount.appending(path: "local_ordinary.json"))
                == #"{"sessionId":"local_ordinary","title":"Normal local session","cwd":"/shared/repo"}"#,
            "another account gets the session without the Remote Control fields of this one")
        for pair in [otherAccount, otherOrg] {
            #expect(!box.exists(pair.appending(path: "local_worker.json")))
            let index = try #require(SettingsSync.readJSON(pair.appending(path: "archived-sessions.idx")))
            #expect(index["archived"] as? [String] == ["local_ordinary"])
        }
        #expect(try box.sync(propagateDeletions: true).changes == 0)
    }

    @Test func nativeScratchWorkerKeepsItsBridgeAndPathsByteForByte() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let suffix = "/scratch-workspaces/\(Sandbox.accountA)/org-1/native-worker"
        let original = box.main.path + suffix
        try FileManager.default.createDirectory(atPath: original, withIntermediateDirectories: true)
        let worker = Self.worker.replacingOccurrences(of: "/shared/repo", with: original)
        try box.write(worker, to: a.appending(path: "local_worker.json"))

        _ = try box.sync()

        #expect(box.read(a.appending(path: "local_worker.json")) == worker)
        #expect(
            box.read(same.appending(path: "local_worker.json")) == worker,
            "cwd, originCwd, remoteControlSpawn.folder and CCR identifiers remain coupled")
        #expect(!box.exists(URL(fileURLWithPath: box.work.path + suffix)), "native workers do not get relocated scratch aliases")
        #expect(try box.sync().changes == 0, "an existing native copy must not be localized on a later run either")
    }

    @Test func previouslySharedWorkerHasNoInferredOwnerAndIsNeverDeletedOrOverwritten() throws {
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

        let report = try box.sync(propagateDeletions: true)

        #expect(report.ambiguousAccountBoundCards == 1)
        #expect(report.cardsWritten == 0 && report.cardsRemoved == 0 && report.tombstonesWritten == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
        #expect(box.read(b.appending(path: "local_worker.json")) == newer)
        #expect(SyncFolders.modificationDate(a.appending(path: "local_worker.json")) == old)
        #expect(!box.exists(fresh.appending(path: "local_worker.json")))
        #expect(!box.exists(a.appending(path: "archived-sessions.idx")))

        // Removing one copy must not turn the remaining foreign copy into a newly inferred owner.
        try FileManager.default.removeItem(at: a.appending(path: "local_worker.json"))
        let again = try box.sync(propagateDeletions: true)
        #expect(again.ambiguousAccountBoundCards == 1 && again.cardsRemoved == 0 && again.cardsWritten == 0)
        #expect(box.read(b.appending(path: "local_worker.json")) == newer)
        #expect(!box.exists(a.appending(path: "local_worker.json")))
    }

    @Test func foreignTombstoneCannotDeleteAProjectWorker() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"))
        try box.write("", to: b.appending(path: "deleted_local_worker"))

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

        let report = try box.sync(propagateDeletions: true)

        #expect(report.cardsRemoved == 1)
        #expect(box.exists(same.appending(path: "deleted_worker")))
        #expect(!box.exists(foreign.appending(path: "deleted_worker")))
        #expect(try box.sync(propagateDeletions: true).changes == 0)
        #expect(
            !box.exists(foreign.appending(path: "deleted_worker")),
            "scope survives after all native worker cards are gone")
    }

    @Test func markerInAnyCopyProtectsAgainstANewerUnmarkedCopy() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.worker, to: a.appending(path: "local_worker.json"), modified: Date().addingTimeInterval(-60))
        try box.write(#"{"title":"marker lost in another writer"}"#, to: b.appending(path: "local_worker.json"))
        let report = try box.sync(propagateDeletions: true)
        #expect(report.ambiguousAccountBoundCards == 1)
        #expect(box.read(a.appending(path: "local_worker.json")) == Self.worker)
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
