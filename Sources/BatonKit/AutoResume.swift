import Foundation
import OSLog

/// One session's entry for Claude Desktop's "Auto-continue when limits reset", kept per window in
/// `claude_desktop_config.json` → `preferences.epitaxyPrefs["autoResumeRateLimit.<account>"]["local_<id>"]`.
/// Claude sends the session a message by itself about 90 seconds after `resetsAt`, while that window is open and
/// shows the session, or when it shows it within six hours; it tries at most three times.
public struct AutoResumeEntry: Equatable, Sendable {
    /// `local_<id>`: the name of the session's card in that window.
    public var key: String
    public var resetsAt: Date
    public var attempt: Int
    public var optedIn: Bool

    public static let maxAttempts = 3
    /// Claude drops an entry it finds more than six hours past its reset.
    public static let lateLimit: TimeInterval = 6 * 3600

    public init(key: String, resetsAt: Date, attempt: Int = 0, optedIn: Bool = true) {
        self.key = key; self.resetsAt = resetsAt; self.attempt = attempt; self.optedIn = optedIn
    }

    /// Claude will still continue this session by itself. An entry Claude has already acted on (an attempt made
    /// and its moment passed) isn't: the session has resumed, or Claude gave up on it.
    public func isArmed(now: Date = Date()) -> Bool {
        optedIn && attempt < Self.maxAttempts && resetsAt > now.addingTimeInterval(-Self.lateLimit) && !(attempt >= 1 && now > firesAt)
    }

    /// When Claude sends its message: 90 seconds after the reset, plus a few seconds.
    public var firesAt: Date { resetsAt.addingTimeInterval(LimitState.grace) }
}

/// Reads a window's auto-continue entries, and turns one off in a closed window when its session continues elsewhere,
/// so the session doesn't run in two windows. Only `optedIn` of that one entry changes, the way `LocalOnly` edits the
/// same file: a dated backup, the old value recorded first, an atomic write, a read-back. The account's own key and
/// Claude's `autoResumeRateLimitOptIn` choice are never touched. An open window keeps the whole bucket in memory and
/// writes it back, so it is never edited; nor is a settings file that links outside that window's data folder, which
/// another window may use (`Failure.linkedOutside`).
public struct AutoResume: Sendable {
    public let paths: Paths
    let isRunning: @Sendable (String) -> Bool

    public init(paths: Paths, isRunning: @escaping @Sendable (String) -> Bool) {
        self.paths = paths
        self.isRunning = isRunning
    }

    static let prefix = "autoResumeRateLimit."
    static func bucketKey(_ account: String) -> String { prefix + account }

    // MARK: Reading

