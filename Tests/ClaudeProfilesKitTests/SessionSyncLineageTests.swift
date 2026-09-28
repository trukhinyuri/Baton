import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Forked sessions in sharing")
struct SessionSyncLineageTests {
    static let old = "0d0d0d0d-0000-4000-8000-000000000000"
    static let fork = "f0f0f0f0-0000-4000-8000-000000000000"

    static func card(_ cli: String, prior: [String] = [], title: String) -> String {
        let priors = prior.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"sessionId":"local_1","cliSessionId":"\#(cli)","priorCliSessionIds":[\#(priors)],"title":"\#(title)"}"#
    }

    func transcript(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionSync.facts(of: data).transcript
    }

    /// A window that still holds the card from before Claude forked the session writes it again later.
    @Test func staleWindowCannotRepointFork() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountA)
        try box.write(
            Self.card(Self.fork, prior: [Self.old], title: "forked"), to: a.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(-600))
        try box.write(Self.card(Self.old, title: "renamed in the stale window"), to: b.appending(path: "local_1.json"))

        _ = try box.sync()

        #expect(transcript(of: a.appending(path: "local_1.json")) == Self.fork, "the fork wins over a newer card of its past")
        #expect(transcript(of: b.appending(path: "local_1.json")) == Self.fork, "the stale window is pointed at the fork")

        try box.write(Self.card(Self.old, title: "again"), to: b.appending(path: "local_1.json"), modified: Date().addingTimeInterval(60))
        _ = try box.sync()
        #expect(transcript(of: a.appending(path: "local_1.json")) == Self.fork, "cliSessionId never moves backwards")
        #expect(transcript(of: b.appending(path: "local_1.json")) == Self.fork)
    }

    @Test func liveSessionCardNotOverwritten() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountA)
        let stale = Self.card(Self.old, title: "open here")
        try box.write(Self.card(Self.fork, prior: [Self.old], title: "forked"), to: a.appending(path: "local_1.json"))
        try box.write(stale, to: b.appending(path: "local_1.json"), modified: Date().addingTimeInterval(-600))

        let report = try box.sync { $0.liveSessionIDs = [Self.old] }

        #expect(box.read(b.appending(path: "local_1.json")) == stale, "a running claude process has this session open")
        #expect(report.keptLive == 1)
        #expect(transcript(of: a.appending(path: "local_1.json")) == Self.fork)

        _ = try box.sync { $0.liveSessionIDs = [] }
        #expect(transcript(of: b.appending(path: "local_1.json")) == Self.fork, "updated once the process is gone")
    }
}
