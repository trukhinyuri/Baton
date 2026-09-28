import Foundation
import Testing

@testable import BatonKit

extension Sandbox {
    /// A Claude.app whose `app.asar` names `keys`, the way a Claude Desktop version that knows them does.
    func installClaude(knowing keys: [String] = ["ccRemoteControlDefaultEnabled", "remoteControlStayReachable"]) throws {
        let asar = paths.claudeApp.appending(path: "Contents/Resources/app.asar")
        try FileManager.default.createDirectory(at: asar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("\u{0}asar-header{}" + keys.map { "const k=\"\($0)\";" }.joined() + "\u{0}").utf8).write(to: asar)
    }

    func desktopConfig(_ dataDir: URL) -> URL { dataDir.appending(path: "claude_desktop_config.json") }

    /// Every file under the sandbox with its contents, to show what a call changed.
    func contentsSnapshot() -> [String: Data] {
        var result: [String: Data] = [:]
        for relative in NativeForkCarry.files(under: root) {
            result[relative] = try? Data(contentsOf: root.appending(path: relative))
        }
        return result
    }
}

private func preferences(_ url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return object?["preferences"] as? [String: Any] ?? [:]
}

@Suite("Local only")
struct LocalOnlyTests {
    static let config = """
        {
          "mcpServers": {"files": {"command": "/usr/bin/true", "args": ["-v"]}},
          "preferences": {
            "ccdScheduledTasksEnabled": true,
            "ccRemoteControlDefaultEnabled": true,
            "coworkScheduledTasksEnabled" :true,
            "remoteControlStayReachable":   true,
            "wakeSchedulerEnabled": true,
            "zoom": 1.0,
            "name": "caf\\u00e9 \\"quoted\\""
          },
          "zz": [1, 2.50, {"a": null}]
        }

        """

    func closed(_ box: Sandbox) -> LocalOnly { LocalOnly(paths: box.paths, isRunning: { _ in false }) }

    @Test func turnsOffRemoteControlInClosedWindow() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let localOnly = closed(box)

        #expect(try localOnly.apply(window: "work") == .on)

        let prefs = try preferences(box.desktopConfig(box.work))
        #expect(prefs["ccRemoteControlDefaultEnabled"] as? Bool == false)
        #expect(prefs["remoteControlStayReachable"] as? Bool == false)
        #expect(localOnly.status(window: "work") == .on)
        let backups = NativeForkCarry.files(under: box.paths.backupsDir)
        #expect(backups.contains { $0.hasSuffix("Profiles/work/claude_desktop_config.json") }, "a dated backup comes first")
        #expect(backups.allSatisfy { $0.range(of: #"^\d{4}-\d{2}-\d{2}/"#, options: .regularExpression) != nil })
        let state = try String(contentsOf: box.paths.localOnlyFile, encoding: .utf8)
        #expect(state.contains("ccRemoteControlDefaultEnabled") && state.contains("remoteControlStayReachable"), "prior values are kept")

        // A window whose Claude never wrote the secondary key doesn't get it; the main switch is added.
        try box.write(#"{"preferences":{"keepAwakeEnabled":true}}"#, to: box.desktopConfig(box.main))
        #expect(try localOnly.apply(window: "main") == .on)
        let main = try preferences(box.desktopConfig(box.main))
        #expect(main["ccRemoteControlDefaultEnabled"] as? Bool == false)
        #expect(main["remoteControlStayReachable"] == nil)
        #expect(main["keepAwakeEnabled"] as? Bool == true)
        #expect(try localOnly.apply(window: "main") == .on, "a second run changes nothing")
    }

