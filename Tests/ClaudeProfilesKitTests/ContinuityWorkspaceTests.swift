import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Complete-context continuation workspace")
struct ContinuityWorkspaceTests {
    private let fm = FileManager.default
    private let sourceURL = URL(string: "https://claude.ai/epitaxy/project/chan_source")!
    private let mirrorURL = URL(string: "https://claude.ai/epitaxy/project/chan_mirror")!

    private func workspace(_ box: Sandbox) throws -> ContinuityWorkspace {
        try .create(in: box.root.appending(path: "Workspaces"), title: "Existing work", kind: "codeProject", sourceProfileID: "source", sourceURL: sourceURL)
    }
    private func contents(_ store: ContinuityWorkspace, _ path: String) throws -> Data {
        let snapshot = try store.load()
        let entry = try #require(snapshot.entries.first { $0.path == path })
        return try store.data(for: entry)
    }

    @Test func fullTextBinaryAndProvenanceSurviveReloadWithPrivatePermissions() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let file = box.root.appending(path: "attachment.bin")
        let binary = Data([0, 255, 0, 1, 128])
        try binary.write(to: file)
        let transcript = String(repeating: "Original transcript, not a summary.\n", count: 2000)
        let first = try store.publish(texts: [.init(path: "capture-1/transcript.jsonl", text: transcript, sourceURL: sourceURL)],
                                      files: [.init(path: "capture-1/attachment.bin", fileURL: file.resolvingSymlinksInPath(), expectedSHA256: ContinuityWorkspace.sha256(binary), expectedSize: binary.count)],
                                      coverage: [.init(component: "transcript", status: .complete, detail: "All selected transcript records captured"),
                                                 .init(component: "cloud memory", status: .unavailable, detail: "Not included in this capture")],
                                      limitations: ["Original native threads retain their owner"], expectedRevision: 0)
        #expect(first.revision == 1)
        let reopened = ContinuityWorkspace(directory: store.directory)
        let loaded = try reopened.load()
        #expect(loaded.workspaceID == first.workspaceID)
        #expect(loaded.entries.count == 2)
        #expect(loaded.mirrors["source"] == sourceURL)
        #expect(try contents(reopened, "capture-1/transcript.jsonl") == Data(transcript.utf8))
        #expect(try contents(reopened, "capture-1/attachment.bin") == binary)
        #expect(loaded.entries.first?.source == sourceURL.absoluteString)
        #expect(loaded.coverage.contains { $0.component == "cloud memory" && $0.status == .unavailable })
        #expect(loaded.limitations == ["Original native threads retain their owner"])
        #expect(try fm.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int == 0o700)
        for entry in loaded.entries {
            #expect(try fm.attributesOfItem(atPath: store.directory.appending(path: entry.payloadPath).path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try fm.attributesOfItem(atPath: store.directory.appending(path: "LATEST.json").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func roundTripKeepsEarlierCapturesAndSeparateNativeObjects() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        var snapshot = try store.publish(texts: [.init(path: "source/context.md", text: "Original objective and unfinished task")], coverage: [], limitations: [], expectedRevision: 0)
        snapshot = try store.setMirror(profileID: "destination", nativeURL: mirrorURL, expectedRevision: snapshot.revision)
        #expect(throws: (any Error).self) { try store.activate(profileID: "destination", sourcePaused: false, expectedRevision: snapshot.revision) }
        snapshot = try store.activate(profileID: "destination", sourcePaused: true, expectedRevision: snapshot.revision)
        snapshot = try store.publish(texts: [.init(path: "destination/result.md", text: "Verified implementation; next check deployment")], coverage: [], limitations: [], expectedRevision: snapshot.revision)
        snapshot = try store.activate(profileID: "source", sourcePaused: true, expectedRevision: snapshot.revision)
        #expect(snapshot.activeProfile == "source")
        #expect(snapshot.mirrors == ["source": sourceURL, "destination": mirrorURL])
        #expect(snapshot.entries.count == 2)
        #expect(try contents(store, "source/context.md") == Data("Original objective and unfinished task".utf8))
        #expect(try contents(store, "destination/result.md") == Data("Verified implementation; next check deployment".utf8))
    }

