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

    @Test func aWrittenCardCarriesOnlyAModelTheDestinationHasRun() {
        #expect(ModelNote.decide(model: long, historyModel: base, supported: true, card: .written) == ModelNote(model: long, kind: .carried))
        let missing = ModelNote.decide(model: long, historyModel: base, supported: false, card: .written)
        #expect(missing == ModelNote(model: long, kind: .notCarried(opensWith: base)))
        #expect(missing?.isWarning == true)
        #expect(missing?.message(destination: "TEAM").contains("choose") == false)
        #expect(missing?.message(destination: "TEAM").contains("Choose \(long)") == true)
    }

    @Test func anOpenWindowTakesTheModelFromTheHistory() {
        let note = ModelNote.decide(model: long, historyModel: base, supported: true, card: .imported)
        #expect(note == ModelNote(model: long, kind: .chooseBeforeSending))
        #expect(note?.message(destination: "TEAM").contains("already open") == true)
        #expect(ModelNote.decide(model: base, historyModel: base, supported: true, card: .imported)?.kind == .carried)
        #expect(ModelNote.decide(model: base, historyModel: base, supported: false, card: .imported)?.kind == .unverified)
    }

    @Test func aSharedCardAlreadyHasTheModel() {
        #expect(ModelNote.decide(model: long, historyModel: base, supported: true, card: .shared)?.kind == .carried)
        #expect(ModelNote.decide(model: long, historyModel: base, supported: false, card: .shared)?.kind == .unverified)
        #expect(ModelNote.decide(model: nil, historyModel: base, supported: false, card: .written) == nil)
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

    @Test func permissionModeIsNeverWidened() {
        #expect(ContinuationCard.permissionMode("bypassPermissions") == "acceptEdits")
        #expect(ContinuationCard.permissionMode("auto") == "acceptEdits")
        #expect(ContinuationCard.permissionMode("plan") == "plan")
        #expect(ContinuationCard.permissionMode("acceptEdits") == "acceptEdits")
        #expect(ContinuationCard.permissionMode(nil) == "default")
        #expect(ContinuationCard.permissionMode("something-new") == "default")
    }
}

@Suite("Preparing the destination")
struct ContinuePlanTests {
    /// MAIN owns a Project branch on the long-context model; WORK is signed in and closed.
    func setUp(workHasRunLongContext: Bool) throws -> (Sandbox, ProfileManager, Conversation, URL) {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let a = try box.pair(box.main, account: Sandbox.accountA)
        // Claude names organization folders by UUID; the card folder is found only among those.
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

    @Test func branchContinuesAsACopyWithItsModelInAClosedWindow() throws {
        let (box, manager, conversation, b) = try setUp(workHasRunLongContext: true)
        #expect(conversation.kind == .projectBranch)

        var plan = try #require(try manager.plan([conversation], in: "work").first)
        #expect(plan.forks && plan.model?.kind == .carried && plan.cardFolder?.path == b.path)
        #expect(!box.exists(b.appending(path: "local_\(plan.sessionID).json")), "planning changes nothing")

        try manager.prepare(&plan, now: Date())

        #expect(plan.sessionID != Sandbox.cli && plan.cardWritten)
        #expect(box.exists(box.paths.claudeProjectsDir.appending(path: "-repo/\(plan.sessionID).jsonl")))
        let card = try #require(ConversationIndex.readCard(b.appending(path: "local_\(plan.sessionID).json")))
        #expect(card["cliSessionId"] as? String == plan.sessionID)
        #expect(card["sessionId"] as? String == "local_\(plan.sessionID)")
        #expect(card["model"] as? String == "claude-opus-5-5[1m]" && card["effort"] as? String == "xhigh")
        #expect(card["permissionMode"] as? String == "acceptEdits")
        #expect(card["cwd"] as? String == "/repo" && card["title"] as? String == "Duties (continued)")
        #expect(card["adoptedFromOtherSurface"] as? Bool == true)
        #expect(card["projectThreadChild"] == nil && card["remoteControlSpawn"] == nil, "the copy is a regular session")
        #expect(box.read(b.appending(path: "local_\(plan.sessionID).json"))?.contains(#"\/"#) == false)
    }

    @Test func modelTheDestinationHasNotRunIsNotWrittenAndIsFlagged() throws {
        let (_, manager, conversation, b) = try setUp(workHasRunLongContext: false)
        var plan = try #require(try manager.plan([conversation], in: "work", mode: .same).first)
        #expect(!plan.forks)
        #expect(plan.model == ModelNote(model: "claude-opus-5-5[1m]", kind: .notCarried(opensWith: "claude-opus-5-5")))

        try manager.prepare(&plan, now: Date())

        #expect(plan.sessionID == Sandbox.cli)
        let card = try #require(ConversationIndex.readCard(b.appending(path: "local_\(Sandbox.cli).json")))
        #expect(card["model"] as? String == "claude-opus-5-5", "what Claude itself would pick from the history")
        #expect(card["title"] as? String == "Duties")
    }

    @Test func existingCardIsLeftForClaudeToOpen() throws {
        let (box, manager, conversation, b) = try setUp(workHasRunLongContext: true)
        let existing = b.appending(path: "local_\(Sandbox.cli).json")
        try box.write(#"{"cliSessionId":"\#(Sandbox.cli)","title":"mine"}"#, to: existing)
        var plan = try #require(try manager.plan([conversation], in: "work", mode: .same).first)

        try manager.prepare(&plan, now: Date())

        #expect(!plan.cardWritten)
        #expect(box.read(existing) == #"{"cliSessionId":"\#(Sandbox.cli)","title":"mine"}"#)
    }

    @Test func refusesCoworkAndTheOwnersOwnWindow() throws {
        let (_, manager, conversation, _) = try setUp(workHasRunLongContext: true)
        #expect(throws: ProfileError.sameWindow("MAIN")) { try manager.plan([conversation], in: "main") }
        var cowork = conversation
        cowork.kind = .cowork
        #expect(throws: ProfileError.coworkNeedsItsOwnHandoff(conversation.title)) { try manager.plan([cowork], in: "work") }
    }
}

@Suite("Choosing where to continue")
struct DestinationRankingTests {
    let now = Date()

    func status(_ id: String, week: Int?, fiveHour: Int? = 0, age: TimeInterval = 600, signedIn: Bool = true) -> ProfileStatus {
        ProfileStatus(profile: id == "main" ? nil : Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"),
                      accountID: signedIn ? "acct-\(id)" : nil, email: nil,
                      usage: week.map { Usage(fiveHour: fiveHour, week: $0, sampledAt: now.addingTimeInterval(-age)) },
                      isRunning: false)
    }

    @Test func freshSamplesComeFirstThenOldOnesThenNone() {
        let statuses = [
            status("main", week: 100),
            status("stale", week: 3, age: 5 * 3600),
            status("busy", week: 60),
            status("light", week: 30, age: 3 * 3600 - 60),
            status("unknown", week: nil),
            status("out", week: 10, fiveHour: 100),
            status("new", week: 5, signedIn: false),
        ]

        #expect(DestinationRanking.ranked(statuses, now: now).map(\.id) == ["light", "busy", "stale", "unknown"])
        #expect(DestinationRanking.best(statuses, excluding: "light", now: now) == "busy")
        #expect(DestinationRanking.isAtLimit(statuses[0], now: now) && DestinationRanking.isAtLimit(statuses[5], now: now))
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
