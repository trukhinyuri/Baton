import AppKit
import ClaudeProfilesKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [ProfileStatus] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncChanges = 0
    @Published private(set) var syncError: String?
    @Published private(set) var registryError: String?
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var isAdding = false
    @Published var isContinuing = false
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var isLoadingConversations = false
    /// Selected when the continue sheet opens, if still available.
    @Published var preselectedConversation: String?
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    @Published var isCheckingSessions = false
    @Published var diagnostics: [Diagnostics.Entry] = []
    @Published private(set) var setupWarning: String?
    @Published var pendingRemoval: ProfileStatus?
    /// Which accounts may continue work in which folders; `nil` if the rules file can't be read.
    @Published private(set) var folderRules: [FolderRule]? = []

    let manager: ProfileManager
    let isDemo = ProcessInfo.processInfo.environment["CLAUDE_PROFILES_DEMO"] == "1"
    private var refreshTimer: Timer?
    private var syncTimer: Timer?
    /// Profiles whose window was open and not yet signed in at the last check.
    private var awaitingSignIn: Set<String> = []
    private var launchObserver: NSObjectProtocol?

    init() {
        let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/claude-profiles")
        manager = ProfileManager(cliPath: FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil)
        reload()
        // Documentation screenshots: CLAUDE_PROFILES_DEMO=1 shows sample data, …_DEMO_SHEET=1 opens "Add"
        // and …_DEMO_SHEET=continue opens "Continue work…".
        guard !isDemo else {
            let sheet = ProcessInfo.processInfo.environment["CLAUDE_PROFILES_DEMO_SHEET"]
            isAdding = sheet == "1"
            isContinuing = sheet == "continue"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.setContentSize(NSSize(width: 900, height: 530))
            }
            return
        }
        // Re-registers the main Claude after an abandoned sign-in and notes a Claude Desktop version
        // outside the tested range: information for the footer, never a blocking alert.
        let startUp = manager.startUpChecks()
        if !startUp.isEmpty { setupWarning = startUp.joined(separator: " ") }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        Task.detached { [manager] in try? manager.refresh() }
        syncNow()
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            Task { @MainActor in self?.reopenIfStartedWithoutProfile(pid) }
        }
        // macOS reopens windows at login by starting each app copy without its arguments, possibly before this app.
        manager.recentlyStartedWithoutDataDir(within: 120).forEach(reopenIfStartedWithoutProfile)
    }

    var profiles: [ProfileStatus] { statuses }
    var existingLabels: Set<String> { Set(statuses.compactMap { $0.profile?.label }) }

    /// The signed-in profile with the most weekly headroom by a sample from the last three hours, if at least two
    /// have such a sample. An older sample can be far too low: Claude records usage only while its window is used.
    var suggestedID: String? { DestinationRanking.mostHeadroom(statuses) }

    /// Out of five-hour or weekly quota by its latest recorded usage.
    func isAtLimit(_ status: ProfileStatus, now: Date = Date()) -> Bool { DestinationRanking.isAtLimit(status, now: now) }

    /// An open subscription that has reached its limit, so its work may need to continue elsewhere.
    var limitReached: ProfileStatus? { statuses.first { $0.isRunning && isAtLimit($0) } }

    /// Where to continue by default: the signed-in subscription not at its limit with the most weekly headroom
    /// (see `DestinationRanking.ranked`), among those signed in with `accounts` if given.
    func bestDestination(excluding excluded: String?, accounts: Set<String>? = nil) -> String? {
        DestinationRanking.best(statuses, excluding: excluded, accounts: accounts)
    }

    /// The accounts that may continue work touching `folders`, by the folder rules; `nil` when no rule applies.
    /// Rules that can't be read allow nothing.
    func allowedAccounts(for folders: [String]) -> (accounts: Set<String>, rules: [FolderRule])? {
        guard let rules = folderRules else { return ([], []) }
        return FolderRules.allowedAccounts(for: folders, in: rules)
    }

    /// “ · usage as of 5h ago” when a subscription's sample is too old to compare by; empty otherwise.
    func staleNote(_ id: String) -> String {
        guard let usage = statuses.first(where: { $0.id == id })?.usage, !usage.isFresh() else { return "" }
        return " · usage as of \(relativeAge(since: usage.sampledAt))"
    }

    func label(of windowID: String) -> String { statuses.first { $0.id == windowID }?.label ?? manager.label(of: windowID) }

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

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { notice = nil }
        }
        reload()
    }

    func reload() {
        if isDemo { statuses = DemoData.statuses; lastSync = Date().addingTimeInterval(-14); return }
        let manager = manager
        Task.detached {
            let fresh = manager.statuses()
            let problem = manager.registryError
            let rules = try? FolderRules(paths: manager.paths).load()
            await MainActor.run {
                if self.statuses != fresh { self.statuses = fresh }
                if self.registryError != problem { self.registryError = problem }
                if self.folderRules != rules { self.folderRules = rules }
                self.restartAfterFirstSignIn(fresh)
            }
        }
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
                run("Loading your sessions into Claude \(status.label)…") {
                    try await Task.sleep(for: .seconds(3))   // let Claude finish saving the new sign-in
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
        run("Opening Claude \(profile.label) with its own account…") { try await manager.open(profile.id) }
    }

    func syncNow() {
        guard !isDemo else { return }
        let manager = manager
        Task.detached {
            do {
                // nil: the CLI or a launcher is syncing right now; the next tick will catch up.
                guard let report = try manager.syncSessions() else { return }
                await MainActor.run {
                    self.lastSync = Date()
                    self.lastSyncChanges = report.changes
                    self.syncError = nil
                }
            } catch {
                await MainActor.run { self.syncError = error.localizedDescription }
            }
        }
    }

    func open(_ status: ProfileStatus) {
        guard !isDemo else { return }
        let manager = manager
        run(status.isRunning ? nil : "Opening \(status.isMain ? "Claude" : "Claude \(status.label)")…") {
            if let id = status.profile?.id { try await manager.open(id) } else { try await manager.openMain() }
        }
    }

    func checkSessions() {
        let paths = manager.paths
        Task {
            do {
                diagnostics = try await Task.detached { try Diagnostics.inspect(paths: paths) }.value
                isCheckingSessions = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func create(email: String, label: String, color: String) {
        let manager = manager
        run("Creating Claude \(label)…") {
            let profile = try await Task.detached { try manager.create(label: label, email: email, color: color) }.value
            try await manager.open(profile.id)
        }
    }

    func remove(_ status: ProfileStatus) {
        guard let id = status.profile?.id else { return }
        let manager = manager
        run("Removing Claude \(status.label)…") { try await manager.remove(id) }
    }

    func setCarryPermissionMode(_ enabled: Bool, for id: String) {
        let manager = manager
        run(nil) { try manager.setCarryPermissionMode(enabled, for: id) }
    }

    func revealLauncher(_ status: ProfileStatus) {
        guard let profile = status.profile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manager.paths.launcher(for: profile)])
    }

    private func run(_ message: String?, _ work: @escaping @Sendable () async throws -> Void) {
        busyMessage = message
        Task {
            do {
                try await work()
                setupWarning = manager.lastOpenWarning
            } catch { errorMessage = error.localizedDescription }
            busyMessage = nil
            reload()
        }
    }
}

enum DemoData {
    static var conversations: [Conversation] {
        let now = Date(), none = URL(fileURLWithPath: "/nonexistent.jsonl")
        return [
            Conversation(kind: .code, sessionID: "1", title: "Migrate billing API to v2", folders: ["/Users/alex/src/billing"],
                         lastActivity: now.addingTimeInterval(-240), transcript: none),
            Conversation(kind: .cowork, sessionID: "2", title: "Quarterly report draft", folders: ["/Users/alex/Documents/Reports"],
                         lastActivity: now.addingTimeInterval(-1_800), transcript: none, ownerID: "main"),
            Conversation(kind: .code, sessionID: "4", title: "Explain the retry logic", folders: [],
                         lastActivity: now.addingTimeInterval(-26_000), transcript: none),
            Conversation(kind: .cowork, sessionID: "5", title: "Compare three vendors", folders: [],
                         lastActivity: now.addingTimeInterval(-90_000), transcript: none, ownerID: "work"),
        ]
    }

    static var statuses: [ProfileStatus] {
        let now = Date()
        return [
            ProfileStatus(profile: nil, accountID: "demo-main", email: "alex@example.com",
                          usage: Usage(fiveHour: 64, week: 92, sampledAt: now.addingTimeInterval(-600)), isRunning: true),
            ProfileStatus(profile: Profile(id: "work", label: "WORK", email: "alex@acme.dev", color: "#1971C2"),
                          accountID: "demo-work", email: "alex@acme.dev",
                          usage: Usage(fiveHour: 12, week: 31, sampledAt: now.addingTimeInterval(-300)), isRunning: true),
            ProfileStatus(profile: Profile(id: "lab", label: "LAB", email: "alex.lab@example.org", color: "#2F9E44"),
                          accountID: "demo-lab", email: "alex.lab@example.org",
                          usage: Usage(fiveHour: 0, week: 58, sampledAt: now.addingTimeInterval(-7200)), isRunning: false),
            ProfileStatus(profile: Profile(id: "team", label: "TEAM", email: "alex@team.example", color: "#7048E8"),
                          accountID: nil, email: nil, usage: nil, isRunning: true),
        ]
    }
}