    /// The entries for `account` in a `claude_desktop_config.json`: empty when there are none, `nil` when the file or
    /// the bucket isn't what Claude writes.
    public static func entries(inConfig data: Data, account: String) -> [AutoResumeEntry]? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var object = top
        for key in ["preferences", "epitaxyPrefs", bucketKey(account)] {
            guard let value = object[key] else { return [] }
            guard let next = value as? [String: Any] else { return nil }
            object = next
        }
        return entries(inBucket: object)
    }

    /// The entries of one bucket object, by card name.
    static func entries(inBucket object: [String: Any]) -> [AutoResumeEntry] {
        object.compactMap { key, value -> AutoResumeEntry? in
            guard key.hasPrefix("local_"), let entry = value as? [String: Any], var resets = UsageHistory.number(entry["resetsAt"]), resets > 0
            else { return nil }
            if resets > 100_000_000_000 { resets /= 1000 }
            let opted = (entry["optedIn"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            return AutoResumeEntry(
                key: key, resetsAt: Date(timeIntervalSince1970: resets), attempt: UsageHistory.number(entry["attempt"]).map { Int($0) } ?? 0,
                optedIn: opted)
        }.sorted { $0.key < $1.key }
    }

    /// The entries in the config of the window at `dataDir`.
    public static func entries(in dataDir: URL, account: String) -> [AutoResumeEntry]? {
        guard let data = try? Data(contentsOf: dataDir.appending(path: LocalOnly.configName)) else { return [] }
        return entries(inConfig: data, account: account)
    }

    /// The `cliSessionId` of a card, found without parsing the whole file.
    static func cliSessionID(inCard url: URL) -> String? {
        let key = Data(#""cliSessionId":""#.utf8)
        guard let data = try? Data(contentsOf: url), let start = data.range(of: key)?.upperBound,
            let end = data[start...].firstIndex(of: UInt8(ascii: "\"")), end - start <= 64
        else { return nil }
        return String(data: data[start..<end], encoding: .utf8)?.lowercased()
    }

    // MARK: Changing

    public enum Failure: LocalizedError, Equatable {
        case windowOpen(String)
        case entryChanged
        case didNotReadBack
        /// The window's settings file links to a file outside its data folder, as in `LocalOnly.Failure.linkedOutside`.
        case linkedOutside

        public var errorDescription: String? {
            switch self {
            case .windowOpen(let label): "Claude \(label) is open, so its settings file was left as it is"
            case .entryChanged: "Claude changed that entry in the meantime"
            case .linkedOutside:
                "the settings file links to a file outside that window's data folder, which another window may use, so it was left as it is"
            case .didNotReadBack: "the settings file didn't read back as written; the earlier file was put back"
            }
        }
    }

    /// What a change did: turned an entry off where its session no longer runs, or seeded one where it continues.
    public enum Kind: String, Codable, Equatable, Sendable {
        case turnedOff, seeded
    }

    /// What Baton changed, to put it back with `undo`.
    public struct Change: Codable, Equatable, Sendable {
        public var window: String
        public var account: String
        public var entry: String
        public var resetsAt: Date
        public var changedAt: Date
        /// A turn-off: the JSON text `optedIn` had in the settings. A seed: the entry's JSON text before, `null` if none.
        public var prior: String
        /// `nil` in records written before seeding existed: a turn-off.
        public var kind: Kind? = nil
        /// The same as `prior` for Claude's Local Storage copy of the entry; `nil` when that copy wasn't changed.
        public var priorMirror: String? = nil

        public var action: Kind { kind ?? .turnedOff }
    }

    /// An entry to turn off once its window is closed: its session continued elsewhere while that window was open.
    public struct Pending: Codable, Equatable, Sendable {
        public var window: String
        public var account: String
        public var entry: String
        public var resetsAt: Date
        public var recordedAt: Date
    }

    struct State: Codable {
        var version = 1
        var changes: [Change] = []
        var pending: [Pending]? = nil
    }

    /// Changes, the pending turn-offs and the settings files they touch are written under the lock the open-time
    /// merges and Local only hold, so none of them writes over another's change.
    private var lockFile: URL { paths.stateDir.appending(path: "open.lock") }

    static func stateFile(_ paths: Paths) -> URL { paths.stateDir.appending(path: "auto-resume-changes.json") }

    /// Changes not undone yet, oldest first.
    public func changes() -> [Change] { readState().changes }

    /// Turn-offs waiting for their window to close, oldest first.
    public func pending() -> [Pending] { readState().pending ?? [] }

    /// Remembers to turn `entry` off in `window` once that window is closed.
    public func addPending(_ entry: AutoResumeEntry, window: String, account: String, now: Date = Date()) throws {
        _ = try FileLock.withLock(lockFile, blocking: true) {
            var state = readState()
            var pending = state.pending ?? []
            pending.removeAll { $0.window == window && $0.account == account && $0.entry == entry.key }
            pending.append(Pending(window: window, account: account, entry: entry.key, resetsAt: entry.resetsAt, recordedAt: now))
            state.pending = pending
            try saveState(state)
        }
    }

    /// Turns off every pending entry whose window is closed now, the way `turnOff` does, and forgets the ones Claude
    /// is done with. Entries in windows still open stay pending.
    /// - Returns: the windows where Baton turned an entry off.
    @discardableResult
    public func applyPending(now: Date = Date()) -> [String] {
        let waiting = pending()
        guard !waiting.isEmpty else { return [] }
        var done: [Pending] = []
        var turnedOff: [String] = []
        for item in waiting {
            let entry = AutoResume.entries(in: dataDir(item.window), account: item.account)?.first { $0.key == item.entry }
            guard let entry, entry.resetsAt == item.resetsAt, entry.isArmed(now: now) else {
                done.append(item)
                continue
            }
            do {
                if try turnOff(entry, window: item.window, account: item.account, now: now) { turnedOff.append(item.window) }
                done.append(item)
            } catch Failure.windowOpen {
                continue
            } catch {
                Log.error("continue", "A pending auto-continue turn-off failed: \(error.localizedDescription)")
                done.append(item)
            }
        }
        _ = try? FileLock.withLock(lockFile, blocking: true) {
            var state = readState()
            state.pending = (state.pending ?? []).filter { !done.contains($0) }
            try saveState(state)
        }
        return turnedOff
    }

    /// Turns `optedIn` off for one entry of a closed window, in the settings and in Claude's Local Storage copy of the
    /// same entry, which can disagree with the settings (one was seen off while the other was on).
    /// - Returns: `false` when both were off already.
    @discardableResult
    public func turnOff(_ entry: AutoResumeEntry, window: String, account: String, now: Date = Date()) throws -> Bool {
        try FileLock.withLock(lockFile, blocking: true) {
            guard !running(window) else { throw Failure.windowOpen(label(window)) }
            let url = config(window)
            let original = try Data(contentsOf: url)
            var patch = try JSONPatch(original)
            guard let member = try Self.optedIn(in: patch, account: account, entry: entry.key),
                Self.entries(inConfig: original, account: account)?.first(where: { $0.key == entry.key })?.resetsAt == entry.resetsAt
            else { throw Failure.entryChanged }
            let prior = patch.text(member)
            let path = ["preferences", "epitaxyPrefs", Self.bucketKey(account), entry.key, "optedIn"]
            var configChange: (patch: JSONPatch, expected: [String: Any])?
            if prior == "true" {
                patch.replace(member, with: "false")
                configChange = (patch, Self.setting(false, at: path, in: try JSONPatch(original).dictionary()))
            }
            var mirror: MirrorWrite?
            if let copy = mirrorCopy(window, account: account), var bucket = copy.bucket, var object = bucket[entry.key] as? [String: Any],
                Self.entries(inBucket: [entry.key: object]).first?.resetsAt == entry.resetsAt, Self.isTrue(object["optedIn"])
            {
                object["optedIn"] = false
                bucket[entry.key] = object
                mirror = MirrorWrite(copy: copy, bucket: bucket, now: now)
            }
            guard configChange != nil || mirror != nil else { return false }
            let change = Change(
                window: window, account: account, entry: entry.key, resetsAt: entry.resetsAt, changedAt: now, prior: prior,
                priorMirror: mirror == nil ? nil : "true")
            var state = readState()
            state.changes.removeAll { $0.window == window && $0.account == account && $0.entry == entry.key }
            state.changes.append(change)
            try commit(window: window, url: url, original: original, config: configChange, mirror: mirror) { try saveState(state) }
            return true
        } ?? false
    }

    /// Adds entries to a closed window's auto-continue for sessions that continue there after another window's limit,
    /// each with its reset two minutes past, so Claude continues each session once that window shows it. Written to
    /// the settings and to Claude's Local Storage copy, keeping every other entry, with the same backup and read-back
    /// as `turnOff`, and recorded so `undo` removes them. Nothing is written when the account turned the option off
    /// in that window or in `source`: that choice is the user's.
    /// - Parameter entries: the sessions' card names (`local_<id>`); their own reset times aren't used.
    /// - Returns: how many entries were written.
    @discardableResult
    public func seed(
        _ entries: [AutoResumeEntry], window: String, account: String, source: (window: String, account: String)? = nil, now: Date = Date()
    ) throws -> Int {
        try FileLock.withLock(lockFile, blocking: true) { () throws -> Int in
            guard !running(window) else { throw Failure.windowOpen(label(window)) }
            if Self.optedOut(in: dataDir(window), account: account)
                || source.map({ Self.optedOut(in: dataDir($0.window), account: $0.account) }) == true
            {
                Log.notice("continue", "Didn't seed auto-continue in window \(window): the option is off for that account")
                return 0
            }
            var keys: [String] = []
            for key in entries.map(\.key) where key.hasPrefix("local_") && !keys.contains(key) { keys.append(key) }
            guard !keys.isEmpty else { return 0 }
            let resets = Int(now.timeIntervalSince1970) - Self.seedAge
            let value: [String: Any] = ["resetsAt": resets, "attempt": 0, "optedIn": true]
            let text = #"{"resetsAt": \#(resets), "attempt": 0, "optedIn": true}"#
            let url = config(window)
            let original = try Data(contentsOf: url)
            var patch = try JSONPatch(original)
            var expected = try patch.dictionary()
            var priors: [String: String] = [:]
            for key in keys {
                let bucket = try Self.object(at: ["preferences", "epitaxyPrefs", Self.bucketKey(account)], in: &patch)
                if let member = bucket.members.last(where: { $0.key == key }) {
                    priors[key] = patch.text(member)
                    patch.replace(member, with: text)
                } else {
                    priors[key] = "null"
                    patch.insert(key: key, value: text, in: bucket)
                }
                expected = Self.setting(value, at: ["preferences", "epitaxyPrefs", Self.bucketKey(account), key], in: expected)
            }
            var mirror: MirrorWrite?
            var mirrorPriors: [String: String] = [:]
            if let copy = mirrorCopy(window, account: account) {
                if var bucket = copy.bucket {
                    for key in keys {
                        mirrorPriors[key] = bucket[key].map(SidebarLayout.json) ?? "null"
                        bucket[key] = value
                    }
                    mirror = MirrorWrite(copy: copy, bucket: bucket, now: now)
                } else {
                    Log.notice("continue", "Left the Local Storage copy of auto-continue in window \(window) as it is: not what Claude writes")
                }
            }
            var state = readState()
            let resetsAt = Date(timeIntervalSince1970: TimeInterval(resets))
            for key in keys {
                state.changes.removeAll { $0.window == window && $0.account == account && $0.entry == key }
                state.changes.append(
                    Change(
                        window: window, account: account, entry: key, resetsAt: resetsAt, changedAt: now, prior: priors[key] ?? "null",
                        kind: .seeded, priorMirror: mirror == nil ? nil : mirrorPriors[key]))
            }
            try commit(window: window, url: url, original: original, config: (patch, expected), mirror: mirror) { try saveState(state) }
            Log.notice("continue", "Seeded auto-continue for \(keys.count) session\(keys.count == 1 ? "" : "s") in window \(window)")
            return keys.count
        } ?? 0
    }

    /// How far in the past a seeded entry's reset is, so Claude acts on it as soon as the session is shown.
    static let seedAge = 120

    /// Puts back a change Baton made, if the entry is still the one it made: `optedIn` of a turn-off, or the entry a
    /// seed replaced (none, if there was none), in the settings and in the Local Storage copy. The record is dropped
    /// either way, unless the window is open.
    /// - Returns: whether anything changed.
    @discardableResult
    public func undo(_ change: Change) throws -> Bool {
        try FileLock.withLock(lockFile, blocking: true) {
            guard !running(change.window) else { throw Failure.windowOpen(label(change.window)) }
            var state = readState()
            state.changes.removeAll { $0 == change }
            let url = config(change.window)
            let bucketPath = ["preferences", "epitaxyPrefs", Self.bucketKey(change.account)]
            let original = (try? Data(contentsOf: url)) ?? Data()
            let prior = try? JSONSerialization.jsonObject(with: Data(change.prior.utf8), options: .fragmentsAllowed)
            let same = Self.entries(inConfig: original, account: change.account)?.first(where: { $0.key == change.entry })?.resetsAt == change.resetsAt
            var configChange: (patch: JSONPatch, expected: [String: Any])?
            if same, var patch = try? JSONPatch(original), let whole = try? patch.dictionary() {
                switch change.action {
                case .turnedOff:
                    if change.prior != "false", let prior, let member = try Self.optedIn(in: patch, account: change.account, entry: change.entry),
                        patch.text(member) == "false"
                    {
                        patch.replace(member, with: change.prior)
                        configChange = (patch, Self.setting(prior, at: bucketPath + [change.entry, "optedIn"], in: whole))
                    }
                case .seeded:
                    if let bucket = try? Self.existingObject(at: bucketPath, in: patch),
                        let index = bucket.members.lastIndex(where: { $0.key == change.entry })
                    {
                        if change.prior == "null" {
                            patch.remove(index, in: bucket)
                            configChange = (patch, Self.setting(nil, at: bucketPath + [change.entry], in: whole))
                        } else if let prior {
                            patch.replace(bucket.members[index], with: change.prior)
                            configChange = (patch, Self.setting(prior, at: bucketPath + [change.entry], in: whole))
                        }
                    }
                }
            }
            var mirror: MirrorWrite?
            if let priorMirror = change.priorMirror, let copy = mirrorCopy(change.window, account: change.account), var bucket = copy.bucket,
                var object = bucket[change.entry] as? [String: Any],
                Self.entries(inBucket: [change.entry: object]).first?.resetsAt == change.resetsAt
            {
                let before = try? JSONSerialization.jsonObject(with: Data(priorMirror.utf8), options: .fragmentsAllowed)
                switch change.action {
                case .turnedOff:
                    if let before, object["optedIn"].map(InterfaceSync.canonical) == "false" {
                        object["optedIn"] = before
                        bucket[change.entry] = object
                        mirror = MirrorWrite(copy: copy, bucket: bucket, now: Date())
                    }
                case .seeded:
                    bucket[change.entry] = priorMirror == "null" ? nil : before
                    mirror = MirrorWrite(copy: copy, bucket: bucket, now: Date())
                }
            }
            guard configChange != nil || mirror != nil else {
                try saveState(state)
                return false
            }
            try commit(window: change.window, url: url, original: original, config: configChange, mirror: mirror) { try saveState(state) }
            return true
        } ?? false
    }

    /// The `optedIn` member of one entry, by walking the objects that hold it.
    static func optedIn(in patch: JSONPatch, account: String, entry: String) throws -> JSONPatch.Member? {
        guard let object = try existingObject(at: ["preferences", "epitaxyPrefs", bucketKey(account), entry], in: patch) else { return nil }
        return object.members.last { $0.key == "optedIn" }
    }

    /// The object at `path`, `nil` if a step is missing or isn't an object.
    static func existingObject(at path: [String], in patch: JSONPatch) throws -> JSONPatch.Object? {
        var object = try patch.top()
        for key in path {
            guard let member = object.members.last(where: { $0.key == key }), patch.bytes[member.valueStart] == UInt8(ascii: "{") else { return nil }
            object = try patch.object(at: member.valueStart)
        }
        return object
    }

    /// The object at `path`, added empty where a step is missing. A step that isn't an object is refused.
    static func object(at path: [String], in patch: inout JSONPatch) throws -> JSONPatch.Object {
        var object = try patch.top()
        for (depth, key) in path.enumerated() {
            if let member = object.members.last(where: { $0.key == key }) {
                guard patch.bytes[member.valueStart] == UInt8(ascii: "{") else {
                    throw LocalStorageError.corrupt(
                        "\(path.prefix(depth + 1).joined(separator: ".")) in \(LocalOnly.configName) isn't an object; it was left as it is")
                }
                object = try patch.object(at: member.valueStart)
            } else {
                patch.insert(key: key, value: "{}", in: object)
                return try self.object(at: path, in: &patch)
            }
        }
        return object
    }

    /// Whether the account turned "Auto-continue when limits reset" off in the window at `dataDir`, in its settings or
    /// in the Local Storage copy. Only an explicit `false` counts: Claude's default is on.
    public static func optedOut(in dataDir: URL, account: String) -> Bool {
        let key = "autoResumeRateLimitOptIn." + account
        let data = (try? Data(contentsOf: dataDir.appending(path: LocalOnly.configName))) ?? Data()
        let prefs = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap {
            ($0["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any]
        }
        if isFalse(prefs?[key]) { return true }
        let storage = LocalStorage(dataDir: dataDir)
        guard storage.exists, let text = (try? storage.items(origin: InterfaceSync.origin))?["LSS-persisted." + key] else { return false }
        return isFalse(InterfaceSync.object(text)?["value"])
    }

    /// Whether Claude can continue sessions by itself in the window at `dataDir` for `account`, and whether Baton
    /// should seed it: not when the server flag is known to be off, nor when the account turned the option off there or
    /// in `source`.
    public func seeding(window: String, account: String, source: (window: String, account: String)? = nil, now: Date = Date()) -> Seeding {
        let optedOut =
            Self.optedOut(in: dataDir(window), account: account)
            || source.map { Self.optedOut(in: dataDir($0.window), account: $0.account) } == true
        return Seeding.decide(flag: ServerFlags.autoResume(dataDir: dataDir(window), now: now), optedOut: optedOut)
    }

    static func isTrue(_ value: Any?) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
    }

    static func isFalse(_ value: Any?) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false
    }

    // MARK: Local Storage copy

    static func mirrorKey(_ account: String) -> String { "LSS-persisted." + bucketKey(account) }

    /// The entries in Claude's Local Storage copy of the bucket (`{value, tabId, timestamp}`), `nil` if it isn't that.
    public static func entries(inMirror text: String) -> [AutoResumeEntry]? {
        guard let bucket = InterfaceSync.object(text)?["value"] as? [String: Any] else { return nil }
        return entries(inBucket: bucket)
    }

    /// A window's Local Storage copy of one account's bucket, read while the window is closed.
    struct MirrorCopy {
        var storage: LocalStorage
        var key: String
        /// The stored text; `nil` when there is no copy yet.
        var text: String?
        /// The entries inside it: empty when there is no copy, `nil` when the copy isn't what Claude writes.
        var bucket: [String: Any]?
    }

    /// `nil` when the window has no Local Storage, or it can't be read.
    private func mirrorCopy(_ window: String, account: String) -> MirrorCopy? {
        let storage = LocalStorage(dataDir: dataDir(window))
        guard storage.exists else { return nil }
        let key = Self.mirrorKey(account)
        do {
            let text = try storage.items(origin: InterfaceSync.origin)[key]
            let bucket = text.map { InterfaceSync.object($0)?["value"] as? [String: Any] } ?? [:]
            return MirrorCopy(storage: storage, key: key, text: text, bucket: bucket)
        } catch {
            Log.error("continue", "Couldn't read the Local Storage of window \(window): \(error.localizedDescription)")
            return nil
        }
    }

    /// A new text for one Local Storage copy, and the one it replaces.
    struct MirrorWrite {
        var storage: LocalStorage
        var key: String
        var old: String?
        var new: String

        init(copy: MirrorCopy, bucket: [String: Any], now: Date) {
            storage = copy.storage
            key = copy.key
            old = copy.text
            new = SidebarLayout.mirrorText(bucket, copy.text, Int64(now.timeIntervalSince1970 * 1000))
        }

        func putBack() throws {
            try storage.update(origin: InterfaceSync.origin, set: old.map { [key: $0] } ?? [:], remove: old == nil ? [key] : [])
        }
    }

    /// Backups, then the settings file and the Local Storage copy; each read back, and everything put back as it was if
    /// either didn't come out as planned. Only a write that read back is recorded; if the record can't be saved, the
    /// earlier contents go back too.
    private func commit(
        window: String, url: URL, original: Data, config: (patch: JSONPatch, expected: [String: Any])?, mirror: MirrorWrite?,
        record: () throws -> Void
    ) throws {
        if config != nil { guard SettingsSync.leadsInside(url, dataDir(window)) else { throw Failure.linkedOutside } }
        let backup = Backup(paths: paths, now: Date())
        // A linked config is written where it leads, so that file's content is what is backed up, not the link.
        if config != nil { _ = try backup.save(LocalOnly.writeTarget(url), everyTime: true) }
        if let mirror { _ = try backup.save(mirror.storage.dbDir) }
        guard !running(window) else { throw Failure.windowOpen(label(window)) }
        if let config {
            try LocalOnly.replace(url, with: Data(config.patch.bytes))
            guard let written = try? JSONPatch(Data(contentsOf: url)), let dictionary = try? written.dictionary(),
                NSDictionary(dictionary: dictionary).isEqual(to: config.expected)
            else {
                try LocalOnly.replace(url, with: original)
                throw Failure.didNotReadBack
            }
        }
        func putBack() {
            if config != nil { try? LocalOnly.replace(url, with: original) }
            try? mirror?.putBack()
        }
        if let mirror {
            do {
                try mirror.storage.update(origin: InterfaceSync.origin, set: [mirror.key: mirror.new], remove: [])
            } catch {
                if config != nil { try? LocalOnly.replace(url, with: original) }
                throw error
            }
            guard (try? mirror.storage.items(origin: InterfaceSync.origin))?[mirror.key] == mirror.new else {
                putBack()
                throw Failure.didNotReadBack
            }
        }
        do { try record() } catch {
            putBack()
            throw error
        }
    }

    /// `object` with `value` at `path`; `nil` removes the last key.
    static func setting(_ value: Any?, at path: [String], in object: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return object }
        var object = object
        object[key] = path.count == 1 ? value : setting(value, at: Array(path.dropFirst()), in: object[key] as? [String: Any] ?? [:])
        return object
    }

    private func running(_ window: String) -> Bool { isRunning(window) || LocalStorage(dataDir: dataDir(window)).isInUse }
    private func dataDir(_ window: String) -> URL { window == "main" ? paths.mainDataDir : paths.dataDir(for: window) }
    private func config(_ window: String) -> URL { dataDir(window).appending(path: LocalOnly.configName) }
    private func label(_ window: String) -> String { window == "main" ? "(main)" : window.uppercased() }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: Self.stateFile(paths)), let state = try? JSONDecoder.autoResume.decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try JSONEncoder.autoResume.encode(state).write(to: Self.stateFile(paths), options: .atomic)
    }
}

