import Foundation

/// Whether continuing a Code session or Project branch elsewhere keeps working in the same session or in a copy.
public enum ContinueMode: String, Sendable, CaseIterable {
    /// The same session, so the original window must not write to it any more.
    case same
    /// A copy under a new id: the original can keep running, and nothing writes to one session from two windows.
    case fork
    /// A copy for Project branches, which their Project's coordinator may write to again, and for sessions that
    /// may still be written to (see `Conversation.mayStillWrite`); the same session otherwise.
    case auto

    /// A session with a message this recent may still be running in its window.
    public static let forkWindow: TimeInterval = 600

    public func forks(_ conversation: Conversation, now: Date = Date()) -> Bool {
        guard conversation.kind != .cowork else { return false }
        switch self {
        case .same: return false
        case .fork: return true
        case .auto: return conversation.kind == .projectBranch || conversation.mayStillWrite(now: now)
        }
    }
}

/// How one Code session or Project branch continues in another window.
public struct ContinuePlan: Equatable, Sendable {
    public var conversation: Conversation
    /// `"main"` or a profile id.
    public var destination: String
    /// Continues as a copy under a new id instead of the same session.
    public var forks: Bool
    public var model: ModelNote?
    /// The session that opens there: the conversation's own or, once prepared, its copy.
    public var sessionID: String
    /// Whether the destination window took the session in: `true` once Claude has imported it there, `false` if it
    /// didn't within the wait, `nil` when the window knew the session already, so there is nothing to see.
    public var opened: Bool?

    public init(conversation: Conversation, destination: String, forks: Bool, model: ModelNote?) {
        self.conversation = conversation; self.destination = destination; self.forks = forks
        self.model = model; self.sessionID = conversation.sessionID
    }
}

