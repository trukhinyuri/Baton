import Foundation
import Testing

@testable import BatonKit

extension Sandbox {
    /// A minimal Claude.app bundle at `url`, with `version` as its marketing version.
    @discardableResult
    func claudeBundle(at url: URL, version: String = "2.9939.2", identifier: String = ClaudeVersion.bundleIdentifier) throws -> URL {
        try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version,
            "CFBundleExecutable": "Claude", "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }
}

@Suite("Working on other Macs")
struct OtherMacsTests {
    final class Recorder: @unchecked Sendable {
        var calls: [(String, Bool)] = []
        var failing: Set<String> = []
    }

    @Test func resolvesClaudeInUserApplications() throws {
        let box = try Sandbox()
        let system = box.root.appending(path: "System Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let user = try box.claudeBundle(at: box.root.appending(path: "Applications/Claude.app"))
        // While a profile signs in, Launch Services knows only that profile's engine; an engine is never the main app.
        let engine = try box.claudeBundle(at: box.paths.engine(for: "work"))

        let signed = { (_: URL) in true }
        #expect(Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [engine] }, isSignedByAnthropic: signed).path == user.path)

        let elsewhere = try box.claudeBundle(at: box.root.appending(path: "Other/Claude.app"))
        #expect(
            Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [elsewhere, engine] }, isSignedByAnthropic: signed).path
                == user.path,
            "an installed Claude before whatever Launch Services prefers, such as a newer one on a disk image")