extension JSONEncoder {
    fileprivate static var autoResume: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var autoResume: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Whether a hand-over seeds Claude's own auto-continue in the destination (`AutoResume.seed`).
public enum Seeding: String, Codable, Equatable, Sendable {
    /// Seed, then watch whether each session resumed: the server flag is on or can't be told.
    case seed
    /// The server flag `ccd_auto_resume_rate_limit` is off: Claude wouldn't act on an entry, so the sessions are opened
    /// and named instead.
    case flagOff
    /// The account turned "Auto-continue when limits reset" off in the destination or the source.
    case optedOut

    public static func decide(flag: Bool?, optedOut: Bool) -> Seeding {
        if optedOut { return .optedOut }
        return flag == false ? .flagOff : .seed
    }
}

// MARK: - What the hand-over says

/// What happens to another window's auto-continue for a session that continues elsewhere. `label` is what follows
/// "Claude": a profile's label, or "(main)".
public enum AutoResumeNote: Equatable, Sendable {
    /// That window was closed; Baton turned auto-continue off for this session there.
    case turnedOff(label: String)
    /// A dry run: continuing would turn it off there.
    case willTurnOff(label: String)
    /// That window is open, so Baton leaves it for now and turns it off once that window is closed: the app when it
    /// sees it closed, or `ProfileManager.open` before it starts that window again. `copied`: the destination got a
    /// copy, so archiving the original there loses nothing.
    case stillOn(label: String, resetsAt: Date, copied: Bool = false)
    case couldNotTurnOff(label: String, reason: String, copied: Bool = false)

