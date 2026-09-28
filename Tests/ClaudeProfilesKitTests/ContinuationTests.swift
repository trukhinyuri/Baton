import Foundation
import Testing

@testable import ClaudeProfilesKit

extension Sandbox {
    static let cli = "11111111-2222-3333-4444-555555555555"

    /// A Claude Code transcript under `~/.claude/projects`, as every window shares it.
    @discardableResult
    func transcript(_ id: String = Sandbox.cli, lines: [String] = [], modified: Date? = nil) throws -> URL {
        let folder = paths.claudeProjectsDir.appending(path: "-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        try write(lines.joined(separator: "\n"), to: url, modified: modified)
        return url
    }

    func signIn(_ dataDir: URL, account: String = Sandbox.accountA) throws {
        try write(#"{"lastKnownAccountUuid":"\#(account)"}"#, to: dataDir.appending(path: "config.json"))
    }
}

@Suite("One card per conversation")
struct ImportedCardTests {
    static let original = #"{"sessionId":"local_orig","cliSessionId":"\#(Sandbox.cli)","title":"Fix build","cwd":"/repo"}"#
    static let imported =
        #"{"sessionId":"local_\#(Sandbox.cli)","cliSessionId":"\#(Sandbox.cli)","title":"Fix build","cwd":"/repo","adoptedFromOtherSurface":true}"#
    static var importedName: String { "local_\(Sandbox.cli).json" }

    @Test func windowThatOpenedAConversationKeepsOnlyItsOwnCard() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.original, to: a.appending(path: "local_orig.json"), modified: Date().addingTimeInterval(-600))
        try box.write(Self.original, to: b.appending(path: "local_orig.json"), modified: Date().addingTimeInterval(-600))
        // WORK was already open when the card arrived, so opening the conversation there made a card of its own.
        try box.write(Self.imported, to: b.appending(path: Self.importedName))

        let report = try box.sync()

        #expect(report.duplicatesRetired == 1)
        #expect(report.backedUp >= 1, "the retired card is backed up")
        #expect(!box.exists(b.appending(path: "local_orig.json")), "WORK would otherwise list it twice at its next launch")
        #expect(box.exists(b.appending(path: Self.importedName)))
        #expect(box.exists(a.appending(path: "local_orig.json")))
        #expect(!box.exists(a.appending(path: Self.importedName)), "MAIN already has a card for this conversation")
        #expect(try box.sync().changes == 0, "neither card comes back on the next run")
    }

    @Test func newWindowGetsOneCardPerConversation() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.original, to: a.appending(path: "local_orig.json"), modified: Date().addingTimeInterval(-600))
        try box.write(Self.imported, to: b.appending(path: Self.importedName))
        let fresh = try box.pair(box.work, account: Sandbox.accountA, org: "org-2")

        _ = try box.sync()

        let cards = try FileManager.default.contentsOfDirectory(atPath: fresh.path).filter { $0.hasPrefix("local_") }
        #expect(cards == [Self.importedName], "the most recently written card, and only that one")
    }

    @Test func deletingEitherCardDeletesTheConversation() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.original, to: a.appending(path: "local_orig.json"))
        try box.write("", to: b.appending(path: "deleted_local_\(Sandbox.cli)"))

        _ = try box.sync(propagateDeletions: true)

        #expect(!box.exists(a.appending(path: "local_orig.json")), "deleted in WORK under its imported name")
        #expect(box.exists(a.appending(path: "deleted_local_\(Sandbox.cli)")))
    }

    @Test func accountBoundCardIsNotDeletedWithItsContinuedCopy() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let native = #"{"sessionId":"local_branch","cliSessionId":"\#(Sandbox.cli)","title":"Branch","projectThreadChild":true}"#
        try box.write(native, to: a.appending(path: "local_branch.json"))
        try box.write("", to: b.appending(path: "deleted_local_\(Sandbox.cli)"))

        _ = try box.sync(propagateDeletions: true)

        #expect(box.read(a.appending(path: "local_branch.json")) == native)
    }

    @Test func unrelatedCardsAreUntouched() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let other = #"{"sessionId":"local_other","cliSessionId":"99999999-2222-3333-4444-555555555555"}"#
        try box.write(other, to: a.appending(path: "local_other.json"))
        try box.write(Self.imported, to: b.appending(path: Self.importedName))

        let report = try box.sync()

        #expect(report.duplicatesRetired == 0)
        #expect(box.read(b.appending(path: "local_other.json")) == other)
        #expect(box.exists(a.appending(path: Self.importedName)))
    }
}

