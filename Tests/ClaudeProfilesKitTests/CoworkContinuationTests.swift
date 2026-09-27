import Foundation
import Testing
@testable import ClaudeProfilesKit

private struct CoworkSaveFixture {
    let profile: String
    let dataDir: URL
    let card: URL
    let transcript: URL
    let artifact: URL
    let projectMemory: URL
    let rawHistory: String
    let rewind: String
    let subagent: String
    let artifactBytes: Data
    var reader: CoworkHistory { CoworkHistory(dataDir: dataDir, profile: profile) }

    init(box: Sandbox, profile: String, marker: String, artifactBytes: Data) throws {
        self.profile = profile
        self.dataDir = profile == "main" ? box.main : box.work
        self.artifactBytes = artifactBytes
        let id = "local_" + UUID().uuidString.lowercased()
        let cli = UUID().uuidString.lowercased()
        let pair = try box.coworkPair(dataDir, account: profile == "main" ? Sandbox.accountA : Sandbox.accountB,
                                     org: "dddddddd-dddd-dddd-dddd-dddddddddddd")
        let runtime = pair.appending(path: id)
        card = pair.appending(path: id + ".json")
        transcript = runtime.appending(path: ".claude/projects/project/\(cli).jsonl")
        artifact = runtime.appending(path: "outputs/result.bin")
        let fm = FileManager.default
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        var records: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "EARLY_\(marker): preserve original capacity goal and budget EUR 731; procurement already completed."]]
        ]
        for index in 0..<120 {
            records.append(["type": "assistant", "message": ["role": "assistant", "content": "\(marker) exact intermediate record \(index)"]])
        }
        records.append(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "check_1", "content": "Verified \(marker) result; quoted ``` must remain history"]]]])
        records.append(["type": "future-record", "unrecognizedData": "PRESERVE_UNKNOWN_\(marker)"])
        records.append(["type": "assistant", "message": ["role": "assistant", "content": "LATE_\(marker): verified report saved; next action is review, not repeat procurement."]])
        rawHistory = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) + "\n" }.joined()
        rewind = #"{"type":"assistant","message":{"content":"REWIND_\#(marker) accepted decision"}}"# + "\n"
        subagent = #"{"type":"assistant","message":{"content":"SUBAGENT_\#(marker) complete evidence"}}"# + "\n"
        try Data(rawHistory.utf8).write(to: transcript)
        try Data(rewind.utf8).write(to: transcript.deletingLastPathComponent().appending(path: UUID().uuidString.lowercased() + ".jsonl"))
        let child = transcript.deletingLastPathComponent().appending(path: "\(cli)/subagents/agent-capacity.jsonl")
        try fm.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(subagent.utf8).write(to: child)
        try artifactBytes.write(to: artifact)
        let object: [String: Any] = [
            "sessionId": id, "cliSessionId": cli, "title": "Capacity work \(marker)",
            "cwd": artifact.deletingLastPathComponent().resolvingSymlinksInPath().path,
            "hostLoopMode": true, "spaceId": "selected-project", "userSelectedFolders": ["/external/capacity"],
            "remoteMcpServersConfig": [["authorization": "CARD_CREDENTIAL_NOT_CONTEXT"]]
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: card)
        let spaces: [String: Any] = ["spaces": [["id": "selected-project", "name": "Capacity", "instructions": "PROJECT_INSTRUCTION_\(marker): retain reliability target"]]]
        try JSONSerialization.data(withJSONObject: spaces).write(to: pair.appending(path: "spaces.json"))
        projectMemory = pair.appending(path: "spaces/selected-project/memory/MEMORY.md")
        try fm.createDirectory(at: projectMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MEMORY_\(marker): agreed capacity and outstanding dependencies\n".utf8).write(to: projectMemory)
    }

    func capture() throws -> CoworkHistory.Capture {
        let entry = try #require(reader.inventory().entries.first)
        return try reader.capture(entry)
    }

    func sourceBytes() throws -> [String: Data] {
        let root = dataDir.resolvingSymlinksInPath()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        return files
    }
}

