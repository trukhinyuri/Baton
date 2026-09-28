import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Kit safety")
struct KitSafetyTests {
    @Test func concurrentCreateKeepsBoth() throws {
        let box = try Sandbox()
        try box.claudeBundle(at: box.paths.claudeApp)
        let managers = [ProfileManager(paths: box.paths), ProfileManager(paths: box.paths)]
        // The app and the CLI each have their own manager; building the app copies takes a while.
        for manager in managers { manager.appBuilder = { _ in Thread.sleep(forTimeInterval: 0.3) } }

        let labels = ["ONE", "TWO"]
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            do { _ = try managers[i].create(label: labels[i], email: nil) } catch { failures.add(error) }
        }

        #expect(failures.errors.isEmpty)
        #expect(Set(try ProfileRegistry(paths: box.paths).load().map(\.label)) == ["ONE", "TWO"])
    }

    @Test func removeRefusesWhileRunning() async throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        let manager = ProfileManager(paths: box.paths)
        manager.isProfileRunning = { $0 == "work" }

        await #expect(throws: ProfileError.profileOpen("WORK")) { try await manager.remove("work") }

        #expect(box.exists(box.work), "nothing is quit, force-quit or moved to the Trash")
        #expect(try ProfileRegistry(paths: box.paths).load().map(\.id) == ["work"])
    }

    @Test func sameSafetyInKit() throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.transcript(lines: [#"{"type":"user","sessionId":"\#(Sandbox.cli)","message":{"role":"user","content":"hi"}}"#], modified: Date())
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","title":"Busy"}"#, to: a.appending(path: "local_1.json"))
        let manager = ProfileManager(paths: box.paths)
        let conversation = try #require(manager.conversations().first { $0.sessionID == Sandbox.cli })
        #expect(conversation.mayStillWrite())

        #expect(throws: ProfileError.mayStillBeWritten(["Busy"])) { try manager.plan([conversation], in: "work", mode: .same) }
        #expect(try manager.plan([conversation], in: "work", mode: .same, anyway: true).first?.forks == false)
        #expect(try manager.plan([conversation], in: "work", mode: .auto).first?.forks == true, "a copy never has two writers")
        let plans = try manager.plan([conversation], in: "work", mode: .same, anyway: true)
        #expect(throws: ProfileError.mayStillBeWritten(["Busy"])) { try ProfileManager.refuseSecondWriter(plans) }
        let quiet = Date().addingTimeInterval(ContinueMode.forkWindow + 60)
        #expect(throws: Never.self) { try ProfileManager.refuseSecondWriter(plans, now: quiet) }
    }

    @Test func prunesOldBuilds() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let builds = box.main.appending(path: "claude-code")
        for version in ["2.1.0", "2.1.1", "2.1.10"] {
            try fm.createDirectory(at: builds.appending(path: "\(version)/claude.app"), withIntermediateDirectories: true)
            try box.write("sha", to: builds.appending(path: "\(version)/.verified"))
        }
        try fm.createDirectory(at: builds.appending(path: "2.2.0"), withIntermediateDirectories: true)
        let own = box.work.appending(path: "claude-code")
        try fm.createDirectory(at: own.appending(path: "2.0.9"), withIntermediateDirectories: true)
        try box.write("sha", to: own.appending(path: "2.0.9/.verified"))
        try fm.createDirectory(at: own.appending(path: "2.3.0-partial"), withIntermediateDirectories: true)
        let discarded = box.root.appending(path: "Discarded", directoryHint: .isDirectory)
        try fm.createDirectory(at: discarded, withIntermediateDirectories: true)
        var sync = SettingsSync(paths: box.paths)
        sync.discard = { try FileManager.default.moveItem(at: $0, to: discarded.appending(path: $0.lastPathComponent)) }

        try sync.run(into: box.work)

        #expect(
            try fm.contentsOfDirectory(atPath: own.path).sorted() == ["2.1.1", "2.1.10", "2.3.0-partial"],
            "the current build and the one before it; a download in progress is left alone")
        #expect(try fm.contentsOfDirectory(atPath: discarded.path) == ["2.0.9"], "older builds go to the Trash")
        #expect(try fm.contentsOfDirectory(atPath: builds.path).count == 4, "the main app's builds are only read")
    }

    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [any Error] = []
        func add(_ error: any Error) { lock.withLock { list.append(error) } }
        var errors: [any Error] { lock.withLock { list } }
    }
}
