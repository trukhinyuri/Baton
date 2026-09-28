import Foundation
import Testing

@testable import BatonKit

/// A Code session with everything Claude Code keeps beside its transcript, continued as a copy through
/// `ProfileManager` into the WORK window.
private struct ForkedSession {
    let box: Sandbox
    let manager: ProfileManager
    let conversation: Conversation
    var source: URL { conversation.transcript }
    var folder: URL { source.deletingLastPathComponent() }
    var oldFolder: URL { folder.appending(path: Sandbox.cli, directoryHint: .isDirectory) }
    var oldTemp: URL { box.paths.claudeTempDir.appending(path: "-repo/\(Sandbox.cli)", directoryHint: .isDirectory) }

    init(lines: [String]? = nil) throws {
        box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.transcript(
            lines: lines ?? [
                #"{"type":"user","sessionId":"\#(Sandbox.cli)","timestamp":"2026-09-28T10:00:00.000Z","message":{"role":"user","content":"first"}}"#
            ])
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","originCwd":"/repo","title":"T"}"#,
            to: a.appending(path: "local_1.json"))
        manager = ProfileManager(paths: box.paths)
        conversation = try #require(manager.conversations().first { $0.sessionID == Sandbox.cli })
    }

    func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func continueAsCopy() throws -> ContinuePlan {
        var plan = try #require(try manager.plan([conversation], in: "work", mode: .fork).first)
        try manager.prepare(&plan)
        return plan
    }

    func copyScratch(_ plan: ContinuePlan) -> URL {
        box.paths.claudeTempDir.appending(path: "-repo/\(plan.sessionID)/scratchpad/from-\(Sandbox.cli.prefix(8))", directoryHint: .isDirectory)
    }
}