/// Copies a Claude Code transcript under a new session id, the way Claude Code's own `--fork-session` starts a
/// new session from an existing history: with the session's tool results and sub-agents, and its file checkpoints,
/// so Rewind works in the copy. The original is only read.
public enum TranscriptFork {
    /// - Parameter claudeDir: Claude Code's folder (`~/.claude`) with `file-history` and `session-env`; by default
    ///   the one the transcript is in (`<claudeDir>/projects/<folder>/<id>.jsonl`).
    /// - Returns: the new session id, lowercased like the ones Claude Code makes.
    @discardableResult
    public static func fork(_ conversation: Conversation, claudeDir: URL? = nil,
                            newID: String = UUID().uuidString.lowercased()) throws -> String {
        let fm = FileManager.default
        let source = conversation.transcript
        let directory = source.deletingLastPathComponent()
        let oldID = source.deletingPathExtension().lastPathComponent
        let target = directory.appending(path: "\(newID).jsonl")
        let folder = directory.appending(path: oldID, directoryHint: .isDirectory)
        let newFolder = directory.appending(path: newID, directoryHint: .isDirectory)
        let home = claudeDir ?? directory.deletingLastPathComponent().deletingLastPathComponent()
        // Claude Code keeps a session's file checkpoints and hook environment under the session id.
        let perSession = ["file-history", "session-env"].map {
            (home.appending(path: "\($0)/\(oldID)", directoryHint: .isDirectory), home.appending(path: "\($0)/\(newID)", directoryHint: .isDirectory))
        }
        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: newFolder.path),
              !perSession.contains(where: { fm.fileExists(atPath: $0.1.path) }) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }

        // Everything the transcript refers to is copied first, so the new transcript never appears without it.
        var made: [URL] = []
        do {
            var isDirectory: ObjCBool = false
            // Tool results and sub-agent transcripts live next to the transcript, which refers to them by path.
            if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try fm.copyItem(at: folder, to: newFolder)
                made.append(newFolder)
                if let walker = fm.enumerator(at: newFolder, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let url as URL in walker where url.pathExtension == "jsonl" {
                        try write(replacing(oldID, with: newID, in: Data(contentsOf: url)), to: url)
                    }
                }
            }
            for (old, new) in perSession where fm.fileExists(atPath: old.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                made.append(new)
                try linkOrCopy(old, to: new)
            }
            try write(replacing(oldID, with: newID, in: completeRecords(Data(contentsOf: source))), to: target)
        } catch {
            for url in made { try? fm.removeItem(at: url) }   // made by this call a moment ago
            throw error
        }
        return newID
    }

    /// Checkpoint files never change once written (a new version gets a new name), so the copy shares them by
    /// hard links, as Claude Code does, and falls back to copying.
    static func linkOrCopy(_ folder: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: folder.path) {
            let from = folder.appending(path: name), to = target.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { try fm.copyItem(at: from, to: to); continue }
            do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
        }
    }

    /// A session that is still running may be halfway through writing its last record; that part is left out.
    static func completeRecords(_ data: Data) -> Data {
        let newline = UInt8(ascii: "\n")
        guard let last = data.last, last != newline else { return data }
        let start = data.lastIndex(of: newline).map { data.index(after: $0) } ?? data.startIndex
        if (try? JSONSerialization.jsonObject(with: data[start...])) != nil { return data }
        return data[data.startIndex..<start]
    }

    /// Every occurrence of `old` (as written, and lowercased) becomes `new`, except inside a record's own
    /// `message` field: each record's `sessionId` and the paths of the session's own files are rewritten, but
    /// what the record's `message` says is left exactly as it was, so a message that quotes or pastes the old
    /// id keeps it.
    static func replacing(_ old: String, with new: String, in data: Data) -> Data {
        var output = Data(capacity: data.count)
        var from = data.startIndex
        for range in messageValueRanges(in: data) {
            output.append(replacingEverywhere(old, with: new, in: data[from..<range.lowerBound]))
            output.append(data[range])
            from = range.upperBound
        }
        output.append(replacingEverywhere(old, with: new, in: data[from...]))
        return output
    }

    private static func replacingEverywhere(_ old: String, with new: String, in data: Data) -> Data {
        var result = data
        for variant in Set([old, old.lowercased()]) {
            let needle = Data(variant.utf8), replacement = Data(new.utf8)
            var output = Data(capacity: result.count)
            var from = result.startIndex
            while let found = result.range(of: needle, in: from..<result.endIndex) {
                output.append(result[from..<found.lowerBound])
                output.append(replacement)
                from = found.upperBound
            }
            output.append(result[from..<result.endIndex])
            result = output
        }
        return result
    }

    /// The byte ranges of every top-level `"message":` field's value in `data`, one JSONL record at a time. A
    /// value already found is skipped whole before searching for the next `"message":`, so text inside it (such
    /// as a pasted `"message":"…"` fragment) is never mistaken for another record's field.
    private static func messageValueRanges(in data: Data) -> [Range<Data.Index>] {
        let marker = Data(#""message":"#.utf8)
        var ranges: [Range<Data.Index>] = []
        var from = data.startIndex
        while let found = data.range(of: marker, in: from..<data.endIndex) {
            var valueStart = found.upperBound
            while valueStart < data.endIndex, isJSONWhitespace(data[valueStart]) { valueStart = data.index(after: valueStart) }
            let valueEnd = endOfJSONValue(in: data, start: valueStart)
            ranges.append(valueStart..<valueEnd)
            from = valueEnd
        }
        return ranges
    }

    /// Where the JSON value starting at `start` ends: past the matching quote, brace or bracket, or at the next
    /// `,`, `}` or `]` for a number, boolean or null. A lightweight stand-in for a full JSON parse, used only to
    /// find one field's value.
    private static func endOfJSONValue(in data: Data, start: Data.Index) -> Data.Index {
        guard start < data.endIndex else { return start }
        switch data[start] {
        case UInt8(ascii: "\""):
            return endOfJSONString(in: data, quote: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var i = start, depth = 0
            while i < data.endIndex {
                switch data[i] {
                case UInt8(ascii: "\""): i = endOfJSONString(in: data, quote: i); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return data.index(after: i) }
                default: break
                }
                i = data.index(after: i)
            }
            return i
        default:
            var i = start
            while i < data.endIndex, !",}]".utf8.contains(data[i]) { i = data.index(after: i) }
            return i
        }
    }

    /// Where the JSON string that opens at `quote` ends, honoring `\"` escapes.
    private static func endOfJSONString(in data: Data, quote: Data.Index) -> Data.Index {
        var i = data.index(after: quote)
        while i < data.endIndex {
            if data[i] == UInt8(ascii: "\\") { i = data.index(i, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex; continue }
            if data[i] == UInt8(ascii: "\"") { return data.index(after: i) }
            i = data.index(after: i)
        }
        return i
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    /// Removes everything `fork(_:claudeDir:newID:)` made for `id`: its transcript, its own tool-results and
    /// sub-agent folder, and its file-history and session-env copies. Used to undo a copy from a run that failed
    /// partway through, so a `prepare` failure never leaves an orphan behind.
    static func removeCopy(_ id: String, in folder: URL, claudeDir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appending(path: "\(id).jsonl"))
        try? fm.removeItem(at: folder.appending(path: id, directoryHint: .isDirectory))
        for kind in ["file-history", "session-env"] {
            try? fm.removeItem(at: claudeDir.appending(path: "\(kind)/\(id)", directoryHint: .isDirectory))
        }
    }

    /// Written under a temporary name readable only by you, then moved into place.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: url) }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}

/// Which copy a source session already has in a destination, so a second "Continue All" to the same destination
/// reuses it instead of forking another. Kept in `continue-copies.json`, one entry per (source, destination); the
/// copy's own transcript is the real record, so a stale entry whose copy is gone (removed by hand, or rolled
/// back after a failed run) is simply overwritten by a fresh fork the next time.
struct ContinueCopies: Sendable {
    let file: URL

    init(paths: Paths) { file = paths.stateDir.appending(path: "continue-copies.json") }

    private struct Entry: Codable, Equatable { var source: String; var destination: String; var copy: String }
    private struct Stored: Codable { var version = 1; var copies: [Entry] }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.copies
    }

    private func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Stored(copies: entries)).write(to: file, options: .atomic)
    }

    /// The copy already made of `source` in `destination`, if its transcript is still in `folder`.
    func existingCopy(of source: String, in destination: String, folder: URL) -> String? {
        guard let entry = load().first(where: { $0.source == source && $0.destination == destination }),
              FileManager.default.fileExists(atPath: folder.appending(path: "\(entry.copy).jsonl").path) else { return nil }
        return entry.copy
    }

    /// Records that `source` now has `copy` in `destination`, replacing any earlier entry for the same pair.
    func record(source: String, destination: String, copy: String) throws {
        var entries = load().filter { !($0.source == source && $0.destination == destination) }
        entries.append(Entry(source: source, destination: destination, copy: copy))
        try save(entries)
    }

    /// Drops every entry naming `copy`, so a copy rolled back after a failed run is never offered for reuse.
    func forget(copy: String) throws {
        try save(load().filter { $0.copy != copy })
    }
}

