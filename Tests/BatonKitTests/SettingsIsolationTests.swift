import Foundation
import Testing

@testable import BatonKit

@Suite("Portable settings and account isolation")
struct SettingsIsolationTests {
    func write(_ box: Sandbox, _ dir: URL, _ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: "claude_desktop_config.json"))
    }

    func writeExtensionIndex(_ box: Sandbox, _ dir: URL, versions: [String: String]) throws {
        let records = versions.mapValues { version -> [String: Any] in
            [
                "version": version, "hash": "package-" + version, "installedAt": "2026-09-27T12:00:00Z",
                "manifest": [:], "signatureInfo": [:], "source": "fixture",
            ]
        }.map { id, value -> (String, [String: Any]) in
            var record = value; record["id"] = id; return (id, record)
        }
        try JSONSerialization.data(withJSONObject: ["extensions": Dictionary(uniqueKeysWithValues: records)])
            .write(to: dir.appending(path: "extensions-installations.json"))
    }

    @Test func serverMergingPreservesDestinationDefinitionsAndIndependentChanges() throws {
        let box = try Sandbox()
        let sync = SettingsSync(paths: box.paths)
        try write(box, box.main, ["mcpServers": ["shared": ["command": "v1"], "conflict": ["command": "main"]]])
        try write(box, box.work, ["mcpServers": ["own": ["command": "private"], "conflict": ["command": "profile"]]])
        try sync.run(into: box.work)
        var config = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        var servers = try #require(config["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["conflict", "own", "shared"])
        #expect((servers["conflict"] as? [String: String])?["command"] == "profile")
        servers["own"] = ["command": "private-v2"]
        config["mcpServers"] = servers
        try write(box, box.work, config)
        try write(box, box.main, ["mcpServers": ["shared": ["command": "v2"], "conflict": ["command": "main-v2"], "added": [:]]])
        try sync.run(into: box.work)
        servers = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json"))?["mcpServers"] as? [String: Any])
        #expect((servers["shared"] as? [String: String])?["command"] == "v2")
        #expect((servers["own"] as? [String: String])?["command"] == "private-v2")
        #expect((servers["conflict"] as? [String: String])?["command"] == "profile")
        #expect(servers["added"] != nil)
        #expect(try sync.run(into: box.work) == 0)
    }

    @Test func profileServerEditsAndRemovalsSurviveSourceUpdates() throws {
        let box = try Sandbox()
        let sync = SettingsSync(paths: box.paths)
        try write(box, box.main, ["mcpServers": ["edited": ["command": "v1"], "removed": ["command": "v1"]]])
        try sync.run(into: box.work)
        try write(box, box.work, ["mcpServers": ["edited": ["command": "mine"]]])
        try write(box, box.main, ["mcpServers": ["edited": ["command": "v2"], "removed": ["command": "v2"]]])
        try sync.run(into: box.work)
        let servers = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json"))?["mcpServers"] as? [String: Any])
        #expect((servers["edited"] as? [String: String])?["command"] == "mine")
        #expect(servers["removed"] == nil)
    }

    @Test func oldDictionaryBaselineDoesNotClaimIndividualServers() throws {
        let box = try Sandbox()
        let state = box.paths.stateDir.appending(path: "Settings/work.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InterfaceSync.writeState(["desktop:mcpServers": String(repeating: "a", count: 64)], to: state)
        try write(box, box.main, ["mcpServers": ["same-name": ["command": "main"]]])
        try write(box, box.work, ["mcpServers": ["same-name": ["command": "own"], "only-here": [:]]])
        try SettingsSync(paths: box.paths).run(into: box.work)
        let servers = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json"))?["mcpServers"] as? [String: Any])
        #expect((servers["same-name"] as? [String: String])?["command"] == "own")
        #expect(servers["only-here"] != nil)
        #expect(InterfaceSync.readState(state)["desktop:mcpServers"] == nil)
    }

    @Test(arguments: ["{broken", #"{"preferences:sidebarMode":17}"#, #"{"preferences:sidebarMode":"not-a-fingerprint"}"#])
    func invalidBaselineFailsBeforeAnySettingOrAssetChanges(state: String) throws {
        let box = try Sandbox()
        let stateURL = box.paths.stateDir.appending(path: "Settings/work.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try box.write(state, to: stateURL)
        try box.write("new binary", to: box.main.appending(path: "claude-ssh-remote"))
        try box.write("own binary", to: box.work.appending(path: "claude-ssh-remote"))
        try write(box, box.main, ["preferences": ["sidebarMode": "code"]])
        try write(box, box.work, ["preferences": ["sidebarMode": "chat"]])
        let config = try Data(contentsOf: box.work.appending(path: "claude_desktop_config.json"))
        #expect(throws: (any Error).self) { try SettingsSync(paths: box.paths).run(into: box.work) }
        #expect(box.read(box.work.appending(path: "claude-ssh-remote")) == "own binary")
        #expect(try Data(contentsOf: box.work.appending(path: "claude_desktop_config.json")) == config)
        #expect(box.read(stateURL) == state)
    }

    @Test func extensionPackagesMergeWithoutDeletingProfileOnlyPackagesOrEdits() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let main = box.main.appending(path: "Claude Extensions"), own = box.work.appending(path: "Claude Extensions")
        for folder in [main.appending(path: "shared"), own.appending(path: "private")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try box.write("v1", to: main.appending(path: "shared/manifest.json"))
        try box.write("own", to: own.appending(path: "private/manifest.json"))
        try writeExtensionIndex(box, box.main, versions: ["shared": "1"])
        try writeExtensionIndex(box, box.work, versions: ["private": "own"])
        let sync = SettingsSync(paths: box.paths)
        try sync.run(into: box.work)
        #expect(box.read(own.appending(path: "private/manifest.json")) == "own")
        #expect(box.read(own.appending(path: "shared/manifest.json")) == "v1")
        var records = try #require(SettingsSync.readJSON(box.work.appending(path: "extensions-installations.json"))?["extensions"] as? [String: [String: Any]])
        #expect(records.keys.sorted() == ["private", "shared"], "new source package must have its registry entry too")
        try box.write("v2", to: main.appending(path: "shared/manifest.json"))
        try writeExtensionIndex(box, box.main, versions: ["shared": "2"])
        try sync.run(into: box.work)
        #expect(box.read(own.appending(path: "shared/manifest.json")) == "v2", "an unchanged package follows its source update")
        records = try #require(SettingsSync.readJSON(box.work.appending(path: "extensions-installations.json"))?["extensions"] as? [String: [String: Any]])
        #expect(records["shared"]?["version"] as? String == "2")
        #expect(records["private"]?["version"] as? String == "own")
        try box.write("custom", to: own.appending(path: "shared/manifest.json"))
        try box.write("v3", to: main.appending(path: "shared/manifest.json"))
        try writeExtensionIndex(box, box.main, versions: ["shared": "3"])
        try sync.run(into: box.work)
        #expect(box.read(own.appending(path: "shared/manifest.json")) == "custom")
        #expect(box.read(own.appending(path: "private/manifest.json")) == "own")
        records = try #require(SettingsSync.readJSON(box.work.appending(path: "extensions-installations.json"))?["extensions"] as? [String: [String: Any]])
        #expect(records["shared"]?["version"] as? String == "2", "a package conflict must preserve its matching registry record")
        #expect(!(try fm.contentsOfDirectory(atPath: own.path)).contains { $0.hasPrefix(".baton-setup-") })
    }

    @Test func unknownExtensionRegistryNeverImportsOrUpdatesPackageFiles() throws {
        let box = try Sandbox()
        let main = box.main.appending(path: "Claude Extensions/shared"), own = box.work.appending(path: "Claude Extensions/shared")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try box.write("new", to: main.appending(path: "manifest.json"))
        try box.write("existing", to: own.appending(path: "manifest.json"))
        try writeExtensionIndex(box, box.main, versions: ["shared": "2"])
        let future = #"{"schema":2,"extensions":[{"id":"shared","version":"1"}]}"#
        try box.write(future, to: box.work.appending(path: "extensions-installations.json"))
        try SettingsSync(paths: box.paths).run(into: box.work)
        #expect(box.read(own.appending(path: "manifest.json")) == "existing")
        #expect(box.read(box.work.appending(path: "extensions-installations.json")) == future)
    }

    @Test func existingOpaqueSettingsAndDeletedInheritedAssetsArePreserved() throws {
        let box = try Sandbox()
        let sync = SettingsSync(paths: box.paths)
        try box.write("main configuration", to: box.main.appending(path: "extensions-installations.json"))
        try box.write("profile configuration", to: box.work.appending(path: "extensions-installations.json"))
        try box.write("binary v1", to: box.main.appending(path: "claude-ssh-remote"))
        try sync.run(into: box.work)
        #expect(box.read(box.work.appending(path: "extensions-installations.json")) == "profile configuration")
        try FileManager.default.removeItem(at: box.work.appending(path: "claude-ssh-remote"))
        try box.write("binary v2", to: box.main.appending(path: "claude-ssh-remote"))
        try sync.run(into: box.work)
        #expect(!box.exists(box.work.appending(path: "claude-ssh-remote")))
    }

    @Test func destinationSetupSymlinkIsNeverFollowedOrReplaced() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let source = box.main.appending(path: "Claude Extensions Settings")
        let external = box.root.appending(path: "external")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try box.write("main", to: source.appending(path: "extension.json"))
        try box.write("external", to: external.appending(path: "extension.json"))
        let target = box.work.appending(path: "Claude Extensions Settings")
        try fm.createSymbolicLink(at: target, withDestinationURL: external)
        try SettingsSync(paths: box.paths).run(into: box.work)
        #expect(try fm.destinationOfSymbolicLink(atPath: target.path) == external.path)
        #expect(box.read(external.appending(path: "extension.json")) == "external")
    }

    /// A profile's config linked to a file inside the profile's own data folder stays a link: the file it leads to gets
    /// the shared settings and keeps its own permissions, and the backup holds its content from before, not another link.
    @Test func aLinkedProfileConfigStaysALink() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let own = box.work.appending(path: "Kept/claude_desktop_config.json")
        try fm.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"futureTopLevel":"own"}"#
        try box.write(original, to: own)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: own.path)
        let config = box.work.appending(path: "claude_desktop_config.json")
        try fm.createSymbolicLink(at: config, withDestinationURL: own)
        try write(box, box.main, ["preferences": ["dockBounceEnabled": true]])

        #expect(try SettingsSync(paths: box.paths).run(into: box.work) == 1)

        #expect(try fm.destinationOfSymbolicLink(atPath: config.path) == own.path, "still a link")
        let written = try #require(SettingsSync.readJSON(own))
        #expect((written["preferences"] as? [String: Any])?["dockBounceEnabled"] as? Bool == true, "the linked file got the change")
        #expect(written["futureTopLevel"] as? String == "own")
        #expect(try fm.attributesOfItem(atPath: own.path)[.posixPermissions] as? Int == 0o640, "its own permissions, not the link's")
        let backups = try #require(fm.enumerator(at: box.paths.backupsDir, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let saved = backups.filter { $0.lastPathComponent == own.lastPathComponent }
        #expect(saved.count == 1)
        #expect(saved.allSatisfy { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == nil }, "a copy, not a link")
        #expect(saved.first.flatMap(box.read) == original, "the content before the change")
    }

    /// A profile's config that links outside the profile's data folder, to the main app's config or a dotfiles folder,
    /// is left as it is: the main app may be open while the profile is closed, and would lose its wake helper.
    @Test func aProfileConfigLinkedOutsideItsFolderIsLeftAlone() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let mainConfig = box.main.appending(path: "claude_desktop_config.json")
        let mainText = #"{"preferences":{"dockBounceEnabled":true,"wakeSchedulerEnabled":true}}"#
        try box.write(mainText, to: mainConfig)
        let desktop = box.work.appending(path: "claude_desktop_config.json")
        try fm.createSymbolicLink(at: desktop, withDestinationURL: mainConfig)
        let dotfiles = box.root.appending(path: "dotfiles/config.json")
        try fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dotfilesText = #"{"userThemeMode":"dark"}"#
        try box.write(dotfilesText, to: dotfiles)
        let config = box.work.appending(path: "config.json")
        try fm.createSymbolicLink(at: config, withDestinationURL: dotfiles)
        try box.write(#"{"userThemeMode":"light"}"#, to: box.main.appending(path: "config.json"))

        #expect(try SettingsSync(paths: box.paths).run(into: box.work) == 0)

        #expect(box.read(mainConfig) == mainText, "the main app's config is untouched")
        #expect(box.read(dotfiles) == dotfilesText)
        #expect(try fm.destinationOfSymbolicLink(atPath: desktop.path) == mainConfig.path)
        #expect(try fm.destinationOfSymbolicLink(atPath: config.path) == dotfiles.path)
        #expect(!fm.fileExists(atPath: box.paths.backupsDir.path), "nothing to back up")
    }

    @Test func sshDefinitionsMergeByIDWhileTrustAndProfileChangesStayLocal() throws {
        let box = try Sandbox()
        let filename = "ssh_configs.json"
        func writeSSH(_ dir: URL, _ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: filename))
        }
        try writeSSH(
            box.main,
            [
                "configs": [
                    ["id": "shared", "name": "Shared", "sshHost": "main-host"],
                    ["id": "conflict", "name": "Main", "sshHost": "main-conflict"],
                ],
                "trustedHosts": ["main-host", "main-conflict"],
            ])
        try writeSSH(
            box.work,
            [
                "configs": [
                    ["id": "private", "name": "Private", "sshHost": "private-host"],
                    ["id": "conflict", "name": "Own", "sshHost": "own-conflict"],
                ],
                "trustedHosts": ["private-host"],
            ])
        let sync = SettingsSync(paths: box.paths)
        try sync.run(into: box.work)
        var result = try #require(SettingsSync.readJSON(box.work.appending(path: filename)))
        var configs = try #require(result["configs"] as? [[String: String]])
        #expect(configs.map { $0["id"]! } == ["private", "conflict", "shared"])
        #expect(configs.first { $0["id"] == "conflict" }?["sshHost"] == "own-conflict")
        #expect(result["trustedHosts"] as? [String] == ["private-host"])
        try writeSSH(
            box.main,
            [
                "configs": [["id": "shared", "name": "Shared", "sshHost": "updated-host"]],
                "trustedHosts": ["updated-host"],
            ])
        try sync.run(into: box.work)
        result = try #require(SettingsSync.readJSON(box.work.appending(path: filename)))
        configs = try #require(result["configs"] as? [[String: String]])
        #expect(configs.first { $0["id"] == "shared" }?["sshHost"] == "updated-host")
        #expect(configs.first { $0["id"] == "private" }?["sshHost"] == "private-host")
        #expect(result["trustedHosts"] as? [String] == ["private-host"])

        let fresh = box.root.appending(path: "fresh-profile")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try sync.run(into: fresh)
        #expect(
            SettingsSync.readJSON(fresh.appending(path: filename))?["trustedHosts"] == nil,
            "new profiles must make their own trust decisions")
    }

    @Test func unknownSSHSchemaIsPreservedRatherThanGuessed() throws {
        let box = try Sandbox()
        let source = box.main.appending(path: "ssh_configs.json")
        let target = box.work.appending(path: "ssh_configs.json")
        try box.write(#"{"configs":[{"id":"new","name":"New","sshHost":"host"}],"trustedHosts":["host"]}"#, to: source)
        let own = #"{"version":2,"configs":{"private":{"host":"mine"}},"trustedHosts":["mine"]}"#
        try box.write(own, to: target)
        try SettingsSync(paths: box.paths).run(into: box.work)
        #expect(box.read(target) == own)
        try box.write(#"{"configs":[{"id":"duplicate","name":"One","sshHost":"a"},{"id":"duplicate","name":"Two","sshHost":"b"}]}"#, to: source)
        try box.write(#"{"configs":[],"trustedHosts":["mine"]}"#, to: target)
        let before = box.read(target)
        try SettingsSync(paths: box.paths).run(into: box.work)
        #expect(box.read(target) == before)
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
        let initial: [String: Any] = [
            "preferences": ["sidebarMode": "code"],
            "mcpServers": ["local": ["command": "tool", "env": ["TOKEN": "fixture-sensitive-value"]]],
        ]
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
        holder.arguments = [
            "-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
            LocalStorage(dataDir: box.work).dbDir.appending(path: "LOCK").path,
        ]
        let stdout = Pipe(), stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        defer { stdin.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
        _ = stdout.fileHandleForReading.availableData
        #expect(throws: LocalStorageError.databaseInUse) { try SettingsSync(paths: box.paths).run(into: box.work) }
        #expect(try Data(contentsOf: target) == original)
    }

    /// A crash or a force quit during an extension or setup copy leaves its stage in the profile's data, where Claude
    /// finds it. The next merge removes such stages; one kept after a failed restore, and anything else, stays.
    @Test func stagesLeftByACrashAreRemovedByTheNextMerge() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let leftovers = [".baton-extensions-\(UUID().uuidString)", ".baton-setup-\(UUID().uuidString)"]
        let kept = [".baton-recovery-\(UUID().uuidString)", ".baton-setup-mine", "Own folder"]
        for name in leftovers + kept {
            try fm.createDirectory(at: box.work.appending(path: "\(name)/packages"), withIntermediateDirectories: true)
        }

        try SettingsSync(paths: box.paths).run(into: box.work)

        let names = Set(try fm.contentsOfDirectory(atPath: box.work.path))
        #expect(names.isDisjoint(with: leftovers))
        #expect(names.isSuperset(of: kept))
    }
}
