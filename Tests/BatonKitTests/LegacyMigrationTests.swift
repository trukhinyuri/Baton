import Darwin
import Foundation
import Testing

@testable import BatonKit

/// Moving Baton's folders from their name before 1.0, Claude Profiles. Everything happens in a temporary home: the
/// process list, volumes and the Trash are stand-ins, and renames happen inside the sandbox only.
@Suite("Moving the Claude Profiles folders to Baton")
struct LegacyMigrationTests {
    let home: URL
    var support: URL { home.appending(path: "Library/Application Support", directoryHint: .isDirectory) }
    var legacyState: URL { support.appending(path: "Claude Profiles", directoryHint: .isDirectory) }
    var newState: URL { support.appending(path: "Baton", directoryHint: .isDirectory) }
    var legacyLaunchers: URL { home.appending(path: "Applications/Claude Profiles", directoryHint: .isDirectory) }
    var newLaunchers: URL { home.appending(path: "Applications/Baton", directoryHint: .isDirectory) }
    var trashFolder: URL { home.appending(path: "Trash", directoryHint: .isDirectory) }
    let fm = FileManager.default

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: Helpers

    /// An install from before 1.0: the registry, a profile's data and, unless `launchers` is false, a launcher and an engine.
    func makeLegacyInstall(launchers: Bool = true) throws {
        try fm.createDirectory(at: legacyState.appending(path: "Profiles/work"), withIntermediateDirectories: true)
        try Data(#"{"profiles":[{"id":"work"}]}"#.utf8).write(to: legacyState.appending(path: "profiles.json"))
        guard launchers else { return }
        try fm.createDirectory(at: legacyLaunchers.appending(path: "Claude WORK.app/Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS"), withIntermediateDirectories: true)
    }

    func makeApp(_ url: URL, bundleID: String) throws {
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    }

    /// Stand-ins for the system. The Trash is a folder in the sandbox; `rename` is the real exclusive rename unless given.
    func environment(
        processes: [LegacyMigration.RunningProcess] = [], rename: (@Sendable (URL, URL) throws -> Void)? = nil,
        volume: (@Sendable (URL) -> UInt64?)? = nil, lockWait: TimeInterval = 2
    ) -> LegacyMigration.Environment {
        let trashFolder = trashFolder
        return LegacyMigration.Environment(
            processes: { processes }, rename: rename ?? LegacyMigration.renameExclusive, volume: volume ?? { _ in 1 },
            trash: { url in
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trashFolder.appending(path: url.lastPathComponent))
            }, pid: 4242, lockWait: lockWait)
    }

    func paths() -> Paths { Paths(home: home, claudeApp: home.appending(path: "Applications/Claude.app")) }

    func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

    func cleanUp() { try? fm.removeItem(at: home) }

    // MARK: Where Baton lives

