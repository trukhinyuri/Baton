import Foundation
import Testing

@testable import BatonKit

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

extension CloudMoveLockTests {
    /// A `settings.json` linked into place from a dotfiles folder stays a link: the file it leads to gets only the
    /// deny entry, byte for byte around it, keeps its permissions, and is backed up as content.
    @Test func aLinkedSettingsFileStaysALinkAndKeepsItsFormat() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let dotfiles = box.root.appending(path: "dotfiles/claude-settings.json")
        try fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = """
            {
              "model": "opus",
              "permissions": {
                "allow": ["Read"]
              },
              "env": {"B": "1", "A": "2"}
            }

            """
        try box.write(before, to: dotfiles)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfiles.path)
        try fm.createDirectory(at: box.paths.claudeDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: box.paths.claudeSettingsFile, withDestinationURL: dotfiles)

        let lock = box.paths.cloudMoveLock
        #expect(try lock.setEnabled(true) == .on)
        #expect(try fm.destinationOfSymbolicLink(atPath: box.paths.claudeSettingsFile.path) == dotfiles.path, "still a link")
        let on = before.replacingOccurrences(of: #""allow": ["Read"]"#, with: #""deny": ["\#(CloudMoveLock.tool)"],\#n    "allow": ["Read"]"#)
        #expect(box.read(dotfiles) == on, "only the deny list is added, and key order and spacing stay")
        #expect(try fm.attributesOfItem(atPath: dotfiles.path)[.posixPermissions] as? Int == 0o600)
        let backups = try #require(fm.enumerator(at: box.paths.backupsDir, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let saved = backups.filter { $0.lastPathComponent == dotfiles.lastPathComponent }
        #expect(saved.count == 1 && (try? fm.destinationOfSymbolicLink(atPath: saved[0].path)) == nil, "a copy, not a link")
        #expect(saved.first.flatMap(box.read) == before)

        #expect(try lock.setEnabled(false) == .off)
        #expect(box.read(dotfiles) == on.replacingOccurrences(of: #"["\#(CloudMoveLock.tool)"]"#, with: "[]"))
        #expect(try fm.destinationOfSymbolicLink(atPath: box.paths.claudeSettingsFile.path) == dotfiles.path)

        // With no permissions object at all, one is added with only the entry.
        try box.write(#"{"model":"opus"}"#, to: dotfiles)
        #expect(try lock.setEnabled(true) == .on)
        #expect(box.read(dotfiles) == #"{"permissions":{"deny": ["\#(CloudMoveLock.tool)"]},"model":"opus"}"#)
    }
}

extension Paths {
    fileprivate var cloudMoveLock: CloudMoveLock { CloudMoveLock(paths: self) }
}
