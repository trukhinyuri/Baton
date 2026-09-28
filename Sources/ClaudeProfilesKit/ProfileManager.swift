import AppKit
import Darwin

public enum ProfileError: LocalizedError, Equatable {
    case claudeNotInstalled(String)
    case invalidLabel
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

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled(let path): "Claude Desktop is not installed at \(path). Install it from claude.ai/download."
        case .invalidLabel: "Use 1–\(Profile.maxLabelLength) letters, digits, “-” or “_” for the label."
        case .invalidEmail: "That doesn’t look like an email address."
        case .duplicateLabel(let label): "A profile labeled “\(label)” already exists."
        case .notFound(let id): "No profile “\(id)”."
        case .cloneFailed(let reason): "Couldn’t create the app copy: \(reason)"
        case .windowStillRunning(let label): "Claude \(label) is open without its profile and did not quit. Finish or stop its active work, close that window, then open the profile again."
        case .notSignedIn(let label): "Sign in to Claude \(label) first, then continue there."
        case .sameWindow(let label): "This already belongs to Claude \(label). Choose another profile to continue in."
        case .coworkNeedsItsOwnHandoff(let title): "“\(title)” is a Cowork task. Continue it on its own, so its history and files are attached."
        case .notAllowed(let folders, let accounts, let label, let email):
            "Work in \(folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " and ")) continues only in "
                + (accounts.isEmpty ? "no account (its folder rules have none in common)" : accounts.joined(separator: " or "))
                + ", and Claude \(label) is signed in as \(email ?? "an account whose email can't be read"). Nothing was changed. "
                + "Continue in a window signed in with that account, or change the rule with `claude-profiles rule`."
        case .rulesUnreadable(let reason): "Can't read the folder rules, so nothing continues until they are fixed: \(reason)"
        case .windowDidNotAppear(let label, let links):
            "Claude \(label) started but its window didn't appear, so \(links) of the sessions were not handed to it. Open them from its sidebar, or continue them again once it's open."
        }
    }
}

/// What the UI and CLI show for one Claude window: the main app or a profile.
public struct ProfileStatus: Identifiable, Equatable, Sendable {
    public var profile: Profile?          // nil for the main Claude app
    public var accountID: String?
    public var email: String?
    public var usage: Usage?
    public var isRunning: Bool
    /// The profile's app copy is open without the profile's data (opened from its own Dock icon or reopened
    /// by macOS at login), so that window shows the main app's account.
    public var isOpenWithoutProfile: Bool

    public init(profile: Profile?, accountID: String?, email: String?, usage: Usage?, isRunning: Bool,
                isOpenWithoutProfile: Bool = false) {
        self.profile = profile
        self.accountID = accountID
        self.email = email
        self.usage = usage
        self.isRunning = isRunning
        self.isOpenWithoutProfile = isOpenWithoutProfile
    }

    public var id: String { profile?.id ?? "main" }
    public var isMain: Bool { profile == nil }
    public var isSignedIn: Bool { accountID != nil }
    public var label: String { profile?.label ?? "MAIN" }
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
public final class ProfileManager: @unchecked Sendable {
    public let paths: Paths
    public let registry: ProfileRegistry
    public let signInRouting: SignInRouting
    /// The `claude-profiles` executable that launchers call. `nil` makes launchers open the engine directly.
    public var cliPath: URL?
    private var fm: FileManager { .default }
    /// Serializes changes to the registry and to engines within this process; `FileLock` does it across processes.
    private let lock = NSRecursiveLock()
    private var emailCache: [String: (account: String, email: String?, checkedAt: Date)] = [:]
    private var openWarning: String?
    /// Opening can succeed using the profile's saved settings even if portable setup could not be refreshed.
    public var lastOpenWarning: String? { lock.withLock { openWarning } }

    public init(paths: Paths = .standard, cliPath: URL? = nil) {
        self.paths = paths
        self.registry = ProfileRegistry(paths: paths)
        self.signInRouting = SignInRouting(paths: paths)
        self.cliPath = cliPath
    }

