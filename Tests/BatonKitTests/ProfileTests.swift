import AppKit
import Foundation
import Testing

@testable import BatonKit

@Suite("Profiles")
struct ProfileTests {
    @Test(arguments: [
        ("jane.doe@acme.com", "JANE"),
        ("x@y.io", "X"),
        ("verylongname@corp.com", "VERYLONG"),
    ])
    func suggestsLabelFromEmail(email: String, label: String) {
        #expect(Profile.suggestedLabel(for: email, taken: []) == label)
    }

    @Test func suggestedLabelAvoidsTakenOnes() {
        #expect(Profile.suggestedLabel(for: "jane@a.com", taken: ["JANE"]) == "JANE2")
        #expect(Profile.suggestedLabel(for: "jane@a.com", taken: ["jane", "JANE2"]) == "JANE3")
    }

    @Test func slugIsFilesystemSafe() {
        #expect(Profile.slug(for: "WORK") == "work")
        #expect(Profile.slug(for: "a b/c") == "a-b-c")
        #expect(Profile.slug(for: "ЛАБ") == "profile")
    }

    @Test func validatesInput() {
        #expect(Profile.isValidLabel("TEAM-2"))
        #expect(!Profile.isValidLabel(""))
        #expect(!Profile.isValidLabel("WAY-TOO-LONG"))
        #expect(!Profile.isValidLabel("a b"))
        #expect(Profile.isValidEmail("a@b.co"))
        #expect(!Profile.isValidEmail("a@b"))
        #expect(!Profile.isValidEmail("a b@c.com"))
    }

