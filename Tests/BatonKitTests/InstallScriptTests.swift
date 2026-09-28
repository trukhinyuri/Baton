import Foundation
import Testing

@testable import BatonKit

/// scripts/install-app.sh and its functions, run only with --where, --dry-run or sourced, against a temporary home
/// passed with --home. `HOME` points nowhere, so nothing falls back to the real home folder.
@Suite("Install script")
struct InstallScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root: URL
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var legacy: URL { home.appending(path: "Applications/Claude Profiles", directoryHint: .isDirectory) }
    var new: URL { home.appending(path: "Applications/Baton", directoryHint: .isDirectory) }
    var systemApps: URL { root.appending(path: "Applications", directoryHint: .isDirectory) }
    var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
    }

    func cleanUp() { try? fm.removeItem(at: root) }

    /// Runs `/bin/sh` with `arguments` in the repository, with `HOME` pointing nowhere and, unless `testOptions` is
    /// false, `BATON_INSTALL_TEST=1` so the script accepts its test-only options.
    func sh(_ arguments: [String], testOptions: Bool = true) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.currentDirectoryURL = Self.repo
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.appending(path: "not-home").path
        environment["BATON_INSTALL_TEST"] = testOptions ? "1" : nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func install(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try sh(["scripts/install-app.sh"] + arguments + ["--home", home.path])
    }

    /// Runs `script` with the install functions loaded; `$1`… are `arguments`.
    func lib(_ script: String, _ arguments: [String] = []) throws -> String {
        try sh(["-c", ". scripts/install-lib.sh; " + script, "lib"] + arguments).output
    }

    func makeApp(_ url: URL, bundleID: String) throws {
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    }

    /// Every path under the sandbox, to prove a dry run changed nothing.
    func tree() -> [String] {
        ((fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).sorted()
    }

    @Test func theScriptsParse() throws {
        #expect(try sh(["-n", "scripts/install-app.sh"]).status == 0)
        #expect(try sh(["-n", "scripts/install-lib.sh"]).status == 0)
    }

    @Test func whereFollowsTheFolders() throws {
        defer { cleanUp() }
        #expect(try install(["--where"]).output == new.path + "\n", "a fresh home")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(try install(["--where"]).output == legacy.path + "\n", "until the folder is renamed")
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(try install(["--where"]).output == new.path + "\n", "both: Baton's")
        #expect(try install(["--where", "/Somewhere/Else"]).output == "/Somewhere/Else\n", "an explicit DEST")
        #expect(try install(["--where", "--bogus"]).status == 2)
    }

    @Test func aDryRunPlansTheUpgradeAndChangesNothing() throws {
        defer { cleanUp() }
        try makeApp(legacy.appending(path: "Claude Profiles.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        try makeApp(systemApps.appending(path: "Claude Profiles.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        try makeApp(legacy.appending(path: "Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        try makeApp(root.appending(path: "build/Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: bin.appending(path: "baton").path, withDestinationPath: legacy.appending(path: "Baton.app/Contents/Helpers/baton").path)
        let before = tree()

        let result = try install([
            "--dry-run", "--system-apps", systemApps.path, "--bin-dirs", bin.path, "--app", root.appending(path: "build/Baton.app").path,
        ])
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.contains("Dry run: nothing is changed."))
        let stops = lines.contains("A real run would stop here until Baton is quit; the rest is what it would do then.")
        #expect(result.status == (stops ? 1 : 0), "exit 1 only while Baton runs on this Mac")
        #expect(lines.contains { $0.hasPrefix("Would stage ") && $0.contains("\(home.path)/Applications/.baton-install.XXXXXX") })
        #expect(
            lines.contains(
                "Would save \(legacy.path)/Claude Profiles.app as a ZIP in \(home.path)/Library/Application Support/Baton/AppBackups, then move it to the Trash."
            ))
        #expect(
            lines.contains(
                "Would save \(systemApps.path)/Claude Profiles.app as a ZIP in \(home.path)/Library/Application Support/Baton/AppBackups, then move it to the Trash."
            ))
        #expect(lines.contains("Would save the current \(legacy.path)/Baton.app as a ZIP in \(home.path)/Library/Application Support/Baton/AppBackups."))
        #expect(lines.contains("Would install to \(legacy.path)/Baton.app."))
        #expect(lines.contains { $0.hasPrefix("Would then run the installed baton migrate to rename \(legacy.path) to \(new.path).") })
        #expect(lines.contains("Once that folder is renamed, point these command links at Baton:"))
        #expect(lines.contains("  ln -sf \"\(new.path)/Baton.app/Contents/Helpers/baton\" \"\(bin.path)/baton\""))
        #expect(!result.output.contains("can stay open"))
        #expect(tree() == before, "a dry run changes nothing")
        #expect(!fm.fileExists(atPath: root.appending(path: "not-home").path))
    }

    @Test func aDryRunIntoBatonNeedsNoRename() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try makeApp(root.appending(path: "build/Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        let result = try install(["--dry-run", "--system-apps", systemApps.path, "--bin-dirs", bin.path, "--app", root.appending(path: "build/Baton.app").path])
        #expect(result.output.contains("Would install to \(new.path)/Baton.app."))
        #expect(!result.output.contains("migrate"))
        #expect(!result.output.contains("command links"))
    }

    @Test func findsCommandLinksIntoTheOldAppOrFolder() throws {
        defer { cleanUp() }
        let other = root.appending(path: "other-bin", directoryHint: .isDirectory)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        // Absolute into the old folder, relative into the old app, and ones that are fine.
        try fm.createSymbolicLink(
            atPath: bin.appending(path: "baton").path, withDestinationPath: legacy.appending(path: "Baton.app/Contents/Helpers/baton").path)
        try fm.createSymbolicLink(
            atPath: bin.appending(path: "claude-profiles").path, withDestinationPath: "../Applications/Claude Profiles.app/Contents/Helpers/claude-profiles")
        try fm.createSymbolicLink(
            atPath: other.appending(path: "baton").path, withDestinationPath: new.appending(path: "Baton.app/Contents/Helpers/baton").path)
        try Data("#!/bin/sh\n".utf8).write(to: other.appending(path: "claude-profiles"))

        let found = try lib(#"stale_links "$1" "$2""#, ["\(bin.path):\(other.path):\(root.path)/missing", legacy.path])
        #expect(found == "\(bin.path)/claude-profiles\n\(bin.path)/baton\n" || found == "\(bin.path)/baton\n\(bin.path)/claude-profiles\n")
        #expect(found.split(separator: "\n").count == 2)

        let fixes = try lib(#"print_link_fixes "$1" "$2" "$3""#, [bin.path, legacy.path, new.appending(path: "Baton.app").path])
        #expect(fixes.hasPrefix("These command links point at the old app or folder. Point them at Baton:\n"))
        #expect(fixes.contains("  ln -sf \"\(new.path)/Baton.app/Contents/Helpers/baton\" \"\(bin.path)/baton\"\n"))
        #expect(fixes.contains("  ln -sf \"\(new.path)/Baton.app/Contents/Helpers/baton\" \"\(bin.path)/claude-profiles\"\n"))
        #expect(try lib(#"print_link_fixes "$1" "$2" "$3""#, [other.path, legacy.path, "/x"]).isEmpty, "nothing to fix, nothing printed")
    }

    @Test func saysWhatHappensAfterTheRename() throws {
        defer { cleanUp() }
        let (dest, renamed) = (legacy.path, new.path)
        // Renamed: the old folder is gone and Baton.app is in the new one.
        try makeApp(new.appending(path: "Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        #expect(try lib(#"follow_up 0 "$1" "$2""#, [dest, renamed]) == "Baton.app is now in \(renamed)/Baton.app: its folder has the Baton name.\n")
        #expect(try lib(#"final_app 0 "$1" "$1" "$2""#, [dest, renamed]) == "\(renamed)/Baton.app\n")
        #expect(
            try lib(#"follow_up 3 "$1" "$2""#, [dest, renamed])
                == "Baton.app is installed in \(dest)/Baton.app and works from there; the line above says why the folder keeps its old name.\n"
        )
        #expect(
            try lib(#"follow_up 1 "$1" "$2""#, [dest, renamed]).hasPrefix(
                "baton migrate failed (exit 1). Baton.app is installed in \(dest)/Baton.app and works from there."))
        #expect(try lib(#"final_app 3 "$1" "$1" "$2""#, [dest, renamed]) == "\(dest)/Baton.app\n")
        #expect(try lib(#"final_app 0 "$2" "$1" "$2""#, [dest, renamed]) == "\(renamed)/Baton.app\n")
        // baton migrate exits 0 when both folders exist too: Baton.app then stays where it was installed.
        try makeApp(legacy.appending(path: "Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        #expect(try lib(#"final_app 0 "$1" "$1" "$2""#, [dest, renamed]) == "\(dest)/Baton.app\n")
        #expect(
            try lib(#"follow_up 0 "$1" "$2""#, [dest, renamed])
                == "Baton.app is installed in \(dest)/Baton.app, but \(renamed) exists too, so Baton uses that folder; the line above says what to do.\n"
        )
    }

    @Test func backupNamesNeverRepeat() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(try lib(#"unique_path "$1" "A (x) 1" zip"#, [root.path]) == "\(root.path)/A (x) 1.zip\n")
        try Data().write(to: root.appending(path: "A (x) 1.zip"))
        try Data().write(to: root.appending(path: "A (x) 1 2.zip"))
        #expect(try lib(#"unique_path "$1" "A (x) 1" zip"#, [root.path]) == "\(root.path)/A (x) 1 3.zip\n")
        let script = try String(contentsOf: Self.repo.appending(path: "scripts/install-app.sh"), encoding: .utf8)
        #expect(script.contains(#"unique_path "$backups" "$2 ($(basename "$(dirname "$1")")) "#), "named after the app's folder too")
    }

    @Test func testOptionsNeedADryRun() throws {
        defer { cleanUp() }
        let real = try sh(["scripts/install-app.sh", "--home", home.path], testOptions: false)
        #expect(real.status == 2)
        #expect(real.output.contains("--home is for tests: use it with --dry-run (or BATON_INSTALL_TEST=1)."))
        let whereOnly = try sh(["scripts/install-app.sh", "--where", "--app", "/x"], testOptions: false)
        #expect(whereOnly.status == 2, "--where alone isn't a dry run")
    }

    @Test func aLinkThatLeadsNowhereStopsTheInstall() throws {
        defer { cleanUp() }
        try makeApp(root.appending(path: "build/Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: support.appending(path: "Claude Profiles").path, withDestinationPath: "/Volumes/Missing-\(UUID())")
        let before = tree()
        let result = try install(["--dry-run", "--system-apps", systemApps.path, "--bin-dirs", bin.path, "--app", root.appending(path: "build/Baton.app").path])
        #expect(result.status == 1)
        #expect(result.output.contains("Claude Profiles links to /Volumes/Missing-"))
        #expect(result.output.contains("which isn't there right now. Connect it and try again; nothing was installed."))
        #expect(tree() == before, "no Baton folder is started in its place")
    }

    @Test func refusesTheOldFolderWhileBatonsExists() throws {
        defer { cleanUp() }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try makeApp(root.appending(path: "build/Baton.app"), bundleID: "io.github.trukhinyuri.claudeprofiles")
        let result = try install([legacy.path, "--dry-run", "--app", root.appending(path: "build/Baton.app").path])
        #expect(result.status == 2)
        #expect(result.output.contains("Both \(new.path) and \(legacy.path) exist, and Baton uses \(new.path)"))
    }

    /// The README's command block says the same words as `baton --help`.
    @Test func readmeCommandsMatchTheHelp() throws {
        let main = try String(contentsOf: Self.repo.appending(path: "Sources/baton/main.swift"), encoding: .utf8)
        let readme = try String(contentsOf: Self.repo.appending(path: "README.md"), encoding: .utf8)
        let help = try #require(main.components(separatedBy: "    USAGE\n").last?.components(separatedBy: "    \"\"\"").first)
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map {
            $0.hasPrefix("      ") ? String($0.dropFirst(6)) : $0.trimmingCharacters(in: .whitespaces)
        }
        let block = try #require(readme.components(separatedBy: "## Command line\n\n```text\n").last?.components(separatedBy: "```").first)
        #expect(block == lines.joined(separator: "\n") + "\n")
    }

    @Test func uninstallMovesTheAppToTheTrash() throws {
        let makefile = try String(contentsOf: Self.repo.appending(path: "Makefile"), encoding: .utf8)
        let recipe = makefile.components(separatedBy: "\nuninstall:\n").last?.components(separatedBy: "\n\n").first ?? ""
        #expect(recipe.contains("to_trash"))
        #expect(!recipe.contains("rm "), "never deleted")
    }
}
