import Foundation

/// Showing sessions one at a time in a window, so that Claude continues each: Claude acts on a session's auto-continue
/// entry only while that session is on screen.
public enum ShowInTurn {
    /// One session to show, with what decides its place in the turn.
    public struct Item: Equatable, Sendable {
        /// The Claude Code session id.
        public var session: String
        public var lastActivity: Date
        /// Its place in the window's pin order, 0 for the top pin; `nil` when it isn't pinned.
        public var pinRank: Int?

        public init(session: String, lastActivity: Date, pinRank: Int? = nil) {
            self.session = session.lowercased(); self.lastActivity = lastActivity; self.pinRank = pinRank
        }
    }

    /// Unpinned sessions first, least recently active first, then pinned ones from the bottom of the pin order up, so
    /// the top pin is shown last and stays on screen.
    public static func order(_ items: [Item]) -> [String] {
        let unpinned = items.filter { $0.pinRank == nil }.sorted { ($0.lastActivity, $0.session) < ($1.lastActivity, $1.session) }
        let pinned = items.compactMap { item in item.pinRank.map { (rank: $0, item: item) } }.sorted { $0.rank > $1.rank }.map(\.item)
        return (unpinned + pinned).map(\.session)
    }

    public struct Result: Equatable, Sendable {
        /// Sessions handed to the window, in order.
        public var shown: [String] = []
        public var resumed: [String] = []
        /// Shown, or never shown because the window went away, and not seen to continue.
        public var notResumed: [String] = []
    }

    public enum Refusal: LocalizedError, Equatable {
        /// A closed window would be started by the link without its data folder, on the main app's data.
        case windowClosed(String)
        /// The window started before the sessions were shared into it, so a link would import each under a new name.
        case startedBeforeShare(String)

        public var errorDescription: String? {
            switch self {
            case .windowClosed(let label): "\(label) isn't open, so its sessions weren't shown"
            case .startedBeforeShare(let label): "\(label) started before the sessions reached it; it shows them after a restart"
            }
        }
    }
}

extension ProfileManager {
    /// Hands `sessions` to the open `window` one resume link at a time, in the order given (`ShowInTurn.order`),
    /// moving on once `done` says a session continued or `dwell` seconds passed; after the last, waits up to `lastWait`
    /// seconds for the ones still going. Only a window that started after its cards were shared is sent links: in one
    /// that started before, a link imports the session under a new name. If the window closes on the way, no more
    /// links go out, since a link would start Claude on the main app's data.
    public func showInTurn(
        _ window: String, sessions: [String], dwell: Double = 25, lastWait: Double = 60, poll: Double = 1,
        done: @escaping @Sendable (String) -> Bool
    ) async throws -> ShowInTurn.Result {
        var result = ShowInTurn.Result()
        let sessions = sessions.map { $0.lowercased() }
        guard !sessions.isEmpty else { return result }
        try ensureWritable()
        let label = displayLabel(of: window)
        let copies = runningCopies(of: window)
        guard !copies.isEmpty else { throw ShowInTurn.Refusal.windowClosed(label) }
        let dataDir = window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
        let started = copies.compactMap(\.launchDate).min()
        guard !WindowStatus.sessionsWaitForRestart(shared: lastCardShared(into: dataDir), windowStarted: started) else {
            throw ShowInTurn.Refusal.startedBeforeShare(label)
        }
        let app = window == "main" ? paths.claudeApp : paths.engine(for: window)
        var resumed = Set<String>()
        for session in sessions {
            guard !runningCopies(of: window).isEmpty else {
                Log.notice("continue", "Window \(window) closed while its sessions were shown; \(sessions.count - result.shown.count) not shown")
                break
            }
            try await deliver([ClaudeLink.resume(session)], to: app)
            result.shown.append(session)
            let until = Date().addingTimeInterval(dwell)
            while !done(session), Date() < until { try await Task.sleep(for: .seconds(poll)) }
            if done(session) { resumed.insert(session) }
        }
        let until = Date().addingTimeInterval(lastWait)
        while result.shown.contains(where: { !resumed.contains($0) && !done($0) }), Date() < until {
            try await Task.sleep(for: .seconds(poll))
        }
        for session in result.shown where done(session) { resumed.insert(session) }
        result.resumed = sessions.filter(resumed.contains)
        result.notResumed = sessions.filter { !resumed.contains($0) }
        Log.notice("continue", "Showed \(result.shown.count) sessions in window \(window): \(result.resumed.count) continued")
        return result
    }

    /// The default test for `showInTurn`: the session has a live Claude Code process in `window` and its transcript
    /// grew since this call.
    public func resumeWatch(_ sessions: [String], in window: String) -> @Sendable (String) -> Bool {
        let projects = paths.claudeProjectsDir
        let files = ConversationIndex.transcriptFiles(in: projects)
        let before = Dictionary(uniqueKeysWithValues: sessions.map { ($0.lowercased(), files[$0.lowercased()].map(Self.size) ?? 0) })
        return { [self] session in
            let session = session.lowercased()
            guard liveSessions(in: window).contains(session) else { return false }
            let file = files[session] ?? ConversationIndex.transcriptFiles(in: projects)[session]
            return file.map(Self.size).map { $0 > before[session] ?? 0 } ?? false
        }
    }

    private static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
