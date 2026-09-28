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

        #expect(Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [engine] }).path == user.path)

        let elsewhere = try box.claudeBundle(at: box.root.appending(path: "Other/Claude.app"))
        #expect(
            Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [engine, elsewhere] }).path == elsewhere.path,
            "Launch Services' choice comes first")

        let installed = try box.claudeBundle(at: system.appending(path: "Claude.app"))
        #expect(
            Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [] }).path == installed.path,
            "/Applications before ~/Applications")

        let impostor = try box.claudeBundle(at: box.root.appending(path: "Impostor/Claude.app"), identifier: "com.example.other")
        #expect(Paths.findClaude(home: box.root, systemApplications: system, lookup: { _ in [impostor] }).path == installed.path)

        let nowhere = box.root.appending(path: "Empty", directoryHint: .isDirectory)
        #expect(
            Paths.findClaude(home: nowhere, systemApplications: nowhere, lookup: { _ in [] }).path == nowhere.appending(path: "Claude.app").path,
            "with no Claude anywhere, the usual place, so the error names it")
    }

    @Test func restoresMainAfterStaleSignIn() throws {
        let box = try Sandbox()
        let recorder = Recorder()
        let routing = SignInRouting(
            paths: box.paths,
            registerReporting: { app, on in
                recorder.calls.append((app.lastPathComponent, on)); return 0
            })

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
            })

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
        #expect(ClaudeVersion.tested.lowerBound == "2.9939.2")
        let newer = try #require(ClaudeVersion.warning(for: "2.9940.0"))
        #expect(newer.contains("2.9940.0") && newer.contains("newer") && newer.contains("2.9939.2"))
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