    @Test func registryRoundTrips() throws {
        let box = try Sandbox()
        let registry = ProfileRegistry(paths: box.paths)
        #expect(try registry.load().isEmpty)
        let profile = Profile(
            id: "work", label: "WORK", email: "a@b.co", color: "#1971C2",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.save([profile])
        #expect(try registry.load() == [profile])
    }

    @Test func olderRegistryReadsWithPermissionModeOff() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        try box.write(##"[{"id":"work","label":"WORK","color":"#1971C2","createdAt":"2026-09-01T10:00:00Z"}]"##, to: box.paths.registryFile)
        let registry = ProfileRegistry(paths: box.paths)

        let loaded = try #require(try registry.load().first)
        #expect(loaded.carryPermissionMode == nil && !loaded.carriesPermissionMode)

        var owner = loaded
        owner.carryPermissionMode = true
        try registry.save([owner])
        #expect(try registry.load().first?.carriesPermissionMode == true)
        #expect(box.read(box.paths.registryFile)?.contains(#""carryPermissionMode""#) == true)
    }

    /// MAIN and CLAUDE name the main window in the app, the CLI and reports, so no subscription may take them.
    @Test func mainAndClaudeNameOnlyTheMainWindow() throws {
        #expect(!Profile.isValidLabel("MAIN"))
        #expect(!Profile.isValidLabel("claude"))
        #expect(Profile.suggestedLabel(for: "main@company.com", taken: []) == "MAIN2")
        let box = try Sandbox()
        try box.claudeBundle(at: box.paths.claudeApp, identifier: "test.baton.not-claude")
        let manager = ProfileManager(paths: box.paths)
        manager.appBuilder = { _ in }

        #expect(throws: ProfileError.reservedLabel("MAIN")) { try manager.create(label: "main", email: nil) }
        #expect(throws: ProfileError.reservedLabel("CLAUDE")) { try manager.create(label: "Claude", email: nil) }
        #expect(try manager.create(label: "MAIN_", email: nil).id == "main-2", "a label that would get the id main gets another")
    }

    /// An Add that fails halfway (a full disk, a copy that doesn't verify) leaves nothing, and trying again keeps the id.
    @Test func failedAddLeavesNothingBehind() throws {
        let box = try Sandbox()
        try box.claudeBundle(at: box.paths.claudeApp, identifier: "test.baton.not-claude")
        let manager = ProfileManager(paths: box.paths)
        let fails = Flag()
        fails.set(true)
        manager.appBuilder = { profile in
            try FileManager.default.createDirectory(
                at: box.paths.launcher(for: profile).appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            if fails.value { throw CocoaError(.fileWriteOutOfSpace) }
        }

        #expect(throws: CocoaError.self) { try manager.create(label: "LAB", email: nil) }
        #expect(!box.exists(box.paths.dataDir(for: "lab")))
        #expect(!box.exists(box.paths.launcher(for: Profile(id: "lab", label: "LAB", email: nil, color: "#000000"))))
        #expect(try manager.registry.load().isEmpty)

        fails.set(false)
        #expect(try manager.create(label: "LAB", email: nil).id == "lab", "not lab-2")
    }

    @Test func unexpectedAccountIsCaseInsensitive() {
        let profile = Profile(id: "w", label: "W", email: "Jane@Acme.com", color: "#000000")
        var status = ProfileStatus(profile: profile, accountID: "id", email: "jane@acme.com", usage: nil, isRunning: false)
        #expect(!status.isUnexpectedAccount)
        status.email = "other@acme.com"
        #expect(status.isUnexpectedAccount)
    }
}

@Suite("Reading Claude Desktop data")
struct DesktopDataTests {
    @Test func readsOnlyTheAccountIDFromConfig() throws {
        let box = try Sandbox()
        try box.write(
            #"{"lastKnownAccountUuid":"\#(Sandbox.accountA)","oauth:tokenCache":"secret"}"#,
            to: box.main.appending(path: "config.json"))
        #expect(DesktopData.accountID(in: box.main) == Sandbox.accountA)
        #expect(DesktopData.accountID(in: box.work) == nil)
    }

    @Test func readsLatestUsageSample() throws {
        let box = try Sandbox()
        try box.write(
            #"{"version":1,"samples":[{"t":1790338178961,"u":{"fh":20,"sd":79}},{"t":1790337278917,"u":{"fh":15,"sd":77}}]}"#,
            to: box.main.appending(path: "plan-usage-history.json"))
        let usage = try #require(DesktopData.usage(in: box.main))
        #expect(usage.fiveHour == 20)
        #expect(usage.week == 79)
        #expect(usage.isFiveHourStale(now: usage.sampledAt.addingTimeInterval(6 * 3600)))
        #expect(!usage.isFiveHourStale(now: usage.sampledAt.addingTimeInterval(3600)))
    }

    @Test func findsTheEmailBelongingToTheAccount() {
        let account = Sandbox.accountA
        var blob = Data()
        blob.append(Data("uuid\"$\(Sandbox.accountB)\"\remail_address\"\u{10}teammate@acme.com".utf8))
        blob.append(Data([0x00, 0x01, 0x02]))
        blob.append(Data("uuid\"$\(account)\"\remail_address\"\u{0e}jane@acme.com\"".utf8))
        #expect(DesktopData.email(inBlob: blob, accountID: account) == "jane@acme.com")
        #expect(DesktopData.email(inBlob: blob, accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc") == nil)
    }

    @Test func findsTheEmailInIndexedDBFiles() throws {
        let box = try Sandbox()
        let dir = box.main.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try box.write("junk uuid\"$\(Sandbox.accountA)\"\remail_address\"\u{0e}jane@acme.com junk", to: dir.appending(path: "000003.log"))
        #expect(DesktopData.email(in: box.main, accountID: Sandbox.accountA) == "jane@acme.com")
    }
}

@Suite("Icons and launchers")
struct LauncherTests {
    @Test func icnsHasAValidHeader() {
        let image = IconRenderer.profileIcon(base: NSImage(size: NSSize(width: 16, height: 16)), label: "WORK", color: NSColor(hex: "#1971C2"))
        let data = IconRenderer.icnsData(for: image)
        #expect(data.prefix(4) == Data("icns".utf8))
        let length = data[4..<8].reduce(0) { $0 << 8 | Int($1) }
        #expect(length == data.count)
    }

    @Test func launcherScriptQuotesPaths() throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths, cliPath: URL(fileURLWithPath: "/Apps/It's Here/baton"))
        let script = manager.launcherScript(for: Profile(id: "work", label: "WORK", email: nil, color: "#000000"))
        #expect(script.contains(#"'/Apps/It'\''s Here/baton' open 'work'"#))
        #expect(script.contains("--user-data-dir="))
    }