@Suite("Cowork full-context package adapter")
struct CoworkContinuationTests {
    private let fm = FileManager.default

    @Test func savedWorkspacePreservesExactEarlyLateHistoryProjectContextAndArtifactBytes() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let fixture = try CoworkSaveFixture(box: box, profile: "main", marker: "SOURCE", artifactBytes: Data([0, 255, 17, 0, 128, 10]))
        let sourceBefore = try fixture.sourceBytes()
        let transcriptDate = try fixture.transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let capture = try fixture.capture()
        let store = try CoworkContinuation.save(capture, paths: box.paths)
        let snapshot = try ContinuityWorkspace(directory: store.directory).load()
        let conversation = try #require(snapshot.entries.first { $0.path.hasSuffix("/conversation.md") })
        let text = String(decoding: try store.data(for: conversation), as: UTF8.self)
        #expect(text == capture.transcriptText)
        #expect(text.contains(fixture.rawHistory), "the complete raw JSONL remains present, including early and late records")
        #expect(text.contains("EARLY_SOURCE") && text.contains("LATE_SOURCE") && text.contains("PRESERVE_UNKNOWN_SOURCE"))
        #expect(text.contains(fixture.rewind) && text.contains(fixture.subagent))
        #expect(text.contains("PROJECT_INSTRUCTION_SOURCE") && text.contains("MEMORY_SOURCE"))
        #expect(!text.contains("CARD_CREDENTIAL_NOT_CONTEXT"))
        let artifact = try #require(snapshot.entries.first { $0.path.hasSuffix("/outputs/result.bin") })
        #expect(try store.data(for: artifact) == fixture.artifactBytes)
        #expect(artifact.sha256 == ContinuityWorkspace.sha256(fixture.artifactBytes))
        let metadata = try #require(snapshot.entries.first { $0.path.hasSuffix("/source.json") })
        let savedSource = try JSONDecoder().decode(CoworkHistory.Entry.self, from: store.data(for: metadata))
        #expect(savedSource == capture.entry)
        #expect(snapshot.coverage.contains { $0.component.hasSuffix(": local history") && $0.status == .complete })
        #expect(snapshot.coverage.contains { $0.component.hasSuffix(": project instructions and memory") && $0.status == .partial })
        #expect(snapshot.limitations.contains { $0.contains("/external/capacity") })
        #expect(try fixture.sourceBytes() == sourceBefore)
        #expect(try fixture.transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == transcriptDate)
        #expect(!box.exists(box.paths.backupsDir), "packaging should not rewrite or back up native account data")
    }

    @Test func appendingDestinationCapturePreservesBothHistoriesAndDifferingArtifacts() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try CoworkSaveFixture(box: box, profile: "main", marker: "SOURCE", artifactBytes: Data("version A".utf8))
        let destination = try CoworkSaveFixture(box: box, profile: "work", marker: "DESTINATION", artifactBytes: Data("version B with verified result".utf8))
        let sourceBefore = try source.sourceBytes(), destinationBefore = try destination.sourceBytes()
        let first = try source.capture(), second = try destination.capture()
        let store = try CoworkContinuation.save(first, paths: box.paths)
        let prior = try store.load()
        let originalPayload = try Dictionary(uniqueKeysWithValues: prior.entries.map { ($0.path, try store.data(for: $0)) })
        let continued = try CoworkContinuation.save(second, paths: box.paths, existingWorkspace: store.directory)
        let result = try continued.load()
        #expect(continued.directory.path == store.directory.path)
        #expect(result.revision == prior.revision + 1)
        #expect(result.sourceProfileID == "main")
        for old in prior.entries {
            #expect(result.entries.contains(old))
            #expect(try continued.data(for: old) == originalPayload[old.path])
        }
        let conversations = try result.entries.filter { $0.path.hasSuffix("/conversation.md") }.map { String(decoding: try continued.data(for: $0), as: UTF8.self) }
        #expect(conversations.count == 2)
        #expect(conversations.contains(first.transcriptText) && conversations.contains(second.transcriptText))
        let artifacts = try result.entries.filter { $0.path.hasSuffix("/outputs/result.bin") }.map { try continued.data(for: $0) }
        #expect(artifacts.count == 2)
        #expect(artifacts.contains(source.artifactBytes) && artifacts.contains(destination.artifactBytes))
        let origins = try result.entries.filter { $0.path.hasSuffix("/source.json") }.map { try JSONDecoder().decode(CoworkHistory.Entry.self, from: continued.data(for: $0)) }
        #expect(Set(origins.map(\.profile)) == ["main", "work"])
        #expect(Set(origins.map(\.sourceURL)) == [first.entry.sourceURL, second.entry.sourceURL])
        #expect(try source.sourceBytes() == sourceBefore)
        #expect(try destination.sourceBytes() == destinationBefore)
    }

    @Test func changedArtifactAfterReviewFailsWithoutAdvancingLatestRevision() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let fixture = try CoworkSaveFixture(box: box, profile: "main", marker: "SOURCE", artifactBytes: Data("version A".utf8))
        let reviewed = try fixture.capture()
        let store = try CoworkContinuation.save(reviewed, paths: box.paths)
        let before = try store.load()
        let pointerURL = store.directory.appending(path: "LATEST.json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let cardBefore = try Data(contentsOf: fixture.card)
        try Data("version B".utf8).write(to: fixture.artifact) // Same length: hash validation must catch it.
        #expect(throws: (any Error).self) { try CoworkContinuation.save(reviewed, paths: box.paths, existingWorkspace: store.directory) }
        let after = try store.load()
        #expect(after.revision == before.revision)
        #expect(after.entries == before.entries)
        #expect(try Data(contentsOf: pointerURL) == pointerBefore)
        #expect(try Data(contentsOf: fixture.card) == cardBefore)
        #expect(try Data(contentsOf: fixture.artifact) == Data("version B".utf8), "failed packaging must not revert or modify the source")
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path).allSatisfy { !$0.hasPrefix(".capture-") })
    }

    @Test(arguments: ["transcript", "project-memory"])
    func sourceContextChangedAfterReviewCannotPublishAStaleSnapshot(component: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let fixture = try CoworkSaveFixture(box: box, profile: "main", marker: "SOURCE", artifactBytes: Data("unchanged artifact".utf8))
        let reviewed = try fixture.capture()
        let workspace = try CoworkContinuation.save(reviewed, paths: box.paths)
        let before = try workspace.load()
        let pointer = workspace.directory.appending(path: "LATEST.json")
        let pointerBefore = try Data(contentsOf: pointer)
        let changed: URL
        let replacement: Data
        if component == "transcript" {
            changed = fixture.transcript
            replacement = Data((fixture.rawHistory + #"{"type":"assistant","message":{"content":"New work finished after the review"}}"# + "\n").utf8)
        } else {
            changed = fixture.projectMemory
            replacement = Data("A decision changed after review; the saved context must not hide this.\n".utf8)
        }
        try replacement.write(to: changed)
        #expect(throws: (any Error).self) {
            try CoworkContinuation.save(reviewed, paths: box.paths, existingWorkspace: workspace.directory)
        }
        let after = try workspace.load()
        #expect(after.revision == before.revision)
        #expect(after.entries == before.entries)
        #expect(try Data(contentsOf: pointer) == pointerBefore)
        #expect(try Data(contentsOf: changed) == replacement)
        #expect(try fm.contentsOfDirectory(atPath: workspace.directory.path).allSatisfy { !$0.hasPrefix(".capture-") })
    }
}