    public var isWarning: Bool {
        switch self {
        case .stillOn, .couldNotTurnOff: true
        case .turnedOff, .willTurnOff: false
        }
    }

    public func message(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch self {
        case .turnedOff(let label):
            return "Claude \(label) was closed with Auto-continue when limits reset on for this session; Baton turned it off there, "
                + "so the session doesn't continue in two windows. To turn it back on, tick that option on the session's limit "
                + "message in Claude \(label); `baton doctor` lists what Baton turned off."
        case .willTurnOff(let label):
            return "Claude \(label) is closed with Auto-continue when limits reset on for this session; continuing turns it off there."
        case .stillOn(let label, let resetsAt, let copied):
            let firesAt = resetsAt.addingTimeInterval(LimitState.grace)
            let when =
                firesAt > now
                ? "\(LimitText.time(AutoResumeOffer.pickUp(resetsAt), now: now, timeZone: timeZone, locale: locale)) if it's on screen there, "
                    + "or when you next open this session there within 6 hours of the reset"
                : "when you next open this session there, within 6 hours of the reset"
            return "Claude \(label) will continue this session by itself \(when) (Auto-continue when limits reset is on there). "
                + "Baton turns that off once Claude \(label) is closed: right away while the Baton app is running, otherwise "
                + "when that window is next opened from Baton. " + Self.stopAdvice(label: label, copied: copied)
        case .couldNotTurnOff(let label, let reason, let copied):
            return "Claude \(label) may continue this session by itself when it next opens: Auto-continue when limits reset "
                + "couldn't be turned off there (\(reason)). " + Self.stopAdvice(label: label, copied: copied)
        }
    }

