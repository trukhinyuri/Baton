import Foundation
import Testing

@testable import BatonKit

@Suite("Build version and commit")
struct BuildInfoTests {
    @Test func readsVersionFromEnclosingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buildinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Baton.app/Contents")
        try FileManager.default.createDirectory(at: app.appending(path: "Helpers"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "BatonCommit": "abc123def456"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        let helper = BuildInfo.read(executable: app.appending(path: "Helpers/baton"))
        let main = BuildInfo.read(executable: app.appending(path: "MacOS/Baton"))
        #expect(helper == BuildInfo(version: "1.0.0", commit: "abc123def456"))
        #expect(main == helper)
        #expect(helper.description == "Baton 1.0.0 (abc123def456)")
        #expect(AppInstances.version(of: root.appending(path: "Baton.app")) == "1.0.0", "a build without BatonVersion")
    }

    @Test func readsTheCommitABuildFromBeforeTheRenameRecorded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buildinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Claude Profiles.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "ClaudeProfilesCommit": "0123456789ab"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        #expect(BuildInfo.read(executable: app.appending(path: "MacOS/ClaudeProfiles")) == BuildInfo(version: "0.2.0", commit: "0123456789ab"))
    }

    /// Scripts written for Claude Profiles call Contents/Helpers/claude-profiles, which 1.x keeps as a link to baton.
    @Test func theOldHelperNameReportsTheSameBuild() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buildinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Baton.app/Contents")
        try FileManager.default.createDirectory(at: app.appending(path: "Helpers"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "BatonCommit": "abc123def456"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        try Data().write(to: app.appending(path: "Helpers/baton"))
        try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Helpers/claude-profiles").path, withDestinationPath: "baton")
        #expect(BuildInfo.read(executable: app.appending(path: "Helpers/claude-profiles")) == BuildInfo(version: "1.0.0", commit: "abc123def456"))
    }

    /// A release candidate keeps the numbers in Apple's keys and its full version in BatonVersion.
    @Test func aReleaseCandidateReportsItsFullVersion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buildinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Baton.app/Contents")
        try FileManager.default.createDirectory(at: app.appending(path: "Helpers"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1.0.0", "BatonVersion": "1.0.0-rc.1", "BatonCommit": "abc123def456",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        let build = BuildInfo.read(executable: app.appending(path: "Helpers/baton"))
        #expect(build == BuildInfo(version: "1.0.0-rc.1", commit: "abc123def456"))
        #expect(build.description == "Baton 1.0.0-rc.1 (abc123def456)")
        // Copies of the app are compared by the same full version.
        #expect(AppInstances.version(of: root.appending(path: "Baton.app")) == "1.0.0-rc.1")
    }

    /// A release candidate sits between the release before it and its own release, so each replaces the one before.
    @Test func aReleaseCandidateIsBelowItsRelease() {
        #expect(AppInstances.isVersion("0.2.0", below: "1.0.0-rc.1"))
        #expect(AppInstances.isVersion("1.0.0-rc.1", below: "1.0.0-rc.2"))
        #expect(AppInstances.isVersion("1.0.0-rc.2", below: "1.0.0-rc.10"), "numeric parts compare as numbers")
        #expect(AppInstances.isVersion("1.0.0-rc.1", below: "1.0.0"))
        #expect(AppInstances.isVersion("1.0.0-rc.9", below: "1.0.1-rc.1"))
        #expect(AppInstances.isVersion("1.0.0-rc", below: "1.0.0-rc.1"), "fewer parts are lower when the rest is equal")
        #expect(!AppInstances.isVersion("1.0.0", below: "1.0.0-rc.1"))
        #expect(!AppInstances.isVersion("1.0.0-rc.1", below: "1.0.0-rc.1"))
        #expect(!AppInstances.isVersion("1.0.0-rc.2", below: "1.0.0-rc.1"))
        #expect(!AppInstances.isVersion("1.0.0-", below: "1.0.0"), "an empty suffix isn't a version")
        #expect(!AppInstances.isVersion("dev", below: "1.0.0-rc.1"))
    }

    /// The signed 1.0.0 asks a running 1.0.0-rc.1 to quit instead of handing over to it, and rc.1 hands over to 1.0.0.
    @Test func theReleaseReplacesARunningReleaseCandidate() {
        let candidate = AppInstances.RunningCopy(pid: 20, bundle: URL(fileURLWithPath: "/Applications/Baton.app"), version: "1.0.0-rc.1")
        let release = AppInstances.RunningCopy(pid: 21, bundle: URL(fileURLWithPath: "/Applications/Baton.app"), version: "1.0.0")
        #expect(AppInstances.handover(others: [candidate], currentVersion: "1.0.0") == .init(terminate: [20], handOverTo: nil))
        #expect(AppInstances.handover(others: [candidate], currentVersion: "1.0.0-rc.2") == .init(terminate: [20], handOverTo: nil))
        #expect(AppInstances.handover(others: [release], currentVersion: "1.0.0-rc.1") == .init(terminate: [], handOverTo: 21))
    }

    @Test func outsideAnAppReportsDev() {
        let info = BuildInfo.read(executable: URL(fileURLWithPath: "/usr/local/bin/baton"))
        #expect(info == BuildInfo(version: "dev", commit: "dev"))
    }
}
