import Foundation
import Testing
@testable import ClaudeProfilesKit

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func record(_ session: String, at date: Date, model: String? = nil) -> String {
    let message = model.map { #"{"role":"assistant","model":"\#($0)","content":[]}"# } ?? #"{"role":"user","content":"hi"}"#
    return #"{"type":"\#(model == nil ? "user" : "assistant")","sessionId":"\#(session)","timestamp":"\#(stamp(date))","message":\#(message)}"#
}

@Suite("Continuing as a copy")
struct TranscriptForkTests {
    @Test func copiesHistoryAndOwnFilesUnderANewIDAndLeavesTheOriginal() throws {
        let box = try Sandbox()
        let old = Sandbox.cli
        let transcript = try box.transcript(lines: [
            record(old, at: Date().addingTimeInterval(-60)),
            #"{"type":"user","sessionId":"\#(old)","toolUseResult":"saved to /x/-repo/\#(old)/tool-results/r1.txt"}"#,
        ])
        let folder = transcript.deletingLastPathComponent()
        let results = folder.appending(path: "\(old)/tool-results", directoryHint: .isDirectory)
        let agents = folder.appending(path: "\(old)/subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try box.write("tool output", to: results.appending(path: "r1.txt"))
        try box.write(#"{"sessionId":"\#(old)","isSidechain":true}"#, to: agents.appending(path: "agent-1.jsonl"))
        let history = box.paths.claudeDir.appending(path: "file-history/\(old)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try box.write("checkpoint", to: history.appending(path: "b70b15954277ed43@v1"))
        let env = box.paths.claudeDir.appending(path: "session-env/\(old)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        let before = try Data(contentsOf: transcript)
        let conversation = Conversation(kind: .projectBranch, sessionID: old, title: "t", folders: ["/repo"],
                                        lastActivity: Date(), transcript: transcript, ownerID: "main")

        let new = try TranscriptFork.fork(conversation)

        #expect(new != old && UUID(uuidString: new) != nil && new == new.lowercased())
        let copy = try String(contentsOf: folder.appending(path: "\(new).jsonl"), encoding: .utf8)
        #expect(!copy.contains(old), "every record and path names the new session")
        #expect(copy.contains(#""sessionId":"\#(new)""#) && copy.contains("/\(new)/tool-results/r1.txt"))
        #expect(try Data(contentsOf: transcript) == before, "the original is only read")
        #expect(box.read(folder.appending(path: "\(new)/tool-results/r1.txt")) == "tool output")
        #expect(box.read(folder.appending(path: "\(new)/subagents/agent-1.jsonl"))?.contains(new) == true)
        #expect(box.read(agents.appending(path: "agent-1.jsonl"))?.contains(old) == true)
        let checkpoint = box.paths.claudeDir.appending(path: "file-history/\(new)/b70b15954277ed43@v1")
        #expect(box.read(checkpoint) == "checkpoint", "Rewind finds the checkpoints under the copy's id")
        let links = try FileManager.default.attributesOfItem(atPath: checkpoint.path)[.referenceCount] as? Int
        #expect(links == 2, "shared by a hard link, as Claude Code does")
        #expect(box.exists(box.paths.claudeDir.appending(path: "session-env/\(new)")))
        #expect(box.read(history.appending(path: "b70b15954277ed43@v1")) == "checkpoint")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "\(new).jsonl").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasSuffix(".tmp") })
    }

    @Test func leavesOutARecordStillBeingWritten() {
        let complete = Data("{\"a\":1}\n{\"b\":2}".utf8)
        #expect(TranscriptFork.completeRecords(complete) == complete, "the last record is whole, just not ended yet")
        #expect(TranscriptFork.completeRecords(Data("{\"a\":1}\n{\"b\":".utf8)) == Data("{\"a\":1}\n".utf8))
        #expect(TranscriptFork.completeRecords(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}\n".utf8))
    }

    @Test func neverOverwritesAnExistingSession() throws {
        let box = try Sandbox()
        let transcript = try box.transcript(lines: [record(Sandbox.cli, at: Date())])
        let taken = "99999999-2222-3333-4444-555555555555"
        try box.transcript(taken, lines: ["keep"])
        let conversation = Conversation(kind: .code, sessionID: Sandbox.cli, title: "t", folders: [],
                                        lastActivity: Date(), transcript: transcript)

        #expect(throws: (any Error).self) { try TranscriptFork.fork(conversation, newID: taken) }
        #expect(box.read(transcript.deletingLastPathComponent().appending(path: "\(taken).jsonl")) == "keep")
    }

    @Test func copyKeepsOldIdInsideMessageText() throws {
        let box = try Sandbox()
        let old = Sandbox.cli
        let line = #"{"type":"user","sessionId":"\#(old)","message":{"role":"user","content":"copy \#(old) into the ticket"}}"#
        let transcript = try box.transcript(lines: [line])
        let conversation = Conversation(kind: .code, sessionID: old, title: "t", folders: ["/repo"],
                                        lastActivity: Date(), transcript: transcript)

        let new = try TranscriptFork.fork(conversation)

        let copy = try String(contentsOf: transcript.deletingLastPathComponent().appending(path: "\(new).jsonl"), encoding: .utf8)
        #expect(copy.contains(#""sessionId":"\#(new)""#), "the record's own id is rewritten")
        #expect(!copy.contains(#""sessionId":"\#(old)""#))
        #expect(copy.contains("copy \(old) into the ticket"), "what the message said is left exactly as it was")
    }

    @Test func aFailedCopyLeavesNothingBehind() throws {
        let box = try Sandbox()
        let transcript = try box.transcript(lines: [record(Sandbox.cli, at: Date())])
        let history = box.paths.claudeDir.appending(path: "file-history/\(Sandbox.cli)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try box.write("checkpoint", to: history.appending(path: "a@v1"))
        // The transcript can't be read, so the copy fails after its checkpoints were linked.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path) }
        let conversation = Conversation(kind: .code, sessionID: Sandbox.cli, title: "t", folders: [],
                                        lastActivity: Date(), transcript: transcript)
        let new = "99999999-2222-3333-4444-555555555555"

        #expect(throws: (any Error).self) { try TranscriptFork.fork(conversation, newID: new) }
        #expect(!box.exists(box.paths.claudeDir.appending(path: "file-history/\(new)")))
        #expect(!box.exists(transcript.deletingLastPathComponent().appending(path: "\(new).jsonl")))
    }
}

@Suite("Same session or a copy")
struct ContinueModeTests {
    func conversation(_ kind: Conversation.Kind, lastMessage: Date, in box: Sandbox) throws -> Conversation {
        let transcript = try box.transcript(lines: [record(Sandbox.cli, at: lastMessage)])
        return Conversation(kind: kind, sessionID: Sandbox.cli, title: "t", folders: ["/repo"], lastActivity: lastMessage,
                            transcript: transcript, ownerID: kind == .code ? nil : "main")
    }

    @Test func automaticCopiesBranchesAndRecentlyActiveSessions() throws {
        let box = try Sandbox()
        let now = Date()
        let quiet = try conversation(.code, lastMessage: now.addingTimeInterval(-20 * 60), in: box)
        #expect(!ContinueMode.auto.forks(quiet, now: now), "quiet for 20 minutes: the same session")
        let busy = try conversation(.code, lastMessage: now.addingTimeInterval(-5 * 60), in: box)
        #expect(ContinueMode.auto.forks(busy, now: now), "a message 5 minutes ago: it may still be running")
        let branch = try conversation(.projectBranch, lastMessage: now.addingTimeInterval(-3 * 3600), in: box)
        #expect(ContinueMode.auto.forks(branch, now: now), "its Project's coordinator may write to it again")
    }

    @Test func aSessionOpenInARunningProcessIsCopiedHoweverQuiet() throws {
        let box = try Sandbox()
        let now = Date()
        var quiet = try conversation(.code, lastMessage: now.addingTimeInterval(-3 * 3600), in: box)
        quiet.hasLiveProcess = true
        #expect(quiet.mayStillWrite(now: now), "a background task can finish and write to it at any time")
        #expect(ContinueMode.auto.forks(quiet, now: now))
        #expect(!ContinueMode.same.forks(quiet, now: now), "an explicit choice still wins")
    }

    @Test func runningProcessesAreFoundByTheirListAndArguments() throws {
        let box = try Sandbox()
        let registry = box.paths.claudeDir.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let live = "AAAAAAAA-1111-2222-3333-444444444444", gone = "bbbbbbbb-1111-2222-3333-444444444444"
        try box.write(#"{"pid":101,"sessionId":"\#(live)","status":"idle"}"#, to: registry.appending(path: "101.json"))
        try box.write(#"{"pid":102,"sessionId":"\#(gone)"}"#, to: registry.appending(path: "102.json"))
        try box.write(#"{"pid":999,"sessionId":"\#(gone)"}"#, to: registry.appending(path: "103.json"))
        try box.write("not json", to: registry.appending(path: "104.json"))

        let found = LiveSessions.ids(inRegistry: registry, isRunning: { [101, 103, 104].contains($0) })

        #expect(found == [live.lowercased()], "only running processes, and only records that name their own process")
        #expect(LiveSessions.sessionIDs(inArguments: ["claude", "--model", "x", "--resume=\(live)"]) == [live.lowercased()])
        #expect(LiveSessions.sessionIDs(inArguments: ["claude", "-r", gone, "--session-id", "not-a-uuid"]) == [gone])
        #expect(LiveSessions.sessionIDs(inArguments: ["claude", "--", "--resume=\(live)"]).isEmpty)
        #expect(!LiveSessions.isClaude(-1) && !LiveSessions.isClaude(0), "never every process at once")
    }

    @Test func explicitChoiceWinsAndCoworkIsNeverForked() throws {
        let box = try Sandbox()
        let now = Date()
        let busy = try conversation(.projectBranch, lastMessage: now, in: box)
        #expect(!ContinueMode.same.forks(busy, now: now))
        let quiet = try conversation(.code, lastMessage: now.addingTimeInterval(-86_400), in: box)
        #expect(ContinueMode.fork.forks(quiet, now: now))
        let cowork = try conversation(.cowork, lastMessage: now, in: box)
        #expect(!ContinueMode.fork.forks(cowork, now: now) && !ContinueMode.auto.forks(cowork, now: now))
    }
}

@Suite("Everything in a folder")
struct FolderBatchTests {
    @Test func picksRecentCodeWorkInTheFolderAndBelowIt() throws {
        let box = try Sandbox()
        let now = Date()
        let repo = box.root.appending(path: "work/repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo.appending(path: "sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: box.root.appending(path: "work/repo2"), withIntermediateDirectories: true)
        let link = box.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        let none = URL(fileURLWithPath: "/nonexistent.jsonl")
        func make(_ id: String, _ kind: Conversation.Kind, _ folder: String, _ ago: TimeInterval) -> Conversation {
            Conversation(kind: kind, sessionID: id, title: id, folders: [folder], lastActivity: now.addingTimeInterval(-ago), transcript: none)
        }
        let all = [
            make("root", .code, repo.path, 60),
            make("sub", .projectBranch, repo.path + "/sub", 120),
            make("viaLink", .code, link.path + "/", 180),
            make("sibling", .code, box.root.path + "/work/repo2", 60),
            make("old", .code, repo.path, 2 * 86_400),
            make("cowork", .cowork, repo.path, 60),
        ]

        let found = ConversationIndex.recent(in: link.path, since: now.addingTimeInterval(-86_400), from: all)

        #expect(found.map(\.sessionID) == ["root", "sub", "viaLink"])
    }

    @Test func continueAllTakesTheMostRecentAndCountsTheRest() {
        let now = Date()
        let none = URL(fileURLWithPath: "/nonexistent.jsonl")
        func make(_ id: String, _ kind: Conversation.Kind, _ ago: TimeInterval, owner: String = "main") -> Conversation {
            Conversation(kind: kind, sessionID: id, title: id, folders: ["/repo"], lastActivity: now.addingTimeInterval(-ago),
                         transcript: none, ownerID: owner)
        }
        let all = [
            make("c", .code, 300), make("a", .code, 60), make("mine", .projectBranch, 30, owner: "team"),
            make("b", .projectBranch, 120), make("d", .code, 400), make("old", .code, 2 * 86_400),
        ]
        let since = now.addingTimeInterval(-86_400)

        let (batch, leftOut) = ConversationIndex.continueAllBatch(in: "/repo", since: since, from: all, to: "team",
                                                                  folderOnly: true, limit: 2)

        #expect(batch.map(\.sessionID) == ["a", "b"])
        #expect(leftOut == 2)
        #expect(ConversationIndex.continueAllBatch(in: "/repo", since: since, from: all, to: "team", folderOnly: true).leftOut == 0)
    }

    @Test func bringsTheOtherBranchesOfTheSameProject() {
        let now = Date()
        let none = URL(fileURLWithPath: "/nonexistent.jsonl")
        func make(_ id: String, _ kind: Conversation.Kind, _ folder: String, owner: String?, _ ago: TimeInterval = 60) -> Conversation {
            Conversation(kind: kind, sessionID: id, title: id, folders: [folder], lastActivity: now.addingTimeInterval(-ago),
                         transcript: none, ownerID: owner)
        }
        let all = [
            make("branch", .projectBranch, "/work/assistant", owner: "robin"),
            make("session", .code, "/work/assistant", owner: nil),
            make("sibling", .projectBranch, "/work/tools", owner: "robin"),
            make("otherWindow", .projectBranch, "/work/tools", owner: "vir"),
            make("oldSibling", .projectBranch, "/work/tools", owner: "robin", 3 * 86_400),
            make("plain", .code, "/work/tools", owner: nil),
        ]
        let since = now.addingTimeInterval(-86_400)

        #expect(ConversationIndex.recent(in: "/work/assistant", since: since, from: all).map(\.sessionID) == ["branch", "session", "sibling"])
        #expect(ConversationIndex.recent(in: "/work/assistant", since: since, from: all, folderOnly: true).map(\.sessionID) == ["branch", "session"])
        #expect(ConversationIndex.recent(in: "/work/tools", since: since, from: all).map(\.sessionID) == ["branch", "sibling", "otherWindow", "plain"],
                "a Project branch in the folder brings its Project's others, wherever they work")
    }

    @Test func scanKeepsTheModelAndEffortOfTheOwnersCard() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.transcript()
        let branch = #"{"cliSessionId":"\#(Sandbox.cli)","projectThreadChild":true,"cwd":"/repo","model":"claude-opus-5-5[1m]","effort":"xhigh"}"#
        try box.write(branch, to: a.appending(path: "local_branch.json"))

        let found = ConversationIndex.scan(paths: box.paths, windows: [("main", box.main)])

        #expect(found.count == 1)
        #expect(found[0].model == "claude-opus-5-5[1m]" && found[0].effort == "xhigh")
        #expect(found[0].card?.lastPathComponent == "local_branch.json")
    }

    @Test func newSessionLinkNamesTheFolder() throws {
        let link = ClaudeLink.newCodeSession(folder: "/Users/me/My Repo+1")
        #expect(link.scheme == "claude" && link.host() == "code" && link.path() == "/new")
        #expect(!(link.query(percentEncoded: true) ?? "").contains("+"))
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["folder"] && items[0].value == "/Users/me/My Repo+1")
        let withPrompt = try #require(URLComponents(url: ClaudeLink.newCodeSession(folder: "/r", prompt: "go on"), resolvingAgainstBaseURL: false)?.queryItems)
        #expect(withPrompt.map(\.name) == ["folder", "q"] && withPrompt[1].value == "go on")
    }
}

@Suite("Carrying the model over")
struct ModelCarryTests {
    let long = "claude-opus-5-5[1m]", base = "claude-opus-5-5"

    @Test func anImportedSessionTakesTheModelFromTheHistory() {
        let note = ModelNote.decide(model: long, historyModel: base, supported: true, card: .imported)
        #expect(note == ModelNote(model: long, kind: .chooseBeforeSending))
        #expect(note?.isWarning == true && note?.message(destination: "TEAM").contains("Choose \(long)") == true)
        #expect(ModelNote.decide(model: base, historyModel: base, supported: true, card: .imported)?.kind == .carried)
        #expect(ModelNote.decide(model: base, historyModel: base, supported: false, card: .imported)?.kind == .unverified)
    }

    @Test func aSharedCardAlreadyHasTheModel() {
        #expect(ModelNote.decide(model: long, historyModel: base, supported: true, card: .shared)?.kind == .carried)
        #expect(ModelNote.decide(model: long, historyModel: base, supported: false, card: .shared)?.kind == .unverified)
        #expect(ModelNote.decide(model: nil, historyModel: base, supported: false, card: .imported) == nil)
    }

    @Test func modelsComeFromTheWindowsOwnRecords() throws {
        let json = #"{"v":2,"costUSD":1.5,"perModel":{"claude-opus-5-5[1m]":{"costUSD":1.2},"claude-haiku-4-5":{"costUSD":0.3}}}"#
        #expect(ModelSupport.models(inSessionResult: json) == ["claude-opus-5-5[1m]", "claude-haiku-4-5"])
        #expect(ModelSupport.models(inSessionResult: "not json").isEmpty)

        let box = try Sandbox()
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"cliSessionId":"x","projectThreadChild":true,"model":"claude-opus-5-5[1m]"}"#, to: b.appending(path: "local_own.json"))
        try box.write(#"{"cliSessionId":"y","model":"claude-fable-5"}"#, to: b.appending(path: "local_shared.json"))
        #expect(ModelSupport.modelsUsed(in: box.work) == ["claude-opus-5-5[1m]"], "shared cards come from every window, so they prove nothing")
    }

    @Test func lastModelIsTheLatestAnswers() throws {
        let box = try Sandbox()
        let transcript = try box.transcript(lines: [
            record(Sandbox.cli, at: Date(), model: "claude-fable-5"),
            record(Sandbox.cli, at: Date(), model: "claude-opus-5-5"),
            #"{"type":"user","message":{"content":"say \"model\":\"claude-x\""}}"#,
        ])
        #expect(ConversationIndex.lastModel(of: transcript) == "claude-opus-5-5")
    }

    @Test func lastModelIgnoresSidechainModel() throws {
        let box = try Sandbox()
        let transcript = try box.transcript(lines: [
            record(Sandbox.cli, at: Date(), model: "claude-opus-5-5"),
            #"{"type":"assistant","sessionId":"\#(Sandbox.cli)","isSidechain":true,"message":{"model":"claude-haiku-4-5","content":[]}}"#,
            #"{"type":"assistant","sessionId":"\#(Sandbox.cli)","isMeta":true,"message":{"model":"claude-fable-5","content":[]}}"#,
        ])
        #expect(ConversationIndex.lastModel(of: transcript) == "claude-opus-5-5", "a sub-agent's or Claude Code's own model isn't what the person was talking to")
    }
}

@Suite("Preparing the destination")
struct ContinuePlanTests {
    /// MAIN owns a Project branch on the long-context model; WORK is signed in as `workEmail` and closed.
    func setUp(workHasRunLongContext: Bool = true, workEmail: String = "me@team.example") throws -> (Sandbox, ProfileManager, Conversation, URL) {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let idb = box.work.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: idb, withIntermediateDirectories: true)
        try box.write("uuid\"$\(Sandbox.accountB)\"\remail_address\"\u{0e}\(workEmail)\"", to: idb.appending(path: "000003.log"))
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB, org: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        try box.transcript(lines: [record(Sandbox.cli, at: Date().addingTimeInterval(-3600), model: "claude-opus-5-5")])
        let card = #"{"sessionId":"local_branch","cliSessionId":"\#(Sandbox.cli)","projectThreadChild":true,"cwd":"/repo","originCwd":"/repo","title":"Duties","model":"claude-opus-5-5[1m]","effort":"xhigh","permissionMode":"bypassPermissions","remoteControlSpawn":{"folder":"/repo"}}"#
        try box.write(card, to: a.appending(path: "local_branch.json"))
        if workHasRunLongContext {
            try box.write(#"{"cliSessionId":"z","rcChild":true,"model":"claude-opus-5-5[1m]"}"#, to: b.appending(path: "local_rc.json"))
        }
        let manager = ProfileManager(paths: box.paths)
        let conversation = try #require(manager.conversations().first { $0.sessionID == Sandbox.cli })
        return (box, manager, conversation, b)
    }

    @Test func branchContinuesAsACopyThatClaudeImportsItself() throws {
        let (box, manager, conversation, b) = try setUp()
        #expect(conversation.kind == .projectBranch)

        var plan = try #require(try manager.plan([conversation], in: "work").first)
        #expect(plan.forks && plan.opened == nil)
        #expect(plan.model == ModelNote(model: "claude-opus-5-5[1m]", kind: .chooseBeforeSending),
                "Claude takes the model from the history, which doesn't say long context")

        try manager.prepare(&plan)

        #expect(plan.sessionID != Sandbox.cli)
        #expect(box.exists(box.paths.claudeProjectsDir.appending(path: "-repo/\(plan.sessionID).jsonl")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: b.path) == ["local_rc.json"],
                "no card is made by hand: Claude imports the session with its own trust and permission checks")
    }

    @Test func copyTitleNamesSourceWindow() throws {
        let (_, manager, conversation, _) = try setUp()
        #expect(conversation.kind == .projectBranch && conversation.ownerID == "main")

        var plan = try #require(try manager.plan([conversation], in: "work").first)
        try manager.prepare(&plan)

        #expect(plan.conversation.title == "Duties · from MAIN")
    }

    @Test func continueAllTwiceMakesNoSecondCopy() throws {
        let (box, manager, conversation, _) = try setUp()
        var first = try #require(try manager.plan([conversation], in: "work").first)
        try manager.prepare(&first)

        var second = try #require(try manager.plan([conversation], in: "work").first)
        try manager.prepare(&second)

        #expect(second.sessionID == first.sessionID, "the same copy is reused, not a second one")
        let folder = box.paths.claudeProjectsDir.appending(path: "-repo")
        let extras = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "\(Sandbox.cli).jsonl" }
        #expect(extras == ["\(first.sessionID).jsonl"], "only one copy on disk")
    }

    @Test func prepareFailureLeavesNoPartialCopies() async throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let okID = "aaaaaaaa-0000-0000-0000-000000000001", badID = "bbbbbbbb-0000-0000-0000-000000000002"
        let okTranscript = try box.transcript(okID, lines: [record(okID, at: Date())])
        let badTranscript = try box.transcript(badID, lines: [record(badID, at: Date())])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: badTranscript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: badTranscript.path) }
        let ok = Conversation(kind: .code, sessionID: okID, title: "ok", folders: ["/repo"], lastActivity: Date(), transcript: okTranscript)
        let bad = Conversation(kind: .code, sessionID: badID, title: "bad", folders: ["/repo"], lastActivity: Date(), transcript: badTranscript)
        let manager = ProfileManager(paths: box.paths)

        await #expect(throws: (any Error).self) { try await manager.continueAll([ok, bad], in: "work", mode: .fork) }

        let folder = okTranscript.deletingLastPathComponent()
        let leftover = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "\(okID).jsonl" && $0 != "\(badID).jsonl" }
        #expect(leftover.isEmpty, "the copy made for the first conversation before the second one failed is rolled back")
    }

    @Test func aRegularSessionKeepsItsSharedCardInAClosedWindow() throws {
        let (_, manager, conversation, _) = try setUp(workHasRunLongContext: false)
        var code = conversation
        code.kind = .code
        code.ownerID = nil
        let plan = try #require(try manager.plan([code], in: "work").first)
        #expect(!plan.forks && plan.model?.kind == .unverified)
    }

    @Test func importedSessionsAreConfirmedByTheirCards() throws {
        let (box, _, _, b) = try setUp()
        let since = Date()
        try box.write(#"{"sessionId":"local_x","cliSessionId":"ABCDEF01-2222-3333-4444-555555555555","title":"t"}"#,
                      to: b.appending(path: "local_ABCDEF01-2222-3333-4444-555555555555.json"))
        try box.write(#"{"cliSessionId":"old"}"#, to: b.appending(path: "local_old.json"), modified: since.addingTimeInterval(-600))
        #expect(SessionCards.sessions(in: b) == ["abcdef01-2222-3333-4444-555555555555", "z", "old"])
        #expect(SessionCards.sessions(in: b, modifiedSince: since.addingTimeInterval(-60)) == ["abcdef01-2222-3333-4444-555555555555", "z"])
    }

    @Test func folderRuleKeepsWorkInItsAccounts() throws {
        let (box, manager, conversation, _) = try setUp(workEmail: "me@personal.example")
        let rules = FolderRules(paths: box.paths)
        try rules.set("/repo", accounts: ["Me@Team.example "])

        #expect(throws: ProfileError.notAllowed(folders: ["/repo"], accounts: ["me@team.example"], label: "WORK", email: "me@personal.example")) {
            try manager.plan([conversation], in: "work")
        }
        #expect(try manager.allowedAccounts(for: ["/repo/sub"])?.accounts == ["me@team.example"])
        #expect(try manager.allowedAccounts(for: ["/elsewhere"]) == nil)
        #expect(throws: ProfileError.self, "a new session in the folder is work in the folder too") {
            try manager.plan([], in: "work", newSessionIn: "/repo/sub")
        }

        try rules.set("/repo", accounts: [])
        #expect(try manager.plan([conversation], in: "work").count == 1, "no rule, no restriction")
        try rules.set("/repo", accounts: ["me@personal.example"])
        #expect(try manager.plan([conversation], in: "work").count == 1)
    }

    @Test func damagedRulesStopEverything() throws {
        let (box, manager, conversation, _) = try setUp()
        try box.write("{", to: FolderRules(paths: box.paths).file)
        #expect(throws: ProfileError.self) { try manager.plan([conversation], in: "work") }
    }

    @Test func refusesCoworkAndTheOwnersOwnWindow() throws {
        let (_, manager, conversation, _) = try setUp()
        #expect(throws: ProfileError.sameWindow("MAIN")) { try manager.plan([conversation], in: "main") }
        var cowork = conversation
        cowork.kind = .cowork
        #expect(throws: ProfileError.coworkNeedsItsOwnHandoff(conversation.title)) { try manager.plan([cowork], in: "work") }
    }
}