@Suite("Finding conversations")
struct ConversationIndexTests {
    @Test func listsCodeSessionsAndCoworkTasksNewestFirstSkippingAccountBoundCards() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let code = "aaaaaaaa-0000-0000-0000-000000000001", branch = "aaaaaaaa-0000-0000-0000-000000000002"
        let archived = "aaaaaaaa-0000-0000-0000-000000000003", cowork = "aaaaaaaa-0000-0000-0000-000000000004"
        let now = Date()
        try box.transcript(code, modified: now.addingTimeInterval(-60))
        try box.transcript(branch, modified: now.addingTimeInterval(-120))
        try box.transcript(archived, modified: now)
        let card = #"{"cliSessionId":"\#(code.uppercased())","title":" Fix build ","cwd":"/repo"}"#
        try box.write(card, to: a.appending(path: "local_1.json"))
        try box.write(card, to: b.appending(path: "local_1.json"))
        try box.write(#"{"cliSessionId":"\#(branch)","projectThreadChild":true,"cwd":"/repo"}"#, to: b.appending(path: "local_2.json"))
        try box.write(#"{"cliSessionId":"\#(archived)","isArchived":true}"#, to: a.appending(path: "local_3.json"))
        try box.write(#"{"cliSessionId":"no-transcript"}"#, to: a.appending(path: "local_4.json"))

        let coworkPair = box.work.appending(path: "local-agent-mode-sessions/\(Sandbox.accountB)/org-1", directoryHint: .isDirectory)
        let taskFolder = coworkPair.appending(path: "local_task", directoryHint: .isDirectory)
        let projects = taskFolder.appending(path: ".claude/projects/-sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try box.write("{}", to: projects.appending(path: "\(cowork).jsonl"), modified: now.addingTimeInterval(-10))
        try box.write(
            #"{"cliSessionId":"\#(cowork)","title":"Report","userSelectedFolders":["/docs"]}"#,
            to: coworkPair.appending(path: "local_task.json"))
        // An old release's copy of the card, without the task's history.
        let copy = box.main.appending(path: "local-agent-mode-sessions/\(Sandbox.accountA)/org-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try box.write(#"{"cliSessionId":"\#(cowork)","title":"Report"}"#, to: copy.appending(path: "local_task.json"))

        let found = ConversationIndex.scan(paths: box.paths, windows: [("main", box.main), ("work", box.work)])

        #expect(found.map(\.sessionID) == [cowork, code], "the account-bound branch card is never offered for continuing")
        #expect(found[0].kind == .cowork && found[0].ownerID == "work" && found[0].folders == ["/docs"])
        #expect(found[0].taskFolder?.lastPathComponent == "local_task")
        #expect(found[1].kind == .code && found[1].ownerID == nil && found[1].title == "Fix build" && found[1].folders == ["/repo"])
    }

    @Test func sessionWithoutAFolderShowsNoFolder() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.transcript()
        let scratch = box.main.path + "/scratch-workspaces/\(Sandbox.accountA)/org-1/w1"
        try box.write(#"{"cliSessionId":"\#(Sandbox.cli)","cwd":"\#(scratch)","title":""}"#, to: a.appending(path: "local_1.json"))

        let found = ConversationIndex.scan(paths: box.paths, windows: [("main", box.main)])

        #expect(found.count == 1)
        #expect(found[0].folders.isEmpty)
        #expect(found[0].title == "Untitled")
    }

    @Test func ordinaryCardWinsOverABranchOfTheSameConversation() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.transcript()
        try box.write(#"{"cliSessionId":"\#(Sandbox.cli)","projectThreadChild":true}"#, to: a.appending(path: "local_branch.json"))
        try box.write(ImportedCardTests.imported, to: b.appending(path: ImportedCardTests.importedName))

        let found = ConversationIndex.scan(paths: box.paths, windows: [("main", box.main), ("work", box.work)])

        #expect(found.count == 1)
        #expect(found[0].kind == .code, "it was already continued as a regular session, which any window can open")
    }

    @Test func activityIsTheLastMessageNotTheLastWrite() throws {
        let box = try Sandbox()
        let old = Date().addingTimeInterval(-3600)
        let transcript = try box.transcript(lines: [
            #"{"type":"user","timestamp":"2026-09-27T20:00:00.000Z","message":{"content":"hi"}}"#,
            #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: old).dropLast()).000Z","message":{"content":[]}}"#,
            // Claude appends these when a window merely opens the session.
            #"{"type":"last-prompt","lastPrompt":"hi"}"#,
            #"{"type":"cost-state","startTime":1790552995627}"#,
        ])
        var conversation = Conversation(
            kind: .code, sessionID: Sandbox.cli, title: "t", folders: [],
            lastActivity: .distantPast, transcript: transcript)
        #expect(abs(try #require(ConversationIndex.lastActivity(of: transcript)).timeIntervalSince(old)) < 1)
        #expect(!conversation.isActive(), "written just now, but its last message is an hour old")

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"user\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()).dropLast()).000Z\"}".utf8))
        try handle.close()
        #expect(conversation.isActive())

        conversation.transcript = box.root.appending(path: "missing.jsonl")
        #expect(!conversation.isActive())
    }
}

@Suite("Claude links")
struct ClaudeLinkTests {
    @Test func resumeNamesTheSession() {
        #expect(ClaudeLink.resume(Sandbox.cli).absoluteString == "claude://resume?session=\(Sandbox.cli)")
    }

    @Test func textSurvivesClaudesQueryParsing() throws {
        let prompt = "C++ & 50% + “quotes” ?=#/ Привет"
        let file = URL(fileURLWithPath: "/tmp/a b+c/history.md")
        let link = ClaudeLink.newCoworkTask(prompt: prompt, files: [file])
        #expect(link.host() == "cowork" && link.path() == "/new")
        let query = try #require(link.query(percentEncoded: true))
        #expect(!query.contains("+"), "URLSearchParams would read a literal + as a space")
        #expect(!query.contains(" "))
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["q", "file"])
        #expect(items[0].value == prompt)
        #expect(items[1].value == file.path)
    }
}

@Suite("Cowork history")
struct TranscriptTextTests {
    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func keepsWhatWasSaidAndNamesTheToolsUsed() throws {
        let box = try Sandbox()
        let transcript = try box.transcript(lines: [
            Self.line(["type": "user", "message": ["role": "user", "content": "Summarize the report"]]),
            Self.line([
                "type": "assistant",
                "message": [
                    "content": [
                        ["type": "thinking", "thinking": "secret"],
                        ["type": "tool_use", "name": "Read"],
                    ]
                ],
            ]),
            Self.line(["type": "user", "message": ["content": [["type": "tool_result", "content": "file text"]]]]),
            Self.line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash"]]]]),
            Self.line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash"]]]]),
            Self.line(["type": "assistant", "message": ["content": [["type": "text", "text": "Here it is."]]]]),
            Self.line(["type": "user", "isMeta": true, "message": ["content": "<command-name>/clear</command-name>"]]),
            Self.line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "agent work"]]]]),
            Self.line(["type": "user", "isCompactSummary": true, "message": ["content": "Earlier: we read the report."]]),
            Self.line(["type": "user", "message": ["content": [["type": "image"], ["type": "text", "text": "And this?"]]]]),
            "not json",
            Self.line(["type": "summary", "summary": "x"]),
        ])

        let messages = try TranscriptText.messages(in: transcript)

        #expect(
            messages == [
                .init(role: .you, text: "Summarize the report"),
                .init(role: .claude, text: "_Used Read, Bash ×2_\n\nHere it is."),
                .init(role: .summary, text: "Earlier: we read the report."),
                .init(role: .you, text: "[image]"),
                .init(role: .you, text: "And this?"),
            ])
        let markdown = TranscriptText.markdown(messages)
        #expect(markdown.hasPrefix("**You:**\n\nSummarize the report\n"))
        #expect(!markdown.contains("secret") && !markdown.contains("file text") && !markdown.contains("agent work"))
    }

    @Test func longHistoryKeepsTheStartAndTheLatestMessages() {
        let messages = (1...100).map {
            TranscriptText.Message(role: $0.isMultiple(of: 2) ? .claude : .you, text: "message \($0) " + String(repeating: "x", count: 100))
        }
        let markdown = TranscriptText.markdown(messages, limit: 2_000)
        #expect(markdown.count < 2_300)
        #expect(markdown.contains("message 1 "))
        #expect(markdown.contains("message 100 "))
        #expect(!markdown.contains("message 50 "))
        #expect(markdown.contains("earlier messages left out"))
    }
}

