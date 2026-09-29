import AppKit
import BatonKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [ProfileStatus] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncChanges = 0
    @Published private(set) var syncError: String? { didSet { remember(syncError) } }
    @Published private(set) var registryError: String? { didSet { remember(registryError) } }
    /// The actions still running; the footer shows the newest one's message (see `OperationsInFlight`).
    @Published private(set) var operations = OperationsInFlight()
    @Published var errorMessage: String? { didSet { remember(errorMessage) } }
    @Published var isReporting = false
    /// Says what kind of problem `errorMessage` is about.
    @Published private(set) var errorTitle = "Something went wrong"
    /// The window whose status panel is open, and every window's status as of opening it.
    @Published var statusWindow: String?
    @Published private(set) var windowStatuses: [WindowStatus] = []
    /// Errors and warnings the window showed, newest last, for a problem report. Kept only in memory.
    private(set) var recentErrors: [String] = []
    private var lastSyncReport: SyncReport?
    @Published var isAdding = false
    @Published var isContinuing = false
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var isLoadingConversations = false
    /// What the limit banner asks the Continue sheet to select: the most recent session of the window at its limit
    /// (`continueFrom`) and the window the banner named (`continueTo`). Both `nil` for a plain “Continue work…”.
    private(set) var continueFrom: String?
    private(set) var continueTo: String?
    /// The result of the last action, shown above the list in full. One with a warning stays until it is dismissed;
    /// any other goes after 20 seconds, and a warning it covered shows again.
    @Published private(set) var notices = Notices()
    var notice: String? { notices.current?.text }
    var noticeIsWarning: Bool { notices.current?.isWarning == true }
    private var noticeTask: Task<Void, Never>?
    /// The line each window waiting for a Dock-started Claude to finish shows, withdrawn once its open ends.
    private var strayLines: [String: String] = [:]
    /// Brings the Baton window forward; set by the menu bar icon at launch, by the window and by the menu bar's items.
    /// An error while the window is closed (from the menu bar, or from a copy reopened from its own Dock icon) would
    /// otherwise wait unseen until the window next opens.
    var presentWindow: (@MainActor () -> Void)?
    @Published var isCheckingSessions = false
    @Published var diagnostics: [Diagnostics.Entry] = []
    /// What the footer shows: the start-up warnings, which stay until Baton quits, then each window's open warning.
    /// Worked out when read, not kept by a didSet: Swift runs no didSet for what a class sets in its own init.
    var setupWarning: String? {
        let shown = [startUpWarning, openWarnings.text].compactMap { $0 }.joined(separator: " ")
        return shown.isEmpty ? nil : shown
    }
    /// Set once, in init, through `warnAtStartUp`.
    @Published private var startUpWarning: String?
    /// Each window's warning from the last time an open action started it (`ProfileManager.openWarning(of:)`).
    @Published private var openWarnings = OpenWarnings()
    @Published var pendingRemoval: ProfileStatus?
    /// What folder rules kept out of windows in the last sync, for the footer (`ProfileManager.withheldLines`).
    @Published private(set) var withheldNotice: String?
    /// Set when this app is installed more than once (say `make install` plus the Homebrew cask).
    @Published private(set) var installWarning: String?
    /// Which accounts may continue work in which folders; `nil` if the rules file can't be read.
    @Published private(set) var folderRules: [FolderRule]? = []
    /// Local only's optional extra, Mac-wide: off by default. See `CloudMoveLock`.
    @Published private(set) var cloudMoveLockOn = false
    /// Asking before the lock goes on: it changes a setting of every Claude Code session on this Mac.
    @Published var isConfirmingCloudMoveLock = false
    /// Windows blocked at a limit as of the last reload (see `LimitWatch`).
    @Published private(set) var atLimit: Set<String> = []
    /// What the limit banner says for a window whose work is being handed over (moving, waiting), by window id.
    @Published private(set) var handoverLines: [String: String] = [:]
    /// Windows whose work this app is handing over now.
    private var handingOver: Set<String> = []
    private let limitWatch = LimitWatch()

    let manager: ProfileManager
    let isDemo = DemoMode.isOn()
    /// In demo mode with `BATON_DEMO_SHEET=wait`, the offer to wait that the Continue sheet shows at once.
    private(set) var demoOffer: AutoResumeOffer?
    private var refreshTimer: Timer?
    private var syncTimer: Timer?
    /// Profiles whose window was open and not yet signed in at the last check.
    private var awaitingSignIn: Set<String> = []
    private var launchObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    /// One reload runs at a time, so an older snapshot never lands after a newer one; a reload asked for meanwhile
    /// runs once this one is done.
    private var isReloading = false
    private var reloadAgain = false

    init() {
        if !isDemo { Self.handOverToRunningCopy() }
        let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/baton")
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Run from Downloads or from the temporary copy macOS makes of a downloaded app: launchers must not point here,
        // or they stop reaching `baton` once it moves or after a restart, so no subscription is added meanwhile.
        let misplaced = isDemo ? nil : AppLocation.problem(app: Bundle.main.bundleURL, home: home)
        let cliPath = misplaced == nil && FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
        // A folder of the earlier name that links nowhere right now (a disk not connected): nothing may write, or a
        // new, empty Baton folder would win for good. The window shows why; open Baton again once it is connected.
        let unreachable = isDemo ? nil : Paths.unreachableFolder(home: home)
        // Baton's own log first, so the folder rename below reaches the file a problem report reads. The data folder
        // is never renamed, so this path holds after the rename too.
        if !isDemo, unreachable == nil { Log.enableFile(in: Paths.stateRoot(home: home)) }
        // Before any path is resolved, timer runs, launcher is rebuilt or session is shared: the manager's paths are
        // whichever folders exist once this is done. Skipped while Baton runs from inside the old launchers folder,
        // and in demo mode, which changes nothing.
        let migration =
            unreachable != nil || misplaced != nil
            ? nil
            : LegacyMigration.atAppStart(home: home, app: Bundle.main.bundleURL, cli: cliPath, variables: ProcessInfo.processInfo.environment)
        manager = ProfileManager(cliPath: cliPath, readOnly: isDemo || unreachable != nil, misplaced: misplaced)
        // A profile that waits for a Claude started from its Dock icon to finish its work says so until it opens.
        manager.onStrayWait = { [weak self] id, line in
            Task { @MainActor in
                self?.strayLines[id] = line
                self?.show(notice: line, isWarning: true)
            }
        }
        reload()
        if let unreachable {
            warnAtStartUp(unreachable.replacingOccurrences(of: "Connect it and try again;", with: "Connect it and open Baton again;"))
            return
        }
        // Documentation screenshots: BATON_DEMO=1 shows sample data, …_DEMO_SHEET=1 opens "Add"
        // …_DEMO_SHEET=continue opens "Continue work…", …=wait the same with its offer to wait for a reset,
        // …=report "Report a problem…" and …=status a window's status.
        // With …_DEMO_SNAPSHOT=<file.png> it draws the window into that file and quits (see DemoSnapshot).
        // Everything below this guard (checks, timers, sync, launchers, the launch observer) never runs in demo mode.
        guard !isDemo else {
            let sheet = ProcessInfo.processInfo.environment["BATON_DEMO_SHEET"]
            isAdding = sheet == "1"
            isContinuing = sheet == "continue" || sheet == "wait"
            isReporting = sheet == "report"
            if sheet == "wait" { demoOffer = DemoData.autoResumeOffer }
            if sheet == "status" { showStatus(of: "work") }
            if let file = DemoSnapshot.file() {
                let sheets = demoOffer != nil ? 2 : isAdding || isContinuing || isReporting || statusWindow != nil ? 1 : 0
                DemoSnapshot.take(to: file, sheets: sheets)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = DemoSnapshot.mainWindow() else { return }
                // The demo's size and state are not remembered for the real app, which shares its preferences.
                window.isRestorable = false
                _ = window.setFrameAutosaveName("")
                window.setContentSize(DemoSnapshot.contentSize)
            }
            return
        }
        // Re-registers the main Claude after an abandoned sign-in and notes a Claude Desktop version
        // outside the tested range: information for the footer, never a blocking alert.
        var startUp = (misplaced.map { [$0] } ?? []) + manager.startUpChecks()
        switch migration {
        case .migrated(let moved)? where moved.problems.isEmpty:
            show(notice: LegacyMigration.message(for: .migrated(moved), home: manager.paths.home))
        // A rename that left something undone is a warning, not a success notice.
        case .migrated(let moved)?: startUp.append(LegacyMigration.message(for: .migrated(moved), home: manager.paths.home))
        case .failed(let message)?: startUp.append(message)
        default: break  // kept or both exist: the status panel and `baton doctor` say why
        }
        if !startUp.isEmpty { warnAtStartUp(startUp.joined(separator: " ")) }
        cloudMoveLockOn = manager.cloudMoveLock.status() == .on
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        if misplaced == nil { Task.detached { [manager] in try? manager.refresh() } }
        installWarning = AppInstances.duplicateWarning(AppInstances.installedCopies())
        syncNow()
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            Task { @MainActor in self?.reopenIfStartedWithoutProfile(pid) }
        }
        // A window that quits gets Local only right away, before it is started again from the Dock or Spotlight.
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == ClaudeVersion.bundleIdentifier
            else { return }
            Task { @MainActor in self?.applyLocalOnlyToClosedWindows() }
        }
        limitWatch.start(self)
        // Handovers a quit or a crash of Baton left unfinished: a destination to restart once free, a source to close.
        resumeHandovers()
        // macOS reopens windows at login by starting each app copy without its arguments, possibly before this app.
        manager.recentlyStartedWithoutDataDir(within: 120).forEach(reopenIfStartedWithoutProfile)
    }

    /// Only one copy may sync at a time: a second one brings the first forward and quits before touching anything.
    /// An outdated copy (Claude Profiles.app, one in the Trash or an older version) is quit instead, and this one
    /// keeps starting: handing over to it would keep the old app running after an upgrade.
    private static func handOverToRunningCopy() {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppInstances.bundleID).filter { $0.processIdentifier != me }
        guard !running.isEmpty else { return }
        let copies = running.map {
            AppInstances.RunningCopy(pid: $0.processIdentifier, bundle: $0.bundleURL, version: $0.bundleURL.flatMap(AppInstances.version(of:)))
        }
        let decision = AppInstances.handover(others: copies, currentVersion: BuildInfo.current.version)
        let outdated = running.filter { decision.terminate.contains($0.processIdentifier) }
        for app in outdated { app.terminate() }
        // Up to 5 seconds for them to quit; one that doesn't is left to its own quit and never handed over to.
        let deadline = Date().addingTimeInterval(5)
        while outdated.contains(where: { !$0.isTerminated }), Date() < deadline { usleep(100_000) }
        guard let other = decision.handOverTo, let app = running.first(where: { $0.processIdentifier == other }) else { return }
        app.activate()
        exit(0)
    }

    /// Lets an error open the window (`show`), with the `openWindow` of any of the app's views.
    func letErrorsOpenTheWindow(with openWindow: OpenWindowAction) {
        presentWindow = {
            openWindow(id: "main")
            NSApp.activate()
        }
    }

    /// Brings the Baton window forward, opening it if it is closed: a menu command's sheet shows now, not the next
    /// time the window opens.
    func bringWindowForward() { presentWindow?() }

    /// Opens the Continue sheet. From the limit banner it selects the most recent session of the window at its limit
    /// (`tired`) and the window the banner named (`destination`); from anywhere else, the most recent session of any
    /// window and the one with the most room.
    func continueWork(from tired: String? = nil, to destination: String? = nil) {
        continueFrom = tired
        continueTo = destination
        isContinuing = true
    }

    func show(_ error: Error) {
        errorTitle = WindowStatus.alertTitle(for: error)
        errorMessage = error.localizedDescription
        // The alert belongs to the window: with the window closed, open it so the alert shows now.
        if !Self.windowIsOnScreen { presentWindow?() }
    }

    /// The Baton window is open and not in the Dock.
    private static var windowIsOnScreen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized }
    }

    /// The newest of the actions still running, for the footer.
    var busyMessage: String? { operations.message }

    /// An action on `id` is still running, so its Open button waits.
    func isBusy(_ id: String) -> Bool { operations.isBusy(window: id) }

    /// Read out by VoiceOver, which doesn't follow text that changes in place (a result, what Baton is doing).
    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    func showStatus(of id: String) {
        statusWindow = id
        refreshStatus()
    }

    func refreshStatus() {
        guard !isDemo else { windowStatuses = DemoData.windowStatuses; return }
        let manager = manager
        let (localOnly, pending) = localOnlyMaps()
        Task {
            windowStatuses = await Task.detached {
                WindowStatus.collect(
                    manager: manager, diagnostics: (try? Diagnostics.inspect(paths: manager.paths)) ?? [],
                    localOnly: localOnly, pending: pending,
                    folderNotes: LegacyMigration.notes(paths: manager.paths, app: Bundle.main.bundleURL))
            }.value
        }
    }

    /// Local only's on/off state per window, and per window a "waiting for a restart" line while it's `.pending`.
    private func localOnlyMaps() -> (isOn: [String: Bool], pending: [String: [String]]) {
        let localOnly = manager.localOnly
        var isOn: [String: Bool] = [:]
        var pending: [String: [String]] = [:]
        for row in manager.localOnlyStatus() {
            isOn[row.window] = row.status == .on
            if row.status == .pending {
                pending[row.window] = [localOnly.isEnabled(window: row.window) ? "Local only turns on" : "Local only turns off"]
            }
        }
        return (isOn, pending)
    }

    /// Restarts a window so it applies pending changes; refused while a Claude Code session runs in it.
    func restart(_ id: String) {
        guard !isDemo else { return }
        let manager = manager
        run("Restarting Claude \(displayLabel(of: id))…", window: id, opens: true) { try await manager.restart(id) }
    }

    /// Shows `warning` in the footer until Baton quits, and keeps it for a problem report.
    private func warnAtStartUp(_ warning: String) {
        startUpWarning = warning
        remember(warning)
    }

    private func applyLocalOnlyToClosedWindows() {
        let manager = manager
        Task.detached { for problem in manager.applyLocalOnlyToClosedWindows() { Log.error("local-only", problem) } }
    }

    private func remember(_ message: String?) {
        guard let message, recentErrors.last != message else { return }
        recentErrors = Array((recentErrors + [message]).suffix(20))
    }

    /// The problem report for the preview sheet, from what the app already knows. Nothing is sent.
    func makeReport() async -> FeedbackReport {
        guard !isDemo else { return FeedbackReport(facts: DemoData.reportFacts) }
        let (paths, errors, sync, date) = (manager.paths, recentErrors, lastSyncReport, lastSync)
        let localOnly = Dictionary(manager.localOnlyStatus().map { ($0.window, $0.status) }, uniquingKeysWith: { first, _ in first })
        return await Task.detached {
            FeedbackReport(facts: .collect(paths: paths, errors: errors, log: LogTail.read(), lastSync: sync, lastSyncDate: date, localOnly: localOnly))
        }.value
    }

    var profiles: [ProfileStatus] { statuses }
    var existingLabels: Set<String> { Set(statuses.compactMap { $0.profile?.label }) }

    /// The signed-in profile with the most headroom, by weekly usage plus a quarter of five-hour usage, and a sample from
    /// the last three hours, if at least two have such a sample. An older sample can be far too low: Claude records usage only while its window is used.
    var suggestedID: String? { DestinationRanking.mostHeadroom(statuses) }

    /// At its five-hour or weekly limit, and the reset Claude recorded for it hasn't passed (as of the last reload).
    func isAtLimit(_ status: ProfileStatus) -> Bool { atLimit.contains(status.id) }

    /// An open subscription that has reached its limit, so its work may need to continue elsewhere.
    var limitReached: ProfileStatus? { statuses.first { $0.isRunning && isAtLimit($0) } }

    /// Where to continue by default: the signed-in subscription not at its limit with the most headroom, by weekly usage
    /// plus a quarter of five-hour usage (see `DestinationRanking.ranked`), among those signed in with `accounts` if
    /// given, or `preferred` while it is one of them.
    func bestDestination(excluding excluded: String?, accounts: Set<String>? = nil, preferring preferred: String? = nil) -> String? {
        DestinationRanking.best(statuses, excluding: excluded, accounts: accounts, preferring: preferred)
    }

    /// The accounts that may continue work touching `folders`, by the folder rules; `nil` when no rule applies.
    /// Rules that can't be read allow nothing.
    func allowedAccounts(for folders: [String]) -> (accounts: Set<String>, rules: [FolderRule])? {
        guard let rules = folderRules else { return ([], []) }
        return FolderRules.allowedAccounts(for: folders, in: rules)
    }

    /// “ · usage of Claude LAB as of 5h ago” when a subscription's sample is too old to compare by; empty otherwise.
    /// It names the window, since the limit banner shows it next to the one at its limit.
    func staleNote(_ id: String) -> String {
        guard let usage = statuses.first(where: { $0.id == id })?.usage, !usage.isFresh() else { return "" }
        return " · usage of \(buttonLabel(of: id)) as of \(relativeAge(since: usage.sampledAt))"
    }

    func label(of windowID: String) -> String { statuses.first { $0.id == windowID }?.label ?? manager.label(of: windowID) }

    /// What follows "Claude " in what the app says: "(main)" or the profile's label.
    func displayLabel(of windowID: String) -> String {
        statuses.first { $0.id == windowID }?.displayLabel ?? manager.displayLabel(of: windowID)
    }

    /// A window on a button or in a list: "Claude (main)" or "Claude WORK", as everywhere else.
    func buttonLabel(of windowID: String) -> String { "Claude \(displayLabel(of: windowID))" }

    func loadConversations() {
        guard !isDemo else { conversations = DemoData.conversations; return }
        isLoadingConversations = true
        let manager = manager
        Task {
            let found = await Task.detached { manager.conversations() }.value
            if conversations != found { conversations = found }
            isLoadingConversations = false
        }
    }

    /// - Parameter isWarning: the text asks for something (choose a model, stop another window continuing a
    ///   session), so it stays until dismissed.
    func show(notice text: String, isWarning: Bool = false) {
        notices.show(text, isWarning: isWarning)
        noticeTask?.cancel()
        noticeTask = nil
        if !isWarning {
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { notices.expire(text) }
            }
        }
        Self.announce(text)
        reload()
    }

    func dismissNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notices.dismiss()
    }

    func reload() {
        if isDemo {
            statuses = DemoData.statuses
            atLimit = Set(statuses.filter { $0.isSignedIn && $0.limits.isAtLimit() }.map(\.id))
            lastSync = Date().addingTimeInterval(-14)
            return
        }
        guard !isReloading else {
            reloadAgain = true
            return
        }
        isReloading = true
        let manager = manager
        Task.detached {
            let fresh = manager.statuses()
            let problem = manager.registryError
            let rules = try? FolderRules(paths: manager.paths).load()
            let cloudLock = manager.cloudMoveLock.status() == .on
            await MainActor.run {
                if self.statuses != fresh { self.statuses = fresh }
                let blocked = self.limitWatch.update(fresh, model: self)
                if self.atLimit != blocked { self.atLimit = blocked }
                if self.registryError != problem { self.registryError = problem }
                if self.folderRules != rules { self.folderRules = rules }
                if self.cloudMoveLockOn != cloudLock { self.cloudMoveLockOn = cloudLock }
                self.restartAfterFirstSignIn(fresh)
                self.isReloading = false
                if self.reloadAgain {
                    self.reloadAgain = false
                    self.reload()
                }
            }
        }
    }

    /// Turns the optional, Mac-wide cloud move lock on or off; off by default.
    func setCloudMoveLock(_ enabled: Bool) {
        guard !isDemo else { return }
        let manager = manager
        run(nil) { _ = try manager.setCloudMoveLock(enabled) }
    }

    /// Claude reads sessions and per-account settings only at launch, so a window that has just been signed in
    /// for the first time is restarted once to show them.
    private func restartAfterFirstSignIn(_ statuses: [ProfileStatus]) {
        for status in statuses {
            guard let id = status.profile?.id else { continue }
            if status.isRunning && !status.isSignedIn {
                awaitingSignIn.insert(id)
            } else if awaitingSignIn.remove(id) != nil, status.isRunning, status.isSignedIn {
                let manager = manager
                run("Loading your sessions into Claude \(status.label)…", window: id, opens: true) {
                    try await Task.sleep(for: .seconds(3))  // let Claude finish saving the new sign-in
                    try await manager.finishFirstSignIn(id)
                }
            }
        }
    }

    /// A profile's app copy opened from its own Dock icon (kept with “Keep in Dock”) or reopened by macOS starts
    /// without the profile's data and shows the main account. It is replaced with the profile's own window.
    private func reopenIfStartedWithoutProfile(_ pid: pid_t) {
        guard let profile = manager.profileStartedWithoutDataDir(pid: pid) else { return }
        let manager = manager
        run("Opening Claude \(profile.label) with its own account…", window: profile.id, opens: true) { try await manager.open(profile.id) }
    }

    /// - Parameter asked: “Share Sessions Now” rather than the timer: its result is a notice, and a failure is also an
    ///   alert, which opens the window if it is closed. The timer's failures show in the footer only.
    func syncNow(asked: Bool = false) {
        guard !isDemo else { return }
        let manager = manager
        Task.detached {
            do {
                // nil: the CLI or a launcher is syncing right now; the next tick will catch up.
                guard let report = try manager.syncSessions() else {
                    if asked { await MainActor.run { self.show(notice: SyncReport.notice(nil)) } }
                    return
                }
                let withheld = manager.withheldLines(report)
                await MainActor.run {
                    self.lastSync = Date()
                    self.lastSyncReport = report
                    self.withheldNotice = withheld.isEmpty ? nil : withheld.joined(separator: " ")
                    self.lastSyncChanges = report.changes
                    self.syncError = nil
                    if asked { self.show(notice: SyncReport.notice(report)) }
                }
            } catch {
                Log.error("sync", "Sync failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.syncError = error.localizedDescription
                    if asked { self.show(error) }
                }
            }
        }
    }

    /// Does nothing while another action on that window runs: two clicks on Open start it once.
    func open(_ status: ProfileStatus) {
        guard !isDemo, !isBusy(status.id) else { return }
        let manager = manager
        run(status.isRunning ? nil : "Opening Claude \(status.displayLabel)…", window: status.id, opens: true) {
            if let id = status.profile?.id { try await manager.open(id) } else { try await manager.openMain() }
        }
    }

    func checkSessions() {
        let paths = manager.paths
        Task {
            do {
                diagnostics = try await Task.detached { try Diagnostics.inspect(paths: paths) }.value
                isCheckingSessions = true
            } catch { show(error) }
        }
    }

    func create(email: String, label: String, color: String) {
        guard !isDemo else { return }
        let manager = manager
        runOpening("Creating Claude \(label)…") {
            let profile = try await Task.detached { try manager.create(label: label, email: email, color: color) }.value
            try await manager.open(profile.id)
            return profile.id
        }
    }

    func remove(_ status: ProfileStatus) {
        guard !isDemo, let id = status.profile?.id else { return }
        let manager = manager
        run("Removing Claude \(status.label)…", window: id) { try await manager.remove(id) }
    }

    func setCarryPermissionMode(_ enabled: Bool, for id: String) {
        guard !isDemo else { return }
        let manager = manager
        run(nil) { try manager.setCarryPermissionMode(enabled, for: id) }
    }

    func revealLauncher(_ status: ProfileStatus) {
        guard let profile = status.profile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manager.paths.launcher(for: profile)])
    }

    /// Runs `work` with `message` in the footer.
    /// - Parameters:
    ///   - window: the window the action is on, whose Open button waits for it.
    ///   - opens: the action opens `window`, so that window's warning replaces its earlier one; other windows' warnings
    ///     and the start-up warnings stay.
    private func run(_ message: String?, window: String? = nil, opens: Bool = false, _ work: @escaping @Sendable () async throws -> Void) {
        runOpening(message, window: window) {
            try await work()
            return opens ? window : nil
        }
    }

    /// The same, for work that says which window it opened once it is done.
    private func runOpening(_ message: String?, window: String? = nil, _ work: @escaping @Sendable () async throws -> String?) {
        guard !isDemo else { return }  // demo mode changes nothing on this Mac
        let operation = operations.start(message, window: window)
        if let message { Self.announce(message) }
        Task {
            do {
                // Never waits: the manager guards warnings with a lock it holds only while reading or writing them.
                if let window = try await work() {
                    let warning = manager.openWarning(of: window)
                    openWarnings.record(warning, for: window)
                    remember(warning)
                }
            } catch { show(error) }
            if let window, let line = strayLines.removeValue(forKey: window) { notices.withdraw(line) }
            operations.finish(operation)
            reload()
            if statusWindow != nil { refreshStatus() }
        }
    }
}

