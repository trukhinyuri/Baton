import Foundation
import Testing

@testable import BatonKit

@Suite("Closed windows and managed policy")
struct ClosedWindowTests {
    /// The main Claude usually starts from the Dock or Spotlight, never through Baton; it gets Local only while closed.
    @Test func aClosedWindowGetsLocalOnlyWithTheNextSync() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(LocalOnlyTests.config, to: box.desktopConfig(box.main))
        let windows = FakeWindows()
        let manager = ProfileManager(paths: box.paths)
        manager.runningCopies = { windows.running }
        #expect(manager.localOnly.status(window: "main") == .pending)

        _ = try manager.syncSessions()

        #expect(manager.localOnly.status(window: "main") == .on)
    }

    @Test func anOpenWindowIsLeftForLater() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(LocalOnlyTests.config, to: box.desktopConfig(box.main))
        let windows = FakeWindows()
        windows.start(box.paths.claudeApp, arguments: [])
        let manager = ProfileManager(paths: box.paths)
        manager.runningCopies = { windows.running }

        _ = try manager.syncSessions()

        #expect(manager.localOnly.status(window: "main") == .pending)
        #expect(box.read(box.desktopConfig(box.main)) == LocalOnlyTests.config)
    }

    @Test func namesTheManagedPoliciesThatConcernBaton() throws {
        let box = try Sandbox()
        let folder = box.root.appending(path: "Library/Managed Preferences", directoryHint: .isDirectory)
        #expect(ProfileManager(paths: box.paths).managedPreferences.path == folder.path, "tests never read this Mac's policy")
        #expect(ManagedPolicy.warnings(in: folder, user: "alex").isEmpty)

        func write(_ values: [String: Any], to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file)
        }
        try write(["disableMultiAccount": true], to: folder.appending(path: "alex/com.anthropic.claudefordesktop.plist"))
        #expect(ManagedPolicy.warnings(in: folder, user: "alex").map { $0.contains("Single account only") } == [true])
        #expect(ManagedPolicy.warnings(in: folder, user: "sam").isEmpty, "another user's policy is theirs")

        try write(["disableDeepLinkRegistration": true, "disableMultiAccount": false], to: folder.appending(path: "com.anthropic.claudefordesktop.plist"))
        #expect(ManagedPolicy.warnings(in: folder, user: "alex").count == 2)
    }
}
