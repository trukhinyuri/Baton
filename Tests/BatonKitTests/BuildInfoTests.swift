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

    @Test func outsideAnAppReportsDev() {
        let info = BuildInfo.read(executable: URL(fileURLWithPath: "/usr/local/bin/baton"))
        #expect(info == BuildInfo(version: "dev", commit: "dev"))
    }
}
