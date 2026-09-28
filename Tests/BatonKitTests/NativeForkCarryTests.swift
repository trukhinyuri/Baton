import CryptoKit
import Foundation
import Testing

@testable import BatonKit

/// A session Claude Desktop copied itself: `new` starts with `old`'s records, and a card names `old` as prior.
private struct DesktopFork {
    static let old = "11111111-1111-4111-8111-111111111111"
    static let new = "22222222-2222-4222-8222-222222222222"
    static let project = "-Users-me-work"
    let box: Sandbox
    var projects: URL { box.paths.claudeProjectsDir.appending(path: Self.project, directoryHint: .isDirectory) }
    var oldFolder: URL { projects.appending(path: Self.old, directoryHint: .isDirectory) }
    var newFolder: URL { projects.appending(path: Self.new, directoryHint: .isDirectory) }
    var oldTemp: URL { box.paths.claudeTempDir.appending(path: "\(Self.project)/\(Self.old)", directoryHint: .isDirectory) }
    var carriedScratch: URL {
        box.paths.claudeTempDir.appending(path: "\(Self.project)/\(Self.new)/scratchpad/from-\(Self.old.prefix(8))", directoryHint: .isDirectory)
    }

    static func record(_ uuid: String, session: String, text: String = "hi") -> String {
        #"{"type":"user","uuid":"\#(uuid)","sessionId":"\#(session)","message":{"role":"user","content":"\#(text)"}}"#
    }