@Suite("Continuing a Cowork task")
struct CoworkHandoffTests {
    func task(in box: Sandbox, files: [String: Int]) throws -> Conversation {
        let taskFolder = box.work.appending(path: "local-agent-mode-sessions/a/o/local_task", directoryHint: .isDirectory)
        for (path, size) in files {
            let url = taskFolder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        let transcript = try box.transcript(lines: [TranscriptTextTests.line(["type": "user", "message": ["content": "Draft the plan"]])])
        return Conversation(
            kind: .cowork, sessionID: Sandbox.cli, title: "Q4 plan: draft/final", folders: ["/Users/me/Plans"],
            lastActivity: Date(), transcript: transcript, ownerID: "work", taskFolder: taskFolder)
    }

    @Test func attachesThePrivateHistoryAndTheTasksFiles() throws {
        let box = try Sandbox()
        let conversation = try task(
            in: box,
            files: [
                "uploads/brief.pdf": 10, "outputs/plan.docx": 20, "outputs/.hidden": 1,
                "outputs/history.md": 5,
            ])

        let handoff = try CoworkHandoff.prepare(conversation, sourceLabel: "WORK", paths: box.paths)

        #expect(handoff.folder.deletingLastPathComponent().path == box.paths.handoffsDir.path)
        #expect(handoff.folder.lastPathComponent.hasSuffix(" Q4 plan- draft-final"))
        #expect(Set(handoff.files.map(\.lastPathComponent)) == ["brief.pdf", "plan.docx", "2-history.md"])
        let history = try String(contentsOf: handoff.history, encoding: .utf8)
        #expect(history.contains("Cowork task continued from Claude WORK"))
        #expect(history.contains("- /Users/me/Plans"))
        #expect(history.contains("Draft the plan"))
        #expect(history.contains("Not carried over: connectors, scheduled tasks"))
        let mode = try FileManager.default.attributesOfItem(atPath: handoff.history.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: handoff.folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(handoff.prompt.contains("“Q4 plan: draft/final”") && handoff.prompt.contains("history.md"))
        #expect(handoff.prompt.contains("/Users/me/Plans"))
        let items = try #require(URLComponents(url: handoff.link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "file" }.first?.value == handoff.history.path, "the history is attached first")
        #expect(items.filter { $0.name == "file" }.count == 4)
    }

    @Test func tooLargeOrTooManyFilesAreListedNotAttached() throws {
        let box = try Sandbox()
        var files = ["outputs/huge.bin": CoworkHandoff.maxFileSize + 1]
        for i in 1...12 { files["outputs/f\(i).txt"] = 1 }
        let conversation = try task(in: box, files: files)

        let handoff = try CoworkHandoff.prepare(conversation, sourceLabel: "WORK", paths: box.paths)

        #expect(handoff.files.count == CoworkHandoff.maxFiles)
        #expect(!handoff.files.contains { $0.lastPathComponent == "huge.bin" })
        let history = try String(contentsOf: handoff.history, encoding: .utf8)
        #expect(history.contains("huge.bin"))
        #expect(history.contains("Files not attached"))
    }
}

@Suite("Continue in another profile")
struct ContinueValidationTests {
    @Test func refusesWindowsThatCannotTakeTheConversation() async throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths)
        let transcript = try box.transcript()
        let code = Conversation(kind: .code, sessionID: Sandbox.cli, title: "t", folders: [], lastActivity: Date(), transcript: transcript)
        var cowork = code
        cowork.kind = .cowork
        cowork.ownerID = "main"

        await #expect(throws: ProfileError.self) { try await manager.continueConversation(code, in: "nobody") }
        await #expect(throws: ProfileError.self) { try await manager.continueConversation(code, in: "main") }
        try box.signIn(box.main)
        await #expect(throws: ProfileError.self) { try await manager.continueConversation(cowork, in: "main") }
        #expect(!box.exists(box.paths.handoffsDir), "nothing is prepared for a window that cannot take it")
    }
}

