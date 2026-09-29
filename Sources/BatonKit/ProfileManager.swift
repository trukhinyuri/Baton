import AppKit
import Darwin

public enum ProfileError: LocalizedError, Equatable {
    case claudeNotInstalled(String)
    /// The Claude found isn't signed by Anthropic, so it is neither opened nor given `claude://` links.
    case claudeNotFromAnthropic(String)
    case invalidLabel
    /// MAIN and CLAUDE name the main Claude window.
    case reservedLabel(String)
    case invalidEmail
    case duplicateLabel(String)
    case notFound(String)
    case cloneFailed(String)
    case windowStillRunning(String)
    case notSignedIn(String)
    case sameWindow(String)
    case coworkNeedsItsOwnHandoff(String)
    /// Work under a folder rule may continue only with the rule's accounts.
    case notAllowed(folders: [String], accounts: [String], label: String, email: String?)
    case rulesUnreadable(String)
    /// The window started but didn't show up in time, so the links it can't keep yet were not handed over.
    case windowDidNotAppear(label: String, links: Int)
    /// A profile is removed only while its window is closed.
    case profileOpen(String)
    /// Continuing the same session while its window may still write to it would give it two writers.
    case mayStillBeWritten([String])
    /// Demo mode (`BATON_DEMO=1`) shows sample data and changes nothing on this Mac.
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled(let path): "Claude Desktop is not installed at \(path). Install it from claude.ai/download."
        case .claudeNotFromAnthropic(let path):
            "\(path) isn't Claude Desktop as Anthropic signs it, so Baton doesn't open it or send claude:// links to it. "
                + "Install Claude Desktop from Anthropic in Applications."
        case .invalidLabel: "Use 1–\(Profile.maxLabelLength) letters, digits, “-” or “_” for the label."
        case .reservedLabel(let label): "“\(label)” is the name of the main Claude window. Choose another label."
        case .invalidEmail: "That doesn't look like an email address."
        case .duplicateLabel(let label): "A profile labeled “\(label)” already exists."
        case .notFound(let id): "No profile “\(id)”."
        case .cloneFailed(let reason): "Couldn't create the app copy: \(reason)"
        case .windowStillRunning(let label):
            "Claude \(label) is open without its profile and did not quit. Finish or stop its active work, close that window, then open the profile again."
        case .notSignedIn(let label): "Sign in to Claude \(label) first, then continue there."
        case .sameWindow(let label): "This already belongs to Claude \(label). Choose another profile to continue in."
        case .coworkNeedsItsOwnHandoff(let title): "“\(title)” is a Cowork task. Continue it on its own, so its history and files are attached."
        case .notAllowed(let folders, let accounts, let label, let email):
            "Work in \(folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " and ")) continues only in "
                + (accounts.isEmpty ? "no account (its folder rules have none in common)" : accounts.joined(separator: " or "))
                + ", and Claude \(label) is signed in as \(email ?? "an account whose email can't be read"). Nothing was changed. "
                + "Continue in a window signed in with that account, or change the rule with `baton rule`."
        case .rulesUnreadable(let reason): "Can't read the folder rules, so nothing continues until they are fixed: \(reason)"
        case .windowDidNotAppear(let label, let links):
            "Claude \(label) started but its window didn't appear, so \(links) of the sessions were not handed to it. Open them from its sidebar, or continue them again once it's open."
        case .profileOpen(let label):
            "Claude \(label) is open. Quit it first (⌘Q in that window), then remove the profile. Nothing was removed."
        case .mayStillBeWritten(let titles):
            titles.map { "“\($0)”" }.joined(separator: ", ")
                + (titles.count == 1 ? " may still be written to in its window. " : " may still be written to in their windows. ")
                + "Continue as a copy, or close it there first and continue anyway."
        case .readOnly: "Demo mode shows sample data and changes nothing on this Mac."
        }
    }
}

/// What the UI and CLI show for one Claude window: the main app or a profile.
public struct ProfileStatus: Identifiable, Equatable, Sendable {
    public var profile: Profile?  // nil for the main Claude app
    public var accountID: String?
    public var email: String?
    public var usage: Usage?
    /// Five-hour and weekly limits with their reset times, when known (see `Limits`).
    public var limits: Limits
    public var isRunning: Bool
    /// The profile's app copy is open without the profile's data (opened from its own Dock icon or reopened
    /// by macOS at login), so that window shows the main app's account.
    public var isOpenWithoutProfile: Bool

    public init(
        profile: Profile?, accountID: String?, email: String?, usage: Usage?, isRunning: Bool,
        isOpenWithoutProfile: Bool = false, limits: Limits? = nil
    ) {
        self.profile = profile
        self.accountID = accountID
        self.email = email
        self.usage = usage
        self.limits = limits ?? Limits(usage: usage)
        self.isRunning = isRunning
        self.isOpenWithoutProfile = isOpenWithoutProfile
    }

    public var id: String { profile?.id ?? "main" }
    public var isMain: Bool { profile == nil }
    public var isSignedIn: Bool { accountID != nil }
    public var label: String { profile?.label ?? "MAIN" }
    /// What follows "Claude " in what Baton says: "(main)" for the main window, the profile's label otherwise.
    /// `label` stays "MAIN", as on the badge, in reports and in `doctor`'s tables.
    public var displayLabel: String { profile?.label ?? "(main)" }
    public var color: String { profile?.color ?? Profile.mainColor }
    /// Signed in with a different account than the one the profile was created for.
    public var isUnexpectedAccount: Bool {
        guard let expected = profile?.email, let email else { return false }
        return expected.caseInsensitiveCompare(email) != .orderedSame
    }
}

/// What one call to `ProfileManager.syncSessions()` did.
public struct SyncReport: Equatable, Sendable {
    public var sessions: SessionSync.Report
    public var cowork: CoworkSync.Report
    /// What was carried into sessions Claude Desktop copied itself.
    public var carried: [NativeForkCarry.Report] = []
    public var changes: Int { sessions.changes + cowork.changes + carried.reduce(0) { $0 + $1.changes } }
}

/// Creates, opens and removes profiles. Every operation is local to this Mac.
///
/// Lock order, the same in the app, the CLI and launchers, so no two of them ever wait for each other in a circle:
/// 1. File locks (`FileLock`) first, outermost first: registry.lock, engines.lock, open.lock (which auto-continue's
///    state uses too), sync.lock, local-only.lock. A lock never waits for one earlier in this list, so work that needs
///    open.lock after a sync (Local only for closed windows) runs only once sync.lock is released. The leaf file locks
///    (continue-copies.lock, limit-sightings.lock, the log's) are taken last and wait for nothing while held. Opening
///    a window keeps open.lock until the copy it starts shows up among the running apps (`FileLock.Held`), and takes no
///    other lock meanwhile.
/// 2. In-process locks (`stateLock`, `cardsSharedLock`) last, held only while reading or writing memory: never while
///    waiting for a file lock, doing I/O or calling out. Across threads of one process the file locks serialize too.
///    The one exception is `LimitTracker`'s lock: it is held while reading and writing limit-sightings.json under that
///    file's lock and while listing transcripts, and nothing else is taken under it.
public final class ProfileManager: @unchecked Sendable {
    public let paths: Paths
    public let registry: ProfileRegistry
    /// Set once at start; a test substitutes one that records instead of calling `lsregister`.
    public internal(set) var signInRouting: SignInRouting
    /// The `baton` executable that launchers call. `nil` makes launchers open the engine directly.
    public var cliPath: URL?
    private var fm: FileManager { .default }
    /// Guards the in-memory state below; see the lock order above.
    private let stateLock = NSLock()
    private var emailCache: [String: (account: String, email: String?, checkedAt: Date)] = [:]
    /// Which window ran which Claude Code session, for its limit messages (see `LimitTracker`).
    public let limitTracker = LimitTracker()
    /// Each window's warning from the last time this manager prepared it to start, and the latest of them.
    private var openWarnings: [String: String] = [:]
    private var openWarning: String?
    /// The problems the last `applyLocalOnlyToClosedWindows()` found, reported only when new.
    private var localOnlyProblems: Set<String> = []
    /// Windows this manager is opening, each with the calls waiting for their turn (see `oneAtATime`).
    private var opening: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Opening can succeed using the profile's saved settings even if portable setup could not be refreshed.
    /// The latest such warning of any window; `openWarning(of:)` gives one window's.
    public var lastOpenWarning: String? { stateLock.withLock { openWarning } }