// MARK: - Handing work over when a window reaches its limit

extension AppModel {
    /// The limit banner: a window whose work is being handed over, else an open window at its limit, and its line.
    var limitBanner: (status: ProfileStatus, line: String)? {
        if let (id, line) = handoverLines.min(by: { $0.key < $1.key }), let status = statuses.first(where: { $0.id == id }) {
            return (status, line)
        }
        guard let tired = limitReached else { return nil }
        return (tired, HandoverTrigger.bannerLine(tired, noRoom: manager.noRoomLine(for: tired.id, statuses: statuses)))
    }

    /// After each reload (`LimitWatch.update`): hands over the work of every open window that has just reached its
    /// limit while it was used, unless `baton handover auto off` turned that off.
    func handOverDue(_ statuses: [ProfileStatus]) {
        guard !isDemo, !manager.isReadOnly else { return }
        let log = HandoverLog(paths: manager.paths)
        let due = HandoverTrigger.due(
            statuses, handled: { log.handled(source: $0, resetsAt: $1) },
            busy: { self.handingOver.contains($0) || log.inProgress(source: $0) })
        guard !due.isEmpty, HandoverAuto(paths: manager.paths).isOn else { return }
        for source in due { handOver(from: source) }
    }

    /// Hands `source`'s work to the window with the most room (or `destination`), as `baton handover` does: the banner
    /// says it is moving, then waiting for a busy destination, and the result line shows in the window and as a
    /// notification. A source left open is closed once nothing works there.
    func handOver(from source: String, to destination: String? = nil) {
        guard !isDemo, handingOver.insert(source).inserted else { return }
        let manager = manager
        Task {
            do {
                let plan = try await Task.detached { try manager.planHandover(from: source, to: destination) }.value
                guard !plan.picksUpItself else {
                    handingOver.remove(source)
                    return
                }
                await runHandover(source: source, destination: plan.destination) { progress in
                    try await manager.handOver(plan, progress: progress)
                }
            } catch {
                // No room, handed over already or elsewhere: the banner says what holds, and the log why.
                Log.notice("handover", "Didn't hand over window \(source): \(error.localizedDescription)")
                handingOver.remove(source)
            }
        }
    }

