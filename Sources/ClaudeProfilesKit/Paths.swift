import Foundation

/// Every location Claude Profiles reads or writes. Injected everywhere so tests can run in a sandbox.
public struct Paths: Sendable, Equatable {
    /// The user's home directory.
    public var home: URL
    /// The official Claude Desktop app. Profiles run APFS clones of it.
    public var claudeApp: URL
    /// Where Claude Code keeps each session's scratchpad and background task output
    /// (`<claudeTempDir>/<folder>/<session>/{scratchpad,tasks}`). The system may clear it at restart.
    public var claudeTempDir: URL

    /// - Parameter claudeTempDir: by default a folder inside `home`, so a sandboxed `home` never reaches the real one.
    public init(home: URL, claudeApp: URL, claudeTempDir: URL? = nil) {
        self.home = home
        self.claudeApp = claudeApp
        self.claudeTempDir = claudeTempDir ?? home.appending(path: "tmp/claude", directoryHint: .isDirectory)
    }

    public static var standard: Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser,
              claudeApp: URL(fileURLWithPath: "/Applications/Claude.app"),
              claudeTempDir: URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true))
    }

    public var applicationSupport: URL { home.appending(path: "Library/Application Support", directoryHint: .isDirectory) }

    /// Data directory of the main Claude Desktop app (the one you open from /Applications).
    public var mainDataDir: URL { applicationSupport.appending(path: "Claude", directoryHint: .isDirectory) }

    /// Claude Code's own folder: settings, file checkpoints and the list of its running processes.
    public var claudeDir: URL { home.appending(path: ".claude", directoryHint: .isDirectory) }
    /// Claude Code conversations (`<folder>/<session>.jsonl`), shared by every Claude window on this Mac.
    public var claudeProjectsDir: URL { claudeDir.appending(path: "projects", directoryHint: .isDirectory) }

    /// Claude Profiles's own state: profile registry and backups.
    public var stateDir: URL { applicationSupport.appending(path: "Claude Profiles", directoryHint: .isDirectory) }
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

    /// Launchers are visible in Finder, Spotlight and Launchpad and can be kept in the Dock.
    public var launchersDir: URL { home.appending(path: "Applications/Claude Profiles", directoryHint: .isDirectory) }
    public func launcher(for profile: Profile) -> URL { launchersDir.appending(path: "Claude \(profile.label).app", directoryHint: .isDirectory) }

    /// Engines are the APFS clones of Claude.app that actually run. Hidden: open them via launchers.
    public var enginesDir: URL { launchersDir.appending(path: ".engines", directoryHint: .isDirectory) }
    public func engine(for id: String) -> URL { enginesDir.appending(path: "Claude \(id).app", directoryHint: .isDirectory) }
}
