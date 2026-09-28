import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("One copy of Claude Profiles")
struct AppInstancesTests {
    private func makeApp(_ url: URL, bundleID: String) throws {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    }

    @Test func singleInstanceDetectsSecondCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instances-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appending(path: "Applications"), user = root.appending(path: "home/Applications")
        try makeApp(system.appending(path: "Claude Profiles.app"), bundleID: AppInstances.bundleID)
        try makeApp(user.appending(path: "Claude Profiles.app"), bundleID: AppInstances.bundleID)
        try makeApp(system.appending(path: "Other.app"), bundleID: "com.example.other")
        try FileManager.default.createDirectory(at: system.appending(path: "Not an app"), withIntermediateDirectories: true)

        let copies = AppInstances.installedCopies(in: [system, user, root.appending(path: "missing")])
        #expect(copies.map(\.lastPathComponent) == ["Claude Profiles.app", "Claude Profiles.app"])
        let warning = try #require(AppInstances.duplicateWarning(copies))
        #expect(warning.contains(system.appending(path: "Claude Profiles.app").path))
        #expect(warning.contains(user.appending(path: "Claude Profiles.app").path))
        #expect(AppInstances.duplicateWarning(Array(copies.prefix(1))) == nil)

        // A second copy that starts while one is running hands over to the first and quits.
        #expect(AppInstances.otherInstance(running: [101, 202], me: 202) == 101)
        #expect(AppInstances.otherInstance(running: [202], me: 202) == nil)
    }
}