    /// Takes up the handovers Baton left unfinished: one stopped while it started starts over, one waiting for its
    /// destination waits again, and a source left open is closed once nothing works there.
    private func resumeHandovers() {
        guard !isDemo, !manager.isReadOnly else { return }
        let log = HandoverLog(paths: manager.paths)
        for entry in log.unfinished() where !handingOver.contains(entry.source) && !log.inProgress(source: entry.source) {
            let manager = manager, source = entry.source
            switch entry.state {
            case "starting":
                let to = try? manager.restartStoppedHandover(source: source)
                handOver(from: source, to: to ?? nil)
            case "waiting":
                handingOver.insert(source)
                Task { await runHandover(source: source, destination: entry.destination) { _ in try await manager.finishWaitingHandover(source: source) } }
            default:
                Task.detached { _ = try? await manager.watchHandoverSource(source) }
            }
        }
    }

    /// Runs one handover with its line in the banner and its destination's Open button waiting, then shows the result.
    private func runHandover(
        source: String, destination: String, _ work: @escaping @Sendable (_ progress: @escaping @Sendable (String) -> Void) async throws -> HandoverResult?
    ) async {
        let manager = manager
        let moving = HandoverText.moving(source: displayLabel(of: source), destination: displayLabel(of: destination))
        handoverLines[source] = moving
        Self.announce(moving)
        let operation = operations.start(nil, window: destination)
        do {
            guard var result = try await work({ _ in }) else { throw CancellationError() }
            if result.state == .waiting {
                handoverLines[source] = result.line
                Self.announce(result.line)
                if let finished = try await manager.finishWaitingHandover(source: source) { result = finished }
            }
            handoverLines[source] = nil
            show(notice: result.line, isWarning: result.isWarning)
            LimitWatch.notify(title: "\(displayLabel(of: source)) is at its limit", body: result.line, id: "handover-\(source)")
            if result.state == .done { openWarnings.record(manager.openWarning(of: destination), for: destination) }
            // Closed as soon as its current work finishes, when Claude Code still worked there at the handover.
            if !result.sourceClosed { Task.detached { _ = try? await manager.watchHandoverSource(source) } }
        } catch is CancellationError {
            handoverLines[source] = nil  // nothing was waiting any more
        } catch {
            handoverLines[source] = nil
            show(notice: "\(displayLabel(of: source))'s work didn't move: \(error.localizedDescription)", isWarning: true)
        }
        handingOver.remove(source)
        operations.finish(operation)
        reload()
    }
}

