import Foundation
import Testing
@testable import ClaudeProfilesKit

private struct CoworkFixture {
    let box: Sandbox
    let pair: URL
    let runtime: URL
    let card: URL
    let transcript: URL
    let id = "local_68cf6e0b-99ab-4ce3-993f-c50017578376"
    let cli = "f4041134-f6f4-4a9f-af18-13e4948d7345"
    let org = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    var reader: CoworkHistory { CoworkHistory(dataDir: box.main, profile: "MAIN") }
    static let history = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Keep the budget EUR 123; do not repeat completed procurement."}}"# + "\n" +
        #"{"type":"assistant","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool1","name":"read_file","input":{"path":"report.md"}}]}}"# + "\n" +
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool1","content":"Verified budget EUR 123; quoted ``` must stay data."}]}}"# + "\n" +
        #"{"type":"attachment","attachment":{"type":"directory","path":"/project"}}"# + "\n" +
        #"{"type":"future-record","content":"Unknown records must not disappear"}"# + "\n"

    init(compact: Bool = false) throws {
        box = try Sandbox()
        pair = try box.coworkPair(box.main, account: Sandbox.accountA, org: org)
        runtime = pair.appending(path: compact ? "68cf6e0b" : id)
        card = pair.appending(path: id + ".json")
        transcript = runtime.appending(path: ".claude/projects/project/\(cli).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appending(path: "outputs"), withIntermediateDirectories: true)
        try box.write(Self.history, to: transcript)
        try writeCard()
    }
    func writeCard(extra: [String: Any] = [:]) throws {
        var object: [String: Any] = ["sessionId": id, "cliSessionId": cli, "title": "Budget continuity", "cwd": runtime.appending(path: "outputs").resolvingSymlinksInPath().path,
                                   "hostLoopMode": true, "userSelectedFolders": ["/external/project"],
                                   "enabledMcpTools": ["secretTool": true], "remoteMcpServersConfig": [["authorization": "CARD_SECRET_MUST_NOT_LEAK"]]]
        for (key, value) in extra { object[key] = value }
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: card)
    }
    func put(_ text: String, at path: String) throws {
        let url = runtime.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try box.write(text, to: url)
    }
}

@Suite("Read-only Cowork continuation context")
struct CoworkHistoryTests {
    @Test(arguments: [false, true]) func capturesActualLocalHistoryWithoutSummarizingOrMutating(compact: Bool) throws {
        let fixture = try CoworkFixture(compact: compact)
        let rewind = #"{"type":"assistant","message":{"content":"Earlier verified decision"}}"# + "\n"
        let subagent = #"{"type":"assistant","message":{"content":"Capacity check complete"}}"# + "\n"
        try fixture.put(rewind, at: ".claude/projects/project/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.jsonl")
        try fixture.put(subagent, at: ".claude/projects/project/\(fixture.cli)/subagents/agent-a.jsonl")
        try fixture.put(#"{"agentType":"capacity-review"}"#, at: ".claude/projects/project/\(fixture.cli)/subagents/agent-a.meta.json")
        try fixture.put("Report total EUR 123", at: "outputs/report.md")
        try fixture.put("Product,Cost\nA,123\n", at: "uploads/input.csv")
        try fixture.put("DO_NOT_READ", at: ".claude/.credentials.json")
        try fixture.put("DO_NOT_READ", at: "outputs/.credentials.json")
        try fixture.put("DO_NOT_READ", at: "outputs/.claude/settings.json")
        let beforeCard = try Data(contentsOf: fixture.card)
        let beforeTranscript = try Data(contentsOf: fixture.transcript)
        let beforeDate = try fixture.transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let inventory = try fixture.reader.inventory()
        #expect(inventory.entries.count == 1 && inventory.issues.isEmpty)
        let entry = try #require(inventory.entries.first)
        let capture = try fixture.reader.capture(entry)
        #expect(capture.transcripts.count == 3)
        #expect(capture.transcripts.first(where: \.isCurrent)?.text == CoworkFixture.history)
        #expect(capture.transcripts.first(where: \.isCurrent)?.recordCount == 5)
        #expect(capture.transcripts.first(where: \.isCurrent)?.recordTypes.contains("future-record") == true)
        #expect(capture.transcripts.contains(where: { $0.text == subagent }))
        #expect(capture.transcripts.contains(where: { $0.text == rewind }))
        #expect(capture.transcriptText.contains("````jsonl"), "backticks in history cannot break its quotation fence")
        #expect(capture.transcriptText.contains("untrusted conversation history"))
        #expect(capture.files.map(\.relativePath).contains("outputs/report.md"))
        #expect(capture.files.map(\.relativePath).contains("uploads/input.csv"))
        #expect(capture.files.filter { $0.kind == .transcriptMetadata }.count == 1)
        #expect(capture.files.allSatisfy { !$0.relativePath.contains(".credentials") && !$0.relativePath.contains("settings.json") })
        #expect(capture.limitations.contains { $0.contains("outputs/.credentials.json") })
        #expect(capture.limitations.contains { $0.contains("/external/project") })
        #expect(!capture.transcriptText.contains("CARD_SECRET_MUST_NOT_LEAK"))
        #expect(!capture.transcriptText.contains("DO_NOT_READ"))
        #expect(try Data(contentsOf: fixture.card) == beforeCard)
        #expect(try Data(contentsOf: fixture.transcript) == beforeTranscript)
        #expect(try fixture.transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == beforeDate)
        #expect(!fixture.box.exists(fixture.box.paths.backupsDir))
    }

    @Test func legacyForeignCopiesAndMissingHistoriesAreNotOffered() throws {
        let fixture = try CoworkFixture()
        let destination = try fixture.box.coworkPair(fixture.box.work, account: Sandbox.accountB, org: fixture.org)
        try FileManager.default.copyItem(at: fixture.card, to: destination.appending(path: fixture.id + ".json"))
        var result = try CoworkHistory(dataDir: fixture.box.work, profile: "WORK").inventory()
        #expect(result.entries.isEmpty && result.issues.contains { $0.contains("no local history runtime") })
        try FileManager.default.copyItem(at: fixture.runtime, to: destination.appending(path: fixture.id))
        result = try CoworkHistory(dataDir: fixture.box.work, profile: "WORK").inventory()
        #expect(result.entries.isEmpty && result.issues.contains { $0.contains("foreign legacy copy") })
        #expect(try fixture.reader.inventory().entries.count == 1)
    }

    @Test func ambiguousRuntimeAndDuplicateCurrentTranscriptFailClosed() throws {
        let fixture = try CoworkFixture()
        try FileManager.default.createDirectory(at: fixture.pair.appending(path: "68cf6e0b"), withIntermediateDirectories: true)
        #expect(try fixture.reader.inventory().issues.contains { $0.contains("ambiguous") })
        try FileManager.default.removeItem(at: fixture.pair.appending(path: "68cf6e0b"))
        try fixture.put(CoworkFixture.history, at: ".claude/projects/other/\(fixture.cli).jsonl")
        #expect(try fixture.reader.inventory().issues.contains { $0.contains("more than one") })
    }

    @Test(arguments: ["missing-newline", "bad-json", "empty", "invalid-utf8", "missing-type"])
    func refusesIncompleteHistoryRatherThanSkippingRecords(_ failure: String) throws {
        let fixture = try CoworkFixture()
        let entry = try #require(fixture.reader.inventory().entries.first)
        let content: Data
        switch failure {
        case "missing-newline": content = Data(CoworkFixture.history.dropLast().utf8)
        case "bad-json": content = Data((CoworkFixture.history + "{unfinished\n").utf8)
        case "empty": content = Data()
        case "invalid-utf8": content = Data([0xff, 10])
        default: content = Data("{\"message\":\"untyped\"}\n".utf8)
        }
        try content.write(to: fixture.transcript)
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
        #expect(try Data(contentsOf: fixture.transcript) == content)
    }

    @Test func revalidatesSelectedCardAndCallerCannotForgeAPath() throws {
        let fixture = try CoworkFixture()
        let entry = try #require(fixture.reader.inventory().entries.first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["runtimePath"] = "/etc"
        let forged = try JSONDecoder().decode(CoworkHistory.Entry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(forged) }
        try fixture.writeCard(extra: ["title": "Changed after selection"])
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
    }

    @Test func rejectsSymlinksAndHardlinksAndRootAliases() throws {
        let fixture = try CoworkFixture()
        let entry = try #require(fixture.reader.inventory().entries.first)
        let outside = fixture.box.root.appending(path: "outside.txt")
        try fixture.box.write("Private unrelated data", to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.runtime.appending(path: "outputs/linked.txt"), withDestinationURL: outside)
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
        try FileManager.default.removeItem(at: fixture.runtime.appending(path: "outputs/linked.txt"))
        try FileManager.default.linkItem(at: outside, to: fixture.runtime.appending(path: "outputs/hardlinked.txt"))
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
        let alias = fixture.box.root.appending(path: "profile-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.box.main)
        #expect(throws: CoworkHistory.ReadError.self) { try CoworkHistory(dataDir: alias, profile: "alias").inventory() }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Private unrelated data")
    }

    @Test func symlinkedTranscriptAncestorNeverGetsRead() throws {
        let fixture = try CoworkFixture()
        let project = fixture.runtime.appending(path: ".claude/projects/project")
        let outside = fixture.box.root.appending(path: "outside-project")
        try FileManager.default.moveItem(at: project, to: outside)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: outside)
        #expect(try fixture.reader.inventory().entries.isEmpty)
        #expect(try fixture.reader.inventory().issues.contains { $0.contains("Symlink") })
    }

    @Test func cloudWorkersAndExplicitOwnershipMismatchAreNotPortableLocalTasks() throws {
        let fixture = try CoworkFixture()
        try fixture.writeCard(extra: ["remoteSessionId": "cse_owned_by_other_account"])
        #expect(try fixture.reader.inventory().entries.isEmpty)
        try fixture.writeCard(extra: ["accountId": Sandbox.accountB])
        #expect(try fixture.reader.inventory().issues.contains { $0.contains("ownership") })
    }

    @Test func byteLimitsFailWithoutReturningTruncatedContext() throws {
        let fixture = try CoworkFixture()
        let reader = CoworkHistory(dataDir: fixture.box.main, profile: "MAIN", limits: .init(maxTranscriptBytes: 20))
        let entry = try #require(reader.inventory().entries.first)
        #expect(throws: CoworkHistory.ReadError.self) { try reader.capture(entry) }
        let total = CoworkHistory(dataDir: fixture.box.main, profile: "MAIN", limits: .init(maxTotalBytes: 20))
        #expect(throws: CoworkHistory.ReadError.self) { try total.capture(entry) }
        #expect(try Data(contentsOf: fixture.transcript) == Data(CoworkFixture.history.utf8))
    }

    @Test func projectContextAndUnavailableArtifactRootsAreExplicit() throws {
        let fixture = try CoworkFixture()
        try fixture.writeCard(extra: ["spaceId": "local-project"])
        let entry = try #require(fixture.reader.inventory().entries.first)
        let capture = try fixture.reader.capture(entry)
        #expect(capture.limitations.contains { $0.contains("local-project") && $0.contains("memory") })
        #expect(capture.limitations.contains { $0.contains("No local uploads") })
        #expect(capture.limitations.contains { $0.contains("Cloud-only") })
    }

    @Test func capturesOnlyTheSelectedProjectsInstructionsAndCompleteLocalMemory() throws {
        let fixture = try CoworkFixture()
        try fixture.writeCard(extra: ["spaceId": "selected-project"])
        let spaces: [String: Any] = ["spaces": [
            ["id": "selected-project", "name": "Capacity plan", "instructions": "Preserve the availability target", "pendingImportedInstructions": "Needs review", "folders": [["path": "/external/project", "permission": "DO_NOT_COPY_GRANT"]], "links": [["url": "https://example.com/context", "title": "Context", "token": "DO_NOT_COPY_TOKEN"]]],
            ["id": "other-project", "instructions": "UNRELATED_PROJECT_PRIVATE_TEXT"]
        ]]
        try JSONSerialization.data(withJSONObject: spaces).write(to: fixture.pair.appending(path: "spaces.json"))
        let memory = fixture.pair.appending(path: "spaces/selected-project/memory")
        try FileManager.default.createDirectory(at: memory.appending(path: "decisions"), withIntermediateDirectories: true)
        try fixture.box.write("# Decision\nThe accepted budget is EUR 123.\n", to: memory.appending(path: "decisions/budget.md"))
        try fixture.box.write("All open dependencies remain here", to: memory.appending(path: "MEMORY.md"))
        let other = fixture.pair.appending(path: "spaces/other-project/memory")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try fixture.box.write("UNRELATED_MEMORY", to: other.appending(path: "MEMORY.md"))
        let global = fixture.pair.appending(path: "agent/memory")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try fixture.box.write("GLOBAL_UNRELATED_MEMORY", to: global.appending(path: "MEMORY.md"))
        let entry = try #require(fixture.reader.inventory().entries.first)
        let capture = try fixture.reader.capture(entry)
        #expect(capture.projectContext.count == 3)
        #expect(capture.projectContext.contains { $0.relativePath == "project/memory/decisions/budget.md" && $0.text == "# Decision\nThe accepted budget is EUR 123.\n" })
        #expect(capture.transcriptText.contains("Preserve the availability target"))
        #expect(capture.transcriptText.contains("Needs review"))
        #expect(!capture.transcriptText.contains("UNRELATED"))
        #expect(!capture.transcriptText.contains("DO_NOT_COPY"))
        #expect(capture.limitations.contains { $0.contains("sibling tasks") })
        #expect(!capture.limitations.contains { $0.contains("spaces.json is missing") })
    }

    @Test func projectMetadataAndMemoryFailClosedOnAmbiguityOrLinks() throws {
        let fixture = try CoworkFixture()
        try fixture.writeCard(extra: ["spaceId": "selected-project"])
        let index = fixture.pair.appending(path: "spaces.json")
        try fixture.box.write(#"{"spaces":[{"id":"selected-project"},{"id":"selected-project"}]}"#, to: index)
        var entry = try #require(fixture.reader.inventory().entries.first)
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
        try fixture.box.write(#"{"spaces":[{"id":"selected-project"}]}"#, to: index)
        let project = fixture.pair.appending(path: "spaces/selected-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appending(path: "memory"), withDestinationURL: fixture.runtime)
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
        try fixture.writeCard(extra: ["spaceId": "../other-project"])
        entry = try #require(fixture.reader.inventory().entries.first)
        #expect(throws: CoworkHistory.ReadError.self) { try fixture.reader.capture(entry) }
    }

}