@Suite("Folder rules")
struct FolderRuleTests {
    @Test func closestRuleWinsAndBatchesNeedAnAccountInCommon() {
        let rules = [FolderRule(folder: "/work", accounts: ["a@x.com", "b@x.com"]),
                     FolderRule(folder: "/work/client", accounts: ["b@x.com"]),
                     FolderRule(folder: "/other", accounts: ["c@x.com"])]
        #expect(FolderRules.rule(for: "/work/client/app", in: rules)?.folder == "/work/client")
        #expect(FolderRules.rule(for: "/workshop", in: rules) == nil, "a folder with the same prefix isn't inside it")
        #expect(FolderRules.allowedAccounts(for: ["/work/app"], in: rules)?.accounts == ["a@x.com", "b@x.com"])
        #expect(FolderRules.allowedAccounts(for: ["/work/app", "/work/client"], in: rules)?.accounts == ["b@x.com"])
        #expect(FolderRules.allowedAccounts(for: ["/work", "/other"], in: rules)?.accounts == [])
        #expect(FolderRules.allowedAccounts(for: ["/tmp", "/"], in: rules) == nil)
    }

    @Test func rulesSurviveProfileChangesAndAreEditedPerFolder() throws {
        let box = try Sandbox()
        let rules = FolderRules(paths: box.paths)
        #expect(try rules.load().isEmpty)
        try rules.set("/work", accounts: ["a@x.com"])
        try rules.set("/other", accounts: ["c@x.com"])
        try rules.set("/work", accounts: ["b@x.com"])
        #expect(try rules.load() == [FolderRule(folder: "/other", accounts: ["c@x.com"]), FolderRule(folder: "/work", accounts: ["b@x.com"])])
        #expect(try rules.set("/other", accounts: []) == nil)
        #expect(try rules.load().map(\.folder) == ["/work"])
    }
}

