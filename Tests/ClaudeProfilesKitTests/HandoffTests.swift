import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Reviewed context handoff")
struct HandoffTests {
    @Test func keepsContextAndCreatesPrivateStandaloneDocument() throws {
        let box = try Sandbox()
        let handoff = Handoff(title: "Continue development", source: "WORK", destination: "LAB",
                              context: "Completed tests. Next: review diff.\nQuoted: $(do not execute)",
                              folder: box.root.path, sourceURL: "https://claude.ai/epitaxy/project/chan_example?thread=cmsg_example")
        let file = try handoff.save(paths: box.paths)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains(handoff.context))
        #expect(saved.contains("new conversation"))
        #expect(saved.contains("Destination profile: LAB"))
        #expect(file.deletingLastPathComponent().lastPathComponent == "Handoffs")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!box.exists(box.work.appending(path: "config.json")), "handoff never writes account settings")
    }

    @Test(arguments: ["https://claude.ai/cowork/local_68example",
                      "https://claude.ai/epitaxy/local_69example"])
    func acceptsNativeCoworkAndLocalCodeConversationLinks(url: String) throws {
        try Handoff(title: "Continue work", source: "WORK", destination: "LAB",
                    context: "Verified stopping point and next step.", sourceURL: url).validate()
    }

    @Test func rejectsLoginLinksAndMissingInputs() {
        let invalid = ["https://claude.ai/login?token=secret", "https://claude.ai.evil.test/project/abc",
                       "https://user:secret@claude.ai/project/abc", "https://claude.ai/project/abc?token=secret",
                       "https://claude.ai.evil.test/cowork/local_68example",
                       "https://claude.ai.evil.test/epitaxy/local_69example",
                       "https://claude.ai/epitaxy/arbitrary-page"]
        for url in invalid {
            #expect(throws: (any Error).self) { try Handoff(title: "t", source: "a", destination: "b", context: "c", sourceURL: url).validate() }
        }
        #expect(throws: (any Error).self) { try Handoff(title: "t", source: "a", destination: "a", context: "c").validate() }
        #expect(throws: (any Error).self) { try Handoff(title: "t", source: "a", destination: "b", context: " ").validate() }
        #expect(throws: (any Error).self) { try Handoff(title: "t", source: "a", destination: "b", context: "c", folder: "/does-not-exist/handoff").validate() }
    }
}
