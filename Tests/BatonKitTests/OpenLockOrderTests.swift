import Foundation
import Testing

@testable import BatonKit

/// Whether windows count as running in a test, and how many times one was started.
final class FakeWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [RunningClaude] = []
    private var starts = 0

    var running: [RunningClaude] { lock.withLock { open } }
    var started: Int { lock.withLock { starts } }

    func start(_ app: URL, arguments: [String]) {
        lock.withLock {
            starts += 1
            // The first argument is the executable, as the process's own command line has it.
            open.append(RunningClaude(bundlePath: app.standardizedFileURL.path, arguments: [app.appending(path: "Contents/MacOS/Claude").path] + arguments))
        }
    }
}

extension Sandbox {
    /// A closed, signed-in WORK profile whose app copy is up to date, and a manager that never looks at this Mac's
    /// windows or starts anything: `windows` stands in for both.
    func closedWorkWindow(_ windows: FakeWindows, launchDelay: Double = 0) throws -> ProfileManager {
        // Not Claude's bundle identifier, so nothing on this Mac is taken for one of these windows.
        try claudeBundle(at: paths.claudeApp, identifier: "test.baton.not-claude")
        try claudeBundle(at: paths.engine(for: "work"), identifier: "test.baton.not-claude")
        try ProfileRegistry(paths: paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try signIn(main, account: Sandbox.accountA)
        try signIn(work, account: Sandbox.accountB)
        let manager = ProfileManager(paths: paths)
        // Taken for Claude as Anthropic signs it, so the main window opens too.
        manager.signatureCheck = { _ in true }
        manager.runningCopies = { windows.running }
        manager.appLauncher = { app, arguments, _ in
            try await Task.sleep(for: .seconds(launchDelay))
            windows.start(app, arguments: arguments)
        }
        return manager
    }

    /// Makes sharing sessions before a start fail, so opening a closed window gives a warning.
    func failSharingSessions() throws {
        let main = try pair(self.main, account: Sandbox.accountA)
        try pair(work, account: Sandbox.accountB)
        try write(#"{"title":"New since the last start"}"#, to: main.appending(path: "local_new.json"))
        try write("broken", to: paths.stateDir.appending(path: "code-native-session-scopes.json"))
    }
}

/// Waits for `group` off the cooperative pool, so a test that deadlocks fails instead of hanging.
private func finished(_ group: DispatchGroup, within seconds: Double) async -> Bool {
    await withCheckedContinuation { done in
        DispatchQueue.global().async { done.resume(returning: group.wait(timeout: .now() + seconds) == .success) }
    }
}

@Suite("Opening windows and locks")
struct OpenLockOrderTests {
    /// The app's timer sync holds sync.lock and reads account emails for a folder rule, while opening a closed window
    /// waits for sync.lock under open.lock. Neither may hold a lock the other needs.
    @Test func syncWithAFolderRuleAndOpeningAClosedWindowBothFinish() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        try box.setEmail("me@employer.example", in: box.main, account: Sandbox.accountA)
        try box.setEmail("me@home.example", in: box.work, account: Sandbox.accountB)
        try FolderRules(paths: box.paths).set("/employer", accounts: ["me@employer.example"])
        let main = try box.pair(box.main, account: Sandbox.accountA)
        try box.pair(box.work, account: Sandbox.accountB)
        try box.write(SessionSyncRulesTests.employerCard, to: main.appending(path: "local_1.json"))

        let group = DispatchGroup()
        let syncDone = DispatchSemaphore(value: 0)
        let synced = Flag()
        let syncLock = box.paths.stateDir.appending(path: "sync.lock")
        manager.whilePreparing = { _ in
            // The sync starts while this window is being prepared and takes sync.lock first.
            group.enter()
            Thread.detachNewThread {
                // The look below takes sync.lock for a moment too; a sync that finds it taken then tries again, so the
                // test never passes on a sync that was skipped.
                let deadline = Date().addingTimeInterval(5)
                var report: SyncReport?
                repeat {
                    do { report = try manager.syncSessions() } catch { break }
                } while report == nil && Date() < deadline
                synced.set(report != nil)
                syncDone.signal()
                group.leave()
            }
            let deadline = Date().addingTimeInterval(5)
            while (try? FileLock.withLock(syncLock, blocking: false) {}) != nil, Date() < deadline {
                if syncDone.wait(timeout: .now() + 0.01) == .success {
                    syncDone.signal()
                    break
                }
            }
        }
        group.enter()
        Task.detached {
            try? await manager.open("work")
            group.leave()
        }

        #expect(await finished(group, within: 20), "opening and the sync wait for each other for good")
        #expect(synced.value, "the sync ran while the window was prepared")
        #expect(windows.started == 1)
        let card = box.work.appending(path: "claude-code-sessions/\(Sandbox.accountB)/org-1/local_1.json")
        #expect(!box.exists(card), "the folder rule still keeps the card out of the other account")
    }

    /// Reading the last open's warning, as the app's main thread does, never waits for another window being prepared.
    @Test func warningsCanBeReadWhileAWindowIsPrepared() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        let answered = Flag()
        manager.whilePreparing = { _ in
            let read = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = manager.lastOpenWarning
                _ = manager.openWarning(of: "main")
                read.signal()
            }
            answered.set(read.wait(timeout: .now() + 3) == .success)
        }