/// The sessions a window has cards for, read from one card folder.
enum SessionCards {
    /// The `cliSessionId` of every `local_*.json` card in `folder`, lowercased; only cards modified since
    /// `modifiedSince` if given. Cards can be large, so the id is found without parsing the whole file.
    static func sessions(in folder: URL, modifiedSince: Date? = nil) -> Set<String> {
        let key = Data(#""cliSessionId":""#.utf8)
        var found = Set<String>()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
            let url = folder.appending(path: name)
            if let modifiedSince, (SyncFolders.modificationDate(url) ?? .distantPast) < modifiedSince { continue }
            guard let data = try? Data(contentsOf: url), let start = data.range(of: key)?.upperBound,
                  let end = data[start...].firstIndex(of: UInt8(ascii: "\"")), end - start <= 64,
                  let id = String(data: data[start..<end], encoding: .utf8), !id.isEmpty else { continue }
            found.insert(id.lowercased())
        }
        return found
    }
}

/// What happens to the model a conversation ran with when it continues in another window.
public struct ModelNote: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// It continues with the same model.
        case carried
        /// It continues with the same model, which that window's account has not run before.
        case unverified
        /// Claude imports the session there and picks the model from the history, which doesn't record a choice
        /// such as long context; choose it before sending.
        case chooseBeforeSending
    }

    public var model: String
    public var kind: Kind

    public init(model: String, kind: Kind) { self.model = model; self.kind = kind }

    /// Needs your attention before the first message.
    public var isWarning: Bool { kind != .carried }

    public func message(destination: String) -> String {
        switch kind {
        case .carried:
            return "Continues with \(model)."
        case .unverified:
            return "Continues with \(model), which Claude \(destination) hasn't run before. If it isn't offered there, choose another model before you send."
        case .chooseBeforeSending:
            return "Claude \(destination) takes the model from the history when it opens this. Choose \(model) in the model menu before you send."
        }
    }

    /// - Parameters:
    ///   - model: the model on the conversation's card.
    ///   - historyModel: the model of the last answer in the transcript, which Claude uses when it imports it.
    ///   - supported: the destination's account has run `model` before.
    ///   - card: whether the destination has the conversation's card already or Claude imports the session there.
    public static func decide(model: String?, historyModel: String?, supported: Bool, card: CardSource) -> ModelNote? {
        guard let model else { return nil }
        switch card {
        case .shared:
            return ModelNote(model: model, kind: supported ? .carried : .unverified)
        case .imported:
            guard model == historyModel else { return ModelNote(model: model, kind: .chooseBeforeSending) }
            return ModelNote(model: model, kind: supported ? .carried : .unverified)
        }
    }

    public enum CardSource: Sendable { case shared, imported }
}

