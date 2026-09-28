import AppKit
import Foundation

/// Every location Baton reads or writes. Injected everywhere so tests can run in a sandbox.
public struct Paths: Sendable, Equatable {
    /// The user's home directory.
    public var home: URL
    /// The official Claude Desktop app. Profiles run APFS clones of it.
    public var claudeApp: URL
    /// Where Claude Code keeps each session's scratchpad and background task output
    /// (`<claudeTempDir>/<folder>/<session>/{scratchpad,tasks}`). The system may clear it at restart.
    public var claudeTempDir: URL
    /// Baton's own state: profile registry and backups. `~/Library/Application Support/Baton`, or the folder of
    /// its earlier name, Claude Profiles, until `LegacyMigration` moves it (see `resolveRoot`).
    public var stateDir: URL
    /// Launchers are visible in Finder, Spotlight and Launchpad and can be kept in the Dock. `~/Applications/Baton`,
    /// or the Claude Profiles folder until `LegacyMigration` moves it.
    public var launchersDir: URL

    /// Resolves `stateDir` and `launchersDir` now, each on its own: build `Paths` after `LegacyMigration` has run.
    /// - Parameter claudeTempDir: by default a folder inside `home`, so a sandboxed `home` never reaches the real one.
    public init(home: URL, claudeApp: URL, claudeTempDir: URL? = nil) {
        self.home = home
        self.claudeApp = claudeApp
        self.claudeTempDir = claudeTempDir ?? home.appending(path: "tmp/claude", directoryHint: .isDirectory)
        stateDir = Self.resolveRoot(new: Self.newStateDir(home: home), legacy: Self.legacyStateDir(home: home))
        launchersDir = Self.resolveRoot(new: Self.newLaunchersDir(home: home), legacy: Self.legacyLaunchersDir(home: home))
    }

    public static var standard: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            home: home,
            claudeApp: findClaude(home: home, lookup: launchServicesApps),
            claudeTempDir: URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true))
    }

    /// Claude Desktop: where Launch Services has it, else in /Applications, else in ~/Applications. Profile engines
    /// and launchers carry its bundle id too and are never taken for it, nor is a copy in the Trash.
    /// - Returns: `/Applications/Claude.app` when there is no Claude anywhere, so the error names the usual place.
    public static func findClaude(
        home: URL, systemApplications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        lookup: (String) -> [URL]
    ) -> URL {
        // Under either name: a copy in the folder Baton doesn't use now is still one of its own.
        let own = [newLaunchersDir(home: home), legacyLaunchersDir(home: home)].map { $0.standardizedFileURL.path + "/" }
        func isClaude(_ app: URL) -> Bool {
            let path = app.standardizedFileURL.path
            guard !own.contains(where: path.hasPrefix), !path.contains("/.Trash/") else { return false }
            return ClaudeVersion.bundleInfo(at: app)?["CFBundleIdentifier"] as? String == ClaudeVersion.bundleIdentifier
        }
        let candidates =
            lookup(ClaudeVersion.bundleIdentifier)
            + [systemApplications.appending(path: "Claude.app"), home.appending(path: "Applications/Claude.app")]
        return candidates.first(where: isClaude) ?? systemApplications.appending(path: "Claude.app", directoryHint: .isDirectory)
    }

    /// Launch Services' preferred copy first, then every other copy it knows.
    static func launchServicesApps(_ bundleIdentifier: String) -> [URL] {
        let workspace = NSWorkspace.shared
        return [workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)].compactMap { $0 }
            + workspace.urlsForApplications(withBundleIdentifier: bundleIdentifier)
    }

    public var applicationSupport: URL { Self.applicationSupport(home: home) }

    // MARK: Baton's own folders under both names

    /// The folder name before 1.0 (see docs/adr/0007-baton-rename.md). Only `LegacyMigration` and path resolution use it.
    public static let legacyFolderName = "Claude Profiles"
    public static let folderName = "Baton"

    static func applicationSupport(home: URL) -> URL { home.appending(path: "Library/Application Support", directoryHint: .isDirectory) }
    public static func newStateDir(home: URL) -> URL { applicationSupport(home: home).appending(path: folderName, directoryHint: .isDirectory) }
    public static func legacyStateDir(home: URL) -> URL { applicationSupport(home: home).appending(path: legacyFolderName, directoryHint: .isDirectory) }
    public static func newLaunchersDir(home: URL) -> URL { home.appending(path: "Applications/\(folderName)", directoryHint: .isDirectory) }
    public static func legacyLaunchersDir(home: URL) -> URL { home.appending(path: "Applications/\(legacyFolderName)", directoryHint: .isDirectory) }

    /// The new folder if it exists; else the legacy one if it is a real directory (a symbolic link, such as the one
    /// `LegacyMigration` leaves behind, doesn't count); else the new one, for a fresh install.
    static func resolveRoot(new: URL, legacy: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: new.path, isDirectory: &isDirectory), isDirectory.boolValue { return new }
        return isRealDirectory(legacy) ? legacy : new
    }

    /// A directory itself, not a symbolic link to one.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether Baton still uses a folder of its earlier name because it hasn't been moved yet.
    public var usesLegacyFolders: Bool {
        stateDir == Self.legacyStateDir(home: home) || launchersDir == Self.legacyLaunchersDir(home: home)
    }

    /// Data directory of the main Claude Desktop app (the one you open from /Applications).
    public var mainDataDir: URL { applicationSupport.appending(path: "Claude", directoryHint: .isDirectory) }

    /// Claude Code's own folder: settings, file checkpoints and the list of its running processes.
    public var claudeDir: URL { home.appending(path: ".claude", directoryHint: .isDirectory) }
    /// Claude Code conversations (`<folder>/<session>.jsonl`), shared by every Claude window on this Mac.
    public var claudeProjectsDir: URL { claudeDir.appending(path: "projects", directoryHint: .isDirectory) }
    /// Claude Code's own settings, one Mac-wide file; see `CloudMoveLock`.
    public var claudeSettingsFile: URL { claudeDir.appending(path: "settings.json") }

    public var registryFile: URL { stateDir.appending(path: "profiles.json") }
    /// What was carried into sessions Claude Desktop copied itself; see `NativeForkCarry`.
    public var carriedFile: URL { stateDir.appending(path: "carried.json") }
    /// Local only's choices and the values it replaced in each window; see `LocalOnly`.
    public var localOnlyFile: URL { stateDir.appending(path: "local-only.json") }
    public var backupsDir: URL { stateDir.appending(path: "Backups", directoryHint: .isDirectory) }
    /// Histories and files prepared for continuing a conversation in another profile.
    public var handoffsDir: URL { stateDir.appending(path: "Handoffs", directoryHint: .isDirectory) }

    /// Each profile's Claude Desktop data (sign-in, windows, caches) lives in its own directory here.
    public var profilesDir: URL { stateDir.appending(path: "Profiles", directoryHint: .isDirectory) }
    public func dataDir(for id: String) -> URL { profilesDir.appending(path: id, directoryHint: .isDirectory) }

    public func launcher(for profile: Profile) -> URL { launchersDir.appending(path: "Claude \(profile.label).app", directoryHint: .isDirectory) }

    /// Engines are the APFS clones of Claude.app that actually run. Hidden: open them via launchers.
    public var enginesDir: URL { launchersDir.appending(path: ".engines", directoryHint: .isDirectory) }
    public func engine(for id: String) -> URL { enginesDir.appending(path: "Claude \(id).app", directoryHint: .isDirectory) }
}
