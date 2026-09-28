import AppKit
import Darwin
import OSLog

/// What the status panel shows for one Claude window: whose account it is, where its sharing scope comes from,
/// why some of its work isn't shared, whether Local only is on, and changes that wait for it to restart.
public struct WindowStatus: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var isMain: Bool
    public var isRunning: Bool
    /// The signed-in email, or `nil` when not signed in.
    public var account: String?
    /// The account and organizations its local session cards are shared under.
    public var scope: String?
    public var scopeSource: String
    public var skipReasons: [String]
    public var localOnly: Bool?
    public var pendingChanges: [String]
    /// Claude Code sessions running inside this window right now.
    public var liveSessions: Int

    public init(
        id: String, label: String, isMain: Bool, isRunning: Bool, account: String?, scope: String?,
        scopeSource: String, skipReasons: [String] = [], localOnly: Bool? = nil, pendingChanges: [String] = [],
        liveSessions: Int = 0
    ) {
        self.id = id; self.label = label; self.isMain = isMain; self.isRunning = isRunning; self.account = account
        self.scope = scope; self.scopeSource = scopeSource; self.skipReasons = skipReasons; self.localOnly = localOnly
        self.pendingChanges = pendingChanges; self.liveSessions = liveSessions
    }

    private var name: String { isMain ? "Claude" : label }

    /// Only an open window with no Claude Code session running in it: quitting would stop that work.
    /// A closed window picks the changes up when it next opens.
    public var canRestart: Bool { isRunning && liveSessions == 0 }
    public var restartTitle: String { "Restart \(name) to apply" }
    public var restartHelp: String {
        if !isRunning { return "Claude \(isMain ? "" : label + " ")is closed; it applies these changes when it next opens." }
        if liveSessions > 0 {
            return "\(liveSessions) Claude Code session\(liveSessions == 1 ? " is" : "s are") running in this window. "
                + "Let \(liveSessions == 1 ? "it" : "them") finish, then restart."
        }
        return "Quits this window and opens it again. Nothing is running in it."
    }

    // MARK: Collecting

    /// One entry per window, from the same local reads as the main list and the sessions check.
    public static func collect(
        manager: ProfileManager, diagnostics: [Diagnostics.Entry], localOnly: [String: Bool] = [:],
        pending: [String: [String]] = [:]
    ) -> [WindowStatus] {
        let paths = manager.paths
        let running = manager.runningClaudes()
        let claudes = claudeProcesses()
        return manager.statuses().map { status in
            let dataDir = status.isMain ? paths.mainDataDir : paths.dataDir(for: status.id)
            let bundle = status.isMain ? paths.claudeApp : paths.engine(for: status.id)
            let pids = Set(
                running.filter { $0.uses(dataDir: dataDir, mainDataDir: paths.mainDataDir, bundle: bundle) }
                    .compactMap { $0.app?.processIdentifier })
            var scope: String?
            if let account = status.accountID {
                let orgs = Set(
                    ["claude-code-sessions", "local-agent-mode-sessions"].flatMap { folder in
                        ((try? FileManager.default.contentsOfDirectory(atPath: dataDir.appending(path: "\(folder)/\(account)").path)) ?? [])
                            .filter { !$0.hasPrefix(".") }
                    })
                scope = "account \(account.prefix(8)) · \(orgs.count) organization\(orgs.count == 1 ? "" : "s")"
            }
            var skip = diagnostics.first { $0.id == status.id }?.issues ?? []
            if !status.isSignedIn && !skip.contains(where: { $0.contains("sign in") }) {
                skip.append("Not signed in: sign in inside this window to share its sessions.")
            }
            var changes = pending[status.id] ?? []
            if !status.isMain, status.isRunning, manager.engineIsOutdated(status.id) {
                changes.append("Claude Desktop was updated; this window runs the previous version until it restarts.")
            }
            return WindowStatus(
                id: status.id, label: status.label, isMain: status.isMain, isRunning: status.isRunning,
                account: status.email ?? (status.isSignedIn ? "signed in" : nil), scope: scope,
                scopeSource: status.isSignedIn ? "config.json (lastKnownAccountUuid)" : "not signed in yet",
                skipReasons: skip, localOnly: localOnly[status.id], pendingChanges: changes,
                liveSessions: liveSessionCount(windowPIDs: pids, claudePIDs: claudes, parent: parentPID))
        }
    }

    /// Claude Code processes that descend from one of `windowPIDs`, walking up through helpers.
    static func liveSessionCount(windowPIDs: Set<pid_t>, claudePIDs: [pid_t], parent: (pid_t) -> pid_t?) -> Int {
        guard !windowPIDs.isEmpty else { return 0 }
        return claudePIDs.filter { pid in
            var current = pid, seen = Set<pid_t>()
            while let up = parent(current), up > 1, seen.insert(up).inserted {
                if windowPIDs.contains(up) { return true }
                current = up
            }
            return false
        }.count
    }

    static func claudeProcesses() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 && LiveSessions.isClaude($0) }
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    // MARK: Errors

    public enum RestartError: LocalizedError, Equatable {
        case liveSessions(label: String, count: Int)
        case didNotQuit(label: String)

        public var errorDescription: String? {
            switch self {
            case .liveSessions(let label, let count):
                "\(count) Claude Code session\(count == 1 ? " is" : "s are") running in Claude \(label). Nothing was restarted. Let \(count == 1 ? "it" : "them") finish, then try again."
            case .didNotQuit(let label):
                "Claude \(label) didn't quit, so it was not restarted. Quit it yourself, then open it from Claude Profiles."
            }
        }
    }

    /// A title that says what kind of problem the alert is about.
    public static func alertTitle(for error: Error) -> String {
        switch error {
        case let error as ProfileError:
            switch error {
            case .claudeNotInstalled: "Claude Desktop isn’t installed"
            case .invalidLabel, .invalidEmail, .duplicateLabel: "Check the subscription details"
            case .notFound: "Subscription not found"
            case .cloneFailed: "Couldn’t create the app copy"
            case .windowStillRunning: "A window didn’t quit"
            case .notSignedIn: "Not signed in yet"
            case .sameWindow: "Choose another subscription"
            case .coworkNeedsItsOwnHandoff: "Continue this task on its own"
            case .notAllowed: "A folder rule doesn’t allow this"
            case .rulesUnreadable: "Can’t read the folder rules"
            case .windowDidNotAppear: "The window didn’t appear"
            case .profileOpen: "The window is still open"
            case .mayStillBeWritten: "It may still be written to"
            }
        case let error as RestartError:
            switch error {
            case .liveSessions: "Claude Code is still working"
            case .didNotQuit: "A window didn’t quit"
            }
        case is CocoaError: "Couldn’t read or write a file"
        default: "Something went wrong"
        }
    }
}

