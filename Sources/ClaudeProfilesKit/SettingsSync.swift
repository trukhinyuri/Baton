import Foundation
import CryptoKit

/// Shares an explicit set of portable desktop settings before a profile starts. Account state, Projects,
/// Remote Control, Cowork grants and unknown future preferences stay with the profile. Portable settings
/// use a three-way merge: a change made only in the profile survives the next launch.
/// Sign-in data (tokens in `config.json`, cookies) is never copied.
///
/// Run it only while the profile's window is closed: Claude writes these files back when it quits.
public struct SettingsSync: Sendable {
    /// Files and folders copied as they are.
    static let copied = ["Claude Extensions", "Claude Extensions Settings", "extensions-installations.json",
                         "ssh_configs.json", "claude-ssh-remote"]
    /// Claude Code builds the main app has downloaded, one folder per version. Cloning them spares a profile the download.
    static let builds = "claude-code"
    /// Scheduled task switches, which Claude turns on in a window that has tasks. Tasks are kept per account in
    /// each window's own data and never copied, so every window keeps its own switches and runs its own tasks.
    static let windowPreferences = ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled"]
    /// Waking the Mac for scheduled tasks stays with the main app: each app copy would register its own
    /// wake helper with macOS and ask for its own approval in Login Items.
    static let mainOnlyPreferences = ["wakeSchedulerEnabled"]
    /// The only `config.json` keys copied; the rest of that file is sign-in and per-window state.
    static let appearanceKeys = ["userThemeMode", "windowControlsZoomFactor", "locale"]

    /// Deliberately opt-in: a new Claude preference must be understood before it can cross profiles.
    /// In particular, Remote Control, folder grants, browser pairing and account consent are not appearance.
    static let portablePreferences: Set<String> = [
        "keepAwakeEnabled", "dockBounceEnabled", "sidebarMode", "quickEntryDictationShortcut",
        "coworkPreferredBrowser", "ccAutoArchiveInactiveDays", "ccAutoArchiveOnPrClose",
    ]

    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) { self.paths = paths }

    /// - Returns: how many files or folders changed.
    @discardableResult
    public func run(into dataDir: URL, now: Date = Date()) throws -> Int {
        let source = paths.mainDataDir
        let backup = Backup(paths: paths, now: now)
        guard !LocalStorage(dataDir: dataDir).isInUse else { throw LocalStorageError.databaseInUse }
        let stateURL = paths.stateDir.appending(path: "Settings/\(dataDir.lastPathComponent).json")
        var base = InterfaceSync.readState(stateURL)
        var changed = 0

        for name in Self.copied {
            let from = source.appending(path: name), to = dataDir.appending(path: name)
            guard fm.fileExists(atPath: from.path), !fm.contentsEqual(atPath: from.path, andPath: to.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                _ = try backup.save(to)
                try fm.trashItem(at: to, resultingItemURL: nil)
            }
            try fm.copyItem(at: from, to: to)   // an APFS clone, so extensions take no extra space
            changed += 1
        }

        changed += try copyBuilds(into: dataDir)

        let desktop = dataDir.appending(path: "claude_desktop_config.json")
        if let main = try Self.readExistingJSON(source.appending(path: "claude_desktop_config.json")) {
            let current = try Self.readExistingJSON(desktop) ?? [:]
            var result = current, attempt = base
            Self.share("mcpServers", main: main, own: current, into: &result, base: &attempt, prefix: "desktop:")
            let mainPrefs = main["preferences"] as? [String: Any] ?? [:]
            let ownPrefs = current["preferences"] as? [String: Any] ?? [:]
            var prefs = ownPrefs
            for key in Self.portablePreferences {
                Self.share(key, main: mainPrefs, own: ownPrefs, into: &prefs, base: &attempt, prefix: "preferences:")
            }
            // Scheduled tasks keep their own switches; only MAIN registers a wake helper.
            for key in Self.mainOnlyPreferences { prefs[key] = false }
            if !prefs.isEmpty || current["preferences"] != nil { result["preferences"] = prefs }
            if !NSDictionary(dictionary: result).isEqual(to: current) {
                if fm.fileExists(atPath: desktop.path) { _ = try backup.save(desktop) }
                try Self.writeJSON(result, to: desktop)
                changed += 1
            }
            base = attempt
            try InterfaceSync.writeState(base, to: stateURL)
        }
        // Tool toggles are permissions owned by each account. Never copy another account's grants or
        // replace a profile's deliberate denial with MAIN's enabled switch.
        if try copyAppearance(into: dataDir, base: &base) { changed += 1 }
        try InterfaceSync.writeState(base, to: stateURL)
        return changed
    }

    /// Copies Claude Code versions the profile doesn't have yet. Only finished downloads (with `.verified`) are
    /// copied, under a temporary name first, so a profile never sees half a build.
    private func copyBuilds(into dataDir: URL) throws -> Int {
        let from = paths.mainDataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        let to = dataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        var copied = 0
        for version in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !version.hasPrefix(".") {
            let build = from.appending(path: version, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: build.appending(path: ".verified").path),
                  !fm.fileExists(atPath: to.appending(path: version).path) else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            let partial = to.appending(path: ".\(version)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.copyItem(at: build, to: partial)
            try fm.moveItem(at: partial, to: to.appending(path: version, directoryHint: .isDirectory))
            copied += 1
        }
        return copied
    }

    /// Resolves portable values without retaining their contents (MCP configuration may include secrets).
    /// Missing source settings do not delete profile-only settings.
    private static func share(_ key: String, main: [String: Any], own: [String: Any],
                              into result: inout [String: Any], base: inout [String: String], prefix: String) {
        guard let value = main[key] else { return }
        let stateKey = prefix + key
        let mainHash = fingerprint(value), ownHash = own[key].map(fingerprint) ?? InterfaceSync.missing
        guard InterfaceSync.resolve(own: ownHash, main: mainHash, base: base[stateKey]) == .main else { return }
        result[key] = value
        base[stateKey] = mainHash
    }

    private static func fingerprint(_ value: Any) -> String {
        SHA256.hash(data: Data(InterfaceSync.canonical(value).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A corrupt existing configuration is not an empty configuration and must never be replaced silently.
    private static func readExistingJSON(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalStorageError.corrupt("\(url.lastPathComponent) must contain a JSON object")
        }
        return object
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Copies theme, zoom and language into the profile's `config.json`, leaving everything else in it untouched.
    /// That file also holds the profile's sign-in, so it is edited in place and never backed up or copied.
    private func copyAppearance(into dataDir: URL, base: inout [String: String]) throws -> Bool {
        let to = dataDir.appending(path: "config.json")
        guard let main = Self.readJSON(paths.mainDataDir.appending(path: "config.json")),
              var config = Self.readJSON(to) else { return false }
        let own = config
        var attempt = base
        for key in Self.appearanceKeys {
            Self.share(key, main: main, own: own, into: &config, base: &attempt, prefix: "appearance:")
        }
        guard !NSDictionary(dictionary: own).isEqual(to: config) else { base = attempt; return false }
        try Self.writeJSON(config, to: to)
        base = attempt
        return true
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