    /// Profiles from the registry; empty if it is missing or damaged (see `registryError`).
    public var profiles: [Profile] { (try? registry.load()) ?? [] }

    /// Why the registry couldn't be read, if it couldn't. Changes are refused until it is fixed.
    public var registryError: String? {
        do { _ = try registry.load(); return nil } catch {
            return "Can’t read \(paths.registryFile.path): \(error.localizedDescription). A backup is at profiles.json.bak."
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

    // MARK: Status

    public func statuses() -> [ProfileStatus] {
        let running = runningClaudes()
        let main = status(profile: nil, dataDir: paths.mainDataDir,
                          running: running.contains { $0.uses(dataDir: paths.mainDataDir, mainDataDir: paths.mainDataDir, bundle: paths.claudeApp) })
        let all = [main] + profiles.map { profile in
            var entry = status(profile: profile, dataDir: paths.dataDir(for: profile.id),
                               running: running.contains { window(of: profile.id, is: $0) })
            entry.isOpenWithoutProfile = running.contains { $0.isStartedWithoutDataDir(engine: paths.engine(for: profile.id)) }
            return entry
        }
        finishSignInIfDone(all)
        return all
    }

    /// Returns `claude://` links to the main app once the profile signing in is done with them.
    private func finishSignInIfDone(_ statuses: [ProfileStatus]) {
        guard let state = signInRouting.state else { return }
        let target = statuses.first { $0.profile?.id == state.profileID }
        if SignInRouting.isFinished(state, signedIn: target?.isSignedIn ?? false, running: target?.isRunning ?? false,
                                    profileExists: target != nil) {
            signInRouting.end(allProfileIDs: profiles.map(\.id))
        }
    }

    /// The profile whose window currently receives sign-in links, if any.
    public var profileSigningIn: String? { signInRouting.state?.profileID }

    private func status(profile: Profile?, dataDir: URL, running: Bool) -> ProfileStatus {
        let account = DesktopData.accountID(in: dataDir)
        return ProfileStatus(profile: profile, accountID: account,
                             email: account.flatMap { email(in: dataDir, accountID: $0) },
                             usage: DesktopData.usage(in: dataDir), isRunning: running)
    }

    /// Scanning IndexedDB is expensive, so a found email is kept until the account changes
    /// and a miss is retried at most once a minute.
    private func email(in dataDir: URL, accountID: String) -> String? {
        let key = dataDir.path
        if let cached = lock.withLock({ emailCache[key] }), cached.account == accountID,
           cached.email != nil || Date().timeIntervalSince(cached.checkedAt) < 60 {
            return cached.email
        }
        let found = DesktopData.email(in: dataDir, accountID: accountID)
        lock.withLock { emailCache[key] = (accountID, found, Date()) }
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

    func runningClaudes() -> [RunningClaude] { claudeProcesses().map(RunningClaude.init(app:)) }

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
        apps.forEach { $0.terminate() }
        for _ in 0..<Int(seconds * 5) where apps.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        if force { apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() } }
    }

    // MARK: Create

    @discardableResult
    public func create(label rawLabel: String, email rawEmail: String?, color: String? = nil) throws -> Profile {
        guard fm.fileExists(atPath: paths.claudeApp.path) else { throw ProfileError.claudeNotInstalled(paths.claudeApp.path) }
        let label = rawLabel.trimmingCharacters(in: .whitespaces).uppercased()
        guard Profile.isValidLabel(label) else { throw ProfileError.invalidLabel }
        let email = rawEmail?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let email, !Profile.isValidEmail(email) { throw ProfileError.invalidEmail }

        lock.lock(); defer { lock.unlock() }
        var all = try registry.load()
        guard !all.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
            throw ProfileError.duplicateLabel(label)
        }
        var id = Profile.slug(for: label)
        let base = id
        var n = 2
        while all.contains(where: { $0.id == id }) || fm.fileExists(atPath: paths.dataDir(for: id).path) {
            id = "\(base)-\(n)"; n += 1
        }
        let profile = Profile(id: id, label: label, email: email,
                              color: color ?? Profile.palette[all.count % Profile.palette.count])
        try fm.createDirectory(at: paths.dataDir(for: id), withIntermediateDirectories: true)
        try buildEngine(for: profile)
        try buildLauncher(for: profile)
        all.append(profile)
        try registry.save(all)
        return profile
    }

