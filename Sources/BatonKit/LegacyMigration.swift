import Darwin
import Foundation

/// Renames Baton's launchers folder from its name before 1.0, `~/Applications/Claude Profiles`, to
/// `~/Applications/Baton`, and updates the launchers inside it in place. See docs/adr/0007-baton-rename.md.
///
/// Only the launchers folder, the one people see, is renamed. The data folder in Application Support keeps the name it
/// has (`Paths.stateRoot`): absolute paths inside it live in Claude's own data, in session cards and in Claude Code's
/// project keys. Runs at app start before `Paths` is built, from `baton migrate` and from `scripts/install-app.sh`;
/// no other command renames anything. One `rename(2)`, only while nothing runs from the folder; what is kept this
/// time is retried at the next start.
public enum LegacyMigration {
    /// Why the launchers folder kept its old name this time.
    public enum Reason: Sendable, Hashable {
        /// A Claude window or a launcher runs from the old folder, or a Claude window uses a profile's data.
        case claudeRunning
        /// Another Baton or `baton` command runs: it has the old path and could recreate the old folder.
        case batonRunning
        /// Baton runs from inside the old folder (this bundle), so it can't rename it itself.
        case appInsideLegacyFolder(URL)
        /// The rename would cross volumes (the old folder is a mount point), and Baton never copies it.
        case differentVolume
        /// Another `baton` command that opens windows or builds launchers was running, or another rename didn't finish in time.
        case busy
        /// `rename(2)` failed for another reason, in its words.
        case renameFailed(String)
    }

    /// What a finished rename did.
    public struct Moved: Sendable, Equatable {
        public var launchersDir: URL
        /// Launchers updated in place, keeping their bundle folder so Dock and Finder items still find them.
        public var rewrittenLaunchers: Int
        /// An old `Claude Profiles.app` that came along went to the Trash.
        public var trashedOldApp: Bool
        /// Follow-ups that failed after the rename: a launcher not updated, the old app not trashed. Shown as a warning.
        public var problems: [String]

        public init(launchersDir: URL, rewrittenLaunchers: Int = 0, trashedOldApp: Bool = false, problems: [String] = []) {
            self.launchersDir = launchersDir
            self.rewrittenLaunchers = rewrittenLaunchers
            self.trashedOldApp = trashedOldApp
            self.problems = problems
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// No old folder, or it was renamed already, perhaps by another process while this one waited.
        case nothingToDo
        /// Both names exist. Baton uses the new one and leaves the old one alone.
        case bothExist(new: URL, legacy: URL)
        case migrated(Moved)
        case kept(Reason)
        /// Nothing was renamed.
        case failed(String)

        /// `baton migrate`'s exit status: 0 renamed or nothing to do, 3 kept for now, 1 error.
        public var exitCode: Int32 {
            switch self {
            case .nothingToDo, .bothExist, .migrated: 0
            case .kept: 3
            case .failed: 1
            }
        }
    }

    /// A process of this Mac, as far as it can be read: its parent, its executable and, for this user's processes,
    /// its arguments.
    public struct RunningProcess: Sendable, Equatable {
        public var pid: pid_t
        public var parent: pid_t?
        public var executable: String?
        public var arguments: [String]?

