import Foundation
import Testing

@testable import BatonKit

/// A copy of WORK's app started from its Dock icon without the profile's data, which a test ends by hand.
final class FakeStray: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var asks: [Date] = []
    private var forces = 0
    private var lines: [String] = []
    private var waits: [String] = []

    var isRunning: Bool { lock.withLock { alive } }
    var askedAt: [Date] { lock.withLock { asks } }
    var forced: Int { lock.withLock { forces } }
    var logged: [String] { lock.withLock { lines } }
    var waitLines: [String] { lock.withLock { waits } }
    func end() { lock.withLock { alive = false } }
    func ask() { lock.withLock { asks.append(Date()) } }
    func force() {
        lock.withLock {
            forces += 1; alive = false
        }
    }
    func note(_ line: String) { lock.withLock { lines.append(line) } }
    func waiting(_ line: String) { lock.withLock { waits.append(line) } }
}

@Suite("Opening next to a Dock-started stray")
struct OpenStrayTests {
    static let strayPID: pid_t = 500

    /// WORK closed, with a stray of its app running as process 500; `work` Claude Code processes descend from it.
    func manager(_ box: Sandbox, windows: FakeWindows, stray: FakeStray, work: Int) throws -> ProfileManager {
        let manager = try box.closedWorkWindow(windows)
        let engine = box.paths.engine(for: "work")
        let copy = RunningClaude(
            bundlePath: engine.standardizedFileURL.path, arguments: [engine.appending(path: "Contents/MacOS/Claude").path], pid: Self.strayPID)
        manager.runningCopies = { (stray.isRunning ? [copy] : []) + windows.running }
        let claudes = (0..<work).map { pid_t(600 + $0) }
        manager.processTree = { ProcessTree(claudes: claudes, parent: { $0 >= 600 ? Self.strayPID : nil }) }
        manager.limitTracker.liveProcesses = { _ in [] }
        manager.quitRequester = { _ in stray.ask() }
        manager.forceQuitter = { _ in stray.force() }
        manager.strayNoted = { stray.note($0) }
        manager.onStrayWait = { _, line in stray.waiting(line) }
        manager.strayTiming = StrayTiming(grace: 0.4, every: 0.2, tick: 0.05)
        return manager
    }

    @Test func strayWithoutClaudeCodeIsForceQuitAfterTenSeconds() async throws {
        let box = try Sandbox()
        let windows = FakeWindows(), stray = FakeStray()
        let manager = try manager(box, windows: windows, stray: stray, work: 0)
        let started = Date()
        try await manager.open("work")
        #expect(Date().timeIntervalSince(started) >= 0.4, "given the grace time to quit first")
        #expect(stray.askedAt.count == 1)
        #expect(stray.forced == 1)
        #expect(windows.started == 1, "the profile opened once the stray was gone")
        #expect(stray.waitLines.isEmpty, "nothing to wait for, so no line")
    }

    @Test func strayWithClaudeCodeIsAskedEveryFiveSecondsAndNeverForced() async throws {
        let box = try Sandbox()
        let windows = FakeWindows(), stray = FakeStray()
        let manager = try manager(box, windows: windows, stray: stray, work: 2)
        Task.detached {
            try await Task.sleep(for: .seconds(1.2))
            #expect(windows.started == 0, "never opened next to it")
            stray.end()
        }
        try await manager.open("work")
        #expect(stray.forced == 0, "work under it is never killed")
        #expect(stray.askedAt.count >= 3, "asked at first and again every few seconds: \(stray.askedAt.count)")
        #expect(windows.started == 1)
    }

    @Test func profileOpensByItselfWhenStrayIsGone() async throws {
        let box = try Sandbox()
        let windows = FakeWindows(), stray = FakeStray()
        let manager = try manager(box, windows: windows, stray: stray, work: 1)
        let open = Task { try await manager.open("work") }
        for _ in 0..<200 where stray.waitLines.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .seconds(0.3))
        #expect(windows.started == 0)
        #expect(stray.waitLines == ["WORK opens when the Claude started from its Dock icon finishes its work."], "said once")
        stray.end()
        try await open.value
        #expect(windows.started == 1)
        #expect(stray.waitLines.count == 1)
    }

    @Test func everyStrayDecisionIsLogged() async throws {
        let box = try Sandbox()
        let windows = FakeWindows(), kept = FakeStray()
        let manager = try manager(box, windows: windows, stray: kept, work: 2)
        Task.detached {
            try await Task.sleep(for: .seconds(0.6))
            kept.end()
        }
        try await manager.open("work")
        #expect(kept.logged.contains { $0.hasPrefix("stray 500 of WORK asked to quit") })
        #expect(kept.logged.contains("stray 500 kept: 2 Claude Code processes under it"), "why it didn't quit")
        #expect(kept.logged.contains { $0.hasPrefix("stray 500 gone after ") })

        let box2 = try Sandbox()
        let forced = FakeStray()
        let manager2 = try self.manager(box2, windows: FakeWindows(), stray: forced, work: 0)
        try await manager2.open("work")
        #expect(forced.logged.contains { $0.hasPrefix("stray 500 force-quit after ") && $0.hasSuffix(": no Claude Code work") })
    }

    @Test func strayNeverThrowsWindowStillRunning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows(), stray = FakeStray()
        let manager = try manager(box, windows: windows, stray: stray, work: 1)
        Task.detached {
            try await Task.sleep(for: .seconds(0.7))
            stray.end()
        }
        await #expect(throws: Never.self) { try await manager.open("work") }
        #expect(windows.started == 1)
    }

    @Test func noticeIsWithdrawnOnceTheWindowOpens() {
        var notices = Notices()
        notices.show("Earlier warning.", isWarning: true)
        notices.show(ProfileManager.strayLine("WORK"), isWarning: true)
        notices.withdraw(ProfileManager.strayLine("WORK"))
        #expect(notices.current?.text == "Earlier warning.")
    }
}