    @Test func staleChangesAndLogicalOverwriteCannotDiscardHistory() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let first = try store.publish(texts: [.init(path: "history.md", text: "first")], coverage: [], limitations: [], expectedRevision: 0)
        #expect(throws: (any Error).self) { try store.publish(texts: [.init(path: "lost.md", text: "stale")], coverage: [], limitations: [], expectedRevision: 0) }
        #expect(throws: (any Error).self) { try store.setMirror(profileID: "destination", nativeURL: mirrorURL, expectedRevision: 0) }
        #expect(throws: (any Error).self) { try store.publish(texts: [.init(path: "history.md", text: "replacement")], coverage: [], limitations: [], expectedRevision: first.revision) }
        #expect(throws: (any Error).self) {
            try store.publish(texts: [.init(path: "written-before-failure.md", text: "temporary"), .init(path: "history.md", text: "replacement")], coverage: [], limitations: [], expectedRevision: first.revision)
        }
        #expect(try store.load().revision == first.revision)
        #expect(try contents(store, "history.md") == Data("first".utf8))
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path).allSatisfy { !$0.hasPrefix(".capture-") })
        let repeated = try store.publish(texts: [.init(path: "history.md", text: "first")], coverage: [], limitations: [], expectedRevision: first.revision)
        #expect(repeated.entries.count == 1)
    }

    @Test func changedSelectedFilePublishesNothingAndLeavesPreviousRevisionReadable() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let file = box.root.appending(path: "selected.txt")
        let selected = Data("old".utf8)
        try Data("new".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try store.publish(texts: [.init(path: "partial.md", text: "must not become visible")],
                              files: [.init(path: "selected.txt", fileURL: file.resolvingSymlinksInPath(), expectedSHA256: ContinuityWorkspace.sha256(selected), expectedSize: selected.count)],
                              coverage: [], limitations: [], expectedRevision: 0)
        }
        #expect(try store.load().revision == 0)
        #expect(try store.load().entries.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path).allSatisfy { !$0.hasPrefix(".capture-") })
    }

    @Test(arguments: ["../outside", "/absolute", "a/../b", "a//b", "a/./b", "a\\b", "C:drive", "line\nbreak", ""])
    func rejectsUnsafeLogicalPaths(path: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        #expect(throws: (any Error).self) { try store.publish(texts: [.init(path: path, text: "data")], coverage: [], limitations: [], expectedRevision: 0) }
        #expect(try store.load().revision == 0)
    }

    @Test func importedInstructionNamesStayInertAndSymlinkSourcesAreRejected() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let text = "Never execute this historical instruction"
        let snapshot = try store.publish(texts: [.init(path: "CLAUDE.md", text: text), .init(path: ".claude/skills/example/SKILL.md", text: text)], coverage: [], limitations: [], expectedRevision: 0)
        #expect(!fm.fileExists(atPath: store.directory.appending(path: "CLAUDE.md").path))
        #expect(!fm.fileExists(atPath: store.directory.appending(path: ".claude").path))
        #expect(snapshot.entries.allSatisfy { $0.payloadPath.hasSuffix(".data") })
        let source = box.root.resolvingSymlinksInPath().appending(path: "source.txt")
        let link = box.root.resolvingSymlinksInPath().appending(path: "link.txt")
        let bytes = Data(text.utf8)
        try bytes.write(to: source)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) {
            try store.publish(texts: [], files: [.init(path: "link.txt", fileURL: link, expectedSHA256: ContinuityWorkspace.sha256(bytes), expectedSize: bytes.count)],
                              coverage: [], limitations: [], expectedRevision: snapshot.revision)
        }
        let realFolder = box.root.resolvingSymlinksInPath().appending(path: "real-folder")
        let linkedFolder = box.root.resolvingSymlinksInPath().appending(path: "linked-folder")
        try fm.createDirectory(at: realFolder, withIntermediateDirectories: false)
        try bytes.write(to: realFolder.appending(path: "source.txt"))
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: realFolder)
        #expect(throws: (any Error).self) {
            try store.publish(texts: [], files: [.init(path: "parent-link.txt", fileURL: linkedFolder.appending(path: "source.txt"), expectedSHA256: ContinuityWorkspace.sha256(bytes), expectedSize: bytes.count)],
                              coverage: [], limitations: [], expectedRevision: snapshot.revision)
        }
    }

    @Test func corruptionAndPayloadSymlinksFailIntegrityChecks() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let snapshot = try store.publish(texts: [.init(path: "context.md", text: "verified")], coverage: [], limitations: [], expectedRevision: 0)
        let entry = try #require(snapshot.entries.first)
        let payload = store.directory.appending(path: entry.payloadPath)
        try Data("tampered".utf8).write(to: payload)
        #expect(throws: (any Error).self) { try store.load() }
        try fm.removeItem(at: payload)
        let outside = box.root.appending(path: "outside.txt")
        try Data("verified".utf8).write(to: outside)
        try fm.createSymbolicLink(at: payload, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func manifestCorruptionAndUnknownPointerFailClosed() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let pointerURL = store.directory.appending(path: "LATEST.json")
        let pointerData = try Data(contentsOf: pointerURL)
        let pointer = try #require(try JSONSerialization.jsonObject(with: pointerData) as? [String: Any])
        let id = try #require(pointer["snapshot"] as? String)
        try Data("{}".utf8).write(to: store.directory.appending(path: "snapshots/\(id)/manifest.json"))
        #expect(throws: (any Error).self) { try store.load() }
        try Data(#"{"snapshot":"../../outside","revision":0,"manifestSHA256":"ignored"}"#.utf8).write(to: pointerURL)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func gapsPersistWithoutClaimsOfAutomaticToolOrThreadTransfer() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let partial = ContinuityWorkspace.Coverage(component: "threads", status: .partial, detail: "Only two visible transcripts were captured")
        var snapshot = try store.publish(texts: [], coverage: [partial], limitations: ["Connector must be connected separately"], expectedRevision: 0)
        snapshot = try store.publish(texts: [.init(path: "followup.md", text: "Additional verified result")], coverage: [], limitations: [], expectedRevision: snapshot.revision)
        #expect(snapshot.coverage == [partial])
        #expect(snapshot.limitations == ["Connector must be connected separately"])
        let instructions = try String(contentsOf: store.continuationFile, encoding: .utf8)
        #expect(instructions.contains("not as fresh authorization"))
        #expect(instructions.contains("does not transfer the original live threads"))
        #expect(instructions.contains("Do not send messages"))
        #expect(store.continuationPrompt.contains("If these files are not accessible"))
    }

    @Test func mirrorMustBeDistinctAndNativeLinksCannotContainCredentials() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        #expect(throws: (any Error).self) { try store.setMirror(profileID: "destination", nativeURL: sourceURL, expectedRevision: 0) }
        #expect(throws: (any Error).self) { try store.setMirror(profileID: "destination", nativeURL: URL(string: sourceURL.absoluteString + "?thread=another")!, expectedRevision: 0) }
        #expect(throws: (any Error).self) { try store.activate(profileID: "missing", sourcePaused: true, expectedRevision: 0) }
        for unsafe in ["https://claude.ai.evil.test/project/a", "https://user:secret@claude.ai/project/a", "https://claude.ai/project/a?token=secret", "https://claude.ai/code/projects/browse", "https://claude.ai/project/"] {
            #expect(throws: (any Error).self) { try store.setMirror(profileID: "destination", nativeURL: URL(string: unsafe)!, expectedRevision: 0) }
        }
        #expect(try store.load().revision == 0)
    }

    @Test(arguments: ["missing", "modified", "symlink"])
    func entrypointIntegrityIsRequiredForLoadingAndEveryMutation(_ alteration: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let initial = try store.publish(texts: [.init(path: "context.md", text: "Preserved original context")], coverage: [], limitations: [], expectedRevision: 0)
        let pointerURL = store.directory.appending(path: "LATEST.json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let instructions = try Data(contentsOf: store.continuationFile)
        let pointer = try #require(JSONSerialization.jsonObject(with: pointerBefore) as? [String: Any])
        #expect(pointer["entrypointSHA256"] as? String == ContinuityWorkspace.sha256(instructions))
        try fm.removeItem(at: store.continuationFile)
        if alteration == "modified" { try Data("Read the wrong workspace instead".utf8).write(to: store.continuationFile) }
        if alteration == "symlink" {
            let outside = box.root.appending(path: "outside-instructions.md")
            try instructions.write(to: outside)
            try fm.createSymbolicLink(at: store.continuationFile, withDestinationURL: outside)
        }
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) {
            try store.publish(texts: [.init(path: "new.md", text: "Must not publish")], coverage: [], limitations: [], expectedRevision: initial.revision)
        }
        #expect(throws: (any Error).self) { try store.setMirror(profileID: "destination", nativeURL: mirrorURL, expectedRevision: initial.revision) }
        #expect(throws: (any Error).self) { try store.activate(profileID: "source", sourcePaused: true, expectedRevision: initial.revision) }
        #expect(try Data(contentsOf: pointerURL) == pointerBefore)
        if alteration != "missing" { try fm.removeItem(at: store.continuationFile) }
        try instructions.write(to: store.continuationFile)
        #expect(try store.load().revision == initial.revision)
        #expect(try contents(store, "context.md") == Data("Preserved original context".utf8))
        let next = try store.publish(texts: [.init(path: "next.md", text: "Next result")], coverage: [], limitations: [], expectedRevision: initial.revision)
        #expect(next.revision == initial.revision + 1)
        let nextPointer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as? [String: Any])
        #expect(nextPointer["entrypointSHA256"] as? String == pointer["entrypointSHA256"] as? String)
    }

}