    init(sharedHistory: Bool = true) throws {
        box = try Sandbox()
        let history = (1...6).map { Self.record("u\($0)", session: Self.old) }
        try put(history.joined(separator: "\n") + "\n", at: projects.appending(path: "\(Self.old).jsonl"))
        let copied =
            sharedHistory
            ? (1...6).map { Self.record("u\($0)", session: Self.new) }
            : (1...6).map { Self.record("fresh\($0)", session: Self.new) }
        let fork = #"{"type":"history-suppression","sessionId":"\#(Self.new)","cause":"fork_inherit","ts":1}"#
        try put(([fork] + copied).joined(separator: "\n") + "\n", at: projects.appending(path: "\(Self.new).jsonl"))

        let agent = [Self.record("a1", session: Self.old, text: "look at \(Self.old)")].joined() + "\n"
        try put(agent, at: oldFolder.appending(path: "subagents/agent-a1.jsonl"))
        try put(#"{"agentType":"general-purpose"}"#, at: oldFolder.appending(path: "subagents/agent-a1.meta.json"))
        try put(
            #"{"type":"result","key":"v2:abc","text":"/tmp/x/\#(Self.old)/scratchpad/facts.md"}"# + "\n",
            at: oldFolder.appending(path: "subagents/workflows/wf_1/journal.jsonl"))
        try put(#"{"scriptPath":"/p/\#(Self.old)/workflows/scripts/s.js"}"#, at: oldFolder.appending(path: "workflows/wf_1.json"))
        try put("export const meta = {}", at: oldFolder.appending(path: "workflows/scripts/s.js"))
        try put("long tool output", at: oldFolder.appending(path: "tool-results/toolu_1.txt"))

        try put("# plan\n", at: oldTemp.appending(path: "scratchpad/GUIDE.md"))
        try put("notes\n", at: oldTemp.appending(path: "scratchpad/notes/facts.md"))
        try Data([0, 1, 2, 3]).write(to: oldTemp.appending(path: "scratchpad/image.bin"))
        try put(String(repeating: "x", count: NativeForkCarry.maxFileSize + 1), at: oldTemp.appending(path: "scratchpad/huge.md"))
        try put("gitdir: /repo/.git/worktrees/wt", at: oldTemp.appending(path: "scratchpad/wt/.git"))
        try put("let x = 1", at: oldTemp.appending(path: "scratchpad/wt/main.swift"))
        try put("object", at: oldTemp.appending(path: "scratchpad/.build/debug/x.o"))
        try put("// swift-tools-version: 6.0", at: oldTemp.appending(path: "scratchpad/repo-copy/Package.swift"))
        try put("let y = 2", at: oldTemp.appending(path: "scratchpad/repo-copy/Sources/y.swift"))
        for i in 0...NativeForkCarry.maxNotesPerFolder { try put("// \(i)", at: oldTemp.appending(path: "scratchpad/build-b/src/f\(i).swift")) }
        try put("done\n", at: oldTemp.appending(path: "tasks/b1.output"))
        try FileManager.default.createSymbolicLink(
            at: oldTemp.appending(path: "tasks/a1.output"),
            withDestinationURL: oldFolder.appending(path: "subagents/agent-a1.jsonl"))

        let cards = try box.pair(box.main, account: Sandbox.accountA)
        try put(
            #"{"cliSessionId":"\#(Self.new)","priorCliSessionIds":["\#(Self.old)"],"cwd":"/Users/me/work"}"#,
            at: cards.appending(path: "local_card.json"))
    }

    func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func run(dryRun: Bool = false) throws -> [NativeForkCarry.Report] {
        try NativeForkCarry.run(paths: box.paths, dataDirs: [box.main, box.work], dryRun: dryRun)
    }

    /// Every file under the old session's folders with its SHA-256, to prove nothing there changed.
    func oldFingerprint() -> [String: String] {
        var result: [String: String] = [:]
        for root in [oldFolder, oldTemp] {
            for relative in NativeForkCarry.files(under: root) {
                let data = (try? Data(contentsOf: root.appending(path: relative))) ?? Data()
                result["\(root.lastPathComponent)/\(relative)"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        result["old.jsonl"] = box.read(projects.appending(path: "\(Self.old).jsonl"))
        return result
    }
}

@Suite("Carry after Claude Desktop's own copy")
struct NativeForkCarryTests {
    @Test func carriesSidecarsAfterDesktopFork() throws {
        let fork = try DesktopFork()
        let reports = try fork.run()
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.lineage == .init(old: DesktopFork.old, new: DesktopFork.new))

        let agent = try #require(fork.box.read(fork.newFolder.appending(path: "subagents/agent-a1.jsonl")))
        #expect(agent.contains(#""sessionId":"\#(DesktopFork.new)""#))
        #expect(agent.contains("look at \(DesktopFork.old)"))  // what the agent was told stays as it was
        for same in [
            "subagents/agent-a1.meta.json", "subagents/workflows/wf_1/journal.jsonl", "workflows/wf_1.json",
            "workflows/scripts/s.js", "tool-results/toolu_1.txt",
        ] {
            #expect(fork.box.read(fork.newFolder.appending(path: same)) == fork.box.read(fork.oldFolder.appending(path: same)), "\(same)")
        }
        #expect(fork.box.read(fork.carriedScratch.appending(path: "GUIDE.md")) == "# plan\n")
        #expect(fork.box.read(fork.carriedScratch.appending(path: "notes/facts.md")) == "notes\n")
        #expect(fork.box.read(fork.carriedScratch.appending(path: "tasks/b1.output")) == "done\n")
        #expect(!fork.box.exists(fork.carriedScratch.appending(path: "tasks/a1.output")))  // a link to a sub-agent carried above
        #expect(!fork.box.exists(fork.carriedScratch.appending(path: "image.bin")))
        #expect(!fork.box.exists(fork.carriedScratch.appending(path: ".build")))
        #expect(!fork.box.exists(fork.carriedScratch.appending(path: "wt")))
        #expect(!fork.box.exists(fork.carriedScratch.appending(path: "build-b")))
        #expect(Set(report.leftBehind) == ["scratchpad/huge.md", "scratchpad/image.bin", "scratchpad/build-b/ (201 files)", "scratchpad/repo-copy/ (2 files)"])
        #expect(report.worktrees == [fork.oldTemp.appending(path: "scratchpad/wt").path])
        #expect(report.added.count == 9)
        // The new session's own checkpoints get the same names as the old ones, so they are never carried.
        #expect(!fork.box.exists(fork.box.paths.claudeDir.appending(path: "file-history/\(DesktopFork.new)")))
        // The taint Claude Code wrote into the copy stays.
        #expect(fork.box.read(fork.projects.appending(path: "\(DesktopFork.new).jsonl"))?.contains("fork_inherit") == true)
    }

    @Test func neverOverwritesNewSessionFiles() throws {
        let fork = try DesktopFork()
        try fork.put("the new session's own", at: fork.newFolder.appending(path: "tool-results/toolu_1.txt"))
        try fork.put("# new plan\n", at: fork.carriedScratch.appending(path: "GUIDE.md"))
        let report = try #require(try fork.run().first)
        #expect(fork.box.read(fork.newFolder.appending(path: "tool-results/toolu_1.txt")) == "the new session's own")
        #expect(fork.box.read(fork.carriedScratch.appending(path: "GUIDE.md")) == "# new plan\n")
        #expect(report.kept == 2)
        #expect(!report.added.contains { $0.hasSuffix("toolu_1.txt") || $0.hasSuffix("GUIDE.md") })
    }

    @Test func secondRunIsNoop() throws {
        let fork = try DesktopFork()
        _ = try fork.run()
        let manifest = fork.box.read(fork.box.paths.carriedFile)
        #expect(manifest?.contains(DesktopFork.new) == true)
        #expect(try fork.run().isEmpty)
        #expect(fork.box.read(fork.box.paths.carriedFile) == manifest)
    }

    @Test func dryRunWritesNothing() throws {
        let fork = try DesktopFork()
        let report = try #require(try fork.run(dryRun: true).first)
        #expect(report.added.count == 9)
        #expect(!fork.box.exists(fork.newFolder))
        #expect(!fork.box.exists(fork.carriedScratch))
        #expect(!fork.box.exists(fork.box.paths.carriedFile))
    }

    @Test func unrelatedPriorSkipped() throws {
        // `/clear` starts a new conversation in the same card: it shares no records with the old one.
        let fork = try DesktopFork(sharedHistory: false)
        #expect(try fork.run().isEmpty)
        #expect(!fork.box.exists(fork.newFolder))
        #expect(!fork.box.exists(fork.carriedScratch))
        #expect(fork.box.read(fork.box.paths.carriedFile)?.contains("unrelated") == true)
        #expect(try fork.run().isEmpty)
    }

    @Test func oldSessionUntouched() throws {
        let fork = try DesktopFork()
        let before = fork.oldFingerprint()
        _ = try fork.run()
        _ = try fork.run()
        #expect(fork.oldFingerprint() == before)
    }

    @Test func filesMadeAfterTheCopyStayWithTheOldSession() throws {
        let fork = try DesktopFork()
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: fork.projects.appending(path: "\(DesktopFork.new).jsonl").path)
        let early = fork.oldFolder.appending(path: "tool-results/toolu_0.txt")
        try fork.put("before the copy", at: early)
        try FileManager.default.setAttributes([.creationDate: past.addingTimeInterval(-60)], ofItemAtPath: early.path)
        let report = try #require(try fork.run().first)
        #expect(report.added == ["projects/\(DesktopFork.project)/\(DesktopFork.new)/tool-results/toolu_0.txt"])
    }
}
