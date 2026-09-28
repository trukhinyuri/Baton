import Foundation

/// A local conversation that can be continued in another profile.
public struct Conversation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A Claude Code session. Every profile shares its history, so the same session opens in another window.
        case code
        /// A Cowork task. Its history stays with its account, so it continues as a new task that gets the
        /// history and the task's files attached.
        case cowork
    }

    public var kind: Kind
    /// Claude Code's session id (`cliSessionId`), which names the transcript file.
    public var sessionID: String
    public var title: String
    /// Working folders: a Code session's folder, or the folders a Cowork task was given. Empty for "No folder".
    public var folders: [String]
    /// When the conversation last had a message.
    public var lastActivity: Date
    public var transcript: URL
    /// `"main"` or the profile id whose account owns a Cowork task; `nil` for Code sessions, which every window
    /// shares.
    public var ownerID: String?
    /// A Cowork task's own folder, with the files it was given (`uploads`) and made (`outputs`).
    public var taskFolder: URL?
    /// The session card the conversation was found by.
    public var card: URL?
    /// The model and effort the conversation last ran with, from its card. Claude Desktop keeps a long-context
    /// choice such as `claude-opus-5-5[1m]` only there, not in the transcript.
    public var model: String?
    public var effort: String?
    /// A running `claude` process has this session open (see `LiveSessions`), so it may write to it at any time.
    public var hasLiveProcess = false
    /// The window that last ran this Code session, as far as Baton saw (`LimitTracker`); `nil` when unknown. It is
    /// never offered as the place to continue it.
    public var runningIn: String?

    public var id: String { sessionID }

    public init(
        kind: Kind, sessionID: String, title: String, folders: [String], lastActivity: Date,
        transcript: URL, ownerID: String? = nil, taskFolder: URL? = nil,
        card: URL? = nil, model: String? = nil, effort: String? = nil
    ) {
        self.kind = kind; self.sessionID = sessionID; self.title = title; self.folders = folders
        self.lastActivity = lastActivity; self.transcript = transcript; self.ownerID = ownerID; self.taskFolder = taskFolder
        self.card = card; self.model = model; self.effort = effort
    }

    /// Had a message within `seconds`: probably still running, so stop it before continuing elsewhere.
    public func isActive(now: Date = Date(), within seconds: TimeInterval = 60) -> Bool {
        now.timeIntervalSince(ConversationIndex.lastActivity(of: transcript) ?? lastActivity) < seconds
    }

    /// Open in a running Claude Code process, or had a message in the last `ContinueMode.forkWindow`: its window
    /// may still write to it, so continuing it as the same session elsewhere would give it two writers.
    public func mayStillWrite(now: Date = Date()) -> Bool {
        kind != .cowork && (hasLiveProcess || isActive(now: now, within: ContinueMode.forkWindow))
    }

    /// Whether the conversation works in `folder` or a folder inside it. Links and `..` are resolved first.
    public func works(in folder: String) -> Bool {
        let root = ConversationIndex.canonical(folder)
        return folders.contains { own in
            let path = ConversationIndex.canonical(own)
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }
}