        try await manager.open("work")

        #expect(answered.value, "the warning was read only once the window had been prepared")
    }

    /// Each window keeps its own warning: opening another window doesn't erase it.
    @Test func eachWindowKeepsItsOwnWarning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        try box.claudeBundle(at: box.paths.engine(for: "lab"), identifier: "test.baton.not-claude")
        try manager.registry.save(manager.profiles + [Profile(id: "lab", label: "LAB", email: nil, color: "#2F9E44")])
        try FileManager.default.createDirectory(at: box.paths.dataDir(for: "lab"), withIntermediateDirectories: true)
        try box.signIn(box.paths.dataDir(for: "lab"), account: Sandbox.accountB)
        let main = try box.pair(box.main, account: Sandbox.accountA)
        try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"New since the last start"}"#, to: main.appending(path: "local_new.json"))
        // Sessions can't be shared while this file is damaged, so WORK opens with a warning.
        let broken = box.paths.stateDir.appending(path: "code-native-session-scopes.json")
        try box.write("broken", to: broken)

        try await manager.open("work")
        let warning = try #require(manager.openWarning(of: "work"))
        #expect(warning.hasPrefix("Claude WORK opened, but"))

        try FileManager.default.removeItem(at: broken)
        try await manager.open("lab")

        #expect(manager.openWarning(of: "lab") == nil)
        #expect(manager.openWarning(of: "work") == warning, "LAB's open left WORK's warning alone")
    }

    /// Showing a window that is already running prepares nothing, so a warning from its earlier start is not shown again.
    @Test func bringingARunningWindowForwardHasNoWarning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        let main = try box.pair(box.main, account: Sandbox.accountA)
        try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"New since the last start"}"#, to: main.appending(path: "local_new.json"))
        try box.write("broken", to: box.paths.stateDir.appending(path: "code-native-session-scopes.json"))
        try await manager.open("work")
        #expect(manager.openWarning(of: "work") != nil)

        try await manager.open("work")

        #expect(windows.started == 1, "brought forward, not started again")
        #expect(manager.openWarning(of: "work") == nil)
        #expect(manager.lastOpenWarning == nil)
    }

    /// A window found running only once open.lock is taken, started from its Dock icon meanwhile, is brought forward
    /// without the warning from its earlier start.
    @Test func aWindowFoundRunningUnderTheLockHasNoWarning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        try box.failSharingSessions()
        try await manager.open("work")
        #expect(manager.openWarning(of: "work") != nil)
        // The first look finds it closed; by the time open.lock is taken, it runs.
        let looks = Counter()
        manager.runningCopies = { looks.next() == 1 ? [] : windows.running }

        try await manager.open("work")

        #expect(windows.started == 1, "brought forward, not started again")
        #expect(manager.openWarning(of: "work") == nil)
        #expect(manager.lastOpenWarning == nil)
    }

    /// The same for the main window.
    @Test func theMainWindowFoundRunningUnderTheLockHasNoWarning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        let broughtForward = Counter()
        manager.appActivator = { _, _ in _ = broughtForward.next() }
        try box.failSharingSessions()
        try await manager.openMain()
        #expect(manager.openWarning(of: "main") != nil)
        let looks = Counter()
        manager.runningCopies = { looks.next() == 1 ? [] : windows.running }

        try await manager.openMain()

        #expect(windows.started == 1 && broughtForward.next() == 2, "brought forward, not started again")
        #expect(manager.openWarning(of: "main") == nil)
    }

    /// Finishing the first sign-in of a window that is closed already opens nothing, so no earlier warning is shown.
    @Test func finishingTheSignInOfAClosedWindowHasNoWarning() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        try box.failSharingSessions()
        try await manager.open("work")
        #expect(manager.openWarning(of: "work") != nil)

        // No process on this Mac runs the sandbox's app copy, so it counts as closed.
        try await manager.finishFirstSignIn("work")

        #expect(windows.started == 1)
        #expect(manager.openWarning(of: "work") == nil)
    }

    /// A second click while the window is still starting brings it forward instead of starting a second copy on the
    /// same data.
    @Test func openingAWindowThatIsStartingStartsItOnce() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows, launchDelay: 0.3)

        async let first: Void = manager.open("work")
        async let second: Void = manager.open("work")
        _ = try await (first, second)

        #expect(windows.started == 1)
    }

    /// open.lock is kept until the copy started shows up, so an open that waited for it in another process, such as a
    /// Dock launcher's `baton open`, finds the window running instead of starting a second copy on the same data.
    @Test func anOpenWaitingForTheLockFindsTheWindowStarted() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows, launchDelay: 0.3)
        let openLock = box.paths.stateDir.appending(path: "open.lock")
        let foundRunning = Flag()
        let looked = DispatchGroup()
        manager.whilePreparing = { _ in
            // Another process's open: a thread of its own opens the lock file itself, so it waits for this one.
            looked.enter()
            Thread.detachNewThread {
                _ = try? FileLock.withLock(openLock, blocking: true) { foundRunning.set(!windows.running.isEmpty) }
                looked.leave()
            }
        }

        try await manager.open("work")

        #expect(await finished(looked, within: 10))
        #expect(foundRunning.value, "the other open took open.lock before the window it waited for was listed")
    }

    /// A window started from its Dock icon or by the CLI while Baton prepared it is not started again.
    @Test func aWindowStartedWhileBeingPreparedIsNotStartedAgain() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        manager.whilePreparing = { _ in
            windows.start(box.paths.engine(for: "work"), arguments: ["--user-data-dir=\(box.work.path)"])
        }

        try await manager.open("work")

        #expect(windows.started == 1, "only the start from elsewhere")
    }

    /// Claude keeps only the last link a window receives before that window is on screen. Links for a window that is
    /// still starting go one first and the rest once its window shows, not all at once, or all but the last are lost.
    @Test func linksForAWindowStillStartingWaitForItsWindow() async throws {
        let box = try Sandbox()
        let windows = FakeWindows()
        let manager = try box.closedWorkWindow(windows)
        let shown = Flag()
        manager.windowShown = { _ in shown.value }
        let handed = Handed()
        manager.appActivator = { _, links in handed.add(links) }
        try await manager.open("work")
        let links = (1...3).map { URL(string: "claude://claude.ai/claude-code-desktop/local_\($0)")! }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { shown.set(true) }
        try await manager.open("work", links: links)

        #expect(windows.started == 1)
        #expect(handed.links == [[links[0]], Array(links.dropFirst())])

        // A window already on screen gets them all at once.
        try await manager.open("work", links: links)
        #expect(handed.links.last == links)
    }
}

/// The links handed to running windows, one entry per hand-over.
final class Handed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[URL]] = []
    var links: [[URL]] { lock.withLock { stored } }
    func add(_ links: [URL]) { lock.withLock { stored.append(links) } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Counts one more and returns the count.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