enum DemoData {
    /// When WORK's five-hour limit resets, from now.
    static let workResetsIn: TimeInterval = 9 * 60

    /// WORK picks the first session up by itself after its reset: what the Continue sheet offers to wait for.
    static var autoResumeOffer: AutoResumeOffer {
        AutoResumeOffer(label: "WORK", resetsAt: Date().addingTimeInterval(workResetsIn), sessions: ["1"], titles: [conversations[0].title])
    }

    static var conversations: [Conversation] {
        let now = Date(), none = URL(fileURLWithPath: "/nonexistent.jsonl")
        return [
            Conversation(
                kind: .code, sessionID: "1", title: "Migrate billing API to v2", folders: ["/Users/alex/src/billing"],
                lastActivity: now.addingTimeInterval(-240), transcript: none),
            Conversation(
                kind: .cowork, sessionID: "2", title: "Quarterly report draft", folders: ["/Users/alex/Documents/Reports"],
                lastActivity: now.addingTimeInterval(-1_800), transcript: none, ownerID: "main"),
            Conversation(
                kind: .code, sessionID: "4", title: "Explain the retry logic", folders: [],
                lastActivity: now.addingTimeInterval(-26_000), transcript: none),
            Conversation(
                kind: .cowork, sessionID: "5", title: "Compare three vendors", folders: [],
                lastActivity: now.addingTimeInterval(-90_000), transcript: none, ownerID: "work"),
            Conversation(
                kind: .code, sessionID: "6", title: "Add rate limiting to the webhook handler", folders: ["/Users/alex/src/billing"],
                lastActivity: now.addingTimeInterval(-110_000), transcript: none),
            Conversation(
                kind: .code, sessionID: "7", title: "Fix flaky login test", folders: ["/Users/alex/src/web"],
                lastActivity: now.addingTimeInterval(-150_000), transcript: none),
            Conversation(
                kind: .cowork, sessionID: "8", title: "Plan the team offsite", folders: [],
                lastActivity: now.addingTimeInterval(-200_000), transcript: none, ownerID: "lab"),
            Conversation(
                kind: .code, sessionID: "9", title: "Write the release notes", folders: ["/Users/alex/src/web"],
                lastActivity: now.addingTimeInterval(-260_000), transcript: none),
        ]
    }

