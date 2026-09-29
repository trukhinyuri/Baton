import Darwin
import Foundation
import MachO

/// Claude's and Anthropic's settings in the environment Baton was started with. Baton reads none of them itself (it
/// reads only `BATON_DEMO`, `BATON_DEMO_SHEET` and `BATON_DEMO_SNAPSHOT`), and every Claude window it opens must use
/// its own account and settings, not the ones of the terminal or Claude Code session that happened to start Baton.
public enum InheritedEnvironment {
    /// A variable Claude or Anthropic tools read: its name starts with `CLAUDE` or `ANTHROPIC_`.
    public static func isRemoved(_ name: String) -> Bool {
        name.hasPrefix("CLAUDE") || name.hasPrefix("ANTHROPIC_")
    }

    /// `variables` without the ones `isRemoved` names. Everything else, `PATH` and `HOME` included, is kept.
    public static func scrubbed(_ variables: [String: String]) -> [String: String] {
        variables.filter { !isRemoved($0.key) }
    }

    /// Removes those variables from this process, so nothing it starts inherits them. Called first thing in the app
    /// and in `baton`, before any other thread runs.
    public static func scrub() {
        for name in ProcessInfo.processInfo.environment.keys where isRemoved(name) { unsetenv(name) }
    }
}

/// The running executable's own path, links resolved.
public enum RunningExecutable {
    /// From the kernel's record of what was started, not from `argv[0]`, which the caller chooses and which is only a
    /// name when `baton` was found through `PATH`. `nil` if it can't be read.
    public static func url() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return resolved(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// `path` with every link and `..` resolved, `nil` if it doesn't exist.
    public static func resolved(_ path: String) -> URL? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }
}

/// What the `baton` command line has to set up before it runs a command.
public enum CLIDispatch {
    public enum Stage: Equatable, Sendable {
        /// `--version`, `--help` and the build's icon rendering: answered before any path is resolved or anything is read.
        case early
        /// `baton migrate`: renames the launchers folder before `Paths` is built.
        case migrate
        /// Everything else builds a `ProfileManager`; `sharedLock` is true for the commands that open windows or build
        /// launchers or engines, which hold `LegacyMigration.lockFile` so the folder is never renamed under them.
        case manager(sharedLock: Bool)
    }

    /// The commands that open windows or build launchers or engines, after aliases are resolved.
    public static let lockedCommands: Set<String> = ["open", "add", "refresh", "continue", "remove"]

    /// Whether `args` is a command that only reads: `list`, `doctor`, `report`, `conversations`, `rules` and the
    /// `local-only` statuses. They skip the start-up re-registration of the main Claude with Launch Services, so
    /// looking into why `claude://` links go to the wrong window never changes where they go.
    public static func isReadOnly(_ args: [String]) -> Bool {
        switch args.first {
        case nil, "list", "doctor", "report", "conversations", "rules": true
        case "local-only": args.dropFirst().first == "status" || args.dropFirst().prefix(2) == ["cloud-lock", "status"]
        case "handover": args.dropFirst().prefix(2) == ["auto", "status"]
        default: false
        }
    }

    /// - Parameter args: the arguments after the command name, aliases resolved. `--help` or `-h` anywhere answers
    /// with the help text before anything is read or changed.
    public static func stage(for args: [String]) -> Stage {
        if args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) { return .early }
        return switch args.first {
        case "--version", "version", "help", "-h", "--help", "__render-app-icon": .early
        case "migrate": .migrate
        case let command?: .manager(sharedLock: lockedCommands.contains(command))
        case nil: .manager(sharedLock: false)
        }
    }

    /// Answers an `.early` command: its output and exit status. Reads no profile and builds no `ProfileManager`.
    /// - Parameter usage: the help text.
    public static func runEarly(_ args: [String], usage: String) -> (output: String, error: String?, exitCode: Int32) {
        switch args.first {
        case "--version", "version": return (BuildInfo.current.description, nil, 0)
        case "__render-app-icon":  // used by scripts/build-app.sh
            guard args.count >= 2 else { return ("", "__render-app-icon needs an output path", 1) }
            let url = URL(fileURLWithPath: args[1])
            let data =
                url.pathExtension == "png" ? IconRenderer.pngData(IconRenderer.appIcon(), pixels: 1024) : IconRenderer.icnsData(for: IconRenderer.appIcon())
            do {
                guard let data else { return ("", "couldn't render the icon", 1) }
                try data.write(to: url)
                return ("", nil, 0)
            } catch { return ("", error.localizedDescription, 1) }
        default: return (usage, nil, 0)
        }
    }
}
