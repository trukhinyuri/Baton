import Darwin
import Foundation

/// Whether anything works in a window: the one test used before Baton quits a window, whether the window a limit was
/// reached in or the one work continues in. Claude Desktop keeps one Claude Code process alive for every session opened
/// since it started, for hours, so a live process alone doesn't mean work: only a working one does (`ClaudeWork`).
public enum WindowActivity: Equatable, Sendable {
    /// No process of the window runs.
    case closed
    /// The window runs, and no Claude Code process of it works: none are live, or the live ones are idle.
    case idle
    /// `working` Claude Code processes of the window work (`ClaudeWork.isWorking`).
    case busy(working: Int)

    public var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}

/// Whether a live Claude Code process works now, rather than only holding its session open.
///
/// Measured on this Mac on 29 September 2026 (read-only `ps`, the process registry in `~/.claude/sessions`): Claude
/// Desktop's PAY window ran 30 Claude Code processes, one per session opened since it started 4.5 hours before, each
/// under its own `disclaimer` helper. 27 had no child process at all; their registry said `"status": "idle"`. The
/// other three had children: the one running a tool had a `zsh -c` shell running it (registry `"busy"`), one a
/// background `zsh` running a Python script for 4.5 hours, one a shell stuck in `shasum` for 3 hours (both `"idle"`
/// in the registry). No Claude Code process had an MCP server as a child: Claude Desktop runs MCP servers in its own
/// `Claude Helper` utility processes, and `~/.claude.json` configures none. So any descendant is a tool, a shell, a
/// background task or a Monitor, and counts as work; a descendant started within `serverGrace` of the process itself
/// doesn't, since that is how an MCP server or helper started with the session looks where one is configured.
///
/// A process works when:
/// - it has such a descendant, or
/// - Claude Code's own registry says `"status": "busy"` (a turn is under way, as while the model thinks with no tool
///   running and nothing written yet), or
/// - its session's transcript (`~/.claude/projects/*/<session>.jsonl`) was written in the last `quiet` seconds.
enum ClaudeWork {
    /// A transcript written this recently means its session works.
    static let quiet: TimeInterval = 60
    /// A descendant started this soon after the Claude Code process is a server started with the session.
    static let serverGrace: TimeInterval = 10

    static func isWorking(pid: pid_t, session: String?, claudeDir: URL, now: Date = Date()) -> Bool {
        if hasWorkingDescendant(pid) { return true }
        if registryStatus(pid: pid, claudeDir: claudeDir) == "busy" { return true }
        guard let session, let written = transcriptWritten(session: session, projectsDir: claudeDir.appending(path: "projects")) else {
            return false
        }
        return now.timeIntervalSince(written) <= quiet
    }

    /// Whether a process below `pid` started later than `serverGrace` after it.
    static func hasWorkingDescendant(_ pid: pid_t) -> Bool {
        guard let started = startTime(pid) else { return false }
        return hasWorkingDescendant(pid, children: children, startTime: startTime, after: started.addingTimeInterval(serverGrace))
    }

    static func hasWorkingDescendant(
        _ pid: pid_t, children: (pid_t) -> [pid_t], startTime: (pid_t) -> Date?, after: Date, depth: Int = 0
    ) -> Bool {
        guard depth < 16 else { return false }
        for child in children(pid) {
            if let started = startTime(child), started >= after { return true }
            if hasWorkingDescendant(child, children: children, startTime: startTime, after: after, depth: depth + 1) { return true }
        }
        return false
    }

    static func children(_ pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).filter { $0 > 0 }
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// `status` from `~/.claude/sessions/<pid>.json`, if that entry is this process's.
    static func registryStatus(pid: pid_t, claudeDir: URL) -> String? {
        guard let data = try? Data(contentsOf: claudeDir.appending(path: "sessions/\(pid).json")),
            let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (record["pid"] as? Int).map({ $0 == Int(pid) }) ?? true
        else { return nil }
        return record["status"] as? String
    }

    /// When the session's transcript was last written, in whichever project folder it is.
    static func transcriptWritten(session: String, projectsDir: URL) -> Date? {
        let name = session.lowercased() + ".jsonl"
        var newest: Date?
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path)) ?? [] {
            let url = projectsDir.appending(path: folder).appending(path: name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            newest = max(newest ?? modified, modified)
        }
        return newest
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
    /// busy: at least one live Claude Code process of the window works (`ClaudeWork`). A process belongs to the window
    /// by its executable in the window's data folder (as `LimitTracker.liveWindows` tells; such a process can outlive a
    /// crashed window) or by descending from the window's process (as `WindowStatus.liveSessions` counts). closed: no
    /// process at all. idle otherwise, also when only idle Claude Code processes are left of a window that went away.
    public func activity(of window: String) -> WindowActivity {
        let copies = runningCopies(of: window)
        let live = liveProcesses(of: window, copies: copies)
        let working = live.filter { isWorking($0.key, $0.value) }.count
        if working > 0 { return .busy(working: working) }
        return copies.isEmpty && live.isEmpty ? .closed : .idle
    }

    /// Sessions of the window with a live Claude Code process there, working or idle. While the window runs, a session
    /// live somewhere Baton can't attribute (open in a running `claude` without a registry entry) counts as live there
    /// too.
    public func liveSessions(in window: String) -> Set<String> {
        let copies = runningCopies(of: window)
        var sessions = Set(liveProcesses(of: window, copies: copies).values.compactMap { $0 })
        if !copies.isEmpty {
            let registered = Set(limitTracker.liveProcesses(paths.claudeDir).map(\.session))
            sessions.formUnion((liveSessionIDs?() ?? LiveSessions.ids(claudeDir: paths.claudeDir)).subtracting(registered))
        }
        return sessions
    }

    /// Sessions of the window whose Claude Code process works there (D1's copy test): each continues elsewhere as a
    /// copy, while every other session moves as itself.
    public func workingSessions(in window: String) -> Set<String> {
        Set(liveProcesses(of: window, copies: runningCopies(of: window)).filter { isWorking($0.key, $0.value) }.compactMap(\.value))
    }

    /// Whether the Claude Code process `pid`, with `session` open, works (`ClaudeWork.isWorking`).
    func isWorking(_ pid: pid_t, _ session: String?) -> Bool {
        if let processWorking { return processWorking(pid, session) }
        return ClaudeWork.isWorking(pid: pid, session: session, claudeDir: paths.claudeDir)
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

    /// Live Claude Code processes of the window and the session each has open, where the registry tells.
    private func liveProcesses(of window: String, copies: [RunningClaude]) -> [pid_t: String?] {
        let dataDir = window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
        let windowPIDs = Set(copies.compactMap(\.pid))
        let tree = windowPIDs.isEmpty ? ProcessTree(claudes: [], parent: { _ in nil }) : (processTree?() ?? .current)
        var found: [pid_t: String?] = [:]
        for pid in tree.claudes where tree.descends(pid, from: windowPIDs) { found[pid] = .some(nil) }
        for process in limitTracker.liveProcesses(paths.claudeDir) {
            if LimitTracker.window(of: process.executable, in: [(window, dataDir)]) != nil || found[process.pid] != nil {
                found[process.pid] = process.session
            }
        }
        return found
    }
}
