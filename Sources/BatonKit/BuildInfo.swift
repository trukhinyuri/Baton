import Foundation

/// Version and commit of this build, read from the enclosing `Baton.app` so the app and the helper
/// inside it always report the same thing. A build run outside an app bundle (`swift run`) reports "dev".
public struct BuildInfo: Equatable, Sendable {
    public var version: String
    public var commit: String

    public static let current = BuildInfo.read(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))

    /// The line `--version` prints and the problem report starts with.
    public var description: String { "Baton \(version) (\(commit))" }

    /// Walks up from the executable to the nearest `*.app` and reads its `Contents/Info.plist`.
    public static func read(executable: URL) -> BuildInfo {
        var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if dir.pathExtension == "app" {
                let plist = dir.appending(path: "Contents/Info.plist")
                if let data = try? Data(contentsOf: plist),
                    let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                {
                    return BuildInfo(
                        // BatonVersion is the full version, with a suffix such as -rc.1; Apple's keys hold only the
                        // numbers. Builds made before it existed have only CFBundleShortVersionString.
                        version: info["BatonVersion"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "dev",
                        // Builds made before the rename recorded ClaudeProfilesCommit.
                        commit: info["BatonCommit"] as? String ?? info["ClaudeProfilesCommit"] as? String ?? "dev")
                }
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return BuildInfo(version: "dev", commit: "dev")
    }
}
