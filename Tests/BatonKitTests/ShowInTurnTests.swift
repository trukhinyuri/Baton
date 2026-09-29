import Foundation
import Testing

@testable import BatonKit

@Suite("Showing sessions in turn")
struct ShowInTurnTests {
    static let sessions = ["aaaaaaaa-0000-0000-0000-000000000001", "aaaaaaaa-0000-0000-0000-000000000002", "aaaaaaaa-0000-0000-0000-000000000003"]

    /// An open WORK window started at `started`, whose links land in `handed`.
    func manager(_ box: Sandbox, handed: Handed, started: Date? = Date(), open: Bool = true) throws -> ProfileManager {
        let manager = try box.closedWorkWindow(FakeWindows())
        let engine = box.paths.engine(for: "work")
        let copy = RunningClaude(
            bundlePath: engine.standardizedFileURL.path,
            arguments: [engine.appending(path: "Contents/MacOS/Claude").path, "--user-data-dir=\(box.work.path)"], pid: 100, launchDate: started)
        manager.runningCopies = { open ? [copy] : [] }
        manager.appActivator = { _, links in handed.add(links) }
        return manager
    }

    func sessions(_ handed: Handed) -> [String] {
        handed.links.flatMap { $0 }.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
    }

    @Test func deliversOneLinkPerDwell() async throws {
        let box = try Sandbox()
        let handed = Handed()
        let manager = try manager(box, handed: handed)
        let start = Date()

        let result = try await manager.showInTurn("work", sessions: Self.sessions, dwell: 0.3, lastWait: 0.2, poll: 0.05) { _ in false }

        #expect(handed.links.map(\.count) == [1, 1, 1], "one link at a time")
        #expect(handed.links.flatMap { $0 } == Self.sessions.map(ClaudeLink.resume))
        #expect(Date().timeIntervalSince(start) >= 0.9 + 0.2, "each stays its dwell, then the last wait")
        #expect(result.shown == Self.sessions && result.resumed.isEmpty && result.notResumed == Self.sessions)
    }

    @Test func movesOnWhenSessionResumed() async throws {
        let box = try Sandbox()
        let handed = Handed()
        let manager = try manager(box, handed: handed)
        let start = Date()

        // Each session continues as soon as it is shown; the last only a moment later.
        let result = try await manager.showInTurn("work", sessions: Self.sessions, dwell: 30, lastWait: 30, poll: 0.05) { session in
            sessions(handed).contains(session) && (session != Self.sessions[2] || Date().timeIntervalSince(start) > 0.3)
        }

        #expect(result.resumed == Self.sessions && result.notResumed.isEmpty)
        #expect(handed.links.map(\.count) == [1, 1, 1])
        #expect(Date().timeIntervalSince(start) < 29, "didn't wait out the dwell of a session that continued")
    }

    @Test func lastLinkIsTopPin() async throws {
        let now = Date()
        let items = [
            ShowInTurn.Item(session: "pinned-top", lastActivity: now.addingTimeInterval(-500), pinRank: 0),
            ShowInTurn.Item(session: "recent", lastActivity: now),
            ShowInTurn.Item(session: "pinned-second", lastActivity: now, pinRank: 1),
            ShowInTurn.Item(session: "OLD", lastActivity: now.addingTimeInterval(-900)),
        ]
        let order = ShowInTurn.order(items)
        #expect(order == ["old", "recent", "pinned-second", "pinned-top"])

        let box = try Sandbox()
        let handed = Handed()
        let manager = try manager(box, handed: handed)
        _ = try await manager.showInTurn("work", sessions: order, dwell: 0, lastWait: 0, poll: 0.01) { _ in true }
        #expect(sessions(handed).last == "pinned-top", "the top pin stays on screen")
    }

    @Test func noLinkToWindowStartedBeforeCardsWereShared() async throws {
        let box = try Sandbox()
        let handed = Handed()
        let now = Date()
        let early = try manager(box, handed: handed, started: now.addingTimeInterval(-60))
        early.noteCardsShared(into: [box.work.standardizedFileURL.path], at: now)
        await #expect(throws: ShowInTurn.Refusal.startedBeforeShare("WORK")) {
            try await early.showInTurn("work", sessions: Self.sessions) { _ in true }
        }

        let closed = try manager(box, handed: handed, open: false)
        await #expect(throws: ShowInTurn.Refusal.windowClosed("WORK")) {
            try await closed.showInTurn("work", sessions: Self.sessions) { _ in true }
        }
        #expect(handed.links.isEmpty, "no link that would import a session or start Claude on the main app's data")

        let afterRestart = try manager(box, handed: handed, started: now.addingTimeInterval(-60))
        await #expect(throws: ShowInTurn.Refusal.startedBeforeShare("WORK"), "a share from before Baton's restart, given by the caller") {
            try await afterRestart.showInTurn("work", sessions: Self.sessions, sharedAt: now) { _ in true }
        }

        let restarted = try manager(box, handed: handed, started: now.addingTimeInterval(1))
        restarted.noteCardsShared(into: [box.work.standardizedFileURL.path], at: now)
        let result = try await restarted.showInTurn("work", sessions: Self.sessions, dwell: 0, lastWait: 0, poll: 0.01) { _ in true }
        #expect(result.resumed == Self.sessions && handed.links.count == 3)
    }

    @Test func failedLinkStopsAndNamesTheRest() async throws {
        let box = try Sandbox()
        let handed = Handed()
        let manager = try manager(box, handed: handed)
        manager.appActivator = { _, links in
            guard handed.links.isEmpty else { throw CocoaError(.fileReadUnknown) }
            handed.add(links)
        }
        let result = try await manager.showInTurn("work", sessions: Self.sessions, dwell: 0, lastWait: 0, poll: 0.01) { _ in true }
        #expect(result.shown == [Self.sessions[0]] && result.resumed == [Self.sessions[0]])
        #expect(result.notResumed == Array(Self.sessions.dropFirst()) && result.failure != nil)
    }

    @Test func resumedMeansLiveThereAndTranscriptGrew() throws {
        let box = try Sandbox()
        let manager = try manager(box, handed: Handed())
        manager.processTree = { ProcessTree(claudes: [], parent: { _ in nil }) }
        manager.liveSessionIDs = { [] }
        let session = Self.sessions[0]
        let folder = box.paths.claudeProjectsDir.appending(path: "-repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appending(path: "\(session).jsonl")
        try box.write("{}\n", to: transcript)
        let live = LimitTracker.LiveProcess(
            pid: 200, session: session, startedAt: Date(), version: nil, cwd: "/repo", hostSessionID: nil,
            executable: box.work.appending(path: "claude-code/2.1.0/claude.app/Contents/MacOS/claude").path)
        manager.limitTracker.liveProcesses = { _ in [live] }

        let resumed = manager.resumeWatch([session], in: "work")
        #expect(!resumed(session), "live, but nothing written since")
        try box.write("{}\n{}\n", to: transcript)
        #expect(resumed(session))
        manager.limitTracker.liveProcesses = { _ in [] }
        #expect(!resumed(session), "written, but not by a process in that window")
    }
}
