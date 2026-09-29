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
/// in the registry). Measured again later that evening: 10 of PAY's 30 would have counted as working by a registry
/// `"busy"` alone or by any descendant, most of them left over: 7 with `"busy"` set 3 to 5 hours before
/// (`statusUpdatedAt`), their transcripts quiet since, 6 of them ending in a tool call nothing answered; a background
/// shell 5 hours old; a `shasum` waiting on its input for 3.7 hours. The session running that measurement ran a
/// workflow: its registry had said `"busy"` for 5 hours and its own transcript was quiet for 13 minutes, while its
/// workflow agents' transcripts were written every few seconds. No Claude Code process had an MCP server as a child:
/// Claude Desktop runs MCP servers in its own `Claude Helper` utility processes, and `~/.claude.json` configures none.
///
/// A process works when:
/// - its session's transcript (`~/.claude/projects/*/<session>.jsonl`), or one of its subagents' or workflow agents'
///   (`<session>/subagents/**/*.jsonl`), was written in the last `quiet` seconds, or
/// - Claude Code's own registry says `"status": "busy"` and set it within `busyFresh` (a turn under way, as while the
///   model thinks with no tool running and nothing written yet; an older one is left over), or
/// - it has a descendant started within `young` (a tool, a shell, a background task or a Monitor). A direct child
///   that already ran `serverGrace` after the process started doesn't count: that is how an MCP server or helper
///   started with the session looks where one is configured. Older descendants with a quiet transcript don't count
///   either; they end when the window quits.
enum ClaudeWork {
    /// A transcript written this recently means its session works.
    static let quiet: TimeInterval = 60
    /// A registry `"busy"` set this recently means a turn is under way.
    static let busyFresh: TimeInterval = 10 * 60
    /// A descendant started this recently is work.
    static let young: TimeInterval = 30 * 60
    /// A direct child started this soon after the Claude Code process is a server started with the session.
    static let serverGrace: TimeInterval = 10

    static func isWorking(pid: pid_t, session: String?, claudeDir: URL, now: Date = Date()) -> Bool {
        if let entry = registry(pid: pid, claudeDir: claudeDir), entry.status == "busy", let at = entry.statusUpdatedAt,
            now.timeIntervalSince(at) <= busyFresh
        {
            return true
        }
        if hasYoungDescendant(pid, now: now) { return true }
        guard let session, let written = transcriptWritten(session: session, projectsDir: claudeDir.appending(path: "projects")) else {
            return false
        }
        return now.timeIntervalSince(written) <= quiet
    }

    /// Whether a process below `pid` started within `young` of `now`, other than a direct child started within
    /// `serverGrace` of `pid` itself.
    static func hasYoungDescendant(_ pid: pid_t, now: Date) -> Bool {
        guard let started = startTime(pid) else { return false }
        return hasYoungDescendant(pid, children: children, startTime: startTime, processStart: started, now: now)
    }

    static func hasYoungDescendant(
        _ pid: pid_t, children: (pid_t) -> [pid_t], startTime: (pid_t) -> Date?, processStart: Date, now: Date, depth: Int = 0
    ) -> Bool {
        guard depth < 16 else { return false }
        let servers = processStart.addingTimeInterval(serverGrace)
        for child in children(pid) {
            if let started = startTime(child), now.timeIntervalSince(started) <= young, depth > 0 || started > servers { return true }
            if hasYoungDescendant(child, children: children, startTime: startTime, processStart: processStart, now: now, depth: depth + 1) {
                return true
            }
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

    /// `status` and `statusUpdatedAt` (milliseconds since 1970) from `~/.claude/sessions/<pid>.json`, if that entry is
    /// this process's.
    static func registry(pid: pid_t, claudeDir: URL) -> (status: String?, statusUpdatedAt: Date?)? {
        guard let data = try? Data(contentsOf: claudeDir.appending(path: "sessions/\(pid).json")),
            let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (record["pid"] as? Int).map({ $0 == Int(pid) }) ?? true
        else { return nil }
        let updated = (record["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (record["status"] as? String, updated)
    }

    /// When the session's transcript was last written, in whichever project folder it is, counting the transcripts of
    /// its subagents and workflow agents (`<session>/subagents/**/*.jsonl`): a session running a workflow writes only
    /// those for as long as the workflow runs, and its own transcript stays quiet meanwhile.
    static func transcriptWritten(session: String, projectsDir: URL) -> Date? {
        let fm = FileManager.default
        let id = session.lowercased()
        let modified = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        var newest: Date?
        for folder in (try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? [] {
            let base = projectsDir.appending(path: folder)
            var written = [modified(base.appending(path: id + ".jsonl"))]
            let subagents = base.appending(path: id).appending(path: "subagents")
            if fm.fileExists(atPath: subagents.path), let files = fm.enumerator(at: subagents, includingPropertiesForKeys: nil) {
                for case let file as URL in files where file.pathExtension == "jsonl" { written.append(modified(file)) }
            }
            for date in written.compactMap({ $0 }) { newest = max(newest ?? date, date) }
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
        return Set(liveProcesses(of: window, copies: copies).values.compactMap { $0 }).union(unattributedSessions(copies: copies))
    }

    /// Sessions `liveSessions(in:)` counts in the window that its quitting doesn't end: open in a `claude` Baton can't
    /// place, while the window runs. Each continues elsewhere as a copy even once the window is closed.
    public func sessionsOutlivingQuit(of window: String) -> Set<String> {
        let copies = runningCopies(of: window)
        return unattributedSessions(copies: copies).subtracting(liveProcesses(of: window, copies: copies).values.compactMap { $0 })
    }

    private func unattributedSessions(copies: [RunningClaude]) -> Set<String> {
        guard !copies.isEmpty else { return [] }
        let registered = Set(limitTracker.liveProcesses(paths.claudeDir).map(\.session))
        return (liveSessionIDs?() ?? LiveSessions.ids(claudeDir: paths.claudeDir)).subtracting(registered)
    }

    /// Checks the window every `poll` seconds, for up to `limit` seconds, until nothing works there (`activity(of:)`).
    /// - Returns: whether nothing works there now.
    func waitUntilNothingWorks(in window: String, limit: TimeInterval, poll: TimeInterval) async throws -> Bool {
        let until = Date().addingTimeInterval(limit)
        while activity(of: window).isBusy {
            guard Date() < until else { return false }
            try await Task.sleep(for: .seconds(min(poll, max(until.timeIntervalSinceNow, 0.01))))
        }
        return true
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
        // A wrapper whose own child is a Claude Code process isn't one itself: Claude Desktop starts each under its
        // `disclaimer` helper, whose arguments name the Claude Code it runs. The process it runs is judged instead,
        // with its own start time, so the wrapper neither counts twice nor turns that process's servers into work.
        let wrappers = Set(tree.claudes.compactMap(tree.parent))
        for pid in tree.claudes where !wrappers.contains(pid) && tree.descends(pid, from: windowPIDs) { found[pid] = .some(nil) }
        for process in limitTracker.liveProcesses(paths.claudeDir) {
            if LimitTracker.window(of: process.executable, in: [(window, dataDir)]) != nil || found[process.pid] != nil {
                found[process.pid] = process.session
            }
        }
        return found
    }
}