@Suite("What stays behind when a conversation continues")
struct WontFollowTests {
    @Test func wontFollowListsConnectorsBridgeAndTasks() throws {
        let box = try Sandbox()
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let card = a.appending(path: "local_1.json")
        try box.write(
            #"""
            {"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","priorCliSessionIds":["99999999-2222-3333-4444-555555555555"],
             "remoteMcpServersConfig":{"Linear":{"url":"https://example.invalid/mcp"},"Drive":{"url":"https://example.invalid/d"}},
             "enabledMcpTools":{"local:files:read_file":true,"Linear:create_issue":true,"Slack:post":false},
             "bridgeSessionIds":["bridge-1"]}
            """#, to: card)
        try box.transcript(lines: [
            #"{"type":"history-suppression","cause":"fork_inherit","sessionId":"\#(Sandbox.cli)"}"#,
            #"{"type":"user","sessionId":"\#(Sandbox.cli)","message":{"role":"user","content":"hi"}}"#,
        ])
        try box.write(#"{"preferences":{"ccdScheduledTasksEnabled":true}}"#, to: box.main.appending(path: "claude_desktop_config.json"))
        let cowork = box.main.appending(path: "local-agent-mode-sessions/\(Sandbox.accountA)/org-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cowork, withIntermediateDirectories: true)
        try box.write(#"[{"id":"t1","name":"Morning digest"},{"id":"t2","name":"Weekly report"}]"#, to: cowork.appending(path: "scheduled-tasks.json"))

        let items = Continuation.wontFollow(card: card, target: box.work, paths: box.paths)

        let kinds = items.map(\.kind)
        #expect(kinds == [.remoteConnectors, .remoteControlBridge, .scheduledTasks, .rewindLimit])
        let connectors = try #require(items.first { $0.kind == .remoteConnectors })
        #expect(connectors.names == ["Drive", "Linear", "Slack"], "local stdio tools follow; remote ones don't")
        #expect(items.first { $0.kind == .scheduledTasks }?.names == ["Morning digest", "Weekly report"])
        #expect(items.allSatisfy { !$0.detail.isEmpty && !$0.detail.contains("example.invalid") })

        // Another window of the same account has the same connectors and tasks.
        try box.signIn(box.work, account: Sandbox.accountA)
        #expect(Continuation.wontFollow(card: card, target: box.work, paths: box.paths).map(\.kind) == [.remoteControlBridge, .rewindLimit])

        // A Remote Control or Project worker belongs to its account.
        try box.signIn(box.work, account: Sandbox.accountB)
        try box.write(#"{"sessionId":"local_2","cliSessionId":"22222222-2222-3333-4444-555555555555","rcChild":true}"#, to: a.appending(path: "local_2.json"))
        #expect(
            Continuation.wontFollow(card: a.appending(path: "local_2.json"), target: box.work, paths: box.paths).map(\.kind)
                .contains(.accountBoundWorker))

        // An ordinary local session leaves nothing behind.
        try box.write(#"{}"#, to: box.main.appending(path: "claude_desktop_config.json"))
        try FileManager.default.removeItem(at: cowork.appending(path: "scheduled-tasks.json"))
        try box.write(
            #"{"sessionId":"local_3","cliSessionId":"33333333-2222-3333-4444-555555555555","cwd":"/repo","enabledMcpTools":{"local:files:read_file":true}}"#,
            to: a.appending(path: "local_3.json"))
        #expect(Continuation.wontFollow(card: a.appending(path: "local_3.json"), target: box.work, paths: box.paths).isEmpty)
    }
}