    /// Unticking the option is account-wide in that window; archiving is offered only when the destination has a copy,
    /// since archiving the shared session there would archive it everywhere.
    static func stopAdvice(label: String, copied: Bool) -> String {
        "To stop it sooner, untick that option on the limit message there; that turns auto-continue off for every session "
            + "of that account in Claude \(label)." + (copied ? " Or archive the original session there: you continue in a copy." : "")
    }
}

/// Offered before continuing when the source window's reset is minutes away: Claude picks the session up there itself.
public struct AutoResumeOffer: Equatable, Sendable {
    public var label: String
    public var resetsAt: Date
    /// The sessions it picks up, and their titles.
    public var sessions: Set<String>
    public var titles: [String]

    public init(label: String, resetsAt: Date, sessions: Set<String> = [], titles: [String] = []) {
        self.label = label; self.resetsAt = resetsAt; self.sessions = Set(sessions.map { $0.lowercased() }); self.titles = titles
    }

    /// Offered only when the reset is at most this far away.
    public static let within: TimeInterval = 15 * 60

    /// "about <reset + 2 min>": Claude sends its message 90 seconds after the reset, plus a few seconds.
    static func pickUp(_ resetsAt: Date) -> Date { resetsAt.addingTimeInterval(120) }

    /// An armed entry in an open window whose message is still to come, within `within`.
    public static func applies(to entry: AutoResumeEntry, isOpen: Bool, now: Date = Date()) -> Bool {
        isOpen && entry.isArmed(now: now) && now < entry.firesAt && entry.resetsAt.timeIntervalSince(now) <= within
    }

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”".
    public var names: String {
        let quoted = titles.map { "“\($0)”" }
        guard quoted.count > 1, let last = quoted.last else { return quoted.first ?? "this session" }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    public func message(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let several = titles.count > 1
        return "Claude \(label) resets \(LimitText.time(resetsAt, now: now, timeZone: timeZone, locale: locale)) and picks \(names) up by itself "
            + "\(LimitText.time(Self.pickUp(resetsAt), now: now, about: true, timeZone: timeZone, locale: locale)) "
            + (several
                ? "if they're on screen there, or when you next open them there within 6 hours."
                : "if it's on screen there, or when you next open it there within 6 hours.")
    }
}

// MARK: - Continuing

/// An armed auto-continue entry for a session, in a window other than the one it continues in.
public struct AutoResumeMatch: Equatable, Sendable {
    public var window: String
    public var label: String
    public var account: String
    public var session: String
    public var entry: AutoResumeEntry
    public var isOpen: Bool
}

extension ProfileManager {
    /// Auto-continue entries for every window, edited only while that window is closed.
    public var autoResume: AutoResume { AutoResume(paths: paths, isRunning: { self.isWindowOpen($0) }) }