/// Finds conversations from local files only: Claude Desktop's session cards and Claude Code transcripts.
/// Reads nothing from claude.ai and needs no macOS permission.
public enum ConversationIndex {
    /// - Parameter windows: every Claude data directory with the id the app uses for it (`"main"` or a profile id).
    /// - Returns: conversations with a transcript on disk, most recent first. Archived ones are left out.
    public static func scan(paths: Paths, windows: [(id: String, dataDir: URL)]) -> [Conversation] {
        let fm = FileManager.default
        let transcripts = transcriptFiles(in: paths.claudeProjectsDir)
        var found: [String: Conversation] = [:]
        var readCards = Set<String>()

        for (id, dataDir) in windows {
            for pair in (try? SessionSync.sessionPairs(dataDirs: [dataDir], folder: SessionSync.sessionsFolder)) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: pair.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    // Shared copies of a card are the same everywhere; account-bound cards (native Project or
                    // Remote Control workers) exist only with their account and are never offered for continuing.
                    guard !readCards.contains(name), let card = readCard(pair.appending(path: name)) else { continue }
                    guard !SessionSync.isAccountBoundCard(card) else { continue }
                    readCards.insert(name)
                    guard card["isArchived"] as? Bool != true,
                        let session = (card["cliSessionId"] as? String)?.lowercased(), let transcript = transcripts[session],
                        found[session] == nil
                    else { continue }
                    let folder = (card["originCwd"] as? String) ?? (card["cwd"] as? String)
                    found[session] = Conversation(
                        kind: .code, sessionID: session, title: title(of: card),
                        folders: folder.map { $0.contains(SessionSync.scratchFolder) ? [] : [$0] } ?? [],
                        lastActivity: lastActivity(of: transcript) ?? .distantPast,
                        transcript: transcript, ownerID: nil,
                        card: pair.appending(path: name), model: nonEmpty(card["model"]), effort: nonEmpty(card["effort"]))
                }
            }
            for pair in (try? SessionSync.sessionPairs(dataDirs: [dataDir], folder: CoworkSync.sessionsFolder)) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: pair.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    guard let card = readCard(pair.appending(path: name)), card["isArchived"] as? Bool != true,
                        let session = (card["cliSessionId"] as? String)?.lowercased(), found[session] == nil
                    else { continue }
                    // Old releases copied some cards between profiles; only the task with its history on disk counts.
                    let taskFolder = pair.appending(path: String(name.dropLast(".json".count)), directoryHint: .isDirectory)
                    guard let transcript = transcriptFiles(in: taskFolder.appending(path: ".claude/projects"))[session] else { continue }
                    found[session] = Conversation(
                        kind: .cowork, sessionID: session, title: title(of: card),
                        folders: (card["userSelectedFolders"] as? [String]) ?? [],
                        lastActivity: lastActivity(of: transcript) ?? .distantPast,
                        transcript: transcript, ownerID: id, taskFolder: taskFolder)
                }
            }
        }
        return found.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Code sessions working in `folder` (or inside it) with a message since `since`, most recent first. Cowork
    /// tasks are left out: they continue one at a time with their files attached.
    public static func recent(in folder: String, since: Date, from conversations: [Conversation]) -> [Conversation] {
        conversations.filter { $0.kind != .cowork && $0.lastActivity >= since && $0.works(in: folder) }
    }

    /// How many conversations “Continue All” opens at once unless asked for more. Each one becomes a session in the
    /// destination window, so a busy folder moved whole would spend that subscription in minutes.
    public static let continueAllLimit = 6

    /// What “Continue All” moves from `folder` to `destination`: the `limit` most recent of `recent(in:…)`, and how
    /// many more were left out.
    public static func continueAllBatch(
        in folder: String, since: Date, from conversations: [Conversation], to destination: String,
        limit: Int = continueAllLimit
    ) -> (batch: [Conversation], leftOut: Int) {
        let matching = recent(in: folder, since: since, from: conversations).filter { $0.runningIn != destination }
            .sorted { $0.lastActivity > $1.lastActivity }
        let batch = Array(matching.prefix(max(limit, 0)))
        return (batch, matching.count - batch.count)
    }

    /// An absolute path with `~`, `.`, `..` and symbolic links resolved, without a trailing slash.
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// The model of the last assistant message near the end of a transcript: what Claude Desktop picks when it
    /// imports the session without a card. A sub-agent's run (`isSidechain`) and Claude Code's own bookkeeping
    /// (`isMeta`) don't reflect what the person was talking to, so their records are skipped.
    static func lastModel(of transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let tail: UInt64 = 256 << 10
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > tail ? size - tail : 0)) != nil,
            let data = try? handle.readToEnd()
        else { return nil }
        let modelKey = Data(#""model":""#.utf8)
        let sidechainKey = Data(#""isSidechain":true"#.utf8), metaKey = Data(#""isMeta":true"#.utf8)
        let newline = UInt8(ascii: "\n")
        var last: String?
        var lineStart = data.startIndex
        while lineStart <= data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: newline) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            if line.range(of: sidechainKey) == nil, line.range(of: metaKey) == nil {
                var from = line.startIndex
                while let found = line.range(of: modelKey, in: from..<line.endIndex) {
                    from = found.upperBound
                    guard let end = line[from...].firstIndex(of: UInt8(ascii: "\"")), end - from < 80,
                        let text = String(data: line[from..<end], encoding: .utf8), text.hasPrefix("claude-")
                    else { continue }
                    last = text
                }
            }
            guard lineEnd < data.endIndex else { break }
            lineStart = data.index(after: lineEnd)
        }
        return last
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `<session id>` → `<projects>/<folder>/<session id>.jsonl`; the newest file wins if several share an id.
    static func transcriptFiles(in projects: URL) -> [String: URL] {
        let fm = FileManager.default
        var result: [String: (URL, Date)] = [:]
        for folder in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent.lowercased()
                let modified = SyncFolders.modificationDate(file) ?? .distantPast
                if let known = result[id], known.1 >= modified { continue }
                result[id] = (file, modified)
            }
        }
        return result.mapValues(\.0)
    }

    /// The newest record time near the end of a transcript. Opening a session appends bookkeeping records
    /// without a time, so the file's modification date is used only when no time is found.
    static func lastActivity(of transcript: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let tail: UInt64 = 256 << 10
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: size > tail ? size - tail : 0)) != nil else { return nil }
        // An empty file reads as nil; it still has a modification date.
        let data = (try? handle.readToEnd()) ?? Data()
        let key = Data(#""timestamp":""#.utf8)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var newest: Date?
        var from = data.startIndex
        while let found = data.range(of: key, in: from..<data.endIndex) {
            from = found.upperBound
            guard let end = data[from...].firstIndex(of: UInt8(ascii: "\"")), end - from < 40,
                let text = String(data: data[from..<end], encoding: .utf8),
                let date = formatter.date(from: text)
            else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest ?? SyncFolders.modificationDate(transcript)
    }

    static func readCard(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func title(of card: [String: Any]) -> String {
        let title = (card["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled" : title
    }
}

/// `claude://` links that Claude Desktop handles in whichever window receives them.
public enum ClaudeLink {
    /// Opens a Claude Code session by id, importing it into that window's list if the window doesn't know it yet.
    public static func resume(_ sessionID: String) -> URL {
        make("resume", [("session", sessionID)])
    }

    /// Starts a new Claude Code session in `folder`, with `prompt` typed in if given. Nothing is sent.
    public static func newCodeSession(folder: String, prompt: String? = nil) -> URL {
        make("code/new", [("folder", folder)] + (prompt.map { [("q", $0)] } ?? []))
    }

    /// Starts a new Cowork task with `prompt` typed in and `files` attached. Nothing is sent until you send it.
    public static func newCoworkTask(prompt: String, files: [URL]) -> URL {
        make("cowork/new", [("q", prompt)] + files.map { ("file", $0.path) })
    }

    /// Claude reads the query with `URLSearchParams`, which turns a literal `+` into a space, so everything but
    /// unreserved characters is percent-encoded.
    private static func make(_ path: String, _ items: [(String, String)]) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: "claude://\(path)?\(query)")!
    }
}