    /// Started from the Dock, nothing shows what `baton` says; a launcher whose `baton open` fails says why in an alert.
    @Test func aLauncherWhoseBatonFailsSaysWhy() throws {
        let box = try Sandbox()
        let bin = box.root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func tool(_ text: String, at url: URL) throws {
            try box.write("#!/bin/sh\n" + text, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let said = box.root.appending(path: "alert.txt")
        let alert = bin.appending(path: "alert")
        try tool("for a in \"$@\"; do printf '%s\\n' \"$a\"; done > '\(said.path)'\n", at: alert)
        let cli = bin.appending(path: "baton")
        let manager = ProfileManager(paths: box.paths, cliPath: cli)
        // The alert is recorded instead of shown, and no app is ever opened.
        let script = manager.launcherScript(for: Profile(id: "work", label: "WORK", email: nil, color: "#000000"))
            .replacingOccurrences(of: "/usr/bin/osascript", with: alert.path)
            .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/false")
        func run() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        try tool("echo 'error: Claude WORK is open without its profile' >&2\nexit 1\n", at: cli)
        #expect(try run() == 1)
        let lines = box.read(said)?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.suffix(2) == ["Claude WORK didn't open", "error: Claude WORK is open without its profile"])

        try FileManager.default.removeItem(at: said)
        try tool("echo 'warning: a note' >&2\nexit 0\n", at: cli)
        #expect(try run() == 0)
        #expect(!box.exists(said), "no alert when it opened")
    }

    @Test func launchersNeverPointIntoDownloadsOrATranslocatedCopy() {
        let home = URL(fileURLWithPath: "/Users/alex")
        #expect(AppLocation.problem(app: URL(fileURLWithPath: "/Applications/Baton.app"), home: home) == nil)
        #expect(AppLocation.problem(app: URL(fileURLWithPath: "/Users/alex/Applications/Baton.app"), home: home) == nil)
        #expect(AppLocation.problem(app: URL(fileURLWithPath: "/Users/alex/Downloads/Baton.app"), home: home)?.contains("Downloads") == true)
        let translocated = URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/0A1B/d/Baton.app")
        #expect(AppLocation.problem(app: translocated, home: home)?.contains("temporary copy") == true)
    }

    @Test func hexColorsParse() {
        let color = NSColor(hex: "#FF8000").usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent - 1) < 0.01)
        #expect(abs(color.greenComponent - 0.5) < 0.01)
        #expect(color.blueComponent < 0.01)
    }
}

@Suite("Sign-in routing")
struct SignInRoutingTests {
    final class Recorder: @unchecked Sendable {
        var calls: [(String, Bool)] = []
    }

    @Test func routesLinksToTheProfileAndBack() throws {
        let box = try Sandbox()
        let recorder = Recorder()
        let routing = SignInRouting(paths: box.paths) { app, on in recorder.calls.append((app.lastPathComponent, on)) }
        try routing.begin(profileID: "work", allProfileIDs: ["work", "lab"])
        #expect(recorder.calls.map(\.0) == ["Claude.app", "Claude lab.app", "Claude work.app"])
        #expect(recorder.calls.map(\.1) == [false, false, true])
        #expect(routing.state?.profileID == "work")

        recorder.calls = []
        routing.end(allProfileIDs: ["work", "lab"])
        #expect(recorder.calls.last! == ("Claude.app", true))
        #expect(recorder.calls.dropLast().allSatisfy { !$0.1 })
        #expect(routing.state == nil)
    }

    @Test func finishesWhenSignedInAbandonedOrNeverStarted() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let state = SignInRouting.State(profileID: "work", startedAt: start)
        let soon = start.addingTimeInterval(10)
        #expect(!SignInRouting.isFinished(state, signedIn: false, running: false, profileExists: true, now: soon))
        #expect(!SignInRouting.isFinished(state, signedIn: false, running: true, profileExists: true, now: start.addingTimeInterval(600)))
        #expect(SignInRouting.isFinished(state, signedIn: true, running: true, profileExists: true, now: soon))
        #expect(SignInRouting.isFinished(state, signedIn: false, running: false, profileExists: false, now: soon))
        #expect(SignInRouting.isFinished(state, signedIn: false, running: false, profileExists: true, now: start.addingTimeInterval(120)))
        #expect(SignInRouting.isFinished(state, signedIn: false, running: true, profileExists: true, now: start.addingTimeInterval(16 * 60)))
    }
}