    /// Every status with its usage and limits: the samples of its current organization, the limit messages of the
    /// sessions it ran, and its auto-continue reset times.
    func withLimits(_ statuses: [ProfileStatus], now: Date = Date()) -> [ProfileStatus] {
        let windows = statuses.map { (id: $0.id, dataDir: $0.isMain ? paths.mainDataDir : paths.dataDir(for: $0.id)) }
        let activity = limitTracker.activity(paths: paths, windows: windows, now: now)
        return zip(statuses, windows).map { found, window in
            var status = found
            let samples = UsageHistory.samples(in: window.dataDir)
            let resets = status.accountID.flatMap { AutoResume.entries(in: window.dataDir, account: $0) }?.map(\.resetsAt) ?? []
            status.usage = samples.last?.usage
            let found = activity[status.id]
            status.limits = Limits(
                samples: samples, hits: found?.hits ?? [], autoResume: resets, answeredAt: found?.answeredAt, askedAt: found?.askedAt)
            return status
        }
    }

    /// Armed auto-continue entries for `sessions` in windows other than `destination`, by session id. An entry is
    /// matched to a session through that window's card for it (`local_<id>.json` with its `cliSessionId`).
    public func autoResumeMatches(for sessions: Set<String>, excluding destination: String, now: Date = Date()) -> [String: [AutoResumeMatch]] {
        let sessions = Set(sessions.map { $0.lowercased() })
        var result: [String: [AutoResumeMatch]] = [:]
        guard !sessions.isEmpty else { return result }
        for window in windows where window.id != destination {
            guard let account = DesktopData.accountID(in: window.dataDir),
                let entries = AutoResume.entries(in: window.dataDir, account: account)?.filter({ $0.isArmed(now: now) }), !entries.isEmpty
            else { continue }
            let folders = cardFolders(in: window.dataDir)
            var isOpen: Bool?
            for entry in entries {
                guard let session = folders.lazy.compactMap({ AutoResume.cliSessionID(inCard: $0.appending(path: entry.key + ".json")) }).first,
                    sessions.contains(session)
                else { continue }
                let open = isOpen ?? (isWindowOpen(window.id) || LocalStorage(dataDir: window.dataDir).isInUse)
                isOpen = open
                result[session, default: []].append(
                    AutoResumeMatch(
                        window: window.id, label: displayLabel(of: window.id), account: account, session: session,
                        entry: entry, isOpen: open))
            }
        }
        return result
    }

