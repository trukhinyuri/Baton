import Darwin
import Foundation

/// Moves Baton's two folders from the name it had before 1.0, Claude Profiles, to Baton:
/// `~/Library/Application Support/Claude Profiles` and `~/Applications/Claude Profiles`. See docs/adr/0007-baton-rename.md.
///
/// Runs at app start before `Paths` is built, and from `baton migrate` (which `scripts/install-app.sh` calls); no other
/// command moves anything. Both folders are renamed with `rename(2)` or neither is, only while nothing uses them, never
/// across volumes, and nothing of Claude's own is touched. What is kept this time is retried at the next start.
public enum LegacyMigration {
    /// Why the folders stayed under their old name this time.
    public enum Reason: Sendable, Hashable {
        /// A Claude window, a Claude Code session or a launcher runs from the old folders or uses a profile's data in them.
        case claudeRunning
        /// Another Baton or `baton` command runs: it has the old paths and could recreate the old folders.
        case batonRunning
        /// Baton itself runs from inside the old launchers folder.
        case appInsideLegacyFolder
        /// An old folder and its new place are on different volumes, and a rename doesn't cross them.
        case differentVolume
        /// Another Baton was working in the old folders (one of its locks was held), or another move didn't finish in time.
        case busy
    }

    /// A folder that exists under both names. Baton uses the new one and leaves the old one untouched.
    public struct Conflict: Sendable, Equatable {
        public var new: URL
        public var legacy: URL
    }

    /// What a finished move did.
    public struct Moved: Sendable, Equatable {
        public var stateDir: URL
        /// `nil` when there was no old launchers folder to move.
        public var launchersDir: URL?
        /// An old `Claude Profiles.app` that ended up in the new launchers folder went to the Trash.
        public var trashedOldApp = false
        /// Follow-ups that failed after both folders moved: the link for old scripts, or trashing the old app.
        public var problems: [String] = []
    }

    public enum Outcome: Sendable, Equatable {
        /// No old folders, or they were moved already, perhaps by another process while this one waited.
        case nothingToDo
        /// Folders exist under both names.
        case bothExist([Conflict])
        case migrated(Moved)
        case kept(Reason)
        /// Nothing was left half moved unless the message says so.
        case failed(String)

        /// `baton migrate`'s exit status: 0 moved or nothing to do, 3 kept for now, 1 error.
        public var exitCode: Int32 {
            switch self {
            case .nothingToDo, .bothExist, .migrated: 0
            case .kept: 3
            case .failed: 1
            }
        }
    }

    /// A process of this Mac, as far as it can be read: its executable and, for this user's processes, its arguments.
    public struct RunningProcess: Sendable, Equatable {
        public var pid: pid_t
        public var executable: String?
        public var arguments: [String]?