@Suite("Choosing where to continue")
struct DestinationRankingTests {
    let now = Date()

    func status(_ id: String, week: Int?, fiveHour: Int? = 0, age: TimeInterval = 600, signedIn: Bool = true) -> ProfileStatus {
        ProfileStatus(profile: id == "main" ? nil : Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"),
                      accountID: signedIn ? "acct-\(id)" : nil, email: signedIn ? "\(id)@x.com" : nil,
                      usage: week.map { Usage(fiveHour: fiveHour, week: $0, sampledAt: now.addingTimeInterval(-age)) },
                      isRunning: false)
    }

    @Test func lowestWeeklyUsageFirstHoweverOldItsSampleThenNone() {
        let statuses = [
            status("main", week: 100),
            status("stale", week: 3, age: 5 * 3600),
            status("busy", week: 60),
            status("light", week: 30, age: 3 * 3600 - 60),
            status("unknown", week: nil),
            status("out", week: 10, fiveHour: 100),
            status("new", week: 5, signedIn: false),
        ]

        #expect(DestinationRanking.ranked(statuses, now: now).map(\.id) == ["stale", "light", "busy", "unknown"],
                "a reserve kept closed is sampled rarely, and its old sample is still its latest usage")
        #expect(DestinationRanking.best(statuses, excluding: "stale", now: now) == "light")
        #expect(DestinationRanking.ranked([status("old", week: 20, age: 5 * 3600), status("new", week: 20)], now: now).map(\.id) == ["new", "old"])
        #expect(DestinationRanking.isAtLimit(statuses[0], now: now) && DestinationRanking.isAtLimit(statuses[5], now: now))
    }

    @Test func onlyWindowsWithAnAllowedAccountAreOffered() {
        let statuses = [status("personal", week: 10), status("team", week: 90, age: 6 * 3600), status("other", week: 0)]
        #expect(DestinationRanking.ranked(statuses, accounts: ["team@x.com"], now: now).map(\.id) == ["team"])
        #expect(DestinationRanking.best(statuses, accounts: [], now: now) == nil)
        #expect(DestinationRanking.best(statuses, now: now) == "other")
        #expect(!DestinationRanking.isAllowed(status("new", week: nil, signedIn: false), accounts: ["new@x.com"]),
                "an account whose email isn't known is never taken for an allowed one")
    }

    @Test func mostHeadroomNeedsTwoFreshSamplesAndNeverPicksAStaleOne() {
        #expect(DestinationRanking.mostHeadroom([status("a", week: 40), status("b", week: 3, age: 4 * 3600)], now: now) == nil)
        #expect(DestinationRanking.mostHeadroom([status("a", week: 40), status("b", week: 20), status("c", week: 1, age: 6 * 3600)], now: now) == "b")
        #expect(DestinationRanking.mostHeadroom([status("a", week: 40)], now: now) == nil)
    }

    @Test func sampleAgeIsShown() {
        let usage = Usage(fiveHour: 0, week: 3, sampledAt: now.addingTimeInterval(-5 * 3600 - 30))
        #expect(!usage.isFresh(now: now) && abs(usage.age(now: now) - (5 * 3600 + 30)) < 1)
        #expect(Usage(fiveHour: 0, week: 3, sampledAt: now.addingTimeInterval(-Usage.staleAfter)).isFresh(now: now))
        #expect(relativeAge(since: usage.sampledAt, now: now) == "5h ago")
        #expect(relativeAge(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(relativeAge(since: now.addingTimeInterval(-12 * 60), now: now) == "12m ago")
        #expect(relativeAge(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d ago")
    }
}
