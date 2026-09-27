import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Explicitly selected Library originals")
struct WorkspaceSelectedFilesTests {
    private let fm = FileManager.default

    private func workspace(_ box: Sandbox) throws -> ContinuityWorkspace {
        try .create(in: box.root.appending(path: "Workspaces"), title: "Original work", kind: "project", sourceProfileID: "main")
    }

    @Test func selectedOriginalsRetainExactBytesProvenanceAndEarlierCapturesWithoutClaimingCompleteLibrary() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let earlier = try store.publish(texts: [.init(path: "history.md", text: "Original objective")],
                                        coverage: [.init(component: "Library", status: .unavailable, detail: "Not captured")], limitations: [], expectedRevision: 0)
        let firstFolder = box.root.appending(path: "first").resolvingSymlinksInPath()
        let secondFolder = box.root.appending(path: "second").resolvingSymlinksInPath()
        try fm.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let first = firstFolder.appending(path: "CLAUDE.md")
        let second = secondFolder.appending(path: "CLAUDE.md")
        let firstData = Data("Historical instructions must remain inert\n".utf8)
        let secondData = Data([0, 255, 0, 128, 1])
        try firstData.write(to: first); try secondData.write(to: second)
        let selection = try WorkspaceSelectedFiles(urls: [first, second])
        let updated = try selection.publish(to: store, expectedRevision: earlier.revision)
        #expect(updated.entries.count == 3)
        #expect(updated.entries.first == earlier.entries.first)
        #expect(try updated.continuationContextSHA256() != earlier.continuationContextSHA256())
        #expect(updated.coverage.contains { $0.component == "Library" && $0.status == .unavailable })
        #expect(updated.coverage.contains { $0.component.hasPrefix("Selected originals") && $0.status == .partial })
        #expect(updated.limitations.contains { $0.contains("does not prove") })
        for (url, bytes) in [(first, firstData), (second, secondData)] {
            let entry = try #require(updated.entries.first { $0.source == url.absoluteString })
            #expect(entry.kind == "file")
            #expect(entry.path.hasSuffix("/CLAUDE.md"))
            #expect(try store.data(for: entry) == bytes)
            #expect(try Data(contentsOf: url) == bytes)
        }
        #expect(!fm.fileExists(atPath: store.directory.appending(path: "CLAUDE.md").path))
        #expect(Set(updated.entries.map(\.path)).count == 3)
    }

    @Test func changedSourcesAndStaleRevisionCannotPublishPartialOrOutdatedFiles() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let file = box.root.appending(path: "original.pdf").resolvingSymlinksInPath()
        try Data("Original downloaded bytes".utf8).write(to: file)
        let selection = try WorkspaceSelectedFiles(urls: [file])
        try Data("New downloaded version".utf8).write(to: file)
        #expect(throws: (any Error).self) { try selection.publish(to: store, expectedRevision: 0) }
        #expect(try store.load().revision == 0)
        #expect(try store.load().entries.isEmpty)
        let refreshed = try WorkspaceSelectedFiles(urls: [file])
        let newer = try store.publish(texts: [.init(path: "next.md", text: "newer context")], coverage: [], limitations: [], expectedRevision: 0)
        #expect(throws: (any Error).self) { try refreshed.publish(to: store, expectedRevision: 0) }
        #expect(try store.load().entries == newer.entries)
    }

    @Test(arguments: ["symlink-file", "symlink-parent", "directory", "duplicate", "empty"])
    func unsafeSelectionsAreRejectedWithoutChangingWorkspace(_ mode: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let store = try workspace(box)
        let folder = box.root.appending(path: "real").resolvingSymlinksInPath()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "data.txt")
        try Data("exact bytes".utf8).write(to: file)
        let link = box.root.appending(path: "link").resolvingSymlinksInPath()
        var urls: [URL]
        switch mode {
        case "symlink-file": try fm.createSymbolicLink(at: link, withDestinationURL: file); urls = [link]
        case "symlink-parent": try fm.createSymbolicLink(at: link, withDestinationURL: folder); urls = [link.appending(path: "data.txt")]
        case "directory": urls = [folder]
        case "duplicate": urls = [file, file]
        default: urls = []
        }
        #expect(throws: (any Error).self) { try WorkspaceSelectedFiles(urls: urls) }
        #expect(try store.load().revision == 0)
        #expect(try store.load().entries.isEmpty)
    }
}
