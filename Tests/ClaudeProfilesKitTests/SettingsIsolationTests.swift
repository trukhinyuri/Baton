import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Portable settings and account isolation")
struct SettingsIsolationTests {
    func write(_ box: Sandbox, _ dir: URL, _ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: "claude_desktop_config.json"))
    }

    @Test func remoteControlCoworkAndFutureSettingsStayWithTheProfile() throws {
        let box = try Sandbox()
        let privatePrefs: [String: Any] = [
            "ccRemoteControlDefaultEnabled": false,
            "remoteControlPinnedFolders": ["/approved/project"], "remoteControlExcludedFolders": ["/excluded/project"],
            "remoteSessionFolderGrants": ["session_own": ["/approved/project"]],
            "remoteFolderConsentMemory": ["/approved/project"], "remoteToolsDeviceName": "own-device",
            "localAgentModeTrustedFolders": ["/own/cowork"], "chromeExtension": ["pairedDeviceId": "own-browser"],
            "bypassPermissionsOptInByAccount": [Sandbox.accountB: false], "allowAllBrowserActions": false,
            "coworkHipaaRestricted": true, "orgWorkAcrossAppsDisabled": true,
            "futureAccountSetting": ["owner": "own"],
        ]
        var mainPrefs = privatePrefs.mapValues { _ in true as Any }
        mainPrefs["remoteControlPinnedFolders"] = ["/unapproved/project"]
        mainPrefs["futureSourceOnlySetting"] = "must-not-import"
        mainPrefs["dockBounceEnabled"] = true
        var ownPrefs = privatePrefs
        ownPrefs["dockBounceEnabled"] = false
        try write(box, box.main, ["preferences": mainPrefs, "futureTopLevel": "main", "coworkUserFilesPath": "/main/cowork"])
        try write(box, box.work, ["preferences": ownPrefs, "futureTopLevel": "own", "coworkUserFilesPath": "/own/cowork"])
        let sync = SettingsSync(paths: box.paths)
        try sync.run(into: box.work)
        let result = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        let prefs = try #require(result["preferences"] as? [String: Any])
        for (key, value) in privatePrefs {
            #expect(prefs[key].map(InterfaceSync.canonical) == InterfaceSync.canonical(value), "\(key) is profile-owned")
        }
        #expect(prefs["dockBounceEnabled"] as? Bool == true)
        #expect(prefs["futureSourceOnlySetting"] == nil)
        #expect(result["futureTopLevel"] as? String == "own")
        #expect(result["coworkUserFilesPath"] as? String == "/own/cowork")
        #expect(try sync.run(into: box.work) == 0)
    }

    @Test func portableChangesUseThreeWayMergeWithoutRecordingConfigurationSecrets() throws {
        let box = try Sandbox()
        let sync = SettingsSync(paths: box.paths)
        let initial: [String: Any] = ["preferences": ["sidebarMode": "code"],
                                     "mcpServers": ["local": ["command": "tool", "env": ["TOKEN": "fixture-sensitive-value"]]]]
        try write(box, box.main, initial)
        try write(box, box.work, ["preferences": ["sidebarMode": "chat"]])
        try sync.run(into: box.work)
        var own = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        own["preferences"] = ["sidebarMode": "cowork"]
        own["mcpServers"] = ["profile-local": ["command": "other-tool"]]
        try write(box, box.work, own)
        try sync.run(into: box.work)
        var result = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        #expect((result["preferences"] as? [String: Any])?["sidebarMode"] as? String == "cowork")
        #expect((result["mcpServers"] as? [String: Any])?["profile-local"] != nil)
        var changedMain = initial
        changedMain["preferences"] = ["sidebarMode": "projects"]
        try write(box, box.main, changedMain)
        try sync.run(into: box.work)
        result = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        #expect((result["preferences"] as? [String: Any])?["sidebarMode"] as? String == "projects")
        #expect((result["mcpServers"] as? [String: Any])?["profile-local"] != nil)
        let statePath = box.paths.stateDir.appending(path: "Settings/\(box.work.lastPathComponent).json")
        let state = try String(contentsOf: statePath, encoding: .utf8)
        #expect(!state.contains("fixture-sensitive-value"))
        #expect(!state.contains("other-tool"))
        #expect(InterfaceSync.readState(statePath).values.allSatisfy { $0.count == 64 })
    }

    @Test func corruptExistingConfigIsReportedAndNeverOverwritten() throws {
        let box = try Sandbox()
        try write(box, box.main, ["preferences": ["sidebarMode": "code"]])
        let target = box.work.appending(path: "claude_desktop_config.json")
        try box.write("{incomplete", to: target)
        #expect(throws: (any Error).self) { try SettingsSync(paths: box.paths).run(into: box.work) }
        #expect(box.read(target) == "{incomplete")
    }

    @Test func runningProfileSettingsAreNotTouched() throws {
        let box = try InterfaceSyncTests().sandbox()
        try write(box, box.main, ["preferences": ["sidebarMode": "code"]])
        try write(box, box.work, ["preferences": ["sidebarMode": "chat"]])
        let target = box.work.appending(path: "claude_desktop_config.json")
        let original = try Data(contentsOf: target)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
                            LocalStorage(dataDir: box.work).dbDir.appending(path: "LOCK").path]
        let stdout = Pipe(), stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        defer { stdin.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
        _ = stdout.fileHandleForReading.availableData
        #expect(throws: LocalStorageError.databaseInUse) { try SettingsSync(paths: box.paths).run(into: box.work) }
        #expect(try Data(contentsOf: target) == original)
    }
}