    /// When a window whose reset is minutes away would pick some of `conversations` up by itself: offer to wait, and
    /// name them. In a batch, only those are left out; the rest continue.
    public func autoResumeOffer(for conversations: [Conversation], in destination: String, now: Date = Date()) -> AutoResumeOffer? {
        let code = conversations.filter { $0.kind != .cowork }
        let soon = autoResumeMatches(for: Set(code.map(\.sessionID)), excluding: destination, now: now).values.joined()
            .filter { AutoResumeOffer.applies(to: $0.entry, isOpen: $0.isOpen, now: now) }
        guard let first = soon.min(by: { $0.entry.resetsAt < $1.entry.resetsAt }) else { return nil }
        let sessions = Set(soon.map(\.session))
        return AutoResumeOffer(
            label: first.label, resetsAt: first.entry.resetsAt, sessions: sessions,
            titles: code.filter { sessions.contains($0.sessionID) }.map(\.title))
    }

    /// What continuing would do to other windows' auto-continue, without changing anything.
    func previewAutoResume(_ plans: inout [ContinuePlan], now: Date) {
        guard let destination = plans.first?.destination else { return }
        let matches = autoResumeMatches(for: Set(plans.map(\.conversation.sessionID)), excluding: destination, now: now)
        for i in plans.indices {
            let copied = plans[i].forks
            plans[i].autoResume = (matches[plans[i].conversation.sessionID] ?? []).map {
                $0.isOpen ? .stillOn(label: $0.label, resetsAt: $0.entry.resetsAt, copied: copied) : .willTurnOff(label: $0.label)
            }
        }
    }