    // MARK: Open

    /// Brings the profile's window forward, starting it first if needed.
    /// - Parameter link: a `claude://` link for that window to handle, such as a session to open.
    public func open(_ id: String, link: URL? = nil) async throws {
        try await open(id, links: link.map { [$0] } ?? [])
    }

    /// Brings the profile's window forward, starting it first if needed, and hands it `links` in one go.
    /// Handing them over one by one while the window is still starting could start a second copy of it.
    public func open(_ id: String, links: [URL]) async throws {
        lock.withLock { openWarning = nil }
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
            if !links.isEmpty { try await deliver(links, to: engine) } else { window.app?.activate() }
            return
        }
        try lock.withLock {
            // It may have been removed while this call waited for the lock.
            guard profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
            if !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                try buildEngine(for: profile)
            }
            // The app and the CLI may open a profile at the same moment; the merges read and write without Claude's locks.
            _ = try FileLock.withLock(paths.stateDir.appending(path: "open.lock"), blocking: true) {
                // A launcher or CLI can start a profile without the manager's background timer.
                // Claude reads its cards at startup, so share sessions first; a failure must not keep the window closed.
                var problems: [String] = []
                do { _ = try prepareSessionsForLaunch() }
                catch { problems.append("Sessions: \(error.localizedDescription)") }
                do { _ = try SettingsSync(paths: paths).run(into: paths.dataDir(for: profile.id)) }
                catch { problems.append("Setup: \(error.localizedDescription)") }
                do { _ = try InterfaceSync(paths: paths).run(into: paths.dataDir(for: profile.id), profileID: profile.id) }
                catch { problems.append("Interface: \(error.localizedDescription)") }
                if !problems.isEmpty {
                    openWarning = "Claude \(profile.label) opened, but some shared settings could not be refreshed. " + problems.joined(separator: " ")
                }
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(paths.dataDir(for: profile.id).path)"]
        try await launch(engine, configuration: configuration, links: links, label: profile.label)
    }