/// Models a window's account has run, from records Claude Desktop keeps only in that window.
public enum ModelSupport {
    static let origin = "https://claude.ai"
    static let resultPrefix = "epitaxy-session-result:"

    /// Per-session cost records in Local Storage (never copied between windows) and the window's own Project and
    /// Remote Control cards (which stay with their account). Empty if nothing can be read.
    public static func modelsUsed(in dataDir: URL) -> Set<String> {
        var found = Set<String>()
        if let items = try? LocalStorage(dataDir: dataDir).items(origin: origin) {
            for (key, value) in items where key.hasPrefix(resultPrefix) { found.formUnion(models(inSessionResult: value)) }
        }
        let fm = FileManager.default
        for pair in (try? SessionSync.sessionPairs(dataDirs: [dataDir], folder: SessionSync.sessionsFolder)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: pair.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                guard let card = ConversationIndex.readCard(pair.appending(path: name)), SessionSync.isAccountBoundCard(card),
                      let model = card["model"] as? String, !model.isEmpty else { continue }
                found.insert(model)
            }
        }
        return found
    }

    /// `{"perModel":{"claude-opus-5-5[1m]":{…}}}` → the model names.
    static func models(inSessionResult json: String) -> Set<String> {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let perModel = object["perModel"] as? [String: Any] else { return [] }
        return Set(perModel.keys.filter { !$0.isEmpty })
    }
}

/// Where to continue: which signed-in subscriptions have headroom, judged by samples that may be hours old.
public enum DestinationRanking {
    /// Out of five-hour or weekly quota by its latest recorded usage.
    public static func isAtLimit(_ status: ProfileStatus, now: Date = Date()) -> Bool {
        guard status.isSignedIn, let usage = status.usage else { return false }
        if let five = usage.fiveHour, five >= 100, !usage.isFiveHourStale(now: now) { return true }
        if let week = usage.week, week >= 100, now.timeIntervalSince(usage.sampledAt) < 7 * 86_400 { return true }
        return false
    }

    /// Whether `status` is signed in with one of `accounts` (email addresses); any window when `accounts` is `nil`.
    public static func isAllowed(_ status: ProfileStatus, accounts: Set<String>?) -> Bool {
        guard let accounts else { return true }
        return status.email.map { accounts.contains($0.lowercased()) } ?? false
    }

    /// Signed-in subscriptions not at their limit, and signed in with one of `accounts` if given, by the weekly
    /// usage of their latest sample, lowest first; a newer sample first when two are equal, then those without
    /// usage data. An old sample isn't pushed back: a subscription kept in reserve is sampled only when its window
    /// is used, so its sample is old precisely because nobody has used it since.
    public static func ranked(_ statuses: [ProfileStatus], excluding excluded: String? = nil, accounts: Set<String>? = nil,
                              now: Date = Date()) -> [ProfileStatus] {
        let candidates = statuses.filter {
            $0.isSignedIn && $0.id != excluded && !isAtLimit($0, now: now) && isAllowed($0, accounts: accounts)
        }
        return candidates.enumerated().sorted { a, b in
            let (wa, wb) = (a.element.usage?.week ?? 101, b.element.usage?.week ?? 101)
            if wa != wb { return wa < wb }
            let (sa, sb) = (a.element.usage?.sampledAt ?? .distantPast, b.element.usage?.sampledAt ?? .distantPast)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    public static func best(_ statuses: [ProfileStatus], excluding excluded: String? = nil, accounts: Set<String>? = nil,
                            now: Date = Date()) -> String? {
        ranked(statuses, excluding: excluded, accounts: accounts, now: now).first?.id
    }

    /// The one to mark “Most headroom”: only when at least two subscriptions have a fresh sample to compare,
    /// and never one whose sample is stale.
    public static func mostHeadroom(_ statuses: [ProfileStatus], now: Date = Date()) -> String? {
        let fresh = ranked(statuses, now: now).filter { $0.usage?.isFresh(now: now) == true && $0.usage?.week != nil }
        return fresh.count > 1 ? fresh.first?.id : nil
    }
}

/// “now”, “12m ago”, “5h ago”, “3d ago”.
public func relativeAge(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86_400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86_400)d ago"
    }
}