        public init(pid: pid_t, executable: String?, arguments: [String]? = nil) {
            self.pid = pid
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Everything the move reads from or does to the system, so tests run in a temporary folder only.
    public struct Environment: Sendable {
        public var processes: @Sendable () -> [RunningProcess]
        /// Moves a folder; fails if something is already at the destination.
        public var rename: @Sendable (URL, URL) throws -> Void
        /// The volume (`st_dev`) of a path, `nil` if it can't be read.
        public var volume: @Sendable (URL) -> UInt64?
        public var trash: @Sendable (URL) throws -> Void
        /// The migrating process, which may itself run from inside the old launchers folder.
        public var pid: pid_t
        /// How long to wait for another process that is moving the folders.
        public var lockWait: TimeInterval

        public init(
            processes: @escaping @Sendable () -> [RunningProcess], rename: @escaping @Sendable (URL, URL) throws -> Void,
            volume: @escaping @Sendable (URL) -> UInt64?, trash: @escaping @Sendable (URL) throws -> Void,
            pid: pid_t = getpid(), lockWait: TimeInterval = 10
        ) {
            self.processes = processes
            self.rename = rename
            self.volume = volume
            self.trash = trash
            self.pid = pid
            self.lockWait = lockWait
        }

        public static var live: Environment {
            Environment(
                processes: LegacyMigration.liveProcesses, rename: LegacyMigration.renameExclusive, volume: LegacyMigration.volume,
                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        }
    }

    /// The name of Baton's app before 1.0. An old copy is never moved into the new launchers folder.
    public static let legacyAppName = "Claude Profiles.app"

    /// Held while one process checks and moves the folders. Outside both, so it isn't moved with them.
    public static func lockFile(home: URL) -> URL { Paths.applicationSupport(home: home).appending(path: ".baton-migration.lock") }

    // MARK: Moving

    /// Moves the folders if that is safe now.
    /// - Parameter app: the running app's bundle at app start; `nil` for the CLI, which may run from inside the old
    ///   folder because it is one loaded binary.
    public static func run(home: URL, app: URL? = nil, environment: Environment = .live) -> Outcome {
        let pairs = Pairs(home: home)
        // A quick look first, so a fresh or already moved install gets no lock file.
        guard pairs.needsMove else { return pairs.settled }
        if let app, isInside(app.path, pairs.legacyLaunchers.path) { return .kept(.appInsideLegacyFolder) }

        let lock: Int32
        switch acquire(lockFile(home: home), wait: environment.lockWait) {
        case .held(let descriptor): lock = descriptor
        // Another process is still moving them; whatever it left is the answer if it finished.
        case .busy: return pairs.needsMove ? .kept(.busy) : pairs.settled
        case .failed(let reason): return .failed("Couldn't take the lock for moving Baton's folders: \(reason). Nothing was moved.")
        }
        defer { release(lock) }

        // The process that held the lock may have moved them already. `Pairs` looks at the disk every time.
        guard pairs.needsMove else { return pairs.settled }
        if let reason = blocker(pairs: pairs, app: app, environment: environment) { return .kept(reason) }

        // An operation of another Baton in progress (opening a window, a sync, a registry change) keeps the folders too.
        var stateLocks: [Int32] = []
        defer { stateLocks.forEach(release) }
        for name in stateLockNames {
            guard case .held(let descriptor) = acquire(pairs.legacyState.appending(path: name), wait: 0, mode: 0o644) else { return .kept(.busy) }
            stateLocks.append(descriptor)
        }
        return move(pairs, home: home, environment: environment)
    }

    /// The lock files `ProfileManager` and `LocalOnly` take inside the state folder.
    static let stateLockNames = ["registry.lock", "open.lock", "sync.lock", "engines.lock", "local-only.lock"]

    private static func move(_ pairs: Pairs, home: URL, environment: Environment) -> Outcome {
        let log = Log.logger("migration")
        do { try environment.rename(pairs.legacyState, pairs.newState) } catch {
            return .failed(
                "Couldn't move \(display(pairs.legacyState, home: home)) to \(display(pairs.newState, home: home)): \(error.localizedDescription). Nothing was moved; Baton keeps using the Claude Profiles folders."
            )
        }
        var moved = Moved(stateDir: pairs.newState, launchersDir: nil)
        if pairs.hasLegacyLaunchers {
            do { try environment.rename(pairs.legacyLaunchers, pairs.newLaunchers) } catch {
                let reason = error.localizedDescription
                do { try environment.rename(pairs.newState, pairs.legacyState) } catch {
                    log.error("Moved the state folder but not the launchers, and couldn't move it back")
                    return .failed(
                        "Couldn't move \(display(pairs.legacyLaunchers, home: home)) to \(display(pairs.newLaunchers, home: home)): \(reason). "
                            + "Moving \(display(pairs.newState, home: home)) back failed too (\(error.localizedDescription)), so Baton now uses it together with \(display(pairs.legacyLaunchers, home: home))."
                    )
                }
                return .failed(
                    "Couldn't move \(display(pairs.legacyLaunchers, home: home)) to \(display(pairs.newLaunchers, home: home)): \(reason). The other folder was moved back, so nothing changed; Baton keeps using the Claude Profiles folders."
                )
            }
            moved.launchersDir = pairs.newLaunchers
        }
        // Relative, so it keeps working if the home folder moves. Only for scripts; nobody sees Application Support.
        do {
            try FileManager.default.createSymbolicLink(atPath: pairs.legacyState.path, withDestinationPath: Paths.folderName)
        } catch {
            moved.problems.append(
                "Couldn't leave a link at \(display(pairs.legacyState, home: home)) for scripts that use the old name: \(error.localizedDescription).")
        }
        // The old app came along inside the folder. Baton.app replaces it, and one copy at a time may run.
        let oldApp = pairs.newLaunchers.appending(path: legacyAppName, directoryHint: .isDirectory)
        if moved.launchersDir != nil, Paths.isRealDirectory(oldApp), bundleIdentifier(of: oldApp) == AppInstances.bundleID {
            do {
                try environment.trash(oldApp)
                moved.trashedOldApp = true
            } catch {
                moved.problems.append(
                    "Couldn't move the old \(legacyAppName) in \(display(pairs.newLaunchers, home: home)) to the Trash: \(error.localizedDescription).")
            }
        }
        log.notice("Moved Baton's folders from their old name")
        return .migrated(moved)
    }

    // MARK: Checking

    /// Baton's folder pairs under the old and the new name, and what is there now.
    struct Pairs {
        var home: URL
        var newState: URL { Paths.newStateDir(home: home) }
        var legacyState: URL { Paths.legacyStateDir(home: home) }
        var newLaunchers: URL { Paths.newLaunchersDir(home: home) }
        var legacyLaunchers: URL { Paths.legacyLaunchersDir(home: home) }

        var hasLegacyLaunchers: Bool { Paths.isRealDirectory(legacyLaunchers) }

        /// The old state folder is a real directory with nothing at the new name, and the old launchers folder is either
        /// absent or a real directory with nothing at its new name.
        var needsMove: Bool {
            guard Paths.isRealDirectory(legacyState), !exists(newState) else { return false }
            return !exists(legacyLaunchers) || (hasLegacyLaunchers && !exists(newLaunchers))
        }

        var conflicts: [Conflict] {
            [(newState, legacyState), (newLaunchers, legacyLaunchers)]
                .filter { exists($0.0) && Paths.isRealDirectory($0.1) }
                .map { Conflict(new: $0.0, legacy: $0.1) }
        }

        /// The answer when there is nothing to move.
        var settled: Outcome { conflicts.isEmpty ? .nothingToDo : .bothExist(conflicts) }
    }

    /// Anything at `url`, a dangling link included.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Why moving isn't safe right now, or `nil` if it is. Doesn't take the lock and changes nothing.
    static func blocker(pairs: Pairs, app: URL?, environment: Environment) -> Reason? {
        if let app, isInside(app.path, pairs.legacyLaunchers.path) { return .appInsideLegacyFolder }
        // As written and with links resolved: the process list names executables by their real path.
        let roots = [pairs.legacyState, pairs.legacyLaunchers].flatMap { [$0.standardizedFileURL.path, realPath($0)].compactMap { $0 } }

        var found: Set<Reason> = []
        for process in environment.processes() where process.pid != environment.pid {
            if let executable = process.executable {
                let isBaton = isBatonExecutable(executable)
                if roots.contains(where: { isInside(executable, $0) }) {
                    found.insert(isBaton ? .appInsideLegacyFolder : .claudeRunning)
                    continue
                }
                if isBaton {
                    found.insert(.batonRunning)
                    continue
                }
            }
            if let arguments = process.arguments, uses(arguments, roots: roots) { found.insert(.claudeRunning) }
        }
        if found.contains(.appInsideLegacyFolder) { return .appInsideLegacyFolder }

        let support = Paths.applicationSupport(home: pairs.home), applications = pairs.legacyLaunchers.deletingLastPathComponent()
        var sameVolume = environment.volume(pairs.legacyState).map { $0 == environment.volume(support) } ?? false
        if pairs.hasLegacyLaunchers {
            sameVolume = sameVolume && (environment.volume(pairs.legacyLaunchers).map { $0 == environment.volume(applications) } ?? false)
        }
        if !sameVolume { return .differentVolume }
        return [.claudeRunning, .batonRunning].first(where: found.contains)
    }

    /// Baton's app or CLI, under either name, wherever it is installed: an executable at one of these places inside an
    /// app bundle whose Info.plist names Baton's bundle id (which the rename kept), so another app called Baton doesn't count.
    static func isBatonExecutable(_ executable: String) -> Bool {
        let places = ["/Contents/MacOS/Baton", "/Contents/Helpers/baton", "/Contents/MacOS/ClaudeProfiles", "/Contents/Helpers/claude-profiles"]
        guard let place = places.first(where: executable.hasSuffix) else { return false }
        let bundle = URL(fileURLWithPath: String(executable.dropLast(place.count)), isDirectory: true)
        return bundleIdentifier(of: bundle) == AppInstances.bundleID
    }

    /// The path with every link resolved, `nil` if it doesn't exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a command line names a path inside one of `roots`: Electron's `--user-data-dir`, the value of any other
    /// `--name=value` or `-name=value`, or a plain path, such as a launcher script run by `sh`.
    static func uses(_ arguments: [String], roots: [String]) -> Bool {
        if let dataDir = ProcessArguments.userDataDir(in: arguments), roots.contains(where: { isInside(dataDir, $0) }) { return true }
        return arguments.dropFirst().contains { argument in
            var value = Substring(argument)
            if argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") { value = argument[argument.index(after: equals)...] }
            return roots.contains { isInside(String(value), $0) }
        }
    }

    /// `path` is `root` or inside it. Case-insensitive, as the default macOS volume is.
    static func isInside(_ path: String, _ root: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let root = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: What doctor and the status panel say

    /// Plain lines for `baton doctor` and the status panel while Baton uses a folder of its old name, or finds one
    /// next to the new one. Empty once the folders are moved. Reads the process list but changes nothing.
    public static func notes(paths: Paths, app: URL? = nil, environment: Environment = .live) -> [String] {
        let pairs = Pairs(home: paths.home)
        let conflicts = pairs.conflicts
        if !conflicts.isEmpty {
            return conflicts.map { conflict in
                "Both \(display(conflict.new, home: paths.home)) and \(display(conflict.legacy, home: paths.home)) exist. Baton uses the first and leaves the Claude Profiles one untouched; move what you still need out of it yourself."
            }
        }
        guard paths.usesLegacyFolders else { return [] }
        guard pairs.needsMove else {
            // Only one of the two still has its old name, say after a move that couldn't be undone, and the pair that
            // `run` moves together isn't complete.
            let home = paths.home
            var lines: [String] = []
            if paths.stateDir == pairs.legacyState {
                lines.append(
                    "Baton still uses \(display(pairs.legacyState, home: home)) because \(display(pairs.legacyLaunchers, home: home)) is a link or a file, not a folder it can move along. With Baton and every Claude window closed, move that aside, then run `baton migrate`."
                )
            }
            if paths.launchersDir == pairs.legacyLaunchers {
                lines.append(
                    "Baton still uses \(display(pairs.legacyLaunchers, home: home)): it moves that folder only together with \(display(pairs.legacyState, home: home)), which isn't there to move. With Baton and every Claude window closed, rename it to \(Paths.folderName) yourself."
                )
            }
            return lines
        }
        return [line(for: blocker(pairs: pairs, app: app, environment: environment))]
    }

    /// Why the folders still have their old name, in plain words; `nil` when nothing stops moving them now.
    public static func line(for reason: Reason?) -> String {
        switch reason {
        case .claudeRunning?:
            "Baton still uses the Claude Profiles folders because Claude windows are open. It moves them the next time it starts with every Claude window closed."
        case .appInsideLegacyFolder?:
            "Baton runs from inside the old Claude Profiles folder. Quit Baton, close every Claude window, then run scripts/install-app.sh again or `baton migrate`."
        case .batonRunning?:
            "Baton still uses the Claude Profiles folders because another Baton is running. Quit it, then open Baton again with every Claude window closed, or run `baton migrate`."
        case .differentVolume?:
            "Baton still uses the Claude Profiles folders because they are on a different volume from their new place, and Baton only renames them, never copies."
        case .busy?:
            "Baton still uses the Claude Profiles folders because another Baton was working in them. It moves them the next time it starts with every Claude window closed."
        case nil:
            "Baton still uses the Claude Profiles folders. It moves them the next time it starts with every Claude window closed, or now with `baton migrate`."
        }
    }

    /// The result line `baton migrate` prints and the app shows after a move.
    public static func message(for outcome: Outcome, home: URL) -> String {
        switch outcome {
        case .nothingToDo: return "Nothing to move: Baton already uses its own folders."
        case .bothExist(let conflicts):
            return conflicts.map { conflict in
                "Both \(display(conflict.new, home: home)) and \(display(conflict.legacy, home: home)) exist. Baton uses the first and leaves the Claude Profiles one untouched; move what you still need out of it yourself."
            }.joined(separator: " ")
        case .migrated(let moved):
            var text = "Moved Baton's folders from Claude Profiles to \(display(moved.stateDir, home: home))"
            text += moved.launchersDir.map { " and \(display($0, home: home))." } ?? "."
            if moved.trashedOldApp { text += " The old \(legacyAppName) went to the Trash: Baton.app replaces it." }
            return ([text] + moved.problems).joined(separator: " ")
        case .kept(let reason): return line(for: reason)
        case .failed(let message): return message
        }
    }

    /// Before `baton` builds its paths: `baton migrate` moves the folders and returns its line and exit status.
    /// Every other command returns `nil` and uses the folders where they are.
    public static func command(_ args: [String], home: URL, environment: Environment = .live) -> (message: String, exitCode: Int32)? {
        guard args.first == "migrate" else { return nil }
        let outcome = run(home: home, environment: environment)
        return (message(for: outcome, home: home), outcome.exitCode)
    }

    /// `~/…` for a path inside `home`.
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, root = home.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }

    // MARK: The system

    enum LockResult {
        case held(Int32)
        case busy
        case failed(String)
    }

    /// An exclusive `flock(2)` on `url`, waiting up to `wait` seconds for another process to let go of it.
    static func acquire(_ url: URL, wait: TimeInterval, mode: mode_t = 0o600) -> LockResult {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
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

    /// `rename(2)` that refuses to replace anything at the destination, even an empty folder.
    static func renameExclusive(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func volume(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(bitPattern: Int64(info.st_dev)) : nil
    }

    static func bundleIdentifier(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Every process's executable, and the arguments of this user's processes (the only ones macOS lets it read).
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
            let isMine = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == uid
            return RunningProcess(pid: pid, executable: executable, arguments: isMine ? ProcessArguments.of(pid, buffer: &buffer) : nil)
        }
    }
}