    @Test func aFreshInstallUsesBaton() {
        defer { cleanUp() }
        #expect(paths().stateDir == newState)
        #expect(paths().launchersDir == newLaunchers)
        #expect(!paths().usesLegacyFolders)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(!fm.fileExists(atPath: LegacyMigration.lockFile(home: home).path), "nothing to move takes no lock")
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).isEmpty)
    }

    @Test func eachFolderResolvesOnItsOwn() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        #expect(paths().stateDir == legacyState)
        #expect(paths().launchersDir == legacyLaunchers)
        #expect(paths().usesLegacyFolders)
        try fm.createDirectory(at: newLaunchers, withIntermediateDirectories: true)
        #expect(paths().stateDir == legacyState)
        #expect(paths().launchersDir == newLaunchers)
    }

    // MARK: Moving

    @Test func anOldInstallMovesBothFoldersAndLeavesALinkForScripts() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let outcome = LegacyMigration.run(home: home, environment: environment())
        #expect(outcome == .migrated(.init(stateDir: newState, launchersDir: newLaunchers)))
        #expect(outcome.exitCode == 0)

        #expect(fm.fileExists(atPath: newState.appending(path: "profiles.json").path))
        #expect(fm.fileExists(atPath: newState.appending(path: "Profiles/work").path))
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: "Claude WORK.app").path))
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: ".engines/Claude work.app").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: legacyState.path) == "Baton", "a relative link, for old scripts")
        #expect(fm.fileExists(atPath: legacyState.appending(path: "profiles.json").path), "the link leads to the moved folder")
        #expect(!LegacyMigration.exists(legacyLaunchers), "no link in ~/Applications: Finder would show the old name")

        #expect(paths().stateDir == newState)
        #expect(paths().launchersDir == newLaunchers)
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).isEmpty)
        #expect(
            LegacyMigration.message(for: outcome, home: home).hasPrefix("Moved Baton's folders from Claude Profiles to ~/Library/Application Support/Baton"))
    }

    @Test func anOldInstallWithoutLaunchersMovesItsStateFolder() throws {
        defer { cleanUp() }
        try makeLegacyInstall(launchers: false)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .migrated(.init(stateDir: newState, launchersDir: nil)))
        #expect(paths().stateDir == newState)
        #expect(!LegacyMigration.exists(legacyLaunchers) && !LegacyMigration.exists(newLaunchers))
    }

    @Test func aSecondRunHasNothingToDo() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        _ = LegacyMigration.run(home: home, environment: environment())
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(LegacyMigration.run(home: home, environment: environment()).exitCode == 0)
        #expect(isLink(legacyState))
        #expect(fm.fileExists(atPath: newState.appending(path: "profiles.json").path))
    }

    @Test func aFailedSecondRenameMovesTheFirstBack() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let launchers = legacyLaunchers.standardizedFileURL.path
        let outcome = LegacyMigration.run(
            home: home,
            environment: environment(rename: { source, destination in
                if source.standardizedFileURL.path == launchers { throw POSIXError(.EACCES) }
                try LegacyMigration.renameExclusive(source, destination)
            }))
        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("moved back"))
        #expect(outcome.exitCode == 1)
        #expect(Paths.isRealDirectory(legacyState), "both folders keep their old name")
        #expect(fm.fileExists(atPath: legacyState.appending(path: "profiles.json").path))
        #expect(Paths.isRealDirectory(legacyLaunchers))
        #expect(!LegacyMigration.exists(newState) && !LegacyMigration.exists(newLaunchers))
        #expect(paths().stateDir == legacyState && paths().launchersDir == legacyLaunchers)
    }

    @Test func aFailedFirstRenameMovesNothing() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let outcome = LegacyMigration.run(home: home, environment: environment(rename: { _, _ in throw POSIXError(.EPERM) }))
        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("Nothing was moved"))
        #expect(Paths.isRealDirectory(legacyState) && Paths.isRealDirectory(legacyLaunchers))
    }

    // MARK: Keeping the old folders for now

    @Test func anythingRunningFromTheOldFoldersKeepsThem() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let claudeRunning = [
            // A profile's window: an engine and one of its helpers.
            LegacyMigration.RunningProcess(pid: 10, executable: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS/Claude").path),
            LegacyMigration.RunningProcess(
                pid: 11,
                executable: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper").path),
            // The Claude Code binary Claude Desktop keeps in a profile's data folder.
            LegacyMigration.RunningProcess(pid: 12, executable: legacyState.appending(path: "Profiles/work/claude-code/2.1.0/claude").path),
            // Any Claude started on a profile's data.
            LegacyMigration.RunningProcess(
                pid: 13, executable: "/Applications/Claude.app/Contents/MacOS/Claude",
                arguments: ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=" + legacyState.appending(path: "Profiles/work").path]),
        ]
        for process in claudeRunning {
            let outcome = LegacyMigration.run(home: home, environment: environment(processes: [process]))
            #expect(outcome == .kept(.claudeRunning), "\(process)")
            #expect(outcome.exitCode == 3)
        }
        #expect(Paths.isRealDirectory(legacyState) && Paths.isRealDirectory(legacyLaunchers))
        #expect(!LegacyMigration.exists(newState) && !LegacyMigration.exists(newLaunchers))
        #expect(paths().stateDir == legacyState)
        #expect(
            LegacyMigration.notes(paths: paths(), environment: environment(processes: claudeRunning)) == [
                "Baton still uses the Claude Profiles folders because Claude windows are open. It moves them the next time it starts with every Claude window closed."
            ])
    }

    @Test func claudeElsewhereAndTheMigratingProcessDoNotKeepThem() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let processes = [
            // The main Claude on its own data, and a Claude Code session of it.
            LegacyMigration.RunningProcess(pid: 20, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"]),
            LegacyMigration.RunningProcess(pid: 21, executable: support.appending(path: "Claude/claude-code/2.1.0/claude").path),
            // `baton migrate` itself may run from inside the old launchers folder.
            LegacyMigration.RunningProcess(pid: 4242, executable: legacyLaunchers.appending(path: "Baton.app/Contents/Helpers/baton").path),
            // An unreadable one.
            LegacyMigration.RunningProcess(pid: 22, executable: nil),
        ]
        #expect(
            LegacyMigration.run(home: home, environment: environment(processes: processes)) == .migrated(.init(stateDir: newState, launchersDir: newLaunchers)))
    }

    @Test func anotherBatonKeepsThem() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let baton = home.appending(path: "Elsewhere/Baton.app"), stranger = home.appending(path: "Other/Baton.app")
        try makeApp(baton, bundleID: AppInstances.bundleID)
        try makeApp(stranger, bundleID: "com.example.baton")

        let other = LegacyMigration.RunningProcess(pid: 30, executable: baton.appending(path: "Contents/Helpers/baton").path)
        #expect(LegacyMigration.run(home: home, environment: environment(processes: [other])) == .kept(.batonRunning))
        // With a Claude window open too, the line names the windows.
        let window = LegacyMigration.RunningProcess(pid: 31, executable: legacyState.appending(path: "Profiles/work/claude-code/2.1.0/claude").path)
        #expect(LegacyMigration.run(home: home, environment: environment(processes: [other, window])) == .kept(.claudeRunning))
        // Another app that happens to be called Baton isn't one.
        let unrelated = LegacyMigration.RunningProcess(pid: 32, executable: stranger.appending(path: "Contents/MacOS/Baton").path)
        #expect(
            LegacyMigration.run(home: home, environment: environment(processes: [unrelated]))
                == .migrated(.init(stateDir: newState, launchersDir: newLaunchers)))
    }

    @Test func theAppInsideTheOldLaunchersFolderSkipsTheMove() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let app = legacyLaunchers.appending(path: "Baton.app", directoryHint: .isDirectory)
        try makeApp(app, bundleID: AppInstances.bundleID)
        let outcome = LegacyMigration.run(home: home, app: app, environment: environment())
        #expect(outcome == .kept(.appInsideLegacyFolder))
        #expect(outcome.exitCode == 3)
        #expect(Paths.isRealDirectory(legacyState) && Paths.isRealDirectory(legacyLaunchers))
        #expect(
            LegacyMigration.notes(paths: paths(), app: app, environment: environment()) == [
                "Baton runs from inside the old Claude Profiles folder. Quit Baton, close every Claude window, then run scripts/install-app.sh again or `baton migrate`."
            ])
        // Another copy of the app running from there keeps them for the CLI too.
        let running = LegacyMigration.RunningProcess(pid: 40, executable: app.appending(path: "Contents/MacOS/Baton").path)
        #expect(LegacyMigration.run(home: home, environment: environment(processes: [running])) == .kept(.appInsideLegacyFolder))
    }

    @Test func aDifferentVolumeKeepsThem() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let state = legacyState.standardizedFileURL.path, launchers = legacyLaunchers.standardizedFileURL.path
        for moved in [state, launchers] {
            let outcome = LegacyMigration.run(
                home: home, environment: environment(volume: { $0.standardizedFileURL.path == moved ? 2 : 1 }))
            #expect(outcome == .kept(.differentVolume))
        }
        #expect(LegacyMigration.run(home: home, environment: environment(volume: { _ in nil })) == .kept(.differentVolume))
        #expect(Paths.isRealDirectory(legacyState) && Paths.isRealDirectory(legacyLaunchers))
    }

    @Test func anotherBatonWorkingInTheOldFoldersKeepsThem() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let sync) = LegacyMigration.acquire(legacyState.appending(path: "sync.lock"), wait: 0) else {
            Issue.record("couldn't take the sync lock")
            return
        }
        #expect(LegacyMigration.run(home: home, environment: environment()) == .kept(.busy))
        LegacyMigration.release(sync)
        #expect(Paths.isRealDirectory(legacyState))
        #expect(LegacyMigration.run(home: home, environment: environment()) == .migrated(.init(stateDir: newState, launchersDir: newLaunchers)))
    }

    // MARK: Both names

    @Test func bothNamesUseTheNewFolderAndLeaveTheOldOneAlone() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try fm.createDirectory(at: newState, withIntermediateDirectories: true)
        let outcome = LegacyMigration.run(home: home, environment: environment())
        #expect(outcome == .bothExist([.init(new: newState, legacy: legacyState)]))
        #expect(outcome.exitCode == 0)
        #expect(fm.fileExists(atPath: legacyState.appending(path: "profiles.json").path))
        #expect(Paths.isRealDirectory(legacyLaunchers), "the pair moves together or not at all")
        #expect(paths().stateDir == newState)
        let notes = LegacyMigration.notes(paths: paths(), environment: environment())
        #expect(
            notes == [
                "Both ~/Library/Application Support/Baton and ~/Library/Application Support/Claude Profiles exist. Baton uses the first and leaves the Claude Profiles one untouched; move what you still need out of it yourself."
            ])
    }

    @Test func bothLaunchersFoldersKeepTheStateFolderWhereItIs() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try fm.createDirectory(at: newLaunchers, withIntermediateDirectories: true)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .bothExist([.init(new: newLaunchers, legacy: legacyLaunchers)]))
        #expect(Paths.isRealDirectory(legacyState))
        #expect(paths().stateDir == legacyState && paths().launchersDir == newLaunchers)
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).first?.contains("~/Applications/Claude Profiles") == true)
    }

    @Test func aLinkAtTheOldNameCountsAsMoved() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: newState, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: legacyState.path, withDestinationPath: "Baton")
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(paths().stateDir == newState)
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).isEmpty)
        // Even a link that leads nowhere.
        try fm.removeItem(at: newState)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(paths().stateDir == newState)
        #expect(isLink(legacyState))
    }

    @Test func aLauncherFolderLeftBehindAloneGetsALine() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: newState, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyLaunchers, withIntermediateDirectories: true)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(paths().launchersDir == legacyLaunchers)
        let notes = LegacyMigration.notes(paths: paths(), environment: environment())
        #expect(notes.count == 1)
        #expect(notes.first?.hasPrefix("Baton still uses ~/Applications/Claude Profiles:") == true)
    }

    // MARK: The lock

    @Test func aSecondMigratorWaitsAndSeesTheResult() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let other) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0) else {
            Issue.record("couldn't take the migration lock")
            return
        }
        // The other migrator finishes the move while this one waits.
        let (home, legacyState, newState, legacyLaunchers, newLaunchers) = (home, legacyState, newState, legacyLaunchers, newLaunchers)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            usleep(300_000)
            try? LegacyMigration.renameExclusive(legacyState, newState)
            try? LegacyMigration.renameExclusive(legacyLaunchers, newLaunchers)
            try? FileManager.default.createSymbolicLink(atPath: legacyState.path, withDestinationPath: "Baton")
            LegacyMigration.release(other)
            finished.signal()
        }
        let started = Date()
        #expect(LegacyMigration.run(home: home, environment: environment(lockWait: 10)) == .nothingToDo)
        #expect(Date().timeIntervalSince(started) >= 0.25, "it waited for the lock")
        finished.wait()
        #expect(Paths(home: home, claudeApp: home).stateDir == newState)
    }

    @Test func aLockHeldTooLongKeepsTheFolders() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let other) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0) else {
            Issue.record("couldn't take the migration lock")
            return
        }
        defer { LegacyMigration.release(other) }
        #expect(LegacyMigration.run(home: home, environment: environment(lockWait: 0.2)) == .kept(.busy))
        #expect(Paths.isRealDirectory(legacyState))
        #expect(!LegacyMigration.lockFile(home: home).path.hasPrefix(legacyState.path + "/"), "the lock lives outside both folders")
    }

    // MARK: The old app

    @Test func theOldAppThatCameAlongGoesToTheTrash() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try makeApp(legacyLaunchers.appending(path: "Claude Profiles.app"), bundleID: AppInstances.bundleID)
        let outcome = LegacyMigration.run(home: home, environment: environment())
        guard case .migrated(let moved) = outcome else {
            Issue.record("expected a move, got \(outcome)")
            return
        }
        #expect(moved.trashedOldApp)
        #expect(!LegacyMigration.exists(newLaunchers.appending(path: "Claude Profiles.app")))
        #expect(fm.fileExists(atPath: trashFolder.appending(path: "Claude Profiles.app").path), "to the Trash, not deleted")
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: "Claude WORK.app").path), "launchers stay")
        #expect(LegacyMigration.message(for: outcome, home: home).contains("The old Claude Profiles.app went to the Trash"))
    }

    @Test func anotherAppOfThatNameStays() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try makeApp(legacyLaunchers.appending(path: "Claude Profiles.app"), bundleID: "com.example.other")
        guard case .migrated(let moved) = LegacyMigration.run(home: home, environment: environment()) else {
            Issue.record("expected a move")
            return
        }
        #expect(!moved.trashedOldApp)
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: "Claude Profiles.app").path))
    }

    // MARK: The CLI

    @Test func onlyMigrateMoves() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        for args in [[], ["doctor"], ["continue", "last", "--to", "work"], ["pass", "last", "--to", "work"], ["rules"], ["sync"], ["list"]] {
            #expect(LegacyMigration.command(args, home: home, environment: environment()) == nil, "\(args)")
        }
        _ = ProfileManager(paths: paths())
        #expect(Paths.isRealDirectory(legacyState) && Paths.isRealDirectory(legacyLaunchers), "building the manager moves nothing")
        #expect(!LegacyMigration.exists(newState) && !LegacyMigration.exists(newLaunchers))

        let result = try #require(LegacyMigration.command(["migrate"], home: home, environment: environment()))
        #expect(result.exitCode == 0)
        #expect(result.message.hasPrefix("Moved Baton's folders"))
        #expect(LegacyMigration.command(["migrate"], home: home, environment: environment())?.message == "Nothing to move: Baton already uses its own folders.")
        let running = LegacyMigration.RunningProcess(pid: 50, executable: newLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS/Claude").path)
        #expect(LegacyMigration.command(["migrate"], home: home, environment: environment(processes: [running]))?.exitCode == 0)
    }

    @Test func readsPathsInCommandLines() {
        let roots = ["/Users/me/Library/Application Support/Claude Profiles"]
        #expect(LegacyMigration.uses(["Claude", "--user-data-dir=/Users/me/Library/Application Support/Claude Profiles/Profiles/w"], roots: roots))
        #expect(LegacyMigration.uses(["sh", "/users/me/library/application support/claude profiles/x"], roots: roots), "case-insensitive")
        #expect(LegacyMigration.uses(["tool", "--config=/Users/me/Library/Application Support/Claude Profiles/profiles.json"], roots: roots))
        #expect(!LegacyMigration.uses(["Claude", "--user-data-dir=/Users/me/Library/Application Support/Claude"], roots: roots))
        #expect(!LegacyMigration.uses(["/Users/me/Library/Application Support/Claude Profiles/argv0"], roots: roots), "argv[0] is the executable")
        #expect(!LegacyMigration.uses(["x", "/Users/me/Library/Application Support/Claude Profiles2"], roots: roots))
        #expect(LegacyMigration.isInside("/a/b", "/a/b") && LegacyMigration.isInside("/a/b/c", "/a/b/") && !LegacyMigration.isInside("relative", "/a"))
    }
}
