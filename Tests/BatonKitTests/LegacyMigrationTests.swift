import Darwin
import Foundation
import Testing

@testable import BatonKit

/// Renaming the launchers folder from its name before 1.0, Claude Profiles, to Baton; the data folder keeps its name.
/// Everything happens in a temporary home passed in explicitly: the process list and the Trash are stand-ins, renames
/// happen inside the sandbox only, and launchers are signed and registered by a stand-in that does nothing.
@Suite("Renaming the Claude Profiles launchers folder to Baton")
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

    /// An install from before 1.0: the data folder with a profile and, unless `launchers` is false, a launcher and an
    /// engine in the old launchers folder.
    func makeLegacyInstall(launchers: Bool = true) throws {
        try fm.createDirectory(at: legacyState.appending(path: "Profiles/work"), withIntermediateDirectories: true)
        guard launchers else { return }
        try fm.createDirectory(at: legacyLaunchers.appending(path: "Claude WORK.app/Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS"), withIntermediateDirectories: true)
    }

    func makeApp(_ url: URL, bundleID: String, version: String = "1.0.0") throws {
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    }

    /// Stand-ins for the system. The Trash is a folder in the sandbox; `rename` is the real exclusive rename unless
    /// given; launchers are rewritten by a real `ProfileManager` whose signing and registering does nothing.
    func environment(
        processes: [LegacyMigration.RunningProcess] = [], rename: (@Sendable (URL, URL) throws -> Void)? = nil,
        lockWait: TimeInterval = 2, readProcesses: (@Sendable () -> [LegacyMigration.RunningProcess])? = nil
    ) -> LegacyMigration.Environment {
        let trashFolder = trashFolder
        return LegacyMigration.Environment(
            processes: readProcesses ?? { processes }, rename: rename ?? LegacyMigration.renameExclusive,
            trash: { url in
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trashFolder.appending(path: url.lastPathComponent))
            },
            rewriteLaunchers: { home, cli in
                let manager = ProfileManager(paths: Paths(home: home, claudeApp: home.appending(path: "Applications/Claude.app")), cliPath: cli)
                manager.launcherRegistrar = { _ in }
                return manager.rewriteLaunchersInPlace()
            }, pid: 4242, lockWait: lockWait)
    }

    func paths() -> Paths { Paths(home: home, claudeApp: home.appending(path: "Applications/Claude.app")) }

    /// A manager on the sandbox whose launchers are never signed or registered.
    func manager(cli: URL?) -> ProfileManager {
        let manager = ProfileManager(paths: paths(), cliPath: cli)
        manager.launcherRegistrar = { _ in }
        return manager
    }

    func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

    func inode(_ url: URL) throws -> Int {
        try #require(try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func cleanUp() { try? fm.removeItem(at: home) }

    // MARK: Where Baton lives

    @Test func aFreshInstallUsesBaton() {
        defer { cleanUp() }
        #expect(paths().stateDir == newState)
        #expect(paths().launchersDir == newLaunchers)
        #expect(!paths().usesLegacyLaunchersFolder)
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo)
        #expect(!fm.fileExists(atPath: LegacyMigration.lockFile(home: home).path), "nothing to rename takes no lock")
        #expect(!fm.fileExists(atPath: newState.path), "and creates no folder")
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).isEmpty)
    }

    @Test func aLegacyDataFolderIsUsedInPlaceAndNeverRenamed() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        #expect(paths().stateDir == legacyState)
        #expect(paths().launchersDir == legacyLaunchers)
        #expect(LegacyMigration.lockFile(home: home).deletingLastPathComponent().path == legacyState.path, "the lock lives in the data folder")

        guard case .migrated = LegacyMigration.run(home: home, environment: environment()) else {
            Issue.record("the launchers folder should be renamed")
            return
        }
        #expect(LegacyMigration.isRealDirectory(legacyState), "the data folder keeps its name")
        #expect(!LegacyMigration.exists(newState), "no Baton data folder, no link")
        #expect(paths().stateDir == legacyState)
        #expect(paths().launchersDir == newLaunchers)
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).isEmpty, "no line about the data folder")
    }

    @Test func aLinkedLegacyDataFolderIsUsedInPlaceAndNeverRenamed() throws {
        defer { cleanUp() }
        let elsewhere = home.appending(path: "Elsewhere/Claude Profiles data", directoryHint: .isDirectory)
        try fm.createDirectory(at: elsewhere.appending(path: "Profiles/work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: legacyState, withDestinationURL: elsewhere)
        try fm.createDirectory(at: legacyLaunchers.appending(path: "Claude WORK.app/Contents/MacOS"), withIntermediateDirectories: true)
        #expect(paths().stateDir == legacyState)

        guard case .migrated = LegacyMigration.run(home: home, environment: environment()) else {
            Issue.record("the launchers folder should be renamed")
            return
        }
        #expect(isLink(legacyState), "still the same link")
        #expect(LegacyMigration.isRealDirectory(elsewhere))
        #expect(!LegacyMigration.exists(newState))
        #expect(paths().stateDir == legacyState)
    }

    @Test func aBatonDataFolderWinsOverTheOldOne() throws {
        defer { cleanUp() }
        try makeLegacyInstall(launchers: false)
        try fm.createDirectory(at: newState, withIntermediateDirectories: true)
        #expect(paths().stateDir == newState)
        #expect(Paths.unreachableFolder(home: home) == nil)
    }

    /// Both data folders, and the old one still has profiles: doctor and the status panel say which one Baton uses.
    @Test func bothDataFoldersAreNamed() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: newState, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyState, withIntermediateDirectories: true)
        #expect(LegacyMigration.dataFolderNote(home: home).isEmpty, "no profiles in the old one")
        try Data("[]".utf8).write(to: legacyState.appending(path: "profiles.json"))
        #expect(
            LegacyMigration.dataFolderNote(home: home) == [
                "Both ~/Library/Application Support/Baton and ~/Library/Application Support/Claude Profiles exist, and ~/Library/Application Support/Claude Profiles still has profiles. Baton uses ~/Library/Application Support/Baton and leaves the other alone; with Baton quit, move whichever you don't need to the Trash."
            ])
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).last == LegacyMigration.dataFolderNote(home: home).first)
    }

    /// A link at the old name that leads nowhere right now (a disk not connected) is still Baton's folder: no new,
    /// empty Baton folder takes its place, and the CLI and the app stop with a plain line instead.
    @Test func aLegacyLinkThatLeadsNowhereStopsBaton() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let disk = "/Volumes/Missing-\(UUID().uuidString)/Claude Profiles"
        try fm.createSymbolicLink(atPath: legacyState.path, withDestinationPath: disk)
        #expect(paths().stateDir == legacyState)
        #expect(
            Paths.unreachableFolder(home: home)
                == "Baton's data folder ~/Library/Application Support/Claude Profiles links to \(disk), which isn't there right now. Connect it and try again; Baton doesn't start a new folder in its place."
        )
        // Nothing that could run before the check creates a Baton folder either.
        _ = LegacyMigration.holdShared(home: home, wait: 0)
        #expect(!LegacyMigration.exists(newState), "no new, empty Baton folder")

        // The same for the launchers folder.
        try fm.removeItem(at: legacyState)
        try fm.createDirectory(at: home.appending(path: "Applications"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: legacyLaunchers.path, withDestinationPath: disk)
        #expect(paths().launchersDir == legacyLaunchers)
        #expect(Paths.unreachableFolder(home: home)?.hasPrefix("Baton's folder of launchers ~/Applications/Claude Profiles links to \(disk)") == true)

        // A live link, or a real Baton folder, is used as before.
        try fm.removeItem(at: legacyLaunchers)
        try fm.createDirectory(at: newLaunchers, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: legacyLaunchers.path, withDestinationPath: disk)
        #expect(paths().launchersDir == newLaunchers)
        #expect(Paths.unreachableFolder(home: home) == nil)
    }

    // MARK: Renaming the launchers folder

    @Test func theLaunchersFolderIsRenamedWhenNothingRunsFromIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let outcome = LegacyMigration.run(home: home, environment: environment())
        #expect(outcome == .migrated(.init(launchersDir: newLaunchers)))
        #expect(outcome.exitCode == 0)
        #expect(LegacyMigration.isRealDirectory(newLaunchers))
        #expect(!LegacyMigration.exists(legacyLaunchers), "one rename, no link left behind")
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: ".engines/Claude work.app").path))
        #expect(LegacyMigration.run(home: home, environment: environment()) == .nothingToDo, "a second run has nothing to do")
        #expect(
            LegacyMigration.message(for: outcome, home: home)
                == "Renamed ~/Applications/Claude Profiles to ~/Applications/Baton. Relink any command link you made into ~/Applications/Claude Profiles.")
    }

    @Test func anythingRunningFromTheOldFolderKeepsIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let running: [LegacyMigration.RunningProcess] = [
            // An engine, or any helper inside it.
            .init(pid: 50, parent: 1, executable: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS/Claude").path),
            // A launcher's script, run by the shell.
            .init(
                pid: 51, parent: 1, executable: "/bin/sh",
                arguments: ["/bin/sh", legacyLaunchers.appending(path: "Claude WORK.app/Contents/MacOS/launch").path]),
            // A Claude window with a profile's data, whatever copy of Claude it runs.
            .init(
                pid: 52, parent: 1, executable: "/Applications/Claude.app/Contents/MacOS/Claude",
                arguments: ["Claude", "--user-data-dir=\(legacyState.path)/Profiles/work"]),
        ]
        for process in running {
            let outcome = LegacyMigration.run(home: home, environment: environment(processes: [process]))
            #expect(outcome == .kept(.claudeRunning), "\(process.pid)")
            #expect(outcome.exitCode == 3)
            #expect(LegacyMigration.isRealDirectory(legacyLaunchers) && !LegacyMigration.exists(newLaunchers))
        }
        let line = try #require(LegacyMigration.notes(paths: paths(), environment: environment(processes: running)).first)
        #expect(
            line
                == "Baton's folder in ~/Applications still has the Claude Profiles name because Claude windows are open. Baton renames it the next time it starts with every Claude window closed."
        )
    }

    @Test func claudeElsewhereAndAnAncestorNamingTheFolderDoNotKeepIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let cli = legacyLaunchers.appending(path: "Baton.app/Contents/Helpers/baton")
        try makeApp(legacyLaunchers.appending(path: "Baton.app"), bundleID: AppInstances.bundleID)
        let processes: [LegacyMigration.RunningProcess] = [
            // The main Claude, with its own data.
            .init(pid: 40, parent: 1, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"]),
            // scripts/install-app.sh, which only names the folder, and the terminal's shell above it.
            .init(pid: 30, parent: 1, executable: "/bin/zsh", arguments: ["-zsh"]),
            .init(
                pid: 31, parent: 30, executable: "/bin/sh", arguments: ["/bin/sh", legacyLaunchers.appending(path: "install-notes").path, legacyLaunchers.path]),
            // The migrating `baton` itself, inside the old folder.
            .init(pid: 4242, parent: 31, executable: cli.path, arguments: [cli.path, "migrate"]),
        ]
        let outcome = LegacyMigration.run(home: home, cli: cli, environment: environment(processes: processes))
        guard case .migrated = outcome else {
            Issue.record("expected a rename, got \(outcome)")
            return
        }
        #expect(LegacyMigration.isRealDirectory(newLaunchers))
    }

    @Test func anotherBatonKeepsIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let elsewhere = home.appending(path: "Other/Baton.app"), old = home.appending(path: "Other/Claude Profiles.app")
        let stranger = home.appending(path: "Other/Stranger/Baton.app")
        try makeApp(elsewhere, bundleID: AppInstances.bundleID)
        try makeApp(old, bundleID: AppInstances.bundleID)
        try makeApp(stranger, bundleID: "com.example.baton")
        for executable in [
            elsewhere.appending(path: "Contents/MacOS/Baton"), elsewhere.appending(path: "Contents/Helpers/baton"),
            old.appending(path: "Contents/MacOS/ClaudeProfiles"), old.appending(path: "Contents/Helpers/claude-profiles"),
        ] {
            let process = LegacyMigration.RunningProcess(pid: 60, parent: 1, executable: executable.path)
            #expect(LegacyMigration.run(home: home, environment: environment(processes: [process])) == .kept(.batonRunning), "\(executable.path)")
        }
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers))
        let line = LegacyMigration.line(for: .batonRunning, home: home)
        #expect(line.contains("because another Baton is running. Quit it, then open Baton again with every Claude window closed."))

        // Another app that happens to be called Baton doesn't count.
        let other = LegacyMigration.RunningProcess(pid: 61, parent: 1, executable: stranger.appending(path: "Contents/MacOS/Baton").path)
        guard case .migrated = LegacyMigration.run(home: home, environment: environment(processes: [other])) else {
            Issue.record("a stranger named Baton should not keep the folder")
            return
        }
    }

    @Test func theAppInsideTheOldFolderSkipsTheRenameAndSaysHow() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let app = legacyLaunchers.appending(path: "Baton.app", directoryHint: .isDirectory)
        try makeApp(app, bundleID: AppInstances.bundleID)
        let outcome = LegacyMigration.run(home: home, app: app, environment: environment())
        #expect(outcome == .kept(.appInsideLegacyFolder(app)))
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers))
        #expect(!fm.fileExists(atPath: LegacyMigration.lockFile(home: home).path), "decided before the lock")
        let expected =
            "Baton runs from inside ~/Applications/Claude Profiles, so it can't rename that folder itself. Quit Baton, close every Claude window, then run: \"\(app.standardizedFileURL.path)/Contents/Helpers/baton\" migrate"
        #expect(LegacyMigration.message(for: outcome, home: home) == expected)
        #expect(LegacyMigration.notes(paths: paths(), app: app, environment: environment()) == [expected])

        // `baton migrate` from that app, once it is quit, may rename it.
        let cli = app.appending(path: "Contents/Helpers/baton")
        let migrating = LegacyMigration.RunningProcess(pid: 4242, parent: 1, executable: cli.path)
        let result = try #require(LegacyMigration.command(["migrate"], home: home, cli: cli, environment: environment(processes: [migrating])))
        #expect(result.exitCode == 0)
        #expect(LegacyMigration.isRealDirectory(newLaunchers))
    }

    @Test func theAppStillRunningInsideTheOldFolderKeepsIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let app = legacyLaunchers.appending(path: "Baton.app", directoryHint: .isDirectory)
        try makeApp(app, bundleID: AppInstances.bundleID)
        let running = LegacyMigration.RunningProcess(pid: 70, parent: 1, executable: app.appending(path: "Contents/MacOS/Baton").path)
        let cli = app.appending(path: "Contents/Helpers/baton")
        let outcome = LegacyMigration.run(home: home, cli: cli, environment: environment(processes: [running]))
        guard case .kept(.appInsideLegacyFolder(let found)) = outcome else {
            Issue.record("expected the app inside the folder to keep it, got \(outcome)")
            return
        }
        #expect(found.standardizedFileURL.path == app.standardizedFileURL.path)
        #expect(LegacyMigration.message(for: outcome, home: home).hasSuffix("then run: \"\(app.standardizedFileURL.path)/Contents/Helpers/baton\" migrate"))
    }

    @Test func aDifferentVolumeKeepsIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let crossing = environment(rename: { _, _ in throw POSIXError(.EXDEV) })
        let outcome = LegacyMigration.run(home: home, environment: crossing)
        #expect(outcome == .kept(.differentVolume))
        #expect(outcome.exitCode == 3)
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers) && !LegacyMigration.exists(newLaunchers))
        #expect(LegacyMigration.message(for: outcome, home: home).contains("Baton renames folders but never copies them"))

        let refused = LegacyMigration.run(home: home, environment: environment(rename: { _, _ in throw POSIXError(.EACCES) }))
        guard case .kept(.renameFailed) = refused else {
            Issue.record("any other rename error keeps the folder, got \(refused)")
            return
        }
        #expect(refused.exitCode == 3)
    }

    @Test func bothNamesKeepBothAndSayWhatToDo() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try fm.createDirectory(at: newLaunchers, withIntermediateDirectories: true)
        let outcome = LegacyMigration.run(home: home, environment: environment())
        #expect(outcome == .bothExist(new: newLaunchers, legacy: legacyLaunchers))
        #expect(outcome.exitCode == 0)
        #expect(paths().launchersDir == newLaunchers)
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers), "left alone")
        let expected =
            "Both ~/Applications/Baton and ~/Applications/Claude Profiles exist. Baton uses ~/Applications/Baton and leaves the other alone: with every Claude window closed, move anything you still need out of ~/Applications/Claude Profiles, then move that folder to the Trash."
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()) == [expected])
        #expect(LegacyMigration.message(for: outcome, home: home) == expected)
    }

    // MARK: Launchers after the rename

    @Test func launchersAreUpdatedInPlaceWithTheNewPaths() throws {
        defer { cleanUp() }
        try makeLegacyInstall(launchers: false)
        let profile = Profile(id: "work", label: "WORK", email: nil, color: "#000000")
        try ProfileRegistry(paths: paths()).save([profile])
        let oldCLI = legacyLaunchers.appending(path: "Baton.app/Contents/Helpers/baton")
        try makeApp(legacyLaunchers.appending(path: "Baton.app"), bundleID: AppInstances.bundleID)
        try manager(cli: oldCLI).buildLauncher(for: profile)
        let launcher = legacyLaunchers.appending(path: "Claude WORK.app", directoryHint: .isDirectory)
        let before = try inode(launcher)
        #expect(try String(contentsOf: launcher.appending(path: "Contents/MacOS/launch"), encoding: .utf8).contains(oldCLI.path))

        // The migrating `baton` lives in the folder being renamed: launchers get its path after the rename.
        let outcome = LegacyMigration.run(home: home, cli: oldCLI, environment: environment())
        guard case .migrated(let moved) = outcome else {
            Issue.record("expected a rename, got \(outcome)")
            return
        }
        #expect(moved.rewrittenLaunchers == 1 && moved.problems.isEmpty)
        let renamed = newLaunchers.appending(path: "Claude WORK.app", directoryHint: .isDirectory)
        #expect(try inode(renamed) == before, "the same bundle folder, so Dock items still find it")
        let script = try String(contentsOf: renamed.appending(path: "Contents/MacOS/launch"), encoding: .utf8)
        #expect(script.contains(newLaunchers.appending(path: "Baton.app/Contents/Helpers/baton").path), "the CLI at its new path")
        #expect(script.contains(newLaunchers.appending(path: ".engines/Claude work.app").path), "the engine at its new path")
        #expect(!script.contains(legacyLaunchers.path), "nothing points into the old launchers folder")
        #expect(
            LegacyMigration.message(for: outcome, home: home)
                == "Renamed ~/Applications/Claude Profiles to ~/Applications/Baton and updated its 1 launcher in place, so Dock items keep working. Relink any command link you made into ~/Applications/Claude Profiles."
        )
    }

    @Test func aCLIOutsideTheFolderKeepsItsPath() {
        let cli = URL(fileURLWithPath: "/opt/homebrew/Caskroom/baton/1.0/Baton.app/Contents/Helpers/baton")
        #expect(LegacyMigration.afterRename(cli, home: home) == cli)
        let inside = legacyLaunchers.appending(path: "Baton.app/Contents/Helpers/baton")
        #expect(LegacyMigration.afterRename(inside, home: home).path == newLaunchers.appending(path: "Baton.app/Contents/Helpers/baton").path)
    }

    @Test func buildingAnExistingLauncherNeverRemovesIt() throws {
        defer { cleanUp() }
        let profile = Profile(id: "work", label: "WORK", email: nil, color: "#000000")
        try manager(cli: URL(fileURLWithPath: "/first/baton")).buildLauncher(for: profile)
        let launcher = paths().launcher(for: profile)
        let before = try inode(launcher)
        let keepsake = launcher.appending(path: "Contents/Resources/keepsake")
        try Data("left by someone".utf8).write(to: keepsake)

        try manager(cli: URL(fileURLWithPath: "/second/baton")).buildLauncher(for: profile)
        #expect(try inode(launcher) == before)
        #expect(fm.fileExists(atPath: keepsake.path), "updated in place, never removed and rebuilt")
        let script = try String(contentsOf: launcher.appending(path: "Contents/MacOS/launch"), encoding: .utf8)
        #expect(script.contains("/second/baton") && !script.contains("/first/baton"))
        #expect(fm.isExecutableFile(atPath: launcher.appending(path: "Contents/MacOS/launch").path))

        // `refresh` goes the same way when the CLI moved.
        try ProfileRegistry(paths: paths()).save([profile])
        let third = manager(cli: URL(fileURLWithPath: "/third/baton"))
        #expect(third.rewriteLaunchersInPlace().rewritten == 1)
        #expect(try inode(launcher) == before)
    }

    @Test func theOldAppThatCameAlongGoesToTheTrash() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try makeApp(legacyLaunchers.appending(path: "Claude Profiles.app"), bundleID: AppInstances.bundleID)
        let outcome = LegacyMigration.run(home: home, environment: environment())
        guard case .migrated(let moved) = outcome else {
            Issue.record("expected a rename, got \(outcome)")
            return
        }
        #expect(moved.trashedOldApp)
        #expect(!fm.fileExists(atPath: newLaunchers.appending(path: "Claude Profiles.app").path))
        #expect(fm.fileExists(atPath: trashFolder.appending(path: "Claude Profiles.app").path))
        #expect(
            LegacyMigration.message(for: outcome, home: home).hasSuffix(
                "The old Claude Profiles.app went to the Trash: Baton.app replaces it. If Claude Profiles is in your Dock, remove it and add Baton. Relink any command link you made into ~/Applications/Claude Profiles."
            ))
    }

    @Test func anotherAppOfThatNameStays() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try makeApp(legacyLaunchers.appending(path: "Claude Profiles.app"), bundleID: "com.example.other")
        guard case .migrated(let moved) = LegacyMigration.run(home: home, environment: environment()) else {
            Issue.record("expected a rename")
            return
        }
        #expect(!moved.trashedOldApp)
        #expect(fm.fileExists(atPath: newLaunchers.appending(path: "Claude Profiles.app").path))
    }

    @Test func aTrashThatFailsIsAProblemNotASuccess() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        try makeApp(legacyLaunchers.appending(path: "Claude Profiles.app"), bundleID: AppInstances.bundleID)
        var failing = environment()
        failing.trash = { _ in throw POSIXError(.EPERM) }
        guard case .migrated(let moved) = LegacyMigration.run(home: home, environment: failing) else {
            Issue.record("expected a rename")
            return
        }
        #expect(!moved.trashedOldApp)
        #expect(moved.problems.count == 1)
        #expect(moved.problems.first?.hasPrefix("Couldn't move the old Claude Profiles.app in ~/Applications/Baton to the Trash") == true)
    }

    // MARK: The lock

    @Test func aSharedHolderKeepsTheFolder() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let command) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0, shared: true) else {
            Issue.record("couldn't take the shared lock")
            return
        }
        let started = Date()
        let outcome = LegacyMigration.run(home: home, environment: environment(lockWait: 0.3))
        #expect(outcome == .kept(.busy))
        #expect(outcome.exitCode == 3)
        #expect(Date().timeIntervalSince(started) >= 0.25, "it waited for the command")
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers))
        #expect(LegacyMigration.message(for: outcome, home: home).contains("because another baton command was using it"))
        LegacyMigration.release(command)
        guard case .migrated = LegacyMigration.run(home: home, environment: environment()) else {
            Issue.record("renamed once the command let go")
            return
        }
    }

    @Test func aCommandWaitsForARenameUnderWay() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let migrator) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0, shared: false) else {
            Issue.record("couldn't take the lock")
            return
        }
        #expect(LegacyMigration.holdShared(home: home, wait: 0.1) == "Baton is renaming its folder in ~/Applications right now. Try again in a moment.")
        LegacyMigration.release(migrator)
        guard case .held(let command) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0.1, shared: true) else {
            Issue.record("the shared lock is free once the rename is done")
            return
        }
        LegacyMigration.release(command)
    }

    @Test func theProcessListIsReadUnderTheLock() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let lockFile = LegacyMigration.lockFile(home: home)
        let reads = Reads()
        let checking = environment(readProcesses: {
            // A command trying to start now can't: the migrator holds the lock while it reads the list.
            if case .held(let descriptor) = LegacyMigration.acquire(lockFile, wait: 0, shared: true) {
                LegacyMigration.release(descriptor)
                reads.record(underLock: false)
            } else {
                reads.record(underLock: true)
            }
            return []
        })
        guard case .migrated = LegacyMigration.run(home: home, environment: checking) else {
            Issue.record("expected a rename")
            return
        }
        #expect(reads.all == [true], "read once, with the lock held, right before the rename")
    }

    @Test func aSecondMigratorWaitsAndSeesTheResult() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        guard case .held(let other) = LegacyMigration.acquire(LegacyMigration.lockFile(home: home), wait: 0, shared: false) else {
            Issue.record("couldn't take the migration lock")
            return
        }
        let (legacyLaunchers, newLaunchers) = (legacyLaunchers, newLaunchers)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            usleep(300_000)
            try? LegacyMigration.renameExclusive(legacyLaunchers, newLaunchers)
            LegacyMigration.release(other)
            finished.signal()
        }
        #expect(LegacyMigration.run(home: home, environment: environment(lockWait: 10)) == .nothingToDo)
        finished.wait()
    }

    // MARK: Where it runs

    @Test func demoModeNeverRenames() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        #expect(LegacyMigration.atAppStart(home: home, app: home, cli: nil, variables: ["BATON_DEMO": "1"], environment: environment()) == nil)
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers) && !LegacyMigration.exists(newLaunchers))
        #expect(!fm.fileExists(atPath: LegacyMigration.lockFile(home: home).path))
        let started = LegacyMigration.atAppStart(home: home, app: home.appending(path: "Other/Baton.app"), cli: nil, variables: [:], environment: environment())
        guard case .migrated? = started else {
            Issue.record("outside demo mode it renames, got \(String(describing: started))")
            return
        }
    }

    @Test func demoModeChangesNothingThroughTheManager() async throws {
        defer { cleanUp() }
        try makeLegacyInstall(launchers: false)
        try ProfileRegistry(paths: paths()).save([Profile(id: "work", label: "WORK", email: nil, color: "#000000")])
        let demo = ProfileManager(paths: paths(), readOnly: true)
        demo.launcherRegistrar = { _ in Issue.record("demo mode built a launcher") }
        #expect(throws: ProfileError.readOnly) { try demo.refresh() }
        #expect(throws: ProfileError.readOnly) { try demo.create(label: "LAB", email: nil) }
        #expect(throws: ProfileError.readOnly) { try demo.syncSessions() }
        #expect(throws: ProfileError.readOnly) { try demo.setCarryPermissionMode(true, for: "work") }
        #expect(throws: ProfileError.readOnly) { try demo.setLocalOnly(false, window: nil) }
        #expect(throws: ProfileError.readOnly) { try demo.setCloudMoveLock(true) }
        await #expect(throws: ProfileError.readOnly) { try await demo.open("work") }
        await #expect(throws: ProfileError.readOnly) { try await demo.openMain() }
        await #expect(throws: ProfileError.readOnly) { try await demo.remove("work") }
        await #expect(throws: ProfileError.readOnly) { try await demo.restart("work") }
        await #expect(throws: ProfileError.readOnly) { try await demo.continueAll([], in: "work") }
        let rewrite = demo.rewriteLaunchersInPlace()
        #expect(rewrite.rewritten == 0 && rewrite.problems.isEmpty)
        #expect(demo.startUpChecks().isEmpty)
        #expect(!fm.fileExists(atPath: paths().launcher(for: Profile(id: "work", label: "WORK", email: nil, color: "#000000")).path))
    }

    @Test func onlyMigrateRenames() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        for args in [[], ["doctor"], ["continue", "last", "--to", "work"], ["rules"], ["sync"], ["list"], ["open", "work"]] {
            #expect(LegacyMigration.command(args, home: home, cli: nil, environment: environment()) == nil, "\(args)")
        }
        _ = ProfileManager(paths: paths())
        #expect(LegacyMigration.isRealDirectory(legacyLaunchers), "building the manager renames nothing")

        let running = LegacyMigration.RunningProcess(
            pid: 50, parent: 1, executable: legacyLaunchers.appending(path: ".engines/Claude work.app/Contents/MacOS/Claude").path)
        let kept = try #require(LegacyMigration.command(["migrate"], home: home, cli: nil, environment: environment(processes: [running])))
        #expect(kept.exitCode == 3)
        for extra in [["--dry-run"], ["--now"], ["x"]] {
            let refused = try #require(LegacyMigration.command(["migrate"] + extra, home: home, cli: nil, environment: environment()))
            #expect(refused.exitCode == 1 && refused.message.contains("nothing was renamed"), "\(extra)")
            #expect(LegacyMigration.isRealDirectory(legacyLaunchers), "\(extra): an option it doesn't take renames nothing")
        }
        let result = try #require(LegacyMigration.command(["migrate"], home: home, cli: nil, environment: environment()))
        #expect(result.exitCode == 0)
        #expect(result.message.hasPrefix("Renamed ~/Applications/Claude Profiles to ~/Applications/Baton"))
        #expect(
            LegacyMigration.command(["migrate"], home: home, cli: nil, environment: environment())?.message
                == "Nothing to rename: Baton's folder in ~/Applications already has its name.")
    }

    @Test func linesForACLIInsideTheOldFolderNameIt() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let app = legacyLaunchers.appending(path: "Baton.app", directoryHint: .isDirectory)
        let cli = app.appending(path: "Contents/Helpers/baton")
        let command = "\"\(app.standardizedFileURL.path)/Contents/Helpers/baton\" migrate"
        #expect(
            LegacyMigration.line(for: .claudeRunning, home: home, insideApp: LegacyMigration.insideApp(cli: cli, home: home))
                == "Baton's folder in ~/Applications still has the Claude Profiles name because Claude windows are open. Close every Claude window and quit Baton, then run: \(command)"
        )
        #expect(LegacyMigration.insideApp(cli: URL(fileURLWithPath: "/Applications/Baton.app/Contents/Helpers/baton"), home: home) == nil)
        #expect(
            LegacyMigration.line(for: nil, home: home)
                == "Baton's folder in ~/Applications still has the Claude Profiles name. Baton renames it the next time it starts with every Claude window closed, or now with `baton migrate`."
        )
    }

    /// Inside the app `baton migrate` always refuses, since the app itself is a running Baton: the status panel says
    /// to quit and open Baton again instead.
    @Test func theAppNeverOffersBatonMigrate() throws {
        defer { cleanUp() }
        try makeLegacyInstall()
        let notes = LegacyMigration.notes(paths: paths(), app: URL(fileURLWithPath: "/Applications/Baton.app"), environment: environment())
        #expect(
            notes == [
                "Baton's folder in ~/Applications still has the Claude Profiles name. Quit Baton and open it again: with every Claude window closed it renames the folder as it starts."
            ])
        #expect(LegacyMigration.notes(paths: paths(), environment: environment()).first?.hasSuffix("or now with `baton migrate`.") == true, "the CLI's doctor")
    }

    @Test func readsPaths() {
        #expect(LegacyMigration.isInside("/a/b", "/a/b") && LegacyMigration.isInside("/a/b/c", "/a/b/") && !LegacyMigration.isInside("relative", "/a"))
        #expect(LegacyMigration.isInside("/Users/Me/Applications/claude profiles/x", "/Users/me/Applications/Claude Profiles"), "case-insensitive")
        #expect(!LegacyMigration.isInside("/a/bc", "/a/b"))
        #expect(LegacyMigration.ancestors(of: 3, in: [.init(pid: 3, parent: 2, executable: nil), .init(pid: 2, parent: 1, executable: nil)]) == [1, 2, 3])
        #expect(LegacyMigration.ancestors(of: 3, in: [.init(pid: 3, parent: 3, executable: nil)]) == [3], "a loop ends")
    }
}

/// What the process-list stand-in saw, from whichever thread read it.
final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(underLock: Bool) { lock.withLock { values.append(underLock) } }
    var all: [Bool] { lock.withLock { values } }
}