extension ProfileManager {
    /// Quits a window and opens it again so it picks up changed settings, unless a Claude Code session runs in it.
    public func restart(_ id: String) async throws {
        let label = label(of: id)
        guard let window = WindowStatus.collect(manager: self, diagnostics: []).first(where: { $0.id == id }), window.isRunning
        else { return id == "main" ? try await openMain() : try await open(id) }
        if window.liveSessions > 0 { throw WindowStatus.RestartError.liveSessions(label: label, count: window.liveSessions) }
        let dataDir = id == "main" ? paths.mainDataDir : paths.dataDir(for: id)
        let bundle = id == "main" ? paths.claudeApp : paths.engine(for: id)
        let apps = runningClaudes().filter { $0.uses(dataDir: dataDir, mainDataDir: paths.mainDataDir, bundle: bundle) }.compactMap(\.app)
        for app in apps { app.terminate() }
        for _ in 0..<100 where apps.contains(where: { !$0.isTerminated }) { try await Task.sleep(for: .milliseconds(200)) }
        guard apps.allSatisfy(\.isTerminated) else { throw WindowStatus.RestartError.didNotQuit(label: label) }
        Log.logger("restart").notice("Restarted window \(id, privacy: .private)")
        if id == "main" { try await openMain() } else { try await open(id) }
    }
}

/// The newest entries this app wrote to the unified log, for a problem report. Reads only its own subsystem.
public enum LogTail {
    public static func read(limit: Int = FeedbackReport.logLimit, since: TimeInterval = 86_400) -> [String] {
        // The whole local store needs admin rights; without them only this process's own entries are readable.
        guard let store = (try? OSLogStore.local()) ?? (try? OSLogStore(scope: .currentProcessIdentifier)) else { return [] }
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-since)), matching: predicate)
        else { return [] }
        let time = Date.FormatStyle().year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute().second()
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date.formatted(time)) [\(entry.category)] \(entry.composedMessage)")
            if lines.count > limit * 4 { lines.removeFirst(lines.count - limit) }
        }
        return Array(lines.suffix(limit))
    }
}
