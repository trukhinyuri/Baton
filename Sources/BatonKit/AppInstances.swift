import Foundation

/// Baton installed or running more than once. Two copies (say `make install` into ~/Applications and the
/// Homebrew cask in /Applications) would each sync sessions and rebuild launchers, so only one may run at a time.
public enum AppInstances {
    public static let bundleID = "io.github.trukhinyuri.claudeprofiles"

    /// Where the Homebrew cask and `make install` put the app: `scripts/install-app.sh` puts it next to the launchers,
    /// in ~/Applications/Baton or, until Baton renames that folder, ~/Applications/Claude Profiles.
    public static var standardFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications"), Paths.newLaunchersDir(home: home),
            Paths.legacyLaunchersDir(home: home),
        ]
    }

    /// Every `*.app` directly inside `folders` whose Info.plist names `bundleID`, in folder order.
    public static func installedCopies(of bundleID: String = bundleID, in folders: [URL] = standardFolders) -> [URL] {
        folders.flatMap { folder in
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            return names.filter { $0.hasSuffix(".app") }.map { folder.appending(path: $0) }.filter { app in
                guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
                    let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return false }
                return info["CFBundleIdentifier"] as? String == bundleID
            }
        }
    }

    /// What to tell the user when more than one copy is installed; `nil` for one or none.
    public static func duplicateWarning(_ copies: [URL]) -> String? {
        guard copies.count > 1 else { return nil }
        return "Baton is installed \(copies.count) times: " + copies.map(\.path).joined(separator: ", ")
            + ". Keep one and move the others to the Trash, so two copies never share sessions at once."
    }

    /// The copy already running that a newly started one hands over to, if any.
    public static func otherInstance(running pids: [pid_t], me: pid_t) -> pid_t? {
        pids.first { $0 != me }
    }

    /// Another running copy with Baton's bundle id.
    public struct RunningCopy: Sendable, Equatable {
        public var pid: pid_t
        public var bundle: URL?
        /// Its `CFBundleShortVersionString`, read from its bundle on disk.
        public var version: String?

        public init(pid: pid_t, bundle: URL?, version: String?) {
            self.pid = pid
            self.bundle = bundle
            self.version = version
        }
    }

    /// A copy a newly started Baton replaces instead of handing over to: the app before 1.0 (`Claude Profiles.app`),
    /// a copy running from the Trash, or an older version.
    public static func isOutdated(_ copy: RunningCopy, currentVersion: String) -> Bool {
        if let bundle = copy.bundle?.standardizedFileURL {
            if bundle.lastPathComponent == LegacyMigration.legacyAppName || bundle.path.contains("/.Trash/") { return true }
        }
        guard let version = copy.version else { return false }
        return isVersion(version, below: currentVersion)
    }

    /// What a newly started copy does about the others: quit the outdated ones (see `isOutdated`), then bring a
    /// current one forward and quit itself, or keep starting if there is none.
    public static func handover(others: [RunningCopy], currentVersion: String) -> Handover {
        let outdated = others.filter { isOutdated($0, currentVersion: currentVersion) }
        return Handover(terminate: outdated.map(\.pid), handOverTo: others.first { !isOutdated($0, currentVersion: currentVersion) }?.pid)
    }

    /// The outdated copies to quit, and the current copy to hand over to, if any.
    public struct Handover: Sendable, Equatable {
        public var terminate: [pid_t]
        public var handOverTo: pid_t?

        public init(terminate: [pid_t], handOverTo: pid_t?) {
            self.terminate = terminate
            self.handOverTo = handOverTo
        }
    }

    /// Compares dotted version numbers part by part, missing parts as 0. A version that isn't numbers, such as `dev`,
    /// is below none and nothing is below it.
    static func isVersion(_ version: String, below other: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let numbers = text.split(separator: ".").map { Int($0) }
            return numbers.isEmpty || numbers.contains(nil) ? nil : numbers.compactMap { $0 }
        }
        guard let lhs = parts(version), let rhs = parts(other) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let (a, b) = (index < lhs.count ? lhs[index] : 0, index < rhs.count ? rhs[index] : 0)
            if a != b { return a < b }
        }
        return false
    }

    /// `CFBundleShortVersionString` of the app at `bundle`, read from disk.
    public static func version(of bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}