    @Test func otherKeysByteIdentical() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))

        _ = try closed(box).apply(window: "work")

        let expected = Self.config
            .replacingOccurrences(of: #""ccRemoteControlDefaultEnabled": true"#, with: #""ccRemoteControlDefaultEnabled": false"#)
            .replacingOccurrences(of: #""remoteControlStayReachable":   true"#, with: #""remoteControlStayReachable":   false"#)
        #expect(box.read(box.desktopConfig(box.work)) == expected, "only the two values changed, byte for byte")

        // Added where it's missing, without touching the rest.
        let compact = #"{"preferences":{"keepAwakeEnabled":true,"zoom":1.0},"x":"é"}"#
        try box.write(compact, to: box.desktopConfig(box.main))
        _ = try closed(box).apply(window: "main")
        #expect(box.read(box.desktopConfig(box.main)) == #"{"preferences":{"ccRemoteControlDefaultEnabled":false,"keepAwakeEnabled":true,"zoom":1.0},"x":"é"}"#)
    }

    @Test func pendingWhileRunning() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let running = LocalOnly(paths: box.paths, isRunning: { $0 == "work" })

        #expect(try running.apply(window: "work") == .pending)

        #expect(box.read(box.desktopConfig(box.work)) == Self.config, "Claude writes this file back when it quits")
        #expect(!box.exists(box.paths.backupsDir))
        #expect(running.status(window: "work") == .pending)
        #expect(try running.disable(window: "work") == .off, "nothing was written, so nothing waits to be undone")
    }

    @Test func disableRestoresPrior() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let noPreferences = #"{"mcpServers":{}}"#
        try box.write(noPreferences, to: box.desktopConfig(box.main))
        let localOnly = closed(box)
        _ = try localOnly.apply(window: "work")
        _ = try localOnly.apply(window: "main")
        #expect(try preferences(box.desktopConfig(box.main))["ccRemoteControlDefaultEnabled"] as? Bool == false)

        #expect(try localOnly.disable(window: "work") == .off)
        #expect(try localOnly.disable(window: "main") == .off)

        #expect(box.read(box.desktopConfig(box.work)) == Self.config, "the prior values come back, byte for byte")
        #expect(box.read(box.desktopConfig(box.main)) == noPreferences)
        #expect(localOnly.status(window: "work") == .off)
        #expect(try String(contentsOf: box.paths.localOnlyFile, encoding: .utf8).contains("ccRemoteControlDefaultEnabled") == false)

        // Turned back on inside Claude while Local only was on: the user's own choice is left as it is.
        _ = try localOnly.apply(window: "work")
        let flipped = try String(contentsOf: box.desktopConfig(box.work), encoding: .utf8)
            .replacingOccurrences(of: #""remoteControlStayReachable":   false"#, with: #""remoteControlStayReachable":   true"#)
        try box.write(flipped, to: box.desktopConfig(box.work))
        #expect(localOnly.status(window: "work") == .pending, "drifted: reapplied at the next cold start")
        _ = try localOnly.disable(window: "work")
        #expect(try preferences(box.desktopConfig(box.work))["remoteControlStayReachable"] as? Bool == true)
    }

    @Test func turningItOffPerWindowAndGlobally() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))
        try box.write(Self.config, to: box.desktopConfig(box.main))
        let localOnly = closed(box)
        #expect(localOnly.isEnabled(window: "work"), "on by default")

        let off = try localOnly.setEnabled(false, window: "work", windows: ["main", "work"])
        #expect(off == ["work": .off])
        #expect(try localOnly.reconcile(window: "main") == .on)
        #expect(try localOnly.reconcile(window: "work") == .off)
        #expect(box.read(box.desktopConfig(box.work)) == Self.config)

        let all = try localOnly.setEnabled(false, window: nil, windows: ["main", "work"])
        #expect(all == ["main": .off, "work": .off])
        #expect(box.read(box.desktopConfig(box.main)) == Self.config)
        #expect(
            try localOnly.setEnabled(true, window: nil, windows: ["main", "work"]) == ["main": .on, "work": .off],
            "a window's own choice outlives the global one")
    }

    @Test func settingsSyncNeverOverridesLocalOnlyKeys() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.signIn(box.main, account: Sandbox.accountA)
        try box.signIn(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"preferences":{"ccRemoteControlDefaultEnabled":true,"remoteControlStayReachable":true,"keepAwakeEnabled":true,"epitaxyPrefs":{"epitaxy-transcript-links-in-preview":true}}}"#,
            to: box.desktopConfig(box.main))
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let localOnly = closed(box)
        _ = try localOnly.apply(window: "work")

        try SettingsSync(paths: box.paths).run(into: box.work)
        try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")

        let prefs = try preferences(box.desktopConfig(box.work))
        #expect(prefs["keepAwakeEnabled"] as? Bool == true, "the sync did run and rewrite the file")
        #expect((prefs["epitaxyPrefs"] as? [String: Any])?["epitaxy-transcript-links-in-preview"] as? Bool == true)
        #expect(prefs["ccRemoteControlDefaultEnabled"] as? Bool == false)
        #expect(prefs["remoteControlStayReachable"] as? Bool == false)
        #expect(localOnly.status(window: "work") == .on)
        #expect(SettingsSync.portablePreferences.isDisjoint(with: LocalOnly.ownedKeys))
        #expect(InterfaceSync.prefsKeys.isDisjoint(with: LocalOnly.ownedKeys))
    }

    @Test func neverTouchesScheduledTasksOrManagedPolicy() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let transcript = try box.transcript(lines: [#"{"type":"history-suppression","cause":"fork_inherit","sessionId":"\#(Sandbox.cli)"}"#])
        let before = box.contentsSnapshot()

        _ = try closed(box).apply(window: "work")
        _ = try closed(box).disable(window: "work")
        _ = try closed(box).apply(window: "work")

        let after = box.contentsSnapshot()
        let changed = Set(after.keys.filter { before[$0] != after[$0] })
        let config = box.desktopConfig(box.work).path.dropFirst(box.root.path.count + 1)
        let own = [box.paths.localOnlyFile, box.paths.stateDir.appending(path: "local-only.lock")]
        let expected = Set([String(config)] + own.map { String($0.path.dropFirst(box.root.path.count + 1)) })
        #expect(
            changed.subtracting(expected).allSatisfy { $0.hasPrefix("Library/Application Support/Baton/Backups/") },
            "only the window's config, Local only's own record and backups change: \(changed.sorted())")
        #expect(box.read(transcript)?.contains("history-suppression") == true)
        let prefs = try preferences(box.desktopConfig(box.work))
        for key in ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled", "wakeSchedulerEnabled"] {
            #expect(prefs[key] as? Bool == true, "\(key) is a local scheduler switch and stays as it is")
        }
        #expect(LocalOnly.ownedKeys.isDisjoint(with: LocalOnly.neverTouched))
        #expect(
            LocalOnly.neverTouched.isSuperset(of: [
                "ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled", "wakeSchedulerEnabled",
                "chatTabEnabled", "disableMultiAccount",
            ]))
    }

    @Test func reportsMissingKeyForUnknownClaudeVersion() throws {
        let box = try Sandbox()
        try box.installClaude(knowing: ["remoteControlStayReachable"])
        try box.write(Self.config, to: box.desktopConfig(box.work))
        let localOnly = closed(box)

        #expect(try localOnly.apply(window: "work") == .notSupported)
        #expect(localOnly.status(window: "work") == .notSupported)
        #expect(box.read(box.desktopConfig(box.work)) == Self.config, "nothing is written")
        #expect(LocalOnly.missingKeys(in: box.paths.claudeApp) == ["ccRemoteControlDefaultEnabled"])

        try FileManager.default.removeItem(at: box.paths.claudeApp)
        #expect(try localOnly.apply(window: "work") == .notSupported, "no readable Claude.app: nothing can be checked, so nothing is written")
    }

    @Test func damagedConfigIsNeverReplaced() throws {
        let box = try Sandbox()
        try box.installClaude()
        try box.write(#"{"preferences": {"ccRemoteControlDefaultEnabled": tru"#, to: box.desktopConfig(box.work))

        #expect(throws: (any Error).self) { try closed(box).apply(window: "work") }
        #expect(box.read(box.desktopConfig(box.work)) == #"{"preferences": {"ccRemoteControlDefaultEnabled": tru"#)
    }
}