        public init(pid: pid_t, parent: pid_t? = nil, executable: String?, arguments: [String]? = nil) {
            self.pid = pid
            self.parent = parent
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Everything the rename reads from or does to the system, so tests run in a temporary folder only.
    public struct Environment: Sendable {
        public var processes: @Sendable () -> [RunningProcess]
        /// Renames a folder; fails if something is already at the destination.
        public var rename: @Sendable (URL, URL) throws -> Void
        public var trash: @Sendable (URL) throws -> Void
        /// Updates every profile's launcher in place after the rename, writing `cli` into them.
        /// - Returns: how many were updated, and a plain line for each that wasn't.
        public var rewriteLaunchers: @Sendable (_ home: URL, _ cli: URL?) -> (rewritten: Int, problems: [String])
        /// The migrating process. It and its ancestors never count as running from the old folder.
        public var pid: pid_t
        /// How long to wait for the lock when another `baton` command holds it.
        public var lockWait: TimeInterval

        public init(
            processes: @escaping @Sendable () -> [RunningProcess], rename: @escaping @Sendable (URL, URL) throws -> Void,
            trash: @escaping @Sendable (URL) throws -> Void,
            rewriteLaunchers: @escaping @Sendable (_ home: URL, _ cli: URL?) -> (rewritten: Int, problems: [String]),
            pid: pid_t = getpid(), lockWait: TimeInterval = 3
        ) {
            self.processes = processes
            self.rename = rename
            self.trash = trash
            self.rewriteLaunchers = rewriteLaunchers
            self.pid = pid
            self.lockWait = lockWait
        }

        public static var live: Environment {
            Environment(
                processes: LegacyMigration.liveProcesses, rename: LegacyMigration.renameExclusive,
                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                rewriteLaunchers: { home, cli in ProfileManager(paths: .standard(home: home), cliPath: cli).rewriteLaunchersInPlace() })
        }
    }

    /// The name of Baton's app before 1.0. An old copy is never kept in the renamed folder.
    public static let legacyAppName = "Claude Profiles.app"

    /// Taken exclusively while the folder is checked and renamed, and shared by every `baton` command that opens
    /// windows or builds launchers or engines. Inside the data folder, which never moves.
    public static func lockFile(home: URL) -> URL { Paths.stateRoot(home: home).appending(path: ".baton-migration.lock") }

    // MARK: Renaming

    /// At app start: renames the folder if that is safe now. `nil` in demo mode, which never renames or writes anything.
    /// - Parameter variables: the process environment, read for `BATON_DEMO`.
    public static func atAppStart(
        home: URL, app: URL, cli: URL?, variables: [String: String], environment: Environment = .live
    ) -> Outcome? {
        guard !DemoMode.isOn(variables) else { return nil }
        return run(home: home, app: app, cli: cli, environment: environment)
    }

    /// Renames the launchers folder if that is safe now, then updates the launchers in it in place.
    /// - Parameters:
    ///   - app: the running app's bundle at app start; `nil` for the CLI, which may run from inside the old folder
    ///     because it is one loaded binary.
    ///   - cli: the `baton` executable, links resolved, that launchers call. When it lies inside the renamed folder,
    ///     launchers get its path after the rename.
    public static func run(home: URL, app: URL? = nil, cli: URL? = nil, environment: Environment = .live) -> Outcome {
        // A quick look first, so a fresh or already renamed install gets no lock file.
        if let settled = settled(home: home) { return settled }
        if let app, isInside(app.path, Paths.legacyLaunchersDir(home: home).path) { return .kept(.appInsideLegacyFolder(app)) }

        let lock: Int32
        switch acquire(lockFile(home: home), wait: environment.lockWait, shared: false) {
        case .held(let descriptor): lock = descriptor
        // Another command runs, or another rename is under way; whatever it left is the answer if it finished.
        case .busy: return settled(home: home) ?? .kept(.busy)
        case .failed(let reason):
            return .failed("Couldn't take the lock for renaming Baton's folder in ~/Applications: \(reason). Nothing was renamed.")
        }
        defer { release(lock) }

        // The process that held the lock may have renamed it already.
        if let settled = settled(home: home) { return settled }
        // Read right before the rename, under the lock, so nothing that started while this one waited is missed.
        if let reason = blocker(home: home, app: app, environment: environment) { return .kept(reason) }

        let legacy = Paths.legacyLaunchersDir(home: home), new = Paths.newLaunchersDir(home: home)
        let launcherCLI = cli.map { afterRename($0, home: home) }
        do { try environment.rename(legacy, new) } catch {
            if (error as? POSIXError)?.code == .EXDEV { return .kept(.differentVolume) }
            return .kept(.renameFailed(error.localizedDescription))
        }
        let rewrite = environment.rewriteLaunchers(home, launcherCLI)
        var moved = Moved(launchersDir: new, rewrittenLaunchers: rewrite.rewritten, problems: rewrite.problems)
        // The old app came along inside the folder. Baton.app replaces it, and one copy at a time may run.
        let oldApp = new.appending(path: legacyAppName, directoryHint: .isDirectory)
        if isRealDirectory(oldApp), bundleIdentifier(of: oldApp) == AppInstances.bundleID {
            do {
                try environment.trash(oldApp)
                moved.trashedOldApp = true
            } catch {
                moved.problems.append(
                    "Couldn't move the old \(legacyAppName) in \(display(new, home: home)) to the Trash: \(error.localizedDescription). Move it there yourself; Baton.app replaces it."
                )
            }
        }
        Log.notice("migration", "Renamed the launchers folder from its old name")
        return .migrated(moved)
    }

    /// The answer when there is nothing to rename, `nil` while the old folder waits for its rename.
    static func settled(home: URL) -> Outcome? {
        let legacy = Paths.legacyLaunchersDir(home: home), new = Paths.newLaunchersDir(home: home)
        guard Paths.isDirectory(legacy) else { return .nothingToDo }
        return exists(new) ? .bothExist(new: new, legacy: legacy) : nil
    }

    /// Where `cli` will be after the rename: mapped into the new folder when it lies inside the old one.
    static func afterRename(_ cli: URL, home: URL) -> URL {
        let legacy = Paths.legacyLaunchersDir(home: home)
        let path = cli.standardizedFileURL.path
        // As written and, for a real folder (not a link, whose target stays put), with links resolved.
        var roots = [legacy.standardizedFileURL.path]
        if isRealDirectory(legacy), let real = realPath(legacy) { roots.append(real) }
        for root in roots where isInside(path, root) {
            let rest = String(path.dropFirst(root.count))
            let parent = (root as NSString).deletingLastPathComponent
            return URL(fileURLWithPath: parent + "/" + Paths.folderName + rest)
        }
        return cli
    }

    // MARK: Checking

    /// Anything at `url`, a dangling link included.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// A directory itself, not a symbolic link to one.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Why renaming isn't safe right now, or `nil` if it is. Reads the process list; takes no lock and changes nothing.
    ///
    /// Counts any process with its executable inside the old folder (engines and their helpers, another Baton), a
    /// launcher's script run by a shell, any process with `--user-data-dir` inside the data folder's profiles, and any
    /// other Baton or Claude Profiles app or CLI. The migrating process and its ancestors never count: a shell that only
    /// names the folder in its arguments, such as `scripts/install-app.sh`, doesn't keep it.
    static func blocker(home: URL, app: URL?, environment: Environment) -> Reason? {
        let legacy = Paths.legacyLaunchersDir(home: home)
        if let app, isInside(app.path, legacy.path) { return .appInsideLegacyFolder(app) }
        let launchers = roots(legacy)
        let profiles = roots(Paths.stateRoot(home: home).appending(path: "Profiles", directoryHint: .isDirectory))

        let processes = environment.processes()
        let excluded = ancestors(of: environment.pid, in: processes)
        var found: [Reason] = []
        for process in processes where !excluded.contains(process.pid) {
            if let executable = process.executable {
                let baton = batonBundle(of: executable)
                if launchers.contains(where: { isInside(executable, $0) }) {
                    found.append(baton.map { .appInsideLegacyFolder($0) } ?? .claudeRunning)
                    continue
                }
                if baton != nil {
                    found.append(.batonRunning)
                    continue
                }
            }
            guard let arguments = process.arguments else { continue }
            if let dataDir = ProcessArguments.userDataDir(in: arguments), profiles.contains(where: { isInside(dataDir, $0) }) {
                found.append(.claudeRunning)
            } else if isShell(process.executable), arguments.count >= 2, launchers.contains(where: { isInside(arguments[1], $0) }) {
                found.append(.claudeRunning)  // a launcher's script, run by `sh`
            }
        }
        for reason in found {
            if case .appInsideLegacyFolder = reason { return reason }
        }
        return [.claudeRunning, .batonRunning].first(where: found.contains)
    }

    /// `pid` and every process it descends from.
    static func ancestors(of pid: pid_t, in processes: [RunningProcess]) -> Set<pid_t> {
        let parents = Dictionary(processes.map { ($0.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var result: Set<pid_t> = [pid]
        var current = pid
        while let parent = parents[current] ?? nil, parent > 0, result.insert(parent).inserted {
            current = parent
        }
        return result
    }

    /// A folder as written and with links resolved: the process list names executables by their real path.
    static func roots(_ url: URL) -> [String] {
        let written = url.standardizedFileURL.path
        guard let real = realPath(url), real != written else { return [written] }
        return [written, real]
    }

    static func isShell(_ executable: String?) -> Bool {
        guard let executable else { return false }
        return ["sh", "bash", "zsh", "dash", "ksh"].contains((executable as NSString).lastPathComponent)
    }

    /// The app bundle of Baton's app or CLI, under either name, wherever it is installed: an executable at one of these
    /// places inside an app bundle whose Info.plist names Baton's bundle id (which the rename kept), so another app
    /// called Baton doesn't count. `nil` for anything else.
    static func batonBundle(of executable: String) -> URL? {
        guard let bundle = bundle(containing: executable), bundleIdentifier(of: bundle) == AppInstances.bundleID else { return nil }
        return bundle
    }

    /// The app bundle around Baton's app or CLI executable at `executable`, by where it sits in the bundle.
    static func bundle(containing executable: String) -> URL? {
        let places = ["/Contents/MacOS/Baton", "/Contents/Helpers/baton", "/Contents/MacOS/ClaudeProfiles", "/Contents/Helpers/claude-profiles"]
        guard let place = places.first(where: executable.hasSuffix) else { return nil }
        return URL(fileURLWithPath: String(executable.dropLast(place.count)), isDirectory: true)
    }

    /// The path with every link resolved, `nil` if it doesn't exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` is `root` or inside it. Case-insensitive, as the default macOS volume is.
    static func isInside(_ path: String, _ root: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let root = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: What doctor, the status panel and `baton migrate` say

    /// Plain lines for `baton doctor` and the status panel while the launchers folder has its old name, or both
    /// names exist. Empty once it is renamed. Reads the process list but changes nothing.
    /// - Parameters:
    ///   - app: the running app's bundle, `nil` for the CLI.
    ///   - cli: the running `baton`, links resolved: when it is inside the old folder, the line names it.
    public static func notes(paths: Paths, app: URL? = nil, cli: URL? = nil, environment: Environment = .live) -> [String] {
        launcherNotes(paths: paths, app: app, cli: cli, environment: environment) + dataFolderNote(home: paths.home)
    }

    /// A line when both data folders exist and the one of the earlier name still has profiles: Baton uses the Baton
    /// one, so those profiles don't show. Nothing otherwise.
    static func dataFolderNote(home: URL) -> [String] {
        let new = Paths.newStateDir(home: home), legacy = Paths.legacyStateDir(home: home)
        guard Paths.isDirectory(new), FileManager.default.fileExists(atPath: legacy.appending(path: "profiles.json").path) else { return [] }
        let (shown, old) = (display(new, home: home), display(legacy, home: home))
        return [
            "Both \(shown) and \(old) exist, and \(old) still has profiles. Baton uses \(shown) and leaves the other alone; with Baton quit, move whichever you don't need to the Trash."
        ]
    }

    private static func launcherNotes(paths: Paths, app: URL?, cli: URL?, environment: Environment) -> [String] {
        let home = paths.home
        switch settled(home: home) {
        case .bothExist(let new, let legacy)?: return [bothLine(new: new, legacy: legacy, home: home)]
        case .some: return []
        case nil:
            let reason = blocker(home: home, app: app, environment: environment)
            // Inside the app `baton migrate` always refuses (this Baton is running): starting again does the rename.
            if reason == nil, let app, !isInside(app.path, Paths.legacyLaunchersDir(home: home).path) {
                return [
                    "Baton's folder in ~/Applications still has the Claude Profiles name. Quit Baton and open it again: with every Claude window closed it renames the folder as it starts."
                ]
            }
            return [line(for: reason, home: home, insideApp: insideApp(cli: cli, home: home))]
        }
    }

    /// The Baton.app whose `baton` is `cli`, when it lies inside the old folder: it can't rename that folder at start.
    static func insideApp(cli: URL?, home: URL) -> URL? {
        guard let cli, isInside(cli.path, Paths.legacyLaunchersDir(home: home).path) else { return nil }
        return bundle(containing: cli.standardizedFileURL.path)
    }

    /// Why the folder still has its old name, in plain words.
    /// - Parameter insideApp: a Baton.app inside the old folder, which can't rename it when it starts: the line then
    ///   ends with the command that does.
    public static func line(for reason: Reason?, home: URL, insideApp: URL? = nil) -> String {
        let folder = "Baton's folder in ~/Applications still has the Claude Profiles name"
        let later =
            insideApp.map { "Close every Claude window and quit Baton, then run: \(migrateCommand($0))" }
            ?? "Baton renames it the next time it starts with every Claude window closed."
        switch reason {
        case .claudeRunning?:
            return "\(folder) because Claude windows are open. \(later)"
        case .appInsideLegacyFolder(let app)?:
            let legacy = display(Paths.legacyLaunchersDir(home: home), home: home)
            return
                "Baton runs from inside \(legacy), so it can't rename that folder itself. Quit Baton, close every Claude window, then run: \(migrateCommand(app))"
        case .batonRunning?:
            let then =
                insideApp.map { "Quit it, close every Claude window, then run: \(migrateCommand($0))" }
                ?? "Quit it, then open Baton again with every Claude window closed."
            return "\(folder) because another Baton is running. \(then)"
        case .differentVolume?:
            return "\(folder): it is a separate volume, and Baton renames folders but never copies them. Baton keeps using it where it is."
        case .busy?:
            return "\(folder) because another baton command was using it. \(later)"
        case .renameFailed(let reason)?:
            return "\(folder): renaming it failed (\(reason)). \(later)"
        case nil:
            return insideApp.map { "\(folder). Close every Claude window and quit Baton, then run: \(migrateCommand($0))" }
                ?? "\(folder). Baton renames it the next time it starts with every Claude window closed, or now with `baton migrate`."
        }
    }

    /// `"<app>/Contents/Helpers/baton" migrate`, with the full path.
    static func migrateCommand(_ app: URL) -> String {
        "\"\(app.standardizedFileURL.path)/Contents/Helpers/baton\" migrate"
    }

    static func bothLine(new: URL, legacy: URL, home: URL) -> String {
        let (new, legacy) = (display(new, home: home), display(legacy, home: home))
        return
            "Both \(new) and \(legacy) exist. Baton uses \(new) and leaves the other alone: with every Claude window closed, move anything you still need out of \(legacy), then move that folder to the Trash."
    }

    /// The result line `baton migrate` prints and the app shows after a rename.
    /// - Parameter insideApp: see `line(for:home:insideApp:)`.
    public static func message(for outcome: Outcome, home: URL, insideApp: URL? = nil) -> String {
        switch outcome {
        case .nothingToDo: return "Nothing to rename: Baton's folder in ~/Applications already has its name."
        case .bothExist(let new, let legacy): return bothLine(new: new, legacy: legacy, home: home)
        case .migrated(let moved):
            let count = moved.rewrittenLaunchers
            var text = "Renamed ~/Applications/Claude Profiles to \(display(moved.launchersDir, home: home))"
            text += count == 0 ? "." : " and updated its \(count) launcher\(count == 1 ? "" : "s") in place, so Dock items keep working."
            if moved.trashedOldApp {
                text += " The old \(legacyAppName) went to the Trash: Baton.app replaces it. If Claude Profiles is in your Dock, remove it and add Baton."
            }
            text += " Relink any command link you made into ~/Applications/Claude Profiles."
            return ([text] + moved.problems).joined(separator: " ")
        case .kept(let reason): return line(for: reason, home: home, insideApp: insideApp)
        case .failed(let message): return message
        }
    }

    /// `baton migrate`: renames the folder and returns its line and exit status. Every other command returns `nil`.
    /// - Parameter cli: the running `baton`, links resolved.
    public static func command(_ args: [String], home: URL, cli: URL?, environment: Environment = .live) -> (message: String, exitCode: Int32)? {
        guard args.first == "migrate" else { return nil }
        // Nothing to preview it with: an option it doesn't know must not rename the folder anyway.
        guard args.count == 1 else {
            return (
                "`baton migrate` takes no options (got \(args.dropFirst().joined(separator: " "))), and nothing was renamed. "
                    + "`baton doctor` shows the folder's state without changing it.", 1
            )
        }
        let outcome = run(home: home, cli: cli, environment: environment)
        return (message(for: outcome, home: home, insideApp: insideApp(cli: cli, home: home)), outcome.exitCode)
    }

    /// `~/…` for a path inside `home`.
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, root = home.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }

    // MARK: The lock

    /// Holds a shared lock on `lockFile(home:)` until the process exits, so the folder is never renamed while this
    /// command runs; waits up to `wait` seconds for a rename under way to finish. Called before `Paths` is built.
    /// - Returns: a line to show when a rename kept the lock the whole time; `nil` when held, or when the lock file
    ///   can't be opened at all, in which case the command runs without it.
    public static func holdShared(home: URL, wait: TimeInterval = 30) -> String? {
        switch acquire(lockFile(home: home), wait: wait, shared: true) {
        case .held: return nil  // released when the process exits
        case .busy: return "Baton is renaming its folder in ~/Applications right now. Try again in a moment."
        case .failed: return nil
        }
    }

    enum LockResult {
        case held(Int32)
        case busy
        case failed(String)
    }

    /// A `flock(2)` on `url`, exclusive unless `shared`, waiting up to `wait` seconds for other holders to let go.
    static func acquire(_ url: URL, wait: TimeInterval, shared: Bool) -> LockResult {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                close(descriptor)
                return .failed(String(cString: strerror(error)))
            }
            guard Date() < deadline else {
                close(descriptor)
                return .busy
            }
            usleep(50_000)
        }
        return .held(descriptor)
    }

    static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    // MARK: The system

    /// `rename(2)` that refuses to replace anything at the destination, even an empty folder.
    static func renameExclusive(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func bundleIdentifier(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Every process's executable and parent, and the arguments of this user's processes (the only ones macOS lets it read).
    static func liveProcesses() -> [RunningProcess] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let uid = getuid()
        var buffer: [UInt8] = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0 else { return nil }
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = length > 0 ? String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasInfo = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            return RunningProcess(
                pid: pid, parent: hasInfo ? pid_t(info.pbi_ppid) : nil, executable: executable,
                arguments: hasInfo && info.pbi_uid == uid ? ProcessArguments.of(pid, buffer: &buffer) : nil)
        }
    }
}

/// Documentation screenshots: `BATON_DEMO=1` shows sample data and changes nothing on the Mac.
public enum DemoMode {
    public static func isOn(_ variables: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        variables["BATON_DEMO"] == "1"
    }
}