    /// The warning from the last time this manager opened `window` (`"main"` or a profile id), if there was one. An
    /// open that only brought a running window forward prepared nothing, so it has none.
    public func openWarning(of window: String) -> String? { stateLock.withLock { openWarnings[window] } }

    private func noteOpened(_ window: String, warning: String?) {
        stateLock.withLock {
            openWarnings[window] = warning
            openWarning = warning
        }
    }
    /// Demo mode: every call that would change something on this Mac throws `ProfileError.readOnly` instead.
    public let isReadOnly: Bool

    public init(paths: Paths = .standard, cliPath: URL? = nil, readOnly: Bool = false) {
        self.paths = paths
        self.registry = ProfileRegistry(paths: paths)
        self.signInRouting = SignInRouting(paths: paths)
        self.cliPath = cliPath
        self.isReadOnly = readOnly
        let isThisUser = paths.home.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        managedPreferences =
            isThisUser
            ? URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
            : paths.home.appending(path: "Library/Managed Preferences", directoryHint: .isDirectory)
    }

    /// Throws in demo mode, before anything is changed.
    func ensureWritable() throws {
        if isReadOnly { throw ProfileError.readOnly }
    }

    /// Profiles from the registry; empty if it is missing or damaged (see `registryError`).
    public var profiles: [Profile] { (try? registry.load()) ?? [] }

    /// Why the registry couldn't be read, if it couldn't. Changes are refused until it is fixed.
    public var registryError: String? {
        do { _ = try registry.load(); return nil } catch {
            return "Can't read \(paths.registryFile.path): \(error.localizedDescription). A backup is at profiles.json.bak."
        }
    }

