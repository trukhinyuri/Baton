import Foundation
import Testing

@testable import BatonKit

/// Running copies that a test starts and quits by hand.
final class FakeCopies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RunningClaude] = []
    private var asked: [pid_t] = []

    var running: [RunningClaude] { lock.withLock { stored } }
    var quitRequests: [pid_t] { lock.withLock { asked } }
    func set(_ copies: [RunningClaude]) { lock.withLock { stored = copies } }
    func askToQuit(_ copy: RunningClaude, andQuit: Bool) {
        lock.withLock {
            asked.append(copy.pid ?? 0)
            if andQuit { stored.removeAll { $0.pid == copy.pid } }
        }
    }
}

@Suite("Window activity")
struct WindowActivityTests {
    static let session = "11111111-2222-3333-4444-555555555555"
    static let other = "99999999-2222-3333-4444-555555555555"

    /// A manager whose WORK window runs as process 100 when `open`, with the given Claude Code processes and each
    /// process's parent; those in `idle` hold their session open without working.
    func manager(
        _ box: Sandbox, copies: FakeCopies, open: Bool = true, processes: [LimitTracker.LiveProcess] = [], tree: [pid_t: pid_t] = [:],
        unregistered: Set<String> = [], idle: Set<pid_t> = []
    ) throws -> ProfileManager {
        let manager = try box.closedWorkWindow(FakeWindows())
        copies.set(open ? [workCopy(box)] : [])
        manager.runningCopies = { copies.running }
        manager.limitTracker.liveProcesses = { _ in processes }
        // The Claude Code processes are the given ones; the rest of the tree is their helpers.
        manager.processTree = { ProcessTree(claudes: processes.map(\.pid), parent: { tree[$0] }) }
        manager.liveSessionIDs = { Set(processes.map(\.session)).union(unregistered) }
        manager.processWorking = { pid, _ in !idle.contains(pid) }
        return manager
    }

    func workCopy(_ box: Sandbox) -> RunningClaude {
        let engine = box.paths.engine(for: "work")
        return RunningClaude(
            bundlePath: engine.standardizedFileURL.path,
            arguments: [engine.appending(path: "Contents/MacOS/Claude").path, "--user-data-dir=\(box.work.path)"], pid: 100)
    }

    func process(_ pid: pid_t, _ session: String, executable: String) -> LimitTracker.LiveProcess {
        LimitTracker.LiveProcess(pid: pid, session: session, startedAt: Date(), version: "2.1.0", cwd: "/repo", hostSessionID: nil, executable: executable)
    }

    func inData(_ dir: URL) -> String { dir.appending(path: "claude-code/2.1.0/claude.app/Contents/MacOS/claude").path }

    @Test func closedWhenNoProcess() throws {
        let box = try Sandbox()
        let manager = try manager(box, copies: FakeCopies(), open: false)
        #expect(manager.activity(of: "work") == .closed)
        #expect(manager.liveSessions(in: "work").isEmpty)
    }

    @Test func liveProcessByExecutableMakesWindowBusy() throws {
        let box = try Sandbox()
        let manager = try manager(
            box, copies: FakeCopies(),
            processes: [process(200, Self.session, executable: inData(box.work)), process(201, Self.other, executable: inData(box.main))])
        #expect(manager.activity(of: "work") == .busy(working: 1))
        #expect(manager.liveSessions(in: "work") == [Self.session], "main's process isn't this window's")
    }

    @Test func liveProcessByTreeMakesWindowBusy() throws {
        let box = try Sandbox()
        let manager = try manager(
            box, copies: FakeCopies(), processes: [process(300, Self.session, executable: "/usr/local/bin/claude")],
            tree: [300: 250, 250: 100, 400: 1])
        #expect(manager.activity(of: "work") == .busy(working: 1), "started by the window through a helper")
        #expect(manager.liveSessions(in: "work") == [Self.session])
    }

    @Test func runningWithoutLiveProcessIsIdle() throws {
        let box = try Sandbox()
        let manager = try manager(
            box, copies: FakeCopies(), processes: [process(201, Self.other, executable: inData(box.main))], tree: [201: 1])
        #expect(manager.activity(of: "work") == .idle)
        #expect(manager.liveSessions(in: "work").isEmpty)
        #expect(!manager.activity(of: "work").isBusy)
    }

    @Test func unattributedLiveSessionCountsInSource() throws {
        let box = try Sandbox()
        let copies = FakeCopies()
        let manager = try manager(
            box, copies: copies, processes: [process(201, Self.other, executable: inData(box.main))], unregistered: [Self.session])
        #expect(manager.liveSessions(in: "work") == [Self.session], "live somewhere Baton can't tell: counted where it could be")
        copies.set([])
        #expect(manager.liveSessions(in: "work").isEmpty, "not in a closed window")
    }

    @Test func liveProcessOutlivingItsWindowKeepsItBusy() async throws {
        let box = try Sandbox()
        let copies = FakeCopies()
        let manager = try manager(box, copies: copies, open: false, processes: [process(200, Self.session, executable: inData(box.work))])
        #expect(manager.activity(of: "work") == .busy(working: 1), "left running after the window went away")
        #expect(await manager.quitWindow("work", seconds: 0.2) == false, "not closed while it works")
    }