@Suite("Continuing as a complete, fresh copy")
struct ForkCompletenessTests {
    /// Ported audit probe: the second Continue must not reopen a copy made before the source's newer messages.
    @Test func reusedCopyHasLatestHistory() throws {
        let session = try ForkedSession()
        let first = try session.continueAsCopy()
        // The user keeps working in the source window after the first continue.
        let handle = try FileHandle(forWritingTo: session.source); try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                "\n{\"type\":\"user\",\"sessionId\":\"\(Sandbox.cli)\",\"timestamp\":\"2026-09-28T11:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"LATEST-WORK\"}}\n"
                    .utf8))
        try handle.close()

        let second = try session.continueAsCopy()

        let copy = session.folder.appending(path: "\(second.sessionID).jsonl")
        let text = (try? String(contentsOf: copy, encoding: .utf8)) ?? ""
        #expect(text.contains("LATEST-WORK"), "second continue reopened copy \(second.sessionID.prefix(8)) without the source's newer messages")
        #expect(second.sessionID != first.sessionID)
        #expect(session.box.exists(session.folder.appending(path: "\(first.sessionID).jsonl")), "the first copy is its own session and stays")
    }

    @Test func unchangedSourceOrCopyWorkedInIsReused() throws {
        let session = try ForkedSession()
        let first = try session.continueAsCopy()
        #expect(try session.continueAsCopy().sessionID == first.sessionID, "the source didn't change")

        // Both moved on, the copy last: the user already works in the copy, so it is the one to reopen.
        try session.box.write("{\"type\":\"user\"}\n", to: session.source, modified: Date().addingTimeInterval(-60))
        try session.box.write("{\"type\":\"user\"}\n", to: session.folder.appending(path: "\(first.sessionID).jsonl"), modified: Date())
        #expect(try session.continueAsCopy().sessionID == first.sessionID)

        let stored = try String(contentsOf: session.box.paths.stateDir.appending(path: "continue-copies.json"), encoding: .utf8)
        #expect(stored.contains(#""version":2"#) && stored.contains("sourceLength") && stored.contains("sourceTail"))
    }

    /// Workflow journals key their entries by hashes of the prompts, which name the session's own paths, so
    /// Workflow state and scripts are copied byte for byte; sub-agent transcripts get the copy's id.
    @Test func workflowFilesStayByteExactAgentTranscriptsGetTheNewID() throws {
        let session = try ForkedSession()
        let old = Sandbox.cli
        let journal = #"{"type":"result","key":"v2:abc","text":"/tmp/x/\#(old)/scratchpad/facts.md"}"# + "\n"
        let state = #"{"scriptPath":"/p/\#(old)/workflows/scripts/s.js","sessionId":"\#(old)"}"#
        try session.put(journal, at: session.oldFolder.appending(path: "subagents/workflows/wf_1/journal.jsonl"))
        try session.put(#"{"sessionId":"\#(old)","isSidechain":true}"#, at: session.oldFolder.appending(path: "subagents/workflows/wf_1/agent-w1.jsonl"))
        try session.put(state, at: session.oldFolder.appending(path: "workflows/wf_1.json"))
        try session.put("export const meta = {}", at: session.oldFolder.appending(path: "workflows/scripts/s.js"))

        let plan = try session.continueAsCopy()

        let newFolder = session.folder.appending(path: plan.sessionID, directoryHint: .isDirectory)
        #expect(session.box.read(newFolder.appending(path: "subagents/workflows/wf_1/journal.jsonl")) == journal)
        #expect(session.box.read(newFolder.appending(path: "workflows/wf_1.json")) == state)
        #expect(session.box.read(newFolder.appending(path: "workflows/scripts/s.js")) == "export const meta = {}")
        #expect(session.box.read(newFolder.appending(path: "subagents/workflows/wf_1/agent-w1.jsonl"))?.contains(plan.sessionID) == true)
    }

    @Test func carriesScratchpadNotesReportsRest() throws {
        let session = try ForkedSession()
        let temp = session.oldTemp
        try session.put("# plan\n", at: temp.appending(path: "scratchpad/GUIDE.md"))
        try session.put("notes\n", at: temp.appending(path: "scratchpad/notes/facts.md"))
        try Data([0, 1, 2, 3]).write(to: temp.appending(path: "scratchpad/image.bin"))
        try session.put(String(repeating: "x", count: NativeForkCarry.maxFileSize + 1), at: temp.appending(path: "scratchpad/huge.md"))
        try session.put("object", at: temp.appending(path: "scratchpad/.build/debug/x.o"))
        try session.put("// swift-tools-version: 6.0", at: temp.appending(path: "scratchpad/repo-copy/Package.swift"))
        for i in 0...NativeForkCarry.maxNotesPerFolder { try session.put("// \(i)", at: temp.appending(path: "scratchpad/build-b/src/f\(i).swift")) }
        try session.put("done\n", at: temp.appending(path: "tasks/b1.output"))
        try session.put("agent\n", at: session.oldFolder.appending(path: "subagents/agent-a1.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: temp.appending(path: "tasks/a1.output"),
            withDestinationURL: session.oldFolder.appending(path: "subagents/agent-a1.jsonl"))

        let plan = try session.continueAsCopy()

        let into = session.copyScratch(plan)
        #expect(session.box.read(into.appending(path: "GUIDE.md")) == "# plan\n")
        #expect(session.box.read(into.appending(path: "notes/facts.md")) == "notes\n")
        #expect(session.box.read(into.appending(path: "tasks/b1.output")) == "done\n")
        #expect(!session.box.exists(into.appending(path: "tasks/a1.output")), "a link to a sub-agent transcript is not task output")
        for left in ["image.bin", "huge.md", "repo-copy", "build-b", ".build"] {
            #expect(!session.box.exists(into.appending(path: left)), "\(left) stays in the old scratchpad")
        }
        let carried = try #require(plan.carried)
        #expect(carried.scratchCopied.count == 3)
        #expect(
            Set(carried.leftBehind) == [
                "scratchpad/image.bin", "scratchpad/huge.md", "scratchpad/repo-copy/ (1 files)",
                "scratchpad/build-b/ (\(NativeForkCarry.maxNotesPerFolder + 1) files)",
            ])
        #expect(session.box.read(temp.appending(path: "scratchpad/GUIDE.md")) == "# plan\n", "the old scratchpad is only read")
    }

    @Test func reportsWorktreeUnderScratchpad() throws {
        let session = try ForkedSession()
        try session.put("gitdir: /repo/.git/worktrees/wt", at: session.oldTemp.appending(path: "scratchpad/wt/.git"))
        try session.put("let x = 1", at: session.oldTemp.appending(path: "scratchpad/wt/main.swift"))

        let plan = try session.continueAsCopy()

        let carried = try #require(plan.carried)
        #expect(carried.worktrees == [session.oldTemp.appending(path: "scratchpad/wt").path])
        #expect(!session.box.exists(session.copyScratch(plan).appending(path: "wt")), "a git worktree is never copied")
    }

    /// The fork keeps every record of the history, Claude's own taint records included; Baton never
    /// removes or edits one.
    @Test func forkKeepsHistorySuppressionRecords() throws {
        let suppression = #"{"type":"history-suppression","cause":"restored_owner_mismatch","ts":1}"#
        let session = try ForkedSession(lines: [
            #"{"type":"history-suppression","sessionId":"\#(Sandbox.cli)","cause":"fork_inherit","ts":0}"#,
            #"{"type":"user","sessionId":"\#(Sandbox.cli)","message":{"role":"user","content":"hi"}}"#,
            suppression,
        ])

        let plan = try session.continueAsCopy()

        let copy = try String(contentsOf: session.folder.appending(path: "\(plan.sessionID).jsonl"), encoding: .utf8)
        let records = copy.split(separator: "\n").filter { $0.contains(#""type":"history-suppression""#) }
        #expect(records.count == 2)
        #expect(copy.contains(suppression), "a record that names no session is copied byte for byte")
        #expect(copy.contains(#""cause":"fork_inherit""#))
    }

    @Test func rolledBackCopyLeavesNoScratchpad() throws {
        let session = try ForkedSession()
        try session.put("# plan\n", at: session.oldTemp.appending(path: "scratchpad/GUIDE.md"))
        let plan = try session.continueAsCopy()
        let copyTemp = session.box.paths.claudeTempDir.appending(path: "-repo/\(plan.sessionID)", directoryHint: .isDirectory)
        #expect(session.box.exists(copyTemp))

        TranscriptFork.removeCopy(
            plan.sessionID, in: session.folder, claudeDir: session.box.paths.claudeDir,
            tempDir: session.box.paths.claudeTempDir)

        #expect(!session.box.exists(copyTemp))
        #expect(session.box.exists(session.oldTemp.appending(path: "scratchpad/GUIDE.md")))
    }
}