        let installed = try box.claudeBundle(at: system.appending(path: "Claude.app"))
        #expect(
            Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [] }, isSignedByAnthropic: signed).path == installed.path,
            "/Applications before ~/Applications")

        let impostor = try box.claudeBundle(at: box.root.appending(path: "Impostor/Claude.app"), identifier: "com.example.other")
        #expect(
            Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [impostor] }, isSignedByAnthropic: signed).path == installed.path)

        let nowhere = box.root.appending(path: "Empty", directoryHint: .isDirectory)
        #expect(
            Paths.findClaude(home: nowhere, systemApplications: nowhere, lookup: { _ in [] }, isSignedByAnthropic: signed).path
                == nowhere.appending(path: "Claude.app").path,
            "with no Claude anywhere, the usual place, so the error names it")
    }

    /// Only Claude as Anthropic signs it is taken for Claude Desktop: a lookalike with its bundle id is passed over,
    /// even in Applications, and so is a copy macOS runs from a temporary place. Launch Services' copies come last.
    @Test func takesOnlyClaudeSignedByAnthropic() throws {
        let box = try Sandbox()
        let system = box.root.appending(path: "System Applications", directoryHint: .isDirectory)
        let installed = try box.claudeBundle(at: system.appending(path: "Claude.app"))
        let user = try box.claudeBundle(at: box.root.appending(path: "Applications/Claude.app"))
        let downloaded = try box.claudeBundle(at: box.root.appending(path: "Downloads/Claude.app"), version: "99")
        let translocated = try box.claudeBundle(at: box.root.appending(path: "AppTranslocation/1234/d/Claude.app"))
        func find(_ lookup: [URL], signed: [URL]) -> String {
            Paths.findClaude(
                home: box.root, systemApplications: system, lookup: { _ in lookup },
                isSignedByAnthropic: { app in signed.contains { $0.path == app.path } }
            ).path
        }

        #expect(find([downloaded, installed], signed: [user]) == user.path, "a lookalike in /Applications and a newer one in Downloads are passed over")
        #expect(find([downloaded], signed: [downloaded]) == downloaded.path, "Anthropic's own copy elsewhere, when none is installed")
        #expect(find([translocated], signed: [translocated]) == installed.path, "never a translocated copy: the usual place, so the error names it")
        #expect(find([downloaded], signed: []) == installed.path)
    }

    /// The unsigned app `findClaude` names when no Claude Anthropic signed is found is never opened as the main window
    /// nor registered for `claude://` links; start-up says why instead.
    @Test func anUnsignedClaudeIsNeitherOpenedNorRegistered() async throws {
        let box = try Sandbox()
        // Not Claude's bundle id, so nothing on this Mac could take it for Claude even if it were opened.
        try box.claudeBundle(at: box.paths.claudeApp, identifier: "com.example.lookalike")
        let manager = ProfileManager(paths: box.paths)
        let recorder = Recorder()
        manager.signInRouting = SignInRouting(paths: box.paths) { app, on in recorder.calls.append((app.lastPathComponent, on)) }
        let refusal = ProfileError.claudeNotFromAnthropic(box.paths.claudeApp.path)

        await #expect(throws: refusal) { try await manager.openMain() }
        #expect(manager.startUpChecks().contains(refusal.localizedDescription))
        #expect(recorder.calls.isEmpty, "not registered for claude:// links")

        try FileManager.default.removeItem(at: box.paths.claudeApp)
        await #expect(throws: ProfileError.claudeNotInstalled(box.paths.claudeApp.path)) { try await manager.openMain() }
    }

    @Test func restoresMainAfterStaleSignIn() throws {
        let box = try Sandbox()
        let recorder = Recorder()
        let routing = SignInRouting(
            paths: box.paths,
            registerReporting: { app, on in
                recorder.calls.append((app.lastPathComponent, on)); return 0
            }, isSignedByAnthropic: { _ in true })

        // No sign-in on record: the main app is registered again, every start.
        #expect(try routing.restoreMainIfIdle(allProfileIDs: ["work"]))
        #expect(recorder.calls.map(\.0) == ["Claude.app"] && recorder.calls.map(\.1) == [true])

        // A sign-in in progress is left alone.
        try routing.begin(profileID: "work", allProfileIDs: ["work"], now: Date().addingTimeInterval(-60))
        recorder.calls = []
        #expect(try routing.restoreMainIfIdle(allProfileIDs: ["work"]) == false)
        #expect(recorder.calls.isEmpty)
        #expect(routing.state?.profileID == "work")

        // Abandoned for longer than the timeout: links go back to the main app.
        try routing.begin(profileID: "work", allProfileIDs: ["work"], now: Date().addingTimeInterval(-SignInRouting.timeout - 1))
        recorder.calls = []
        #expect(try routing.restoreMainIfIdle(allProfileIDs: ["work"]))
        #expect(recorder.calls.last! == ("Claude.app", true))
        #expect(recorder.calls.dropLast().map(\.0) == ["Claude work.app"] && recorder.calls.dropLast().allSatisfy { !$0.1 })
        #expect(routing.state == nil)
    }

    @Test func reportsLsregisterFailure() throws {
        let box = try Sandbox()
        let recorder = Recorder()
        recorder.failing = ["Claude.app"]
        let routing = SignInRouting(
            paths: box.paths,
            registerReporting: { app, on in
                recorder.calls.append((app.lastPathComponent, on))
                return recorder.failing.contains(app.lastPathComponent) ? 17 : 0
            }, isSignedByAnthropic: { _ in true })

        #expect {
            try routing.restoreMainIfIdle(allProfileIDs: [])
        } throws: { error in
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            return text.contains("17") && text.contains("Claude.app")
        }
        #expect(routing.end(allProfileIDs: ["work"]).count == 1, "end reports the registration that failed")
        recorder.failing = []
        #expect(routing.end(allProfileIDs: ["work"]).isEmpty)
    }

    @Test func warnsOutsideTestedRange() throws {
        #expect(ClaudeVersion.warning(for: "2.9939.2") == nil)
        // Patch builds of a tested minor are tested too: the app was 2.9939.4 while the list said 2.9939.2.
        #expect(ClaudeVersion.warning(for: "2.9939.4") == nil)
        #expect(ClaudeVersion.warning(for: "2.9939.0") == nil)
        #expect(ClaudeVersion.warning(for: "2.9939.12") == nil)
        #expect(ClaudeVersion.Version("2.9939.4").minor == "2.9939")
        #expect(ClaudeVersion.tested.upperBound == "2.9939")
        let newer = try #require(ClaudeVersion.warning(for: "2.9940.0"))
        #expect(newer.contains("2.9940.0") && newer.contains("newer") && newer.contains("2.9939.x"))
        #expect(ClaudeVersion.warning(for: "2.10000.0")?.contains("newer") == true, "compared as numbers, not text")
        #expect(ClaudeVersion.warning(for: "2.998.1")?.contains("older") == true)
        #expect(ClaudeVersion.warning(for: nil) != nil)

        let box = try Sandbox()
        try box.claudeBundle(at: box.paths.claudeApp, version: "2.9941.3")
        #expect(ClaudeVersion.installed(at: box.paths.claudeApp) == "2.9941.3")
        let manager = ProfileManager(paths: box.paths)
        #expect(manager.claudeVersionWarning?.contains("2.9941.3") == true)
    }
}