    @Test func quitWindowLeavesBusyWindowAlone() async throws {
        let box = try Sandbox()
        let copies = FakeCopies()
        let manager = try manager(box, copies: copies, processes: [process(200, Self.session, executable: inData(box.work))])
        manager.quitRequester = { copies.askToQuit($0, andQuit: true) }
        #expect(await manager.quitWindow("work", seconds: 0.2) == false)
        #expect(copies.quitRequests.isEmpty, "running work isn't interrupted")
    }

    @Test func quitWindowNeverForces() async throws {
        let box = try Sandbox()
        let copies = FakeCopies()
        let manager = try manager(box, copies: copies)
        manager.quitRequester = { copies.askToQuit($0, andQuit: false) }

        #expect(await manager.quitWindow("work", seconds: 0.4) == false, "a window that stays is left running")
        #expect(copies.quitRequests == [100], "asked once, never forced")
        #expect(copies.running.count == 1)

        manager.quitRequester = { copies.askToQuit($0, andQuit: true) }
        #expect(await manager.quitWindow("work", seconds: 0.4))
        #expect(manager.activity(of: "work") == .closed)
        #expect(await manager.quitWindow("work", seconds: 0.4), "nothing to quit")
        #expect(copies.quitRequests == [100, 100])
    }
    @Test func idleProcessesLeaveWindowIdle() async throws {
        let box = try Sandbox()
        let copies = FakeCopies()
        let manager = try manager(
            box, copies: copies,
            processes: [process(200, Self.session, executable: inData(box.work)), process(201, Self.other, executable: inData(box.work))],
            idle: [200, 201])
        #expect(manager.activity(of: "work") == .idle, "Claude Desktop keeps idle processes for hours")
        #expect(manager.liveSessions(in: "work") == [Self.session, Self.other])
        #expect(manager.workingSessions(in: "work").isEmpty)
        manager.quitRequester = { copies.askToQuit($0, andQuit: true) }
        _ = await manager.quitWindow("work", seconds: 0.2)
        #expect(copies.quitRequests == [100], "asked to quit, since nothing works there")
    }

    @Test func oneWorkingProcessMakesWindowBusyAndOnlyItsSessionWorks() throws {
        let box = try Sandbox()
        let manager = try manager(
            box, copies: FakeCopies(),
            processes: [process(200, Self.session, executable: inData(box.work)), process(201, Self.other, executable: inData(box.work))],
            idle: [201])
        #expect(manager.activity(of: "work") == .busy(working: 1))
        #expect(manager.workingSessions(in: "work") == [Self.session])
        #expect(manager.liveSessions(in: "work") == [Self.session, Self.other])
    }

    @Test func idleProcessOutlivingItsWindowIsNotClosed() async throws {
        let box = try Sandbox()
        let manager = try manager(
            box, copies: FakeCopies(), open: false, processes: [process(200, Self.session, executable: inData(box.work))], idle: [200])
        #expect(manager.activity(of: "work") == .idle, "its session is still open there")
        #expect(await manager.quitWindow("work", seconds: 0.2) == false)
    }

    @Test func descendantStartedAfterTheProcessIsWork() {
        let start = Date(timeIntervalSince1970: 1_000)
        let tree: [pid_t: [pid_t]] = [10: [11], 11: [12], 20: [21]]
        let started: [pid_t: Date] = [
            11: start.addingTimeInterval(2), 12: start.addingTimeInterval(600), 21: start.addingTimeInterval(3),
        ]
        let after = start.addingTimeInterval(ClaudeWork.serverGrace)
        let children = { (pid: pid_t) in tree[pid] ?? [] }
        #expect(ClaudeWork.hasWorkingDescendant(10, children: children, startTime: { started[$0] }, after: after), "a tool under a server")
        #expect(!ClaudeWork.hasWorkingDescendant(20, children: children, startTime: { started[$0] }, after: after), "a server started with it")
        #expect(!ClaudeWork.hasWorkingDescendant(30, children: children, startTime: { started[$0] }, after: after), "no children")
    }

    @Test func recentTranscriptOrBusyRegistryIsWork() throws {
        let box = try Sandbox()
        let claudeDir = box.paths.claudeDir
        let project = claudeDir.appending(path: "projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appending(path: Self.session + ".jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let pid: pid_t = 999_999
        #expect(ClaudeWork.isWorking(pid: pid, session: Self.session.uppercased(), claudeDir: claudeDir), "written just now")
        let later = Date().addingTimeInterval(ClaudeWork.quiet + 5)
        #expect(!ClaudeWork.isWorking(pid: pid, session: Self.session, claudeDir: claudeDir, now: later), "quiet for over a minute")
        let sessions = claudeDir.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"pid":999999,"sessionId":"x","status":"busy"}"#.utf8).write(to: sessions.appending(path: "999999.json"))
        #expect(ClaudeWork.isWorking(pid: pid, session: Self.session, claudeDir: claudeDir, now: later), "a turn under way")
        try Data(#"{"pid":999999,"sessionId":"x","status":"idle"}"#.utf8).write(to: sessions.appending(path: "999999.json"))
        #expect(!ClaudeWork.isWorking(pid: pid, session: nil, claudeDir: claudeDir, now: later))
    }
}
