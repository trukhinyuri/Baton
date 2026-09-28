import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Build version and commit")
struct BuildInfoTests {
    @Test func readsVersionFromEnclosingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buildinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Claude Profiles.app/Contents")
        try FileManager.default.createDirectory(at: app.appending(path: "Helpers"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "ClaudeProfilesCommit": "abc123def456"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        let helper = BuildInfo.read(executable: app.appending(path: "Helpers/claude-profiles"))
        let main = BuildInfo.read(executable: app.appending(path: "MacOS/ClaudeProfiles"))
        #expect(helper == BuildInfo(version: "1.0.0", commit: "abc123def456"))
        #expect(main == helper)
        #expect(helper.description == "Claude Profiles 1.0.0 (abc123def456)")
    }

    @Test func outsideAnAppReportsDev() {
        let info = BuildInfo.read(executable: URL(fileURLWithPath: "/usr/local/bin/claude-profiles"))
        #expect(info == BuildInfo(version: "dev", commit: "dev"))
    }
}
