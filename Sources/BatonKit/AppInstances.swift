import Foundation

/// Baton installed or running more than once. Two copies (say `make install` into ~/Applications and the
/// Homebrew cask in /Applications) would each sync sessions and rebuild launchers, so only one may run at a time.
public enum AppInstances {
    public static let bundleID = "io.github.trukhinyuri.claudeprofiles"

    /// Where the Homebrew cask and `make install` put the app: `scripts/install-app.sh` puts it next to the launchers,
    /// in ~/Applications/Baton or, until Baton moves that folder, ~/Applications/Claude Profiles.
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
}
