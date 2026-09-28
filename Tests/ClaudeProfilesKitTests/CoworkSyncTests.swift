import Foundation
import Testing

@testable import ClaudeProfilesKit

extension Sandbox {
    var lab: URL { paths.dataDir(for: "lab") }

    @discardableResult
    func coworkPair(_ dataDir: URL, account: String, org: String = "org-1") throws -> URL {
        let dir = dataDir.appending(path: "local-agent-mode-sessions/\(account)/\(org)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func coworkSync(dataDirs: [URL]? = nil, propagateDeletions: Bool = false, now: Date = Date()) throws -> CoworkSync.Report {
        try CoworkSync(paths: paths, dataDirs: dataDirs ?? [main, work]).run(propagateDeletions: propagateDeletions, now: now)
    }
}

@Suite("Cowork runtime preservation")
struct CoworkSyncTests {
    @Test func inventoriesButDoesNotCopyCardsOrRuntimesEvenWithinTheSameAccount() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let sameAccount = try box.coworkPair(box.work, account: Sandbox.accountA)
        let otherAccount = try box.coworkPair(box.work, account: Sandbox.accountB)
        let runtime = a.appending(path: "local_1")
        let transcript = runtime.appending(path: ".claude/projects/session/cli-1.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try box.write(#"{"type":"assistant","message":{"role":"assistant","content":"Existing history"}}"#, to: transcript)
        let card = #"{"sessionId":"local_1","cliSessionId":"cli-1","cwd":"\#(runtime.path)/outputs","hostLoopMode":true}"#
        try box.write(card, to: a.appending(path: "local_1.json"))
        try box.write("[]", to: a.appending(path: "scheduled-tasks.json"))
        try box.write("{}", to: a.appending(path: "remote-session-spaces.json"))
        let originalTranscript = try Data(contentsOf: transcript)

        for delete in [false, true] {
            let report = try box.coworkSync(propagateDeletions: delete)
            #expect(report.pairs == 3 && report.cardsPreserved == 1)
            #expect(report.changes == 0 && report.backedUp == 0)
            for target in [sameAccount, otherAccount] {
                #expect(
                    try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty,
                    "an absolute cwd does not transfer Cowork history or VM ownership")
            }
        }
        #expect(box.read(a.appending(path: "local_1.json")) == card)
        #expect(try Data(contentsOf: transcript) == originalTranscript)
        #expect(!box.exists(box.paths.stateDir.appending(path: "cowork-sync.json")), "inventory creates no deletion state")
        #expect(!box.exists(box.paths.stateDir.appending(path: "cowork-native-session-scopes.json")), "inventory creates no scope state")
        #expect(!box.exists(box.paths.backupsDir), "inventory creates no backups")
    }

    @Test func anOpenedForeignCopyCannotOverwriteTheOwnersToolConfiguration() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        let original = #"{"sessionId":"local_1","cliSessionId":"cli-1","enabledMcpTools":{"originalTool":true},"remoteMcpServersConfig":[{"name":"original"}]}"#
        let foreign =
            #"{"sessionId":"local_1","cliSessionId":"cli-1","enabledMcpTools":{"differentTool":true},"remoteMcpServersConfig":[{"name":"other-profile"}]}"#
        try box.write(original, to: a.appending(path: "local_1.json"), modified: Date().addingTimeInterval(-3600))
        try box.write(foreign, to: b.appending(path: "local_1.json"))
        let dates = [a, b].map { SyncFolders.modificationDate($0.appending(path: "local_1.json")) }

        let report = try box.coworkSync(propagateDeletions: true)

        #expect(report.cardsPreserved == 2 && report.changes == 0)
        #expect(box.read(a.appending(path: "local_1.json")) == original)
        #expect(box.read(b.appending(path: "local_1.json")) == foreign)
        #expect([a, b].map { SyncFolders.modificationDate($0.appending(path: "local_1.json")) } == dates)
    }

    @Test func deletionAndOldStateNeverRemoveOrResurrectAnotherProfilesCards() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        let c = try box.coworkPair(box.lab, account: Sandbox.accountA, org: "org-2")
        try box.write(#"{"sessionId":"local_1"}"#, to: b.appending(path: "local_1.json"))
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        let state = box.paths.stateDir.appending(path: "cowork-sync.json")
        let baseline = #"{"lastRun":1,"present":{"\#(a.path)":["local_1.json"],"\#(b.path)":["local_1.json"]},"deletedIn":{"\#(a.path)":["local_1.json"]}}"#
        try box.write(baseline, to: state)
        let nativeState = box.paths.stateDir.appending(path: "cowork-native-session-scopes.json")
        try box.write("{old damaged metadata", to: nativeState)

        for delete in [false, true] {
            let report = try box.coworkSync(dataDirs: [box.main, box.work, box.lab], propagateDeletions: delete)
            #expect(report.changes == 0 && report.cardsPreserved == 1)
            #expect(box.exists(b.appending(path: "local_1.json")))
            #expect(!box.exists(a.appending(path: "local_1.json")))
            #expect(!box.exists(c.appending(path: "local_1.json")))
            #expect(box.read(state) == baseline)
            #expect(box.read(nativeState) == "{old damaged metadata")
        }
    }

    @Test func nativeCoworkCopiesAreAlsoInventoryOnly() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let same = try box.coworkPair(box.work, account: Sandbox.accountA)
        let other = try box.coworkPair(box.work, account: Sandbox.accountB)
        let worker = NativeSessionScopeTests.worker
        try box.write(worker, to: a.appending(path: "local_worker.json"))
        let first = try box.coworkSync(propagateDeletions: true)
        #expect(first.accountBoundCards == 1 && first.ambiguousAccountBoundCards == 0)
        #expect(!box.exists(same.appending(path: "local_worker.json")))
        #expect(!box.exists(other.appending(path: "local_worker.json")))

        try box.write(worker, to: other.appending(path: "local_worker.json"))
        let second = try box.coworkSync(propagateDeletions: true)
        #expect(second.accountBoundCards == 1 && second.ambiguousAccountBoundCards == 1)
        #expect(second.cardsPreserved == 2 && second.changes == 0)
        #expect(box.read(a.appending(path: "local_worker.json")) == worker)
        #expect(box.read(other.appending(path: "local_worker.json")) == worker)
    }

    @Test func removingAProfileDoesNotCleanUpOtherProfilesCoworkCards() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        let card = #"{"sessionId":"local_1","cwd":"\#(box.main.path)/local-agent-mode-sessions/owner/session/outputs"}"#
        for pair in [a, b] { try box.write(card, to: pair.appending(path: "local_1.json")) }
        let removed = try CoworkSync(paths: box.paths, dataDirs: [box.main, box.work]).removeCards(workingIn: box.main)
        #expect(removed == 0)
        #expect(box.read(a.appending(path: "local_1.json")) == card)
        #expect(box.read(b.appending(path: "local_1.json")) == card)
    }

    @Test func unreadableSessionRootFailsWithoutChangingOldStateOrCards() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        try box.write(#"{"sessionId":"local_1"}"#, to: a.appending(path: "local_1.json"))
        try box.write("not a directory", to: box.work.appending(path: "local-agent-mode-sessions"))
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        let state = box.paths.stateDir.appending(path: "cowork-sync.json")
        try box.write("{old state bytes", to: state)
        #expect(throws: (any Error).self) { try box.coworkSync(propagateDeletions: true) }
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1"}"#)
        #expect(box.read(state) == "{old state bytes")
    }
}
