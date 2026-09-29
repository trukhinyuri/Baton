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
    /// Baton's own state: profile registry, every profile's data and backups. `~/Library/Application Support/Baton`,
    /// or for people upgrading from Claude Profiles the folder of that name, used where it is and never moved
    /// (see `stateRoot(home:)` and docs/adr/0007-baton-rename.md).
    public var stateDir: URL
    /// Launchers are visible in Finder, Spotlight and Launchpad and can be kept in the Dock. `~/Applications/Baton`,
    /// or the Claude Profiles folder until `LegacyMigration` renames it (see `launchersRoot(home:)`).
    public var launchersDir: URL

    /// Resolves `stateDir` and `launchersDir` now: build `Paths` after `LegacyMigration` has run.
    /// - Parameter claudeTempDir: by default a folder inside `home`, so a sandboxed `home` never reaches the real one.
    public init(home: URL, claudeApp: URL, claudeTempDir: URL? = nil) {
        self.home = home
        self.claudeApp = claudeApp
        self.claudeTempDir = claudeTempDir ?? home.appending(path: "tmp/claude", directoryHint: .isDirectory)
        stateDir = Self.stateRoot(home: home)
        launchersDir = Self.launchersRoot(home: home)
    }

    public static var standard: Paths { standard(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// This Mac's Claude Desktop and Claude Code temporary folder, with Baton's folders under `home`.
    public static func standard(home: URL) -> Paths {
        Paths(
            home: home,
            claudeApp: findClaude(home: home, lookup: launchServicesApps),
            claudeTempDir: URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true))
    }

    /// Claude Desktop as Anthropic signs it: in /Applications, else in ~/Applications, else wherever else Launch
    /// Services has it, except on a read-only disk, such as the disk image Claude comes on; a copy on a disk image
    /// mounted for writing counts. Profile engines and launchers carry its bundle id too and are never taken for it,
    /// nor is a copy in the Trash, one macOS runs from a temporary place, or one Anthropic didn't sign, such as a
    /// lookalike in Downloads.
    /// - Parameter isSignedByAnthropic: `ClaudeSource.isSignedByAnthropic` unless a test substitutes it.
    /// - Returns: `/Applications/Claude.app` when there is no such Claude anywhere, so the error names the usual place.
    ///   Whatever is there then is not opened: `ProfileManager.openMain` and `startUpChecks` check the signature.
    public static func findClaude(
        home: URL, systemApplications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        lookup: (String) -> [URL], isSignedByAnthropic: (URL) -> Bool = ClaudeSource.isSignedByAnthropic
    ) -> URL {
        // Under either name: a copy in the folder Baton doesn't use now is still one of its own.
        let own = [newLaunchersDir(home: home), legacyLaunchersDir(home: home)].map { $0.standardizedFileURL.path + "/" }
        func isClaude(_ app: URL) -> Bool {
            let path = app.standardizedFileURL.path
            guard !own.contains(where: path.hasPrefix), !path.contains("/.Trash/"), !path.contains("/AppTranslocation/") else { return false }
            return ClaudeVersion.bundleInfo(at: app)?["CFBundleIdentifier"] as? String == ClaudeVersion.bundleIdentifier
                && isSignedByAnthropic(app)
        }
        let installed = [systemApplications.appending(path: "Claude.app"), home.appending(path: "Applications/Claude.app")]
        let elsewhere = lookup(ClaudeVersion.bundleIdentifier).filter {
            (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
        }
        return (installed + elsewhere).first(where: isClaude) ?? systemApplications.appending(path: "Claude.app", directoryHint: .isDirectory)
    }

    /// Launch Services' preferred copy first, then every other copy it knows.
    static func launchServicesApps(_ bundleIdentifier: String) -> [URL] {
        let workspace = NSWorkspace.shared
        return [workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)].compactMap { $0 }
            + workspace.urlsForApplications(withBundleIdentifier: bundleIdentifier)
    }

    public var applicationSupport: URL { Self.applicationSupport(home: home) }

    // MARK: Baton's own folders under both names

    /// The folder name before 1.0 (see docs/adr/0007-baton-rename.md).
    public static let legacyFolderName = "Claude Profiles"
    public static let folderName = "Baton"

    static func applicationSupport(home: URL) -> URL { home.appending(path: "Library/Application Support", directoryHint: .isDirectory) }
    public static func newStateDir(home: URL) -> URL { applicationSupport(home: home).appending(path: folderName, directoryHint: .isDirectory) }
    public static func legacyStateDir(home: URL) -> URL { applicationSupport(home: home).appending(path: legacyFolderName, directoryHint: .isDirectory) }
    public static func newLaunchersDir(home: URL) -> URL { home.appending(path: "Applications/\(folderName)", directoryHint: .isDirectory) }
    public static func legacyLaunchersDir(home: URL) -> URL { home.appending(path: "Applications/\(legacyFolderName)", directoryHint: .isDirectory) }

    /// Baton's data folder: the Baton one if it exists; else, for someone upgrading from Claude Profiles, the folder of
    /// that name if anything is there, a link included (say to another disk), even one that leads nowhere right now;
    /// else the Baton one, for a fresh install. A link that leads nowhere is never replaced by a new, empty Baton
    /// folder: `unreachableFolder(home:)` says so, and Baton stops until it leads somewhere again.
    /// Never renamed: absolute paths inside it live in Claude's own data, session cards and Claude Code's project keys.
    public static func stateRoot(home: URL) -> URL { resolve(new: newStateDir(home: home), legacy: legacyStateDir(home: home)) }

    /// The launchers folder: the Baton one if it exists; else the Claude Profiles one if anything is there, until
    /// `LegacyMigration` renames it; else the Baton one.
    public static func launchersRoot(home: URL) -> URL { resolve(new: newLaunchersDir(home: home), legacy: legacyLaunchersDir(home: home)) }

    static func resolve(new: URL, legacy: URL) -> URL {
        if isDirectory(new) { return new }
        return exists(legacy) ? legacy : new
    }

    /// A plain line when Baton's data or launchers folder is a link of the earlier name that leads nowhere right now
    /// (a disk that isn't connected, say), `nil` otherwise. The CLI stops with it and the app shows it instead of
    /// starting a new, empty folder that would then win for good.
    public static func unreachableFolder(home: URL) -> String? {
        let folders = [
            ("Baton's data folder", newStateDir(home: home), legacyStateDir(home: home)),
            ("Baton's folder of launchers", newLaunchersDir(home: home), legacyLaunchersDir(home: home)),
        ]
        for (name, new, legacy) in folders where !isDirectory(new) && exists(legacy) && !isDirectory(legacy) {
            let shown = display(legacy, home: home)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) else {
                return "\(name) \(shown) isn't a folder. Move it aside and try again."
            }
            return "\(name) \(shown) links to \(target), which isn't there right now. Connect it and try again; Baton doesn't start a new folder in its place."
        }
        return nil
    }

    /// Anything at `url`, a link that leads nowhere included.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// `~/…` for a path inside `home`.
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, root = home.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }

    /// A folder, or a link that leads to one.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether Baton still uses the launchers folder of its earlier name because it hasn't been renamed yet.
    public var usesLegacyLaunchersFolder: Bool { launchersDir == Self.legacyLaunchersDir(home: home) }

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
