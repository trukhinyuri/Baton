import Darwin
import Foundation

/// Whether anything works in a window: the one test used before Baton quits a window, whether the window a limit was
/// reached in or the one work continues in. A Claude Code process may write to its session at any time, even after its
/// transcript has been quiet for long (`LiveSessions`), so any live process makes a window busy.
public enum WindowActivity: Equatable, Sendable {
    /// No process of the window runs.
    case closed
    /// The window runs with no Claude Code process in it.
    case idle
    /// `live` Claude Code processes belong to the window.
    case busy(live: Int)

    public var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}

/// Running Claude Code processes and a way up to each one's parent.
struct ProcessTree: Sendable {
    var claudes: [pid_t]
    var parent: @Sendable (pid_t) -> pid_t?

    static var current: ProcessTree { ProcessTree(claudes: WindowStatus.claudeProcesses(), parent: { WindowStatus.parentPID($0) }) }

    /// Whether `pid` descends from one of `ancestors`, walking up through helpers.
    func descends(_ pid: pid_t, from ancestors: Set<pid_t>) -> Bool { Self.descends(pid, from: ancestors, parent: parent) }

    static func descends(_ pid: pid_t, from ancestors: Set<pid_t>, parent: (pid_t) -> pid_t?) -> Bool {
        guard !ancestors.isEmpty else { return false }
        var current = pid, seen = Set<pid_t>()
        while let up = parent(current), up > 1, seen.insert(up).inserted {
            if ancestors.contains(up) { return true }
            current = up
        }
        return false
    }
}

extension ProfileManager {
    /// busy: at least one live Claude Code process belongs to the window, by its executable in the window's data folder
    /// (as `LimitTracker.liveWindows` tells; such a process can outlive a crashed window) or by descending from the
    /// window's process (as `WindowStatus.liveSessions` counts). closed: no process at all. idle otherwise.
    public func activity(of window: String) -> WindowActivity {
        let copies = runningCopies(of: window)
        let live = liveProcesses(of: window, copies: copies)
        if !live.pids.isEmpty { return .busy(live: live.pids.count) }
        return copies.isEmpty ? .closed : .idle
    }

    /// Sessions of the window with a live Claude Code process there: the test for whether a session continues elsewhere
    /// as itself or as a copy. While the window runs, a session live somewhere Baton can't attribute (open in a running
    /// `claude` without a registry entry) counts as live there too.
    public func liveSessions(in window: String) -> Set<String> {
        let copies = runningCopies(of: window)
        var sessions = liveProcesses(of: window, copies: copies).sessions
        if !copies.isEmpty {
            let registered = Set(limitTracker.liveProcesses(paths.claudeDir).map(\.session))
            sessions.formUnion((liveSessionIDs?() ?? LiveSessions.ids(claudeDir: paths.claudeDir)).subtracting(registered))
        }
        return sessions
    }

    /// Asks every process of the window to quit and waits up to `seconds` for them to go. Never forces, and never asks
    /// a busy window: running work isn't interrupted, and a window that asks the user something, or keeps running,
    /// stays open.
    /// - Returns: whether the window is closed now.
    public func quitWindow(_ window: String, seconds: Double = 20) async -> Bool {
        guard !isReadOnly else { return false }
        let activity = activity(of: window)
        guard activity != .closed else { return true }
        guard !activity.isBusy else {
            Log.notice("open", "Didn't ask window \(window) to quit: Claude Code works there")
            return false
        }
        let copies = runningCopies(of: window)
        for copy in copies {
            if let quitRequester { quitRequester(copy) } else { copy.app?.terminate() }
        }
        Log.notice("open", "Asked window \(window) to quit (\(copies.count) process\(copies.count == 1 ? "" : "es"))")
        let stillRunning = { self.runningCopies(of: window).contains { copy in copy.app.map { !$0.isTerminated } ?? true } }
        for _ in 0..<Int(seconds * 5) where stillRunning() {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !stillRunning() else {
            Log.notice("open", "Window \(window) didn't quit within \(Int(seconds)) s; left running")
            return false
        }
        return self.activity(of: window) == .closed
    }

    /// The running copies that show the window's own data.
    func runningCopies(of window: String) -> [RunningClaude] {
        let dataDir = window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
        let bundle = window == "main" ? paths.claudeApp : paths.engine(for: window)
        return runningClaudes().filter { $0.uses(dataDir: dataDir, mainDataDir: paths.mainDataDir, bundle: bundle) }
    }

    /// Live Claude Code processes of the window and the sessions they have open.
    private func liveProcesses(of window: String, copies: [RunningClaude]) -> (pids: Set<pid_t>, sessions: Set<String>) {
        let dataDir = window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
        let windowPIDs = Set(copies.compactMap(\.pid))
        let tree = windowPIDs.isEmpty ? ProcessTree(claudes: [], parent: { _ in nil }) : (processTree?() ?? .current)
        var pids = Set(tree.claudes.filter { tree.descends($0, from: windowPIDs) })
        var sessions = Set<String>()
        for process in limitTracker.liveProcesses(paths.claudeDir) {
            if LimitTracker.window(of: process.executable, in: [(window, dataDir)]) != nil || pids.contains(process.pid) {
                pids.insert(process.pid)
                sessions.insert(process.session)
            }
        }
        return (pids, sessions)
    }
}
