import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Cloud move lock")
struct CloudMoveLockTests {
    private func deny(_ url: URL) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (object?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
    }

    @Test func offByDefault() throws {
        let box = try Sandbox()
        #expect(box.paths.cloudMoveLock.status() == .off)
        #expect(!box.paths.cloudMoveLock.addedByThisApp())
        #expect(!FileManager.default.fileExists(atPath: box.paths.claudeSettingsFile.path))
    }

    @Test func turningOnAddsOnlyThisEntry() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.claudeSettingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = """
            {"model": "claude-opus-5-5[1m]", "permissions": {"deny": ["Bash(rm -rf /)"], "allow": ["Read"]}}
            """
        try Data(before.utf8).write(to: box.paths.claudeSettingsFile)

        let lock = box.paths.cloudMoveLock
        #expect(try lock.setEnabled(true) == .on)
        #expect(lock.status() == .on)
        #expect(lock.addedByThisApp())

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: box.paths.claudeSettingsFile)) as? [String: Any]
        #expect(object?["model"] as? String == "claude-opus-5-5[1m]")
        let permissions = object?["permissions"] as? [String: Any]
        #expect((permissions?["allow"] as? [String]) == ["Read"])
        let denyList = try deny(box.paths.claudeSettingsFile)
        #expect(denyList.contains("Bash(rm -rf /)"), "an existing deny rule is kept")
        #expect(denyList.contains(CloudMoveLock.tool))

        // A dated backup of settings.json exists before the edit.
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: box.paths.backupsDir.path)) ?? []
        #expect(!backups.isEmpty)
    }

    @Test func turningOffRemovesOnlyThisEntry() throws {
        let box = try Sandbox()
        let lock = box.paths.cloudMoveLock
        try lock.setEnabled(true)
        #expect(lock.status() == .on)

        #expect(try lock.setEnabled(false) == .off)
        #expect(lock.status() == .off)
        #expect(!lock.addedByThisApp())
        // Turning it off again is harmless.
        #expect(try lock.setEnabled(false) == .off)
    }

    @Test func offWhenNoSettingsFileExists() throws {
        let box = try Sandbox()
        #expect(try box.paths.cloudMoveLock.setEnabled(false) == .off)
        #expect(!FileManager.default.fileExists(atPath: box.paths.claudeSettingsFile.path))
    }

    @Test func sandboxNeverReachesTheRealHome() throws {
        let box = try Sandbox()
        let realSettings = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        let realContents = try? Data(contentsOf: realSettings)
        // The sandbox's home is a throwaway temp directory, never the real user's ~/.claude.
        #expect(box.paths.home.path != FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(box.paths.claudeSettingsFile.path.hasPrefix(box.root.path))
        try box.paths.cloudMoveLock.setEnabled(true)
        #expect((try? Data(contentsOf: realSettings)) == realContents, "the real settings.json, if any, is untouched")
    }
}

extension Paths {
    fileprivate var cloudMoveLock: CloudMoveLock { CloudMoveLock(paths: self) }
}