    public var dataDirs: [URL] {
        [paths.mainDataDir] + profiles.map { paths.dataDir(for: $0.id) }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Every window's data directory with its id: `"main"` or the profile id.
    public var windows: [(id: String, dataDir: URL)] {
        [("main", paths.mainDataDir)] + profiles.map { ($0.id, paths.dataDir(for: $0.id)) }.filter { fm.fileExists(atPath: $0.1.path) }
    }

    /// `"MAIN"` or the profile's label.
    public func label(of windowID: String) -> String {
        windowID == "main" ? "MAIN" : profiles.first { $0.id == windowID }?.label ?? windowID
    }

    /// What follows "Claude " in what Baton says: `"(main)"` or the profile's label.
    public func displayLabel(of windowID: String) -> String { windowID == "main" ? "(main)" : label(of: windowID) }

    // MARK: Status

    public func statuses() -> [ProfileStatus] {
        let running = runningClaudes()
        let main = status(
            profile: nil, dataDir: paths.mainDataDir,
            running: running.contains { $0.uses(dataDir: paths.mainDataDir, mainDataDir: paths.mainDataDir, bundle: paths.claudeApp) })
        let all =
            [main]
            + profiles.map { profile in
                var entry = status(
                    profile: profile, dataDir: paths.dataDir(for: profile.id),
                    running: running.contains { window(of: profile.id, is: $0) })
                entry.isOpenWithoutProfile = running.contains { $0.isStartedWithoutDataDir(engine: paths.engine(for: profile.id)) }
                return entry
            }
        let found = withLimits(all)
        finishSignInIfDone(found)
        return found
    }

    /// Returns `claude://` links to the main app once the profile signing in is done with them.
    private func finishSignInIfDone(_ statuses: [ProfileStatus]) {
        guard let state = signInRouting.state else { return }
        let target = statuses.first { $0.profile?.id == state.profileID }
        if SignInRouting.isFinished(
            state, signedIn: target?.isSignedIn ?? false, running: target?.isRunning ?? false,
            profileExists: target != nil)
        {
            signInRouting.end(allProfileIDs: profiles.map(\.id))
        }
    }

    /// A warning when the installed Claude Desktop is outside the versions this release was tested with.
    public var claudeVersionWarning: String? { ClaudeVersion.warning(for: ClaudeVersion.installed(at: paths.claudeApp)) }

    /// Run once when the app or the CLI starts. Gives `claude://` links back to the main app after an abandoned
    /// sign-in, and says when Claude Desktop is missing or outside the tested versions.
    /// - Returns: warnings to show; empty when all is well.
    public func startUpChecks() -> [String] {
        guard !isReadOnly else { return [] }
        guard fm.fileExists(atPath: paths.claudeApp.path) else {
            return ["Claude Desktop wasn't found in Applications. Install it, then open Baton again."]
        }
        var warnings: [String] = []
        // `Paths.findClaude` names an unsigned /Applications/Claude.app only when no Claude Anthropic signed is found.
        if isSignedByAnthropic(paths.claudeApp) {
            do { _ = try signInRouting.restoreMainIfIdle(allProfileIDs: profiles.map(\.id)) } catch { warnings.append(error.localizedDescription) }
        } else {
            warnings.append(ProfileError.claudeNotFromAnthropic(paths.claudeApp.path).localizedDescription)
        }
        if let warning = claudeVersionWarning { warnings.append(warning) }
        warnings += ManagedPolicy.warnings(in: managedPreferences, user: NSUserName())
        return warnings + Self.reservedIDWarnings(profiles)
    }

    /// A line for each profile an earlier version added under an id that names the main Claude (`Profile.reservedIDs`).
    /// Its folders are not renamed: Claude may be using them, and the user can remove it and add it again.
    static func reservedIDWarnings(_ profiles: [Profile]) -> [String] {
        profiles.filter { Profile.reservedIDs.contains($0.id) }.map {
            "Claude \($0.label) was added by an earlier version under the id \($0.id), which names the main Claude, so Baton "
                + "can mix the two up. Remove it and add that account again with another Dock label."
        }
    }

    /// Where an organization's managed preferences for Claude Desktop are (see `ManagedPolicy`). A manager for another
    /// home, as in tests, reads that home's `Library/Managed Preferences` instead of this Mac's.
    var managedPreferences: URL

    /// The profile whose window currently receives sign-in links, if any.
    public var profileSigningIn: String? { signInRouting.state?.profileID }

    private func status(profile: Profile?, dataDir: URL, running: Bool) -> ProfileStatus {
        let account = DesktopData.accountID(in: dataDir)
        return ProfileStatus(
            profile: profile, accountID: account,
            email: account.flatMap { email(in: dataDir, accountID: $0) },
            usage: nil, isRunning: running)  // with its limits in `withLimits`
    }

    /// Scanning IndexedDB is expensive, so a found email is kept until the account changes
    /// and a miss is retried at most once a minute.
    private func email(in dataDir: URL, accountID: String) -> String? {
        let key = dataDir.path
        if let cached = stateLock.withLock({ emailCache[key] }), cached.account == accountID,
            cached.email != nil || Date().timeIntervalSince(cached.checkedAt) < 60
        {
            return cached.email
        }
        let found = DesktopData.email(in: dataDir, accountID: accountID)
        stateLock.withLock { emailCache[key] = (accountID, found, Date()) }
        return found
    }

    /// Bundle paths of running Claude Desktop processes (main app and engines share a bundle identifier).
    func runningBundlePaths() -> Set<String> {
        Set(claudeProcesses().compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func claudeProcesses() -> [NSRunningApplication] {
        guard let identifier = Bundle(url: paths.claudeApp)?.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    }

    public var isAnyClaudeRunning: Bool { !claudeProcesses().isEmpty }

    func runningClaudes() -> [RunningClaude] { runningCopies?() ?? claudeProcesses().map(RunningClaude.init(app:)) }

    /// Whether `copy` is the profile's own window: its app copy started with its data directory.
    private func window(of id: String, is copy: RunningClaude) -> Bool {
        copy.uses(dataDir: paths.dataDir(for: id), mainDataDir: paths.mainDataDir, bundle: paths.engine(for: id))
    }

    /// The profile whose app copy process `pid` is, if it was started without the profile's data directory:
    /// opened from a Dock icon kept with “Keep in Dock” or reopened by macOS at login. Such a window shows the main
    /// app's account; `open(_:)` replaces it with the profile's own window.
    public func profileStartedWithoutDataDir(pid: pid_t) -> Profile? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        let copy = RunningClaude(app: app)
        return profiles.first { copy.isStartedWithoutDataDir(engine: paths.engine(for: $0.id)) }
    }

    /// Profile app copies running without their data directory that started within `age`, oldest first.
    public func recentlyStartedWithoutDataDir(within age: TimeInterval, now: Date = Date()) -> [pid_t] {
        claudeProcesses()
            .filter { app in app.launchDate.map { now.timeIntervalSince($0) < age } ?? false }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .map(\.processIdentifier)
            .filter { profileStartedWithoutDataDir(pid: $0) != nil }
    }

    /// Asks `apps` to quit and waits up to `seconds`. Ones still running are force-quit only if `force` is set.
    private func quit(_ apps: [NSRunningApplication], waiting seconds: Double, force: Bool) async throws {
        for app in apps { app.terminate() }
        for _ in 0..<Int(seconds * 5) where apps.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        if force { for app in apps where !app.isTerminated { app.forceTerminate() } }
    }

    // MARK: Create

    @discardableResult
    public func create(label rawLabel: String, email rawEmail: String?, color: String? = nil) throws -> Profile {
        try ensureWritable()
        guard fm.fileExists(atPath: paths.claudeApp.path) else { throw ProfileError.claudeNotInstalled(paths.claudeApp.path) }
        let label = rawLabel.trimmingCharacters(in: .whitespaces).uppercased()
        if Profile.isReservedLabel(label) { throw ProfileError.reservedLabel(label) }
        guard Profile.isValidLabel(label) else { throw ProfileError.invalidLabel }
        let email = rawEmail?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let email, !Profile.isValidEmail(email) { throw ProfileError.invalidEmail }

        // The app and the CLI each have a manager; without this, two creations at once keep only one profile.
        return try FileLock.withLock(registryLock, blocking: true) { () throws -> Profile in
            var all = try registry.load()
            guard !all.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
                throw ProfileError.duplicateLabel(label)
            }
            var id = Profile.slug(for: label)
            let base = id
            var n = 2
            while Profile.reservedIDs.contains(id) || all.contains(where: { $0.id == id }) || fm.fileExists(atPath: paths.dataDir(for: id).path) {
                id = "\(base)-\(n)"; n += 1
            }
            let profile = Profile(
                id: id, label: label, email: email,
                color: color ?? Profile.palette[all.count % Profile.palette.count])
            // What this call adds, so a failed Add leaves nothing behind and a retry gets the same id. None of it holds
            // anything yet: Claude has never run on the new data folder, and the app copy and launcher are Baton's own.
            let made = [paths.dataDir(for: id), paths.engine(for: id), paths.launcher(for: profile)].filter { !fm.fileExists(atPath: $0.path) }
            do {
                try fm.createDirectory(at: paths.dataDir(for: id), withIntermediateDirectories: true)
                if let appBuilder {
                    try appBuilder(profile)
                } else {
                    try buildEngine(for: profile)
                    try buildLauncher(for: profile)
                }
                all.append(profile)
                try registry.save(all)
            } catch {
                for url in made where fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
                throw error
            }
            return profile
        }!
    }

    /// Turns "keep the permission mode when continuing here" on or off for one profile. Off by default: a
    /// mode chosen under one account is not silently granted in another unless the owner opts in.
    public func setCarryPermissionMode(_ enabled: Bool, for id: String) throws {
        try ensureWritable()
        try FileLock.withLock(registryLock, blocking: true) {
            var all = try registry.load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
            all[index].carryPermissionMode = enabled ? true : nil
            try registry.save(all)
        }
    }

    /// Held while the profile registry is read and written back.
    var registryLock: URL { paths.stateDir.appending(path: "registry.lock") }
    /// Builds a new profile's engine and launcher; tests replace it to skip copying and signing Claude.
    var appBuilder: (@Sendable (Profile) throws -> Void)?
    /// Whether the profile's app copy is running; tests replace it.
    var isProfileRunning: (@Sendable (String) -> Bool)?
    /// Signs and registers a launcher after it is written; tests replace it so nothing reaches Launch Services.
    var launcherRegistrar: (@Sendable (URL) -> Void)?
    /// The running copies of Claude Desktop; tests replace it so they never look at this Mac's windows.
    var runningCopies: (@Sendable () -> [RunningClaude])?
    /// Starts a new copy of an app with these arguments and links; tests replace it so nothing is started.
    var appLauncher: (@Sendable (_ app: URL, _ arguments: [String], _ links: [URL]) async throws -> Void)?
    /// Hands links to a running copy of an app, or brings it forward without any; tests replace it so nothing reaches
    /// Launch Services.
    var appActivator: (@Sendable (_ app: URL, _ links: [URL]) async throws -> Void)?
    /// Called while a window is prepared to start, under open.lock; tests use it to overlap other work with it.
    var whilePreparing: (@Sendable (String) -> Void)?
    /// Whether an app is Claude as Anthropic signs it (`ClaudeSource.isSignedByAnthropic`); tests replace it, since a
    /// sandbox's Claude.app isn't signed.
    var signatureCheck: (@Sendable (URL) -> Bool)?

    private func isSignedByAnthropic(_ app: URL) -> Bool { signatureCheck?(app) ?? ClaudeSource.isSignedByAnthropic(app) }

    // MARK: Open

    /// Brings the profile's window forward, starting it first if needed.
    /// - Parameter link: a `claude://` link for that window to handle, such as a session to open.
    public func open(_ id: String, link: URL? = nil) async throws {
        try await open(id, links: link.map { [$0] } ?? [])
    }

    /// Brings the profile's window forward, starting it first if needed, and hands it `links` in one go.
    /// Handing them over one by one while the window is still starting could start a second copy of it.
    public func open(_ id: String, links: [URL]) async throws {
        try ensureWritable()
        try await oneAtATime(id) { try await self.openNow(id, links: links) }
    }

    private func openNow(_ id: String, links: [URL]) async throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let engine = paths.engine(for: profile.id)
        if DesktopData.accountID(in: paths.dataDir(for: profile.id)) == nil {
            try signInRouting.begin(profileID: profile.id, allProfileIDs: profiles.map(\.id))
        }
        let running = runningClaudes()
        // A copy started without the profile's data shows the main account, next to the main app on the same data.
        // A recently opened window may already have restored active work. Never force-quit it just because it is new.
        let strays = running.filter { $0.isStartedWithoutDataDir(engine: engine) }.compactMap(\.app)
        if !strays.isEmpty {
            try await quit(strays, waiting: 10, force: false)
            guard strays.allSatisfy(\.isTerminated) else { throw ProfileError.windowStillRunning(profile.label) }
        }
        if let window = running.first(where: { window(of: profile.id, is: $0) }) {
            noteOpened(profile.id, warning: nil)
            return try await bringForward(window, app: engine, links: links)
        }
        try FileLock.withLock(registryLock, blocking: true) {
            // It may have been removed while this call waited, and its app copy must not come back then.
            guard profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
            if !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                try buildEngine(for: profile)
            }
        }
        // The app and the CLI may open a profile at the same moment; the merges read and write without Claude's locks.
        // Kept until the copy started below shows up, so an open waiting for it, in another process, finds it running.
        let openLock = try FileLock.Held(paths.stateDir.appending(path: "open.lock"))
        defer { openLock.release() }
        let startedMeanwhile =
            openLock.run { () -> RunningClaude? in
                // Started while this call waited, from its Dock icon or by another Baton: its data is in use now.
                if let window = runningClaudes().first(where: { window(of: profile.id, is: $0) }) {
                    noteOpened(profile.id, warning: nil)
                    return window
                }
                whilePreparing?(id)
                // Auto-continue entries a Continue had to leave on in windows open at the time: this window stays
                // closed until it starts below, so its own are turned off now, app or no app (`AutoResumeNote.stillOn`).
                autoResume.applyPending()
                // A launcher or CLI can start a profile without the manager's background timer.
                // Claude reads its cards at startup, so share sessions first; a failure must not keep the window closed.
                var problems: [String] = []
                do { _ = try prepareSessionsForLaunch() } catch { problems.append("Sessions: \(error.localizedDescription)") }
                do { _ = try SettingsSync(paths: paths).run(into: paths.dataDir(for: profile.id)) } catch {
                    problems.append("Setup: \(error.localizedDescription)")
                }
                do { _ = try InterfaceSync(paths: paths).run(into: paths.dataDir(for: profile.id), profileID: profile.id) } catch {
                    problems.append("Interface: \(error.localizedDescription)")
                }
                // Last, so no sync above can put a Remote Control switch back.
                do { _ = try localOnly.reconcile(window: profile.id) } catch { problems.append("Local only: \(error.localizedDescription)") }
                noteOpened(
                    profile.id,
                    warning: problems.isEmpty
                        ? nil : "Claude \(profile.label) opened, but some shared settings could not be refreshed. " + problems.joined(separator: " "))
                // Once more, just before starting it: a second copy on the same data would find its storage in use.
                return runningClaudes().first { window(of: profile.id, is: $0) }
            }
        if let startedMeanwhile {
            openLock.release()
            return try await bringForward(startedMeanwhile, app: engine, links: links)
        }
        try await launch(engine, arguments: ["--user-data-dir=\(paths.dataDir(for: profile.id).path)"], links: links, label: profile.label) {
            await self.waitUntilListed { self.runningClaudes().contains { self.window(of: profile.id, is: $0) } }
            openLock.release()
        }
    }

    /// Waits until the copy just started shows up among the running apps, as `isRunning` finds it, for at most
    /// `seconds`: Launch Services lists a new copy only once it has started.
    private func waitUntilListed(_ isRunning: () -> Bool, seconds: Double = 5) async {
        for _ in 0..<Int(seconds * 10) where !isRunning() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Hands `links` to a window that is already running, or brings it forward.
    private func bringForward(_ window: RunningClaude, app: URL, links: [URL]) async throws {
        if !links.isEmpty { try await deliver(links, to: app) } else { window.app?.activate() }
    }

    /// Runs `body` once no other call in this process is opening `window`, in the order the calls came. A second click,
    /// or a Continue into a window that is still starting, then finds the window running instead of starting a second
    /// copy of it on the same data.
    private func oneAtATime(_ window: String, _ body: () async throws -> Void) async throws {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            let now = stateLock.withLock { () -> Bool in
                guard let waiting = opening[window] else {
                    opening[window] = []
                    return true
                }
                opening[window] = waiting + [turn]
                return false
            }
            if now { turn.resume() }
        }
        defer {
            let next = stateLock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard var waiting = opening[window], !waiting.isEmpty else {
                    opening[window] = nil
                    return nil
                }
                let first = waiting.removeFirst()
                opening[window] = waiting
                return first
            }
            next?.resume()
        }
        try await body()
    }

    /// Starts a new copy of the app at `app` and hands it `links`. Until its window exists, Claude keeps only the
    /// last link it receives (`open-url` stores one pending URL), so only the first goes with the launch; the rest
    /// follow once the window is on screen.
    /// - Parameter started: called once the copy has started, before the rest of the links are handed over.
    private func launch(_ app: URL, arguments: [String], links: [URL], label: String, started: () async -> Void) async throws {
        if let appLauncher {
            try await appLauncher(app, arguments, links)
            return await started()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Profile windows run the same app; a new instance keeps one window from reusing another's.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        guard let first = links.first else {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return await started()
        }
        let copy = try await NSWorkspace.shared.open([first], withApplicationAt: app, configuration: configuration)
        await started()
        let rest = Array(links.dropFirst())
        guard !rest.isEmpty else { return }
        guard try await waitForWindow(of: copy.processIdentifier, seconds: 90) else {
            throw ProfileError.windowDidNotAppear(label: label, links: rest.count)
        }
        try await Task.sleep(for: .seconds(1))
        try await deliver(rest, to: app)
    }

    /// Waits until process `pid` shows a window: Claude makes its main window before it starts taking links.
    /// Reading which process owns a window needs no permission.
    func waitForWindow(of pid: pid_t, seconds: Double) async throws -> Bool {
        for _ in 0..<Int(seconds * 4) {
            if Self.hasWindow(pid) { return true }
            if NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true { return false }
            try await Task.sleep(for: .milliseconds(250))
        }
        return Self.hasWindow(pid)
    }

    static func hasWindow(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    public func openMain(link: URL? = nil) async throws {
        try await openMain(links: link.map { [$0] } ?? [])
    }

    public func openMain(links: [URL]) async throws {
        try ensureWritable()
        try await oneAtATime("main") { try await self.openMainNow(links: links) }
    }

    private func openMainNow(links: [URL]) async throws {
        guard isSignedByAnthropic(paths.claudeApp) else {
            guard fm.fileExists(atPath: paths.claudeApp.path) else { throw ProfileError.claudeNotInstalled(paths.claudeApp.path) }
            throw ProfileError.claudeNotFromAnthropic(paths.claudeApp.path)
        }
        let isMain = { (copy: RunningClaude) in copy.uses(dataDir: self.paths.mainDataDir, mainDataDir: self.paths.mainDataDir, bundle: self.paths.claudeApp) }
        if runningClaudes().contains(where: isMain) {
            noteOpened("main", warning: nil)
            return try await bringMainForward(links: links)
        }
        var startedMeanwhile = false
        // Kept until the copy started below shows up, as for a profile's window.
        var openLock: FileLock.Held?
        defer { openLock?.release() }
        do {
            let held = try FileLock.Held(paths.stateDir.appending(path: "open.lock"))
            openLock = held
            held.run {
                // Started while this call waited, from the Dock for instance: its data is in use now.
                if runningClaudes().contains(where: isMain) {
                    startedMeanwhile = true
                    noteOpened("main", warning: nil)
                    return
                }
                whilePreparing?("main")
                autoResume.applyPending()
                var problems: [String] = []
                do { _ = try prepareSessionsForLaunch() } catch { problems.append("sessions could not be shared first: \(error.localizedDescription)") }
                do { _ = try localOnly.reconcile(window: "main") } catch { problems.append("Local only could not be applied: \(error.localizedDescription)") }
                noteOpened("main", warning: problems.isEmpty ? nil : "Claude opened, but " + problems.joined(separator: "; "))
                startedMeanwhile = runningClaudes().contains(where: isMain)
            }
        } catch {
            noteOpened("main", warning: "Claude opened, but sessions could not be shared first: \(error.localizedDescription)")
        }
        if startedMeanwhile {
            openLock?.release()
            return try await bringMainForward(links: links)
        }
        try await launch(paths.claudeApp, arguments: [], links: links, label: "(main)") {
            await self.waitUntilListed { self.runningClaudes().contains(where: isMain) }
            openLock?.release()
        }
    }

    private func bringMainForward(links: [URL]) async throws {
        if let appActivator { return try await appActivator(paths.claudeApp, links) }
        if !links.isEmpty {
            try await deliver(links, to: paths.claudeApp)
        } else {
            _ = try await NSWorkspace.shared.openApplication(at: paths.claudeApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Hands a `claude://` link to the running window of the app at `app`. macOS delivers it to that exact copy,
    /// so no other window sees it and no permission is needed.
    private func deliver(_ links: [URL], to app: URL) async throws {
        if let appActivator { return try await appActivator(app, links) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(links, withApplicationAt: app, configuration: configuration)
    }

    // MARK: Continue

    public enum ContinueResult: Sendable {
        /// The session, or a copy of it, opened in the destination window.
        case openedSession(ContinuePlan)
        /// A new Cowork task is waiting in the destination window with the history and files attached, not sent.
        case startedCoworkTask(CoworkHandoff)
    }

    /// Continues `conversation` in `destination` (`"main"` or a profile id), opening that window if needed.
    /// Code sessions open there as the same session or as a copy (see `ContinueMode`); Cowork tasks become a
    /// new task there.
    public func continueConversation(
        _ conversation: Conversation, in destination: String,
        mode: ContinueMode = .auto, anyway: Bool = false
    ) async throws -> ContinueResult {
        try ensureWritable()
        guard conversation.kind == .cowork else {
            return .openedSession(try await continueAll([conversation], in: destination, mode: mode, anyway: anyway)[0])
        }
        let label = try checkDestination(destination)
        if conversation.ownerID == destination { throw ProfileError.sameWindow(label) }
        try checkRules(folders: conversation.folders, destination: destination)
        let handoff = try CoworkHandoff.prepare(conversation, sourceLabel: self.displayLabel(of: conversation.ownerID ?? "main"), paths: paths)
        try await openWindow(destination, links: [handoff.link])
        return .startedCoworkTask(handoff)
    }

    /// What continuing `conversations` in `destination` would do, without changing anything.
    /// - Parameter folder: a folder a new session will start in as well, which its folder rule covers too.
    /// - Parameter anyway: continue the same session even though its window may still write to it; without it,
    ///   such a session throws `ProfileError.mayStillBeWritten`.
    public func plan(
        _ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
        newSessionIn folder: String? = nil, anyway: Bool = false, now: Date = Date()
    ) throws -> [ContinuePlan] {
        try checkDestination(destination)
        try checkRules(folders: conversations.flatMap(\.folders) + (folder.map { [$0] } ?? []), destination: destination)
        let dataDir = dataDir(of: destination)
        let isOpen = isWindowOpen(destination)
        let live = conversations.isEmpty ? [] : LiveSessions.ids(claudeDir: paths.claudeDir)
        let liveIn = conversations.isEmpty ? [:] : limitTracker.liveWindows(paths: paths, windows: windows)
        var supported: Set<String>?
        var plans = try conversations.map { found in
            var conversation = found
            conversation.hasLiveProcess = found.hasLiveProcess || live.contains(found.sessionID)
            guard conversation.kind != .cowork else { throw ProfileError.coworkNeedsItsOwnHandoff(conversation.title) }
            if liveIn[conversation.sessionID]?.contains(destination) == true { throw ProfileError.sameWindow(displayLabel(of: destination)) }
            let forks = mode.forks(conversation, now: now)
            // A closed window reads the shared card of a regular Code session, with its model, when it starts;
            // anything else Claude imports there and takes the model from the history.
            let source: ModelNote.CardSource = !isOpen && !forks && conversation.kind == .code ? .shared : .imported
            var note: ModelNote?
            if let model = conversation.model {
                if supported == nil { supported = ModelSupport.modelsUsed(in: dataDir) }
                note = ModelNote.decide(
                    model: model, historyModel: ConversationIndex.lastModel(of: conversation.transcript),
                    supported: supported?.contains(model) == true, card: source)
            }
            var plan = ContinuePlan(conversation: conversation, destination: destination, forks: forks, model: note)
            if let card = conversation.card { plan.wontFollow = Continuation.wontFollow(card: card, target: dataDir, paths: paths) }
            return plan
        }
        if !anyway { try Self.refuseSecondWriter(plans, now: now) }
        previewAutoResume(&plans, now: now)
        return plans
    }

    /// Refuses to continue the same session while its window may still write to it (`Conversation.mayStillWrite`);
    /// a copy is always safe.
    public static func refuseSecondWriter(_ plans: [ContinuePlan], now: Date = Date()) throws {
        let busy = plans.filter { !$0.forks && $0.conversation.mayStillWrite(now: now) }
        guard busy.isEmpty else { throw ProfileError.mayStillBeWritten(busy.map(\.conversation.title)) }
    }

    /// How long `continueAll` waits for the destination window to import the sessions it was handed.
    public var importWait: TimeInterval = 45

    /// Continues every one of `conversations` in `destination`, opening that window once with all of them and,
    /// if `folder` is given, a new session in that folder. Copies are made before the window opens; Claude
    /// imports each session itself, and `ContinuePlan.opened` says whether it did.
    @discardableResult
    public func continueAll(
        _ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
        newSessionIn folder: String? = nil, anyway: Bool = false, now: Date = Date()
    ) async throws -> [ContinuePlan] {
        try ensureWritable()
        var plans = try plan(conversations, in: destination, mode: mode, newSessionIn: folder, anyway: anyway, now: now)
        var links: [URL] = []
        var madeThisRun: [(id: String, folder: URL)] = []
        do {
            for i in plans.indices {
                if let made = try prepare(&plans[i]) { madeThisRun.append(made) }
                links.append(ClaudeLink.resume(plans[i].sessionID))
            }
        } catch {
            // A later conversation in the same batch failed: undo every copy this run made, so a partial
            // "Continue All" never leaves an orphan transcript behind.
            let copies = ContinueCopies(paths: paths)
            for made in madeThisRun {
                TranscriptFork.removeCopy(made.id, in: made.folder, claudeDir: paths.claudeDir, tempDir: paths.claudeTempDir)
                try? copies.forget(copy: made.id)
            }
            throw error
        }
        let newSession = folder.map { ClaudeLink.newCodeSession(folder: $0) }
        guard !links.isEmpty else {
            try await openWindow(destination, links: newSession.map { [$0] } ?? [])
            return plans
        }
        let cards = cardFolders(in: dataDir(of: destination))
        let known = SessionCards.sessions(in: cards)
        let started = Date()
        try await openWindow(destination, links: links)
        // Only once the destination has opened, so a failed open leaves the source window's auto-continue as it was.
        // A closed source window can't fire in between; an open one is left on until it closes (`settleAutoResume`).
        settleAutoResume(&plans, now: Date())
        await confirmImported(&plans, known: known, cards: cards, since: started)
        // Claude shows each session once it has imported it, which can take seconds for a long one, and that
        // replaces whatever the window showed. The new session goes last, so it is what stays on screen.
        if let newSession {
            try? await Task.sleep(for: .seconds(1))
            try await openWindow(destination, links: [newSession])
        }
        return plans
    }

    /// Claude writes `local_<session id>.json` when it imports a session; sessions the window knew already
    /// are left as `nil`.
    private func confirmImported(_ plans: inout [ContinuePlan], known: Set<String>, cards: [URL], since: Date) async {
        let awaited = plans.indices.filter { !known.contains(plans[$0].sessionID) }
        guard !cards.isEmpty, !awaited.isEmpty else { return }
        let deadline = Date().addingTimeInterval(importWait)
        var seen = Set<String>()
        repeat {
            seen = SessionCards.sessions(in: cards, modifiedSince: since.addingTimeInterval(-2))
            if awaited.allSatisfy({ seen.contains(plans[$0].sessionID) }) { break }
            try? await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        for i in awaited { plans[i].opened = seen.contains(plans[i].sessionID) }
    }

    /// Makes the copy a plan calls for. A second call for the same source session and destination reuses the
    /// copy already made there instead of forking another (see `ContinueCopies`). The copy's title is marked
    /// with the source window's label when that window is known, and with a plain "copy" otherwise.
    /// - Returns: the new copy's id and the folder it's in, if this call forked one; `nil` if the plan doesn't
    ///   fork or reused an existing copy. Used by `continueAll` to roll a copy back if a later one in the same
    ///   run fails.
    @discardableResult
    func prepare(_ plan: inout ContinuePlan) throws -> (id: String, folder: URL)? {
        guard plan.forks else { return nil }
        if let owner = plan.conversation.ownerID { plan.conversation.title += " · from \(label(of: owner))" } else { plan.conversation.title += " · copy" }
        let copies = ContinueCopies(paths: paths)
        let folder = plan.conversation.transcript.deletingLastPathComponent()
        if let reused = copies.existingCopy(of: plan.conversation.sessionID, transcript: plan.conversation.transcript, in: plan.destination) {
            plan.sessionID = reused
            return nil
        }
        let made = try TranscriptFork.forkReporting(plan.conversation, claudeDir: paths.claudeDir, tempDir: paths.claudeTempDir)
        plan.sessionID = made.id
        plan.carried = made
        try? copies.record(
            source: plan.conversation.sessionID, destination: plan.destination, copy: made.id,
            sourceLength: made.sourceLength, sourceTail: made.sourceTail)
        if !made.leftBehind.isEmpty || !made.worktrees.isEmpty {
            Log.info("continue", "Copy \(made.id) left \(made.leftBehind.count) scratchpad items and \(made.worktrees.count) worktrees behind")
        }
        return (made.id, folder)
    }

    /// The accounts that may continue work touching `folders` (see `FolderRules`); `nil` when no rule applies.
    public func allowedAccounts(for folders: [String]) throws -> (accounts: Set<String>, rules: [FolderRule])? {
        let rules: [FolderRule]
        do { rules = try FolderRules(paths: paths).load() } catch { throw ProfileError.rulesUnreadable(error.localizedDescription) }
        return FolderRules.allowedAccounts(for: folders, in: rules)
    }

    /// Refuses a destination whose account a folder rule doesn't list; an account whose email can't be read is refused too.
    func checkRules(folders: [String], destination: String) throws {
        guard let allowed = try allowedAccounts(for: folders) else { return }
        let dataDir = dataDir(of: destination)
        let email = DesktopData.accountID(in: dataDir).flatMap { email(in: dataDir, accountID: $0) }
        guard let email, allowed.accounts.contains(email.lowercased()) else {
            throw ProfileError.notAllowed(
                folders: allowed.rules.map(\.folder), accounts: allowed.accounts.sorted(),
                label: displayLabel(of: destination), email: email)
        }
    }

    @discardableResult
    private func checkDestination(_ destination: String) throws -> String {
        let label = displayLabel(of: destination)
        guard destination == "main" || profiles.contains(where: { $0.id == destination }) else { throw ProfileError.notFound(destination) }
        guard DesktopData.accountID(in: dataDir(of: destination)) != nil else { throw ProfileError.notSignedIn(label) }
        return label
    }

    private func dataDir(of window: String) -> URL {
        window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
    }

    /// Local only for every window: new Claude Code sessions stay off Remote Control. Applied to a closed
    /// window right away and to every window before it starts.
    public var localOnly: LocalOnly { LocalOnly(paths: paths, isRunning: { self.isWindowOpen($0) }) }

    /// Applies Local only to every closed window still waiting for it (`LocalOnly.Status.pending`), so a window started
    /// from the Dock or Spotlight rather than through Baton starts with it too. It takes open.lock, so it never runs
    /// while sync.lock is held (see the lock order).
    /// - Returns: a line for each window it couldn't apply to, unless the previous call gave the same line: a window
    ///   that fails every time is tried after every sync but reported once, so the log isn't filled with it.
    @discardableResult
    public func applyLocalOnlyToClosedWindows() -> [String] {
        guard !isReadOnly else { return [] }
        let localOnly = localOnly
        var problems: [String] = []
        for window in windows.map(\.id) where localOnly.status(window: window) == .pending && !isWindowOpen(window) {
            do { _ = try localOnly.reconcile(window: window) } catch {
                problems.append("Local only could not be applied to Claude \(displayLabel(of: window)): \(error.localizedDescription)")
            }
        }
        return stateLock.withLock {
            defer { localOnlyProblems = Set(problems) }
            return problems.filter { !localOnlyProblems.contains($0) }
        }
    }

    /// Each window's Local only status, MAIN first, for the window list and `doctor`.
    public func localOnlyStatus() -> [(window: String, label: String, status: LocalOnly.Status)] {
        let localOnly = localOnly
        return windows.map { ($0.id, label(of: $0.id), localOnly.status(window: $0.id)) }
    }

    /// Turns Local only on or off for one window, or with `window` nil for every window without its own choice.
    /// Closed windows change now; open ones when they next start (`pending`).
    @discardableResult
    public func setLocalOnly(_ enabled: Bool, window: String?) throws -> [String: LocalOnly.Status] {
        try ensureWritable()
        if let window {
            guard window == "main" || profiles.contains(where: { $0.id == window }) else { throw ProfileError.notFound(window) }
        }
        return try localOnly.setEnabled(enabled, window: window, windows: windows.map(\.id))
    }

    /// Local only's optional extra: also denies `mcp__ccd_session__move_to_cloud` in `~/.claude/settings.json`,
    /// Mac-wide. Off by default; a separate, explicit choice from `setCloudMoveLock`.
    public var cloudMoveLock: CloudMoveLock { CloudMoveLock(paths: paths) }

    /// Turns the cloud move lock on or off. Safe to call any time: it only edits `permissions.deny`.
    @discardableResult
    public func setCloudMoveLock(_ enabled: Bool) throws -> CloudMoveLock.Status {
        try ensureWritable()
        return try cloudMoveLock.setEnabled(enabled)
    }

    /// Whether the window of `"main"` or a profile id is running with its own data.
    public func isWindowOpen(_ window: String) -> Bool {
        let running = runningClaudes()
        if window == "main" {
            return running.contains { $0.uses(dataDir: paths.mainDataDir, mainDataDir: paths.mainDataDir, bundle: paths.claudeApp) }
        }
        return running.contains { self.window(of: window, is: $0) }
    }

    /// Every folder Claude could read the signed-in account's session cards from at launch, one per
    /// organization it has used. Continue confirmation watches all of them: which organization a newly
    /// imported card lands under isn't something this app can reliably predict (`DesktopData.scope`).
    func cardFolders(in dataDir: URL) -> [URL] {
        guard let account = DesktopData.accountID(in: dataDir) else { return [] }
        return DesktopData.organizationIDs(in: dataDir, accountID: account).sorted().map {
            dataDir.appending(path: "\(SessionSync.sessionsFolder)/\(account)/\($0)", directoryHint: .isDirectory)
        }
    }

    private func openWindow(_ destination: String, links: [URL]) async throws {
        if destination == "main" { try await openMain(links: links) } else { try await open(destination, links: links) }
    }

    /// Local conversations of every window, most recent first, each marked if a running Claude Code process has it open.
    public func conversations() -> [Conversation] {
        let live = LiveSessions.ids(claudeDir: paths.claudeDir)
        let windows = windows
        let ranIn = limitTracker.lastWindows(paths: paths, windows: windows)
        let openIn = limitTracker.liveWindows(paths: paths, windows: windows)
        return ConversationIndex.scan(paths: paths, windows: windows).map { found in
            var conversation = found
            conversation.hasLiveProcess = conversation.kind != .cowork && live.contains(conversation.sessionID)
            conversation.runningIn = conversation.kind == .cowork ? nil : ranIn[conversation.sessionID]
            conversation.openIn = conversation.kind == .cowork ? [] : openIn[conversation.sessionID] ?? []
            return conversation
        }
    }

    /// Refreshes session cards before a cold launch, even when the manager is not running.
    /// Opening a window never propagates deletions or migrates account-owned Project/Cowork workers.
    /// Errors abort the launch instead of silently presenting stale history as successfully shared.
    @discardableResult
    func prepareSessionsForLaunch() throws -> SessionSync.Report {
        guard
            let report = try FileLock.withLock(
                paths.stateDir.appending(path: "sync.lock"), blocking: true,
                {
                    createSessionFolders()
                    var sync = SessionSync(paths: paths, dataDirs: dataDirs)
                    sync.isWindowOpen = { [weak self] dataDir in self?.isWindowOpen(forDataDir: dataDir) ?? true }
                    sync.email = { [weak self] dataDir, account in
                        self?.email(in: dataDir, accountID: account) ?? DesktopData.email(in: dataDir, accountID: account)
                    }
                    return try sync.run(propagateDeletions: false)
                })
        else { throw POSIXError(.EWOULDBLOCK) }
        return report
    }

    /// Whether the window whose data directory is `dataDir` is currently open; a data directory this
    /// manager doesn't recognize counts as open, so sharing never touches it while unsure.
    private func isWindowOpen(forDataDir dataDir: URL) -> Bool {
        windows.first { $0.dataDir == dataDir }.map { isWindowOpen($0.id) } ?? true
    }

    // MARK: Remove

    /// Moves a closed profile's app copy and data (including its sign-in) to the Trash. While its window is open
    /// it refuses with `ProfileError.profileOpen`: quitting it here could cut off work in progress.
    /// Claude Code sessions stay available in every other profile. Cowork sessions keep their files in the
    /// profile's data, so the ones started in it go to the Trash with it and leave the other windows too.
    public func remove(_ id: String) async throws {
        try ensureWritable()
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let engine = paths.engine(for: id).standardizedFileURL
        let running = isProfileRunning?(id) ?? claudeProcesses().contains { $0.bundleURL?.standardizedFileURL == engine }
        guard !running else { throw ProfileError.profileOpen(profile.label) }

        // Share cards of sessions started in this window moments ago before its data goes away.
        _ = try? syncSessions()

        // Under the registry lock, so an open or refresh waiting for it never builds the app copy again.
        _ = try FileLock.withLock(registryLock, blocking: true) {
            let remembered = InterfaceSync(paths: paths).stateFile(for: id)
            for url in [paths.launcher(for: profile), paths.engine(for: id), paths.dataDir(for: id), remembered] where fm.fileExists(atPath: url.path) {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            try registry.save(try registry.load().filter { $0.id != id })
        }
        if signInRouting.state?.profileID == id { signInRouting.end(allProfileIDs: profiles.map(\.id)) }
    }

    // MARK: Maintenance

    /// Rebuilds app copies left behind by a Claude Desktop update and updates launchers that point to a moved CLI,
    /// in place. Copies that are running are left alone until next launch.
    public func refresh() throws {
        try ensureWritable()
        let running = runningBundlePaths()
        for profile in profiles {
            let engine = paths.engine(for: profile.id)
            // Under the registry lock, so a profile removed meanwhile gets no app copy or launcher back.
            _ = try FileLock.withLock(registryLock, blocking: true) {
                guard try registry.load().contains(where: { $0.id == profile.id }) else { return }
                if !running.contains(engine.standardizedFileURL.path), !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                    try buildEngine(for: profile)
                }
                if launcherScript(for: profile) != (try? String(contentsOf: launcherExecutable(for: profile), encoding: .utf8)) {
                    try buildLauncher(for: profile)
                }
            }
        }
    }

    /// Shares ordinary local Code sessions; inventories Cowork without cross-profile writes.
    /// - Parameter dryRun: counts what a run would do and writes nothing (`SessionSync.dryRun`; the Cowork
    ///   inventory and session-folder creation never write regardless, and carrying is skipped entirely).
    /// - Returns: `nil` if another sync (from the app or the CLI) is already running.
    @discardableResult
    public func syncSessions(dryRun: Bool = false) throws -> SyncReport? {
        try ensureWritable()
        let report = try shareSessions(dryRun: dryRun)
        // Once sync.lock is let go: Local only takes open.lock, which comes before it in the lock order.
        if !dryRun, report != nil {
            for problem in applyLocalOnlyToClosedWindows() { Log.error("local-only", problem) }
        }
        return report
    }

    private func shareSessions(dryRun: Bool) throws -> SyncReport? {
        try FileLock.withLock(paths.stateDir.appending(path: "sync.lock"), blocking: false) {
            if !dryRun { createSessionFolders() }
            let propagateDeletions = !isAnyClaudeRunning
            var sync = SessionSync(paths: paths, dataDirs: dataDirs)
            sync.isWindowOpen = { [weak self] dataDir in self?.isWindowOpen(forDataDir: dataDir) ?? true }
            sync.email = { [weak self] dataDir, account in self?.email(in: dataDir, accountID: account) ?? DesktopData.email(in: dataDir, accountID: account) }
            sync.dryRun = dryRun
            let sessions = try sync.run(propagateDeletions: propagateDeletions)
            if !dryRun { noteCardsShared(into: sessions.wroteInto) }
            let cowork = try CoworkSync(paths: paths, dataDirs: dataDirs).run(propagateDeletions: propagateDeletions)
            // Adds files only, never in Claude's own data, so it runs whether or not windows are open.
            var carried: [NativeForkCarry.Report] = []
            if !dryRun {
                // A Continue copy whose transcript is gone is never offered for reuse again.
                let copies = ContinueCopies(paths: paths)
                if FileManager.default.fileExists(atPath: copies.file.path) {
                    do { try copies.dropMissing(in: paths.claudeProjectsDir) } catch {
                        Log.error("sync", "Couldn't tidy continue-copies.json: \(error.localizedDescription)")
                    }
                }
                do { carried = try NativeForkCarry.run(paths: paths, dataDirs: dataDirs) } catch {
                    Log.error("carry", "Carry failed: \(error.localizedDescription)")
                }
            }
            let report = SyncReport(sessions: sessions, cowork: cowork, carried: carried)
            if !dryRun, report.changes > 0 {
                Log.info(
                    "sync",
                    "\(sessions.pairs) session folders: \(sessions.cardsWritten) cards written, \(sessions.cardsRemoved) removed, "
                        + "\(sessions.tombstonesWritten) deletions shared, \(report.changes) changes in all")
            }
            return report
        }
    }

    /// When this manager's sync last wrote a session card into each data folder (standardized path). A window that
    /// was already open by then shows those sessions only after a restart; `WindowStatus` says so.
    private var cardsShared: [String: Date] = [:]
    private let cardsSharedLock = NSLock()

    func noteCardsShared(into dataDirs: Set<String>, at date: Date = Date()) {
        cardsSharedLock.withLock { for dir in dataDirs { cardsShared[dir] = date } }
    }

    /// When sync last wrote a session card into `dataDir`, if it has in this run of the app.
    public func lastCardShared(into dataDir: URL) -> Date? {
        cardsSharedLock.withLock { cardsShared[dataDir.standardizedFileURL.path] }
    }

    /// Claude Desktop creates a signed-in account's session folders only when that account starts its first
    /// session, and reads them only at launch. Creating them right away lets sharing fill them before the next launch.
    func createSessionFolders() {
        for dataDir in dataDirs {
            guard let account = DesktopData.accountID(in: dataDir) else { continue }
            let items = (try? LocalStorage(dataDir: dataDir).items(origin: InterfaceSync.origin)) ?? [:]
            guard let scope = DesktopData.scope(dataDir: dataDir, items: items)?.value,
                scope.hasPrefix(account + "/")
            else { continue }
            let org = String(scope.dropFirst(account.count + 1))
            for kind in [SessionSync.sessionsFolder] {
                let folder = dataDir.appending(path: "\(kind)/\(account)/\(org)", directoryHint: .isDirectory)
                if !fm.fileExists(atPath: folder.path) {
                    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }
            }
        }
    }

    /// Restarts a profile's window once after its first sign-in. Before that, Claude didn't know the account,
    /// so it started without the shared sessions and the settings kept per account.
    /// A window that doesn't quit within 20 seconds is left alone; it picks everything up on its next start.
    public func finishFirstSignIn(_ id: String) async throws {
        try ensureWritable()
        guard profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        // Nothing is prepared unless the window is opened again below, so a warning from an earlier start is not shown.
        noteOpened(id, warning: nil)
        _ = try? syncSessions()
        let engine = paths.engine(for: id).standardizedFileURL
        let running = claudeProcesses().filter { $0.bundleURL?.standardizedFileURL == engine }
        guard !running.isEmpty else { return }  // closed already: it picks everything up when opened
        try await quit(running, waiting: 20, force: false)
        guard running.allSatisfy(\.isTerminated), profiles.contains(where: { $0.id == id }) else { return }
        _ = try? syncSessions()
        try await open(id)
    }

    // MARK: Building

    /// Reads the version from disk every time; `Bundle` caches Info.plist for the life of the process.
    static func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    /// Whether Claude Desktop is newer than the profile's engine, compared part by part as numbers (never as text,
    /// and never just "different": an engine newer than Claude Desktop is kept). An engine without a readable version
    /// counts as outdated.
    func engineIsOutdated(_ id: String) -> Bool {
        Self.isOutdated(engine: Self.version(of: paths.engine(for: id)), installed: Self.version(of: paths.claudeApp))
    }

    static func isOutdated(engine: String?, installed: String?) -> Bool {
        guard let installed else { return false }
        guard let engine else { return true }
        return EngineInstall.isOlder(engine, than: installed)
    }

    /// Clones Claude.app with APFS copy-on-write (near-zero disk use) and gives the clone a labeled Finder icon.
    /// The icon is the only change: it adds a Finder icon file, and Anthropic's code signature still verifies.
    func buildEngine(for profile: Profile) throws {
        _ = try FileLock.withLock(paths.stateDir.appending(path: "engines.lock"), blocking: true) {
            try cloneEngine(for: profile)
        }
    }

    private func cloneEngine(for profile: Profile) throws {
        let engine = paths.engine(for: profile.id)
        try EngineInstall.install(from: paths.claudeApp, to: engine)
        NSWorkspace.shared.setIcon(icon(for: profile), forFile: engine.path, options: [])
    }

    func icon(for profile: Profile) -> NSImage {
        IconRenderer.profileIcon(
            base: NSWorkspace.shared.icon(forFile: paths.claudeApp.path),
            label: profile.label, color: NSColor(hex: Contrast.behindWhiteText(profile.color)))
    }

    func launcherExecutable(for profile: Profile) -> URL {
        paths.launcher(for: profile).appending(path: "Contents/MacOS/launch")
    }

    func launcherScript(for profile: Profile) -> String {
        let engine = paths.engine(for: profile.id).path
        let dataDir = paths.dataDir(for: profile.id).path
        var script = "#!/bin/sh\n# Generated by Baton. Opens Claude with the \(profile.label) profile.\n"
        if let cli = cliPath?.path {
            // Started from the Dock, nothing shows what `baton` says, so a failure is shown in an alert. The engine is
            // not opened then: whatever stopped `baton` (a window that didn't quit, say) would stop a bare open too.
            script += """
                if [ -x \(shellQuote(cli)) ]; then
                    problem=$(\(shellQuote(cli)) open \(shellQuote(profile.id)) 2>&1 >/dev/null)
                    status=$?
                    [ "$status" -eq 0 ] && exit 0
                    /usr/bin/osascript -e 'on run argv' -e 'activate' -e 'display alert (item 1 of argv) message (item 2 of argv) as critical' \\
                        -e 'end run' \(shellQuote("Claude \(profile.label) didn't open")) "${problem:-Baton stopped with status $status.}"
                    exit "$status"
                fi

                """
        }
        script += "exec /usr/bin/open -n -a \(shellQuote(engine)) --args \(shellQuote("--user-data-dir=" + dataDir))\n"
        return script
    }

    /// A tiny app bundle that opens the profile. It can live in the Dock and is found by Spotlight.
    ///
    /// An existing launcher is updated in place and never removed: its bundle folder, which Dock and Finder items
    /// point to, stays the same folder, and only its script, Info.plist and icon are written again.
    func buildLauncher(for profile: Profile) throws {
        let app = paths.launcher(for: profile)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)

        let executable = launcherExecutable(for: profile)
        try launcherScript(for: profile).write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try IconRenderer.icnsData(for: icon(for: profile)).write(to: contents.appending(path: "Resources/AppIcon.icns"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "io.github.trukhinyuri.claudeprofiles.launcher.\(profile.id)",
            "CFBundleName": "Claude \(profile.label)",
            "CFBundleDisplayName": "Claude \(profile.label)",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"), options: .atomic)
        if let launcherRegistrar { launcherRegistrar(app) } else { Self.signAndRegister(app) }
    }

    /// Signs a launcher ad hoc again after its files changed and tells Launch Services it changed.
    static func signAndRegister(_ app: URL) {
        run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
    }

    /// Updates every profile's launcher in place, writing `cliPath` into it: after the launchers folder was renamed
    /// (see `LegacyMigration`), so launchers call `baton` at its new path.
    /// - Returns: how many were updated, and a plain line for each that couldn't be.
    public func rewriteLaunchersInPlace() -> (rewritten: Int, problems: [String]) {
        guard !isReadOnly else { return (0, []) }
        let all: [Profile]
        do { all = try registry.load() } catch {
            return (
                0, ["Couldn't read the profile list, so the launchers were not updated: \(error.localizedDescription). Run `baton refresh` once it is fixed."]
            )
        }
        var rewritten = 0
        var problems: [String] = []
        for profile in all {
            do {
                try buildLauncher(for: profile)
                rewritten += 1
            } catch {
                problems.append("Couldn't update the launcher Claude \(profile.label): \(error.localizedDescription). Run `baton refresh` to try again.")
            }
        }
        return (rewritten, problems)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Claude Desktop's managed preferences, which an organization sets on its Macs through a configuration profile.
/// Baton only reads them, and says when one of them concerns what it does.
enum ManagedPolicy {
    static let domain = "com.anthropic.claudefordesktop"

    /// The preferences set to true for the whole Mac or for `user`.
    static func enabled(in folder: URL, user: String) -> Set<String> {
        var keys = Set<String>()
        for file in [folder.appending(path: "\(domain).plist"), folder.appending(path: "\(user)/\(domain).plist")] {
            guard let data = try? Data(contentsOf: file),
                let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            for (key, value) in values where (value as? Bool) == true { keys.insert(key) }
        }
        return keys
    }

    /// A line for each managed preference that concerns Baton; empty when none is set.
    static func warnings(in folder: URL, user: String) -> [String] {
        let set = enabled(in: folder, user: user)
        var warnings: [String] = []
        if set.contains("disableMultiAccount") {
            warnings.append(
                "Your organization set Claude Desktop on this Mac to one account at a time (the managed policy "
                    + "“Single account only”). Check with them before you sign in to other subscriptions here.")
        }
        if set.contains("disableDeepLinkRegistration") {
            warnings.append(
                "Your organization turned off claude:// links in Claude Desktop on this Mac, so Continue can't open "
                    + "sessions in another window for you. Open them from that window's sidebar instead.")
        }
        return warnings
    }
}

/// Where Baton runs from, for the Dock launchers that call its `baton`.
public enum AppLocation {
    /// Why launchers must not point into `app`, or `nil` when its place is fine. macOS runs a downloaded app that was
    /// never moved from a temporary copy (App Translocation) that is gone after a restart, and an app left in Downloads
    /// is usually about to move; launchers pointing there would stop reaching `baton`.
    public static func problem(app: URL, home: URL) -> String? {
        let path = app.standardizedFileURL.path
        let downloads = home.appending(path: "Downloads", directoryHint: .isDirectory).standardizedFileURL.path
        let place: String
        if path.contains("/AppTranslocation/") {
            place = "a temporary copy macOS made of it"
        } else if path.hasPrefix(downloads + "/") {
            place = "your Downloads folder"
        } else {
            return nil
        }
        return "Baton is running from \(place), so it doesn't update the Dock icons of your subscriptions. "
            + "Quit Baton, move Baton.app to Applications in Finder, then open it from there."
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// An advisory `flock(2)` lock shared by the app, the CLI and launchers.
enum FileLock {
    /// The locks the current thread holds, so a nested blocking call for the same lock runs its body instead of
    /// waiting for itself: `flock` locks belong to each open file, so a second `open` in the same process would
    /// block forever. A nested non-blocking call still finds the lock taken.
    private static let heldKey = "BatonFileLocksHeld"

    /// - Returns: the body's result, or `nil` if `blocking` is false and the lock is held elsewhere.
    static func withLock<T>(_ url: URL, blocking: Bool, _ body: () throws -> T) throws -> T? {
        let path = url.standardizedFileURL.path
        if (Thread.current.threadDictionary[heldKey] as? Set<String>)?.contains(path) == true { return blocking ? try body() : nil }
        return try holding(path) {
            let descriptor = try openFile(url)
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) == 0 else {
                if !blocking && (errno == EWOULDBLOCK || errno == EAGAIN) { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    /// Runs `body` with `path` among the locks the current thread holds.
    private static func holding<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        let thread = Thread.current.threadDictionary
        thread[heldKey] = (thread[heldKey] as? Set<String> ?? []).union([path])
        defer {
            var after = thread[heldKey] as? Set<String> ?? []
            after.remove(path)
            thread[heldKey] = after
        }
        return try body()
    }

    private static func openFile(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    /// A lock taken at once and kept across `await`s until `release()`, such as open.lock while a window starts.
    /// `flock` belongs to the open file, not to a thread, so any thread may let it go.
    final class Held: @unchecked Sendable {
        private let path: String
        private let lock = NSLock()
        private var descriptor: Int32

        /// Waits for the lock.
        init(_ url: URL) throws {
            path = url.standardizedFileURL.path
            descriptor = try FileLock.openFile(url)
            guard flock(descriptor, LOCK_EX) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(descriptor)
                throw error
            }
        }

        deinit { release() }

        /// Runs `body` on this thread with the lock counted as this thread's, so a `withLock` for it in there runs
        /// its body at once instead of waiting for itself.
        func run<T>(_ body: () throws -> T) rethrows -> T { try FileLock.holding(path, body) }

        /// Lets the lock go; later calls do nothing.
        func release() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }
    }
}