    static var windowStatuses: [WindowStatus] {
        statuses.map { status in
            WindowStatus(
                id: status.id, label: status.label, isMain: status.isMain, isRunning: status.isRunning, account: status.email,
                scope: status.isSignedIn ? "account 5c1e8a42 · 1 organization" : nil,
                scopeSource: status.isSignedIn ? "config.json (lastKnownAccountUuid)" : "not signed in yet",
                skipReasons: status.isSignedIn ? [] : ["Not signed in: sign in inside this window to share its sessions."],
                pendingChanges: status.id == "work" ? ["Claude Desktop was updated; this window runs the previous version until it restarts."] : [],
                liveSessions: status.id == "main" ? 1 : 0)
        }
    }

    static var reportFacts: FeedbackReport.Facts {
        FeedbackReport.Facts(
            build: .current, macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: "arm64",
            claudeVersion: "0.14.1",
            windows: statuses.map {
                .init(
                    id: $0.id, label: $0.label, isMain: $0.isMain, isRunning: $0.isRunning,
                    isSignedIn: $0.isSignedIn, claudeCodeVersion: "2.1.281")
            },
            diagnostics: [], lastSync: nil, lastSyncDate: nil,
            errors: ["Can't read /Users/alex/src/billing/.claude: permission denied"],
            log: ["sync: 4 session folders for alex@work.example"], home: "/Users/alex", user: "alex",
            profiles: statuses.compactMap(\.profile).map { [$0.label, $0.id] })
    }

