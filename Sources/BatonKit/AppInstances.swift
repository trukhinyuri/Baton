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
        /// Its version, read from its bundle on disk (see `version(of:)`).
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

    /// Compares dotted version numbers part by part, missing parts as 0, then a prerelease suffix as SemVer does:
    /// `1.0.0-rc.1` is below `1.0.0-rc.2`, which is below `1.0.0`. A version that isn't numbers, such as `dev`, is below
    /// none and nothing is below it.
    static func isVersion(_ version: String, below other: String) -> Bool {
        func parts(_ text: String) -> (numbers: [Int], prerelease: [Substring]?)? {
            let dash = text.firstIndex(of: "-")
            let numbers = text[..<(dash ?? text.endIndex)].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
            guard let dash else { return (numbers.compactMap { $0 }, nil) }
            let prerelease = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            return prerelease.contains(where: \.isEmpty) ? nil : (numbers.compactMap { $0 }, prerelease)
        }
        guard let lhs = parts(version), let rhs = parts(other) else { return false }
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let (a, b) = (index < lhs.numbers.count ? lhs.numbers[index] : 0, index < rhs.numbers.count ? rhs.numbers[index] : 0)
            if a != b { return a < b }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (.some, nil): return true
        case (.some(let a), .some(let b)):
            for (x, y) in zip(a, b) where x != y {
                switch (Int(x), Int(y)) {
                case (let m?, let n?): return m < n
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return x < y
                }
            }
            return a.count < b.count
        }
    }

    /// Baton's version of the app at `bundle`, read from disk: `BatonVersion`, which keeps a suffix such as `-rc.1`,
    /// or `CFBundleShortVersionString` for a build made before that key existed.
    public static func version(of bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["BatonVersion"] as? String ?? info["CFBundleShortVersionString"] as? String
    }
}