    /// Turns auto-continue off in closed windows for the sessions being continued; for open ones, says so and
    /// remembers to turn it off once that window is closed (`applyPendingAutoResume`).
    func settleAutoResume(_ plans: inout [ContinuePlan], now: Date) {
        guard let destination = plans.first?.destination else { return }
        let matches = autoResumeMatches(for: Set(plans.map(\.conversation.sessionID)), excluding: destination, now: now)
        let autoResume = autoResume
        for i in plans.indices {
            let copied = plans[i].forks
            plans[i].autoResume = (matches[plans[i].conversation.sessionID] ?? []).compactMap { match -> AutoResumeNote? in
                let stillOn = AutoResumeNote.stillOn(label: match.label, resetsAt: match.entry.resetsAt, copied: copied)
                let pending = {
                    do { try autoResume.addPending(match.entry, window: match.window, account: match.account, now: now) } catch {
                        Log.error("continue", "Couldn't record a pending auto-continue turn-off: \(error.localizedDescription)")
                    }
                }
                guard !match.isOpen else {
                    pending()
                    return stillOn
                }
                do {
                    guard try autoResume.turnOff(match.entry, window: match.window, account: match.account, now: now) else { return nil }
                    Log.notice("continue", "Turned off auto-continue for one session in window \(match.window)")
                    return .turnedOff(label: match.label)
                } catch AutoResume.Failure.windowOpen {
                    pending()
                    return stillOn
                } catch {
                    return .couldNotTurnOff(label: match.label, reason: error.localizedDescription, copied: copied)
                }
            }
        }
    }

    /// Turns off the auto-continue entries Baton left on in windows that were open during a Continue, now that
    /// those windows are closed. The app calls it after each look at the windows.
    /// - Returns: the labels ("WORK", "(main)") of the windows where it turned one off.
    @discardableResult
    public func applyPendingAutoResume(now: Date = Date()) -> [String] {
        autoResume.applyPending(now: now).map(displayLabel(of:))
    }
}