    /// WORK is at its five-hour limit with a reset time Claude named, so the pictures show the limit banner, the reset
    /// beside the meters and the at-limit entry in the Continue sheet; LAB's sample is four hours old, so its usage
    /// "may have changed since". WORK resets within `AutoResumeOffer.within`, so its offer to wait is one Baton makes.
    static var statuses: [ProfileStatus] {
        let now = Date()
        let workUsage = Usage(fiveHour: 100, week: 31, sampledAt: now.addingTimeInterval(-300))
        var workLimits = Limits(usage: workUsage)
        workLimits.fiveHour = LimitState(
            kind: .fiveHour, percent: 100, sampledAt: workUsage.sampledAt, reachedAt: now.addingTimeInterval(-2_400),
            reset: LimitReset(at: now.addingTimeInterval(workResetsIn), source: .exact))
        return [
            ProfileStatus(
                profile: nil, accountID: "demo-main", email: "alex@example.com",
                usage: Usage(fiveHour: 64, week: 92, sampledAt: now.addingTimeInterval(-600)), isRunning: true),
            ProfileStatus(
                profile: Profile(id: "work", label: "WORK", email: "alex@work.example", color: "#1971C2"),
                accountID: "demo-work", email: "alex@work.example", usage: workUsage, isRunning: true, limits: workLimits),
            ProfileStatus(
                profile: Profile(id: "lab", label: "LAB", email: "alex.lab@example.org", color: "#28863A"),
                accountID: "demo-lab", email: "alex.lab@example.org",
                usage: Usage(fiveHour: 0, week: 58, sampledAt: now.addingTimeInterval(-14_400)), isRunning: false),
            ProfileStatus(
                profile: Profile(id: "team", label: "TEAM", email: "alex@team.example", color: "#7048E8"),
                accountID: nil, email: nil, usage: nil, isRunning: true),
        ]
    }
}