    /// Starts a new copy of the app at `app` and hands it `links`. Until its window exists, Claude keeps only the
    /// last link it receives (`open-url` stores one pending URL), so only the first goes with the launch; the rest
    /// follow once the window is on screen.
    private func launch(_ app: URL, configuration: NSWorkspace.OpenConfiguration, links: [URL], label: String) async throws {
        guard let first = links.first else {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return
        }
        let started = try await NSWorkspace.shared.open([first], withApplicationAt: app, configuration: configuration)
        let rest = Array(links.dropFirst())
        guard !rest.isEmpty else { return }
        guard try await waitForWindow(of: started.processIdentifier, seconds: 90) else {
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
        lock.withLock { openWarning = nil }
        if runningClaudes().contains(where: {
            $0.uses(dataDir: paths.mainDataDir, mainDataDir: paths.mainDataDir, bundle: paths.claudeApp)
        }) {
            if !links.isEmpty { try await deliver(links, to: paths.claudeApp) }
            else { _ = try await NSWorkspace.shared.openApplication(at: paths.claudeApp, configuration: NSWorkspace.OpenConfiguration()) }
            return
        }
        do {
            _ = try FileLock.withLock(paths.stateDir.appending(path: "open.lock"), blocking: true) {
                var problems: [String] = []
                do { _ = try prepareSessionsForLaunch() }
                catch { problems.append("sessions could not be shared first: \(error.localizedDescription)") }
                if !problems.isEmpty { lock.withLock { openWarning = "Claude opened, but " + problems.joined(separator: "; ") } }
            }
        } catch {
            lock.withLock { openWarning = "Claude opened, but sessions could not be shared first: \(error.localizedDescription)" }
        }
        // Profile windows run the same app; a new instance keeps this one from reusing theirs.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await launch(paths.claudeApp, configuration: configuration, links: links, label: "(main)")
    }

    /// Hands a `claude://` link to the running window of the app at `app`. macOS delivers it to that exact copy,
    /// so no other window sees it and no permission is needed.
    private func deliver(_ links: [URL], to app: URL) async throws {
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
    public func continueConversation(_ conversation: Conversation, in destination: String,
                                     mode: ContinueMode = .auto) async throws -> ContinueResult {
        guard conversation.kind == .cowork else {
            return .openedSession(try await continueAll([conversation], in: destination, mode: mode)[0])
        }
        let label = try checkDestination(destination)
        if conversation.ownerID == destination { throw ProfileError.sameWindow(label) }
        try checkRules(folders: conversation.folders, destination: destination)
        let handoff = try CoworkHandoff.prepare(conversation, sourceLabel: self.label(of: conversation.ownerID ?? "main"), paths: paths)
        try await openWindow(destination, links: [handoff.link])
        return .startedCoworkTask(handoff)
    }

    /// What continuing `conversations` in `destination` would do, without changing anything.
    /// - Parameter folder: a folder a new session will start in as well, which its folder rule covers too.
    public func plan(_ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
                     newSessionIn folder: String? = nil, now: Date = Date()) throws -> [ContinuePlan] {
        try checkDestination(destination)
        try checkRules(folders: conversations.flatMap(\.folders) + (folder.map { [$0] } ?? []), destination: destination)
        let dataDir = dataDir(of: destination)
        let isOpen = isWindowOpen(destination)
        let live = conversations.isEmpty ? [] : LiveSessions.ids(claudeDir: paths.claudeDir)
        var supported: Set<String>?
        return try conversations.map { found in
            var conversation = found
            conversation.hasLiveProcess = found.hasLiveProcess || live.contains(found.sessionID)
            guard conversation.kind != .cowork else { throw ProfileError.coworkNeedsItsOwnHandoff(conversation.title) }
            let forks = mode.forks(conversation, now: now)
            // A closed window reads the shared card of a regular Code session, with its model, when it starts;
            // anything else Claude imports there and takes the model from the history.
            let source: ModelNote.CardSource = !isOpen && !forks && conversation.kind == .code ? .shared : .imported
            var note: ModelNote?
            if let model = conversation.model {
                if supported == nil { supported = ModelSupport.modelsUsed(in: dataDir) }
                note = ModelNote.decide(model: model, historyModel: ConversationIndex.lastModel(of: conversation.transcript),
                                        supported: supported?.contains(model) == true, card: source)
            }
            return ContinuePlan(conversation: conversation, destination: destination, forks: forks, model: note)
        }
    }

    /// How long `continueAll` waits for the destination window to import the sessions it was handed.
    public var importWait: TimeInterval = 45

    /// Continues every one of `conversations` in `destination`, opening that window once with all of them and,
    /// if `folder` is given, a new session in that folder. Copies are made before the window opens; Claude
    /// imports each session itself, and `ContinuePlan.opened` says whether it did.
    @discardableResult
    public func continueAll(_ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
                            newSessionIn folder: String? = nil, now: Date = Date()) async throws -> [ContinuePlan] {
        var plans = try plan(conversations, in: destination, mode: mode, newSessionIn: folder, now: now)
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
        if let owner = plan.conversation.ownerID { plan.conversation.title += " · from \(label(of: owner))" }
        else { plan.conversation.title += " · copy" }
        let copies = ContinueCopies(paths: paths)
        let folder = plan.conversation.transcript.deletingLastPathComponent()
        if let reused = copies.existingCopy(of: plan.conversation.sessionID, transcript: plan.conversation.transcript, in: plan.destination) {
            plan.sessionID = reused
            return nil
        }
        let made = try TranscriptFork.forkReporting(plan.conversation, claudeDir: paths.claudeDir, tempDir: paths.claudeTempDir)
        plan.sessionID = made.id
        plan.carried = made
        try? copies.record(source: plan.conversation.sessionID, destination: plan.destination, copy: made.id,
                           sourceLength: made.sourceLength, sourceTail: made.sourceTail)
        if !made.leftBehind.isEmpty || !made.worktrees.isEmpty {
            Log.logger("continue").info("Copy \(made.id, privacy: .private) left \(made.leftBehind.count) scratchpad items and \(made.worktrees.count) worktrees behind")
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
            throw ProfileError.notAllowed(folders: allowed.rules.map(\.folder), accounts: allowed.accounts.sorted(),
                                          label: label(of: destination), email: email)
        }
    }

    @discardableResult
    private func checkDestination(_ destination: String) throws -> String {
        let label = label(of: destination)
        guard destination == "main" || profiles.contains(where: { $0.id == destination }) else { throw ProfileError.notFound(destination) }
        guard DesktopData.accountID(in: dataDir(of: destination)) != nil else { throw ProfileError.notSignedIn(label) }
        return label
    }

    private func dataDir(of window: String) -> URL {
        window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
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
        return ConversationIndex.scan(paths: paths, windows: windows).map { found in
            var conversation = found
            conversation.hasLiveProcess = conversation.kind != .cowork && live.contains(conversation.sessionID)
            return conversation
        }
    }

    /// Refreshes session cards before a cold launch, even when the manager is not running.
    /// Opening a window never propagates deletions or migrates account-owned Project/Cowork workers.
    /// Errors abort the launch instead of silently presenting stale history as successfully shared.
    @discardableResult
    func prepareSessionsForLaunch() throws -> SessionSync.Report {
        guard let report = try FileLock.withLock(paths.stateDir.appending(path: "sync.lock"), blocking: true, {
            createSessionFolders()
            return try SessionSync(paths: paths, dataDirs: dataDirs).run(propagateDeletions: false)
        }) else { throw POSIXError(.EWOULDBLOCK) }
        return report
    }

    // MARK: Remove

    /// Quits the profile's window and moves its app copy and data (including its sign-in) to the Trash.
    /// Claude Code sessions stay available in every other profile. Cowork sessions keep their files in the
    /// profile's data, so the ones started in it go to the Trash with it and leave the other windows too.
    public func remove(_ id: String) async throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let engine = paths.engine(for: id).standardizedFileURL
        try await quit(claudeProcesses().filter { $0.bundleURL?.standardizedFileURL == engine }, waiting: 10, force: true)

        // Share cards of sessions started in this window moments ago before its data goes away.
        _ = try? syncSessions()

        try lock.withLock {
            let remembered = InterfaceSync(paths: paths).stateFile(for: id)
            for url in [paths.launcher(for: profile), paths.engine(for: id), paths.dataDir(for: id), remembered] where fm.fileExists(atPath: url.path) {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            try registry.save(try registry.load().filter { $0.id != id })
        }
        if signInRouting.state?.profileID == id { signInRouting.end(allProfileIDs: profiles.map(\.id)) }
    }

    // MARK: Maintenance

    /// Rebuilds app copies left behind by a Claude Desktop update and launchers that point to a moved CLI.
    /// Copies that are running are left alone until next launch.
    public func refresh() throws {
        let running = runningBundlePaths()
        for profile in profiles {
            let engine = paths.engine(for: profile.id)
            try lock.withLock {
                if !running.contains(engine.standardizedFileURL.path), !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                    try buildEngine(for: profile)
                }
            }
            if launcherScript(for: profile) != (try? String(contentsOf: launcherExecutable(for: profile), encoding: .utf8)) {
                try buildLauncher(for: profile)
            }
        }
    }

    /// Shares ordinary local Code sessions; inventories Cowork without cross-profile writes.
    /// - Returns: `nil` if another sync (from the app or the CLI) is already running.
    @discardableResult
    public func syncSessions() throws -> SyncReport? {
        try FileLock.withLock(paths.stateDir.appending(path: "sync.lock"), blocking: false) {
            createSessionFolders()
            let propagateDeletions = !isAnyClaudeRunning
            let sessions = try SessionSync(paths: paths, dataDirs: dataDirs).run(propagateDeletions: propagateDeletions)
            let cowork = try CoworkSync(paths: paths, dataDirs: dataDirs).run(propagateDeletions: propagateDeletions)
            // Adds files only, never in Claude's own data, so it runs whether or not windows are open.
            var carried: [NativeForkCarry.Report] = []
            do { carried = try NativeForkCarry.run(paths: paths, dataDirs: dataDirs) } catch {
                Log.logger("carry").error("Carry failed: \(error.localizedDescription, privacy: .private)")
            }
            return SyncReport(sessions: sessions, cowork: cowork, carried: carried)
        }
    }

    /// Claude Desktop creates a signed-in account's session folders only when that account starts its first
    /// session, and reads them only at launch. Creating them right away lets sharing fill them before the next launch.
    func createSessionFolders() {
        for dataDir in dataDirs {
            guard let account = DesktopData.accountID(in: dataDir) else { continue }
            let items = (try? LocalStorage(dataDir: dataDir).items(origin: InterfaceSync.origin)) ?? [:]
            guard let scope = DesktopData.scope(dataDir: dataDir, items: items)?.value,
                  scope.hasPrefix(account + "/") else { continue }
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
        guard profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        _ = try? syncSessions()
        let engine = paths.engine(for: id).standardizedFileURL
        let running = claudeProcesses().filter { $0.bundleURL?.standardizedFileURL == engine }
        guard !running.isEmpty else { return }   // closed already: it picks everything up when opened
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

    func engineIsOutdated(_ id: String) -> Bool {
        let installed = Self.version(of: paths.claudeApp)
        return installed != nil && installed != Self.version(of: paths.engine(for: id))
    }

    /// Clones Claude.app with APFS copy-on-write (near-zero disk use) and gives the clone a labeled Finder icon.
    /// The icon is the only change: it adds a Finder icon file, and Anthropic's code signature still verifies.
    func buildEngine(for profile: Profile) throws {
        try lock.withLock {
            _ = try FileLock.withLock(paths.stateDir.appending(path: "engines.lock"), blocking: true) {
                try cloneEngine(for: profile)
            }
        }
    }

    private func cloneEngine(for profile: Profile) throws {
        let engine = paths.engine(for: profile.id)
        try EngineInstall.install(from: paths.claudeApp, to: engine)
        NSWorkspace.shared.setIcon(icon(for: profile), forFile: engine.path, options: [])
    }

    func icon(for profile: Profile) -> NSImage {
        IconRenderer.profileIcon(base: NSWorkspace.shared.icon(forFile: paths.claudeApp.path),
                                 label: profile.label, color: NSColor(hex: profile.color))
    }

    func launcherExecutable(for profile: Profile) -> URL {
        paths.launcher(for: profile).appending(path: "Contents/MacOS/launch")
    }

    func launcherScript(for profile: Profile) -> String {
        let engine = paths.engine(for: profile.id).path
        let dataDir = paths.dataDir(for: profile.id).path
        var script = "#!/bin/sh\n# Generated by Claude Profiles. Opens Claude with the \(profile.label) profile.\n"
        if let cli = cliPath?.path {
            script += "if [ -x \(shellQuote(cli)) ]; then exec \(shellQuote(cli)) open \(shellQuote(profile.id)); fi\n"
        }
        script += "exec /usr/bin/open -n -a \(shellQuote(engine)) --args \(shellQuote("--user-data-dir=" + dataDir))\n"
        return script
    }

    /// A tiny app bundle that opens the profile. It can live in the Dock and is found by Spotlight.
    func buildLauncher(for profile: Profile) throws {
        let app = paths.launcher(for: profile)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
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
            .write(to: contents.appending(path: "Info.plist"))
        Self.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
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

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// An advisory `flock(2)` lock shared by the app, the CLI and launchers.
enum FileLock {
    /// - Returns: the body's result, or `nil` if `blocking` is false and the lock is held elsewhere.
    static func withLock<T>(_ url: URL, blocking: Bool, _ body: () throws -> T) throws -> T? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) == 0 else {
            if !blocking && (errno == EWOULDBLOCK || errno == EAGAIN) { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
