import Foundation

/// Local only: a window's new Claude Code sessions stay on this Mac instead of being offered to Remote Control.
///
/// It sets two of Claude Desktop's own preferences in that window's `claude_desktop_config.json` to `false`, the
/// way the switches in Claude's settings do, and only while the window is closed: Claude writes that file back
/// when it quits. Every write starts with a dated backup and a record of the values it replaces, changes only
/// those values and leaves every other byte of the file as it was, and is read back afterwards. Turning Local only
/// off puts the recorded values back where they are still the ones Local only set.
///
/// Scheduled tasks, waking the Mac for them, managed preferences and Claude Code's transcripts are never touched.
public struct LocalOnly: Sendable {
    public enum Status: String, Codable, Sendable {
        /// The window's Remote Control switches are off.
        case on
        /// Local only is off and nothing it changed waits to be put back.
        case off
        /// Waiting for the window to close, to apply the choice or to put earlier values back.
        case pending
        /// This Claude Desktop doesn't have the Remote Control preference, so nothing is written.
        case notSupported = "not-supported"
    }

    struct Key: Sendable {
        let name: String
        /// Added when the window's settings don't have it yet; the others change only where Claude wrote them.
        let required: Bool
    }

    /// "Remote Control for new sessions" and "Stay reachable".
    static let keys = [
        Key(name: "ccRemoteControlDefaultEnabled", required: true),
        Key(name: "remoteControlStayReachable", required: false),
    ]
    public static let ownedKeys: Set<String> = Set(keys.map(\.name))
    /// Preferences Local only must never write: local scheduled tasks and their wake helper, and the switches
    /// an administrator sets through managed preferences.
    public static let neverTouched: Set<String> = [
        "ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled", "wakeSchedulerEnabled",
        "isClaudeCodeForDesktopEnabled", "disableMultiAccount", "chatTabEnabled", "isDesktopExtensionEnabled",
        "isLocalDevMcpEnabled", "secureVmFeaturesEnabled",
    ]
    static let value = "false"
    static let configName = "claude_desktop_config.json"

    public let paths: Paths
    let isRunning: @Sendable (String) -> Bool

    /// - Parameter isRunning: whether the window of `"main"` or a profile id is running. A window whose Local
    ///   Storage is held by a process counts as running too.
    public init(paths: Paths, isRunning: @escaping @Sendable (String) -> Bool) {
        self.paths = paths
        self.isRunning = isRunning
    }

    // MARK: - Choices

    /// Whether Local only is on for `window`: its own choice, or the choice for every window. On by default.
    public func isEnabled(window: String) -> Bool {
        let state = readState()
        return state.windows[window]?.enabled ?? state.enabled
    }

    /// Turns Local only on for `window` and applies it now if the window is closed.
    @discardableResult
    public func apply(window: String) throws -> Status {
        try locked { state in
            state.windows[window, default: WindowState()].enabled = true
            return try reconcile(window, state: &state)
        }
    }

    /// Turns Local only off for `window` and puts its earlier values back now if the window is closed.
    @discardableResult
    public func disable(window: String) throws -> Status {
        try locked { state in
            state.windows[window, default: WindowState()].enabled = false
            return try reconcile(window, state: &state)
        }
    }

    /// Sets the choice for one window, or with `window` nil for every window that has no choice of its own,
    /// and applies it to each of `windows` that is closed.
    /// - Returns: the status of every window the call applied to.
    @discardableResult
    public func setEnabled(_ enabled: Bool, window: String?, windows: [String]) throws -> [String: Status] {
        if let window { return [window: enabled ? try apply(window: window) : try disable(window: window)] }
        return try locked { state in
            state.enabled = enabled
            var result: [String: Status] = [:]
            for window in windows { result[window] = try reconcile(window, state: &state) }
            return result
        }
    }

    /// Brings a closed window in line with its choice; call it before every cold start of that window.
    @discardableResult
    public func reconcile(window: String) throws -> Status {
        try locked { state in try reconcile(window, state: &state) }
    }

    /// What Local only is doing in `window` right now. Reads only.
    public func status(window: String) -> Status { status(window: window, state: readState()) }

    // MARK: - Claude Desktop support

    /// The owned preferences the installed Claude Desktop doesn't mention, or nil if its app can't be read.
    public static func missingKeys(in claudeApp: URL) -> [String]? {
        guard let known = SupportCache.shared.knownKeys(in: claudeApp) else { return nil }
        return keys.map(\.name).filter { !known.contains($0) }
    }

    /// The keys to write in this Claude Desktop, or nil if it lacks the main one.
    private func applicableKeys() -> [Key]? {
        guard let missing = Self.missingKeys(in: paths.claudeApp) else { return nil }
        guard !Self.keys.contains(where: { $0.required && missing.contains($0.name) }) else { return nil }
        return Self.keys.filter { !missing.contains($0.name) }
    }

    // MARK: - Applying

    private func reconcile(_ window: String, state: inout State) throws -> Status {
        let wanted = state.windows[window]?.enabled ?? state.enabled
        if wanted {
            guard let applicable = applicableKeys() else { return .notSupported }
            guard !running(window) else { return .pending }
            try turnOff(applicable, in: window, state: &state)
        } else {
            guard !(state.windows[window]?.isEmpty ?? true) else { return .off }
            guard !running(window) else { return .pending }
            try restore(window, state: &state)
        }
        return status(window: window, state: state)
    }

    private func status(window: String, state: State) -> Status {
        let own = state.windows[window] ?? WindowState()
        guard own.enabled ?? state.enabled else { return own.isEmpty ? .off : .pending }
        guard let applicable = applicableKeys() else { return .notSupported }
        guard let data = try? Data(contentsOf: config(window)), let patch = try? JSONPatch(data),
            let prefs = try? patch.preferences()
        else { return .pending }
        for key in applicable {
            if let member = prefs.members.first(where: { $0.key == key.name }) {
                if patch.text(member) != Self.value { return .pending }
            } else if key.required {
                return .pending
            }
        }
        return .on
    }

    private func turnOff(_ applicable: [Key], in window: String, state: inout State) throws {
        let url = config(window)
        let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var patch = try JSONPatch(original ?? Data("{}".utf8))
        var own = state.windows[window] ?? WindowState()
        var expected = try patch.dictionary()
        var expectedPrefs = expected["preferences"] as? [String: Any] ?? [:]

        for key in applicable {
            let prefs = try patch.preferences()
            if let member = prefs?.members.first(where: { $0.key == key.name }) {
                let text = patch.text(member)
                guard text != Self.value else { continue }
                if own.prior[key.name] == nil && !own.inserted.contains(key.name) { own.prior[key.name] = text }
                patch.replace(member, with: Self.value)
            } else if key.required {
                if prefs == nil {
                    try patch.insertPreferences(key: key.name, value: Self.value)
                    own.createdPreferences = true
                } else {
                    try patch.insertFirst(key: key.name, value: Self.value, inPreferences: true)
                }
                if own.prior[key.name] == nil && !own.inserted.contains(key.name) { own.inserted.append(key.name) }
            } else {
                continue
            }
            expectedPrefs[key.name] = false
        }
        guard patch.bytes != original.map(Array.init) else { return }
        expected["preferences"] = expectedPrefs
        own.appliedAt = Date()
        try write(patch, over: original, to: url, window: window, recording: own, state: &state) { written in
            for key in applicable where expectedPrefs[key.name] != nil {
                guard let member = try written.preferences()?.members.first(where: { $0.key == key.name }),
                    written.text(member) == Self.value
                else { return false }
            }
            return NSDictionary(dictionary: try written.dictionary()).isEqual(to: expected)
        }
    }

    private func restore(_ window: String, state: inout State) throws {
        let url = config(window)
        guard FileManager.default.fileExists(atPath: url.path) else {
            state.windows[window]?.clearRecords()
            return
        }
        let original = try Data(contentsOf: url)
        var patch = try JSONPatch(original)
        guard var own = state.windows[window] else { return }
        var expected = try patch.dictionary()
        var expectedPrefs = expected["preferences"] as? [String: Any] ?? [:]

        for (name, prior) in own.prior.sorted(by: { $0.key < $1.key }) {
            // A value turned back on inside Claude while Local only was on is the user's own choice.
            guard let member = try patch.preferences()?.members.first(where: { $0.key == name }),
                patch.text(member) == Self.value
            else { continue }
            patch.replace(member, with: prior)
            expectedPrefs[name] = try JSONSerialization.jsonObject(with: Data(prior.utf8), options: .fragmentsAllowed)
        }
        for name in own.inserted {
            guard let prefs = try patch.preferences(), let index = prefs.members.firstIndex(where: { $0.key == name }),
                patch.text(prefs.members[index]) == Self.value
            else { continue }
            patch.remove(index, in: prefs)
            expectedPrefs.removeValue(forKey: name)
        }
        if own.createdPreferences, let top = try? patch.top(), let index = top.members.firstIndex(where: { $0.key == "preferences" }),
            let prefs = try patch.preferences(), prefs.members.isEmpty
        {
            patch.remove(index, in: top)
            expected.removeValue(forKey: "preferences")
        } else if expected["preferences"] != nil {
            expected["preferences"] = expectedPrefs
        }
        own.clearRecords()
        guard patch.bytes != Array(original) else {
            state.windows[window] = own
            return
        }
        try write(patch, over: original, to: url, window: window, recording: own, state: &state) { written in
            NSDictionary(dictionary: try written.dictionary()).isEqual(to: expected)
        }
    }

    /// Backup, then the record, then the file; read back, and put the original bytes back if it didn't come out as planned.
    private func write(
        _ patch: JSONPatch, over original: Data?, to url: URL, window: String, recording own: WindowState,
        state: inout State, check: (JSONPatch) throws -> Bool
    ) throws {
        // The file itself, not a link to it: a link alone would follow later edits instead of keeping this content.
        if original != nil { _ = try Backup(paths: paths, now: Date()).save(Self.writeTarget(url), everyTime: true) }
        // Record the values being replaced before replacing them: a crash after this still knows what to put back.
        let previous = state.windows[window]
        var recorded = state
        recorded.windows[window] = own.merging(previous)
        try saveState(recorded)
        state = recorded
        guard !running(window) else { return }

        try Self.replace(url, with: Data(patch.bytes))
        let written = try? JSONPatch(Data(contentsOf: url))
        guard let written, (try? check(written)) == true else {
            if let original { try Self.replace(url, with: original) }
            throw LocalStorageError.corrupt("\(Self.configName) of \(window) didn't read back as written; the earlier file was put back")
        }
        state.windows[window] = own
        try saveState(state)
    }

    /// Writes `data` over the file at `url` in one step, keeping that file's permissions (0600 for a new file). A link
    /// stays a link: the file it leads to is written, so settings kept elsewhere, such as in a dotfiles folder linked
    /// into place, keep receiving the change, and the link's own permissions are never copied onto them.
    static func replace(_ url: URL, with data: Data) throws {
        let fm = FileManager.default
        let target = writeTarget(url)
        let permissions = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }

    /// The file a write to `url` changes: `url` itself, or the file a link at `url` leads to, link by link.
    static func writeTarget(_ url: URL) -> URL {
        var target = url.standardizedFileURL
        // A loop of links stops here and then fails to be written, as it would without Baton.
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { break }
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).absoluteURL.standardizedFileURL
        }
        return target
    }

    private func running(_ window: String) -> Bool {
        isRunning(window) || LocalStorage(dataDir: dataDir(window)).isInUse
    }

    private func dataDir(_ window: String) -> URL {
        window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
    }

    private func config(_ window: String) -> URL { dataDir(window).appending(path: Self.configName) }

    // MARK: - Record

    struct WindowState: Codable, Equatable, Sendable {
        var enabled: Bool?
        /// The raw JSON text each replaced value had, to put back byte for byte.
        var prior: [String: String] = [:]
        /// Keys Local only added.
        var inserted: [String] = []
        /// Whether Local only added the `preferences` object itself.
        var createdPreferences = false
        var appliedAt: Date?

        var isEmpty: Bool { prior.isEmpty && inserted.isEmpty && !createdPreferences }
        mutating func clearRecords() { prior = [:]; inserted = []; createdPreferences = false; appliedAt = nil }

        /// Keeps an earlier record where this one would forget it, until the write it describes has happened.
        func merging(_ earlier: WindowState?) -> WindowState {
            guard let earlier else { return self }
            var result = self
            result.prior.merge(earlier.prior) { new, _ in new }
            result.inserted = Array(Set(inserted).union(earlier.inserted)).sorted()
            result.createdPreferences = createdPreferences || earlier.createdPreferences
            return result
        }
    }

    struct State: Codable, Equatable, Sendable {
        var version = 1
        var enabled = true
        var windows: [String: WindowState] = [:]
    }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: paths.localOnlyFile),
            let state = try? JSONDecoder.localOnly.decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try JSONEncoder.localOnly.encode(state).write(to: paths.localOnlyFile, options: .atomic)
    }

    /// Under `open.lock` as well: the open-time merges and Baton's auto-continue change write the same settings file
    /// from their own reads, and hold that lock while they do.
    private func locked<T>(_ body: (inout State) throws -> T) throws -> T {
        let result: T?? = try FileLock.withLock(paths.stateDir.appending(path: "open.lock"), blocking: true) {
            try FileLock.withLock(paths.stateDir.appending(path: "local-only.lock"), blocking: true) {
                var state = readState()
                let before = state
                let value = try body(&state)
                if state != before { try saveState(state) }
                return value
            }
        }
        return result!!
    }
}

extension JSONEncoder {
    fileprivate static var localOnly: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var localOnly: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Which preference names an installed Claude Desktop mentions, looked up once per build of its app.
private final class SupportCache: @unchecked Sendable {
    static let shared = SupportCache()
    private let lock = NSLock()
    private var cache: [String: Set<String>] = [:]

    func knownKeys(in claudeApp: URL) -> Set<String>? {
        let asar = claudeApp.appending(path: "Contents/Resources/app.asar")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: asar.path),
            let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let id = "\(asar.path)|\(size)|\(modified.timeIntervalSince1970)"
        if let known = lock.withLock({ cache[id] }) { return known }
        guard let data = try? Data(contentsOf: asar, options: .mappedIfSafe) else { return nil }
        let known = Set(LocalOnly.keys.map(\.name).filter { data.range(of: Data($0.utf8)) != nil })
        lock.withLock { cache[id] = known }
        return known
    }
}

// MARK: - Editing JSON in place

/// Finds members of a JSON object by their byte ranges, so a value can be replaced, added or removed while every
/// other byte of the file stays as it was.
struct JSONPatch {
    var bytes: [UInt8]

    struct Member {
        var key: String
        var keyStart: Int
        var keyEnd: Int
        var valueStart: Int
        var valueEnd: Int
    }

    struct Object {
        var open: Int
        var close: Int
        var members: [Member]
    }

    /// Refuses anything that isn't a JSON object, before any byte is edited.
    init(_ data: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw LocalStorageError.corrupt("\(LocalOnly.configName) must contain a JSON object; it was left as it is")
        }
        bytes = Array(data)
        _ = try top()
    }

    func dictionary() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            throw LocalStorageError.corrupt("\(LocalOnly.configName) must contain a JSON object")
        }
        return object
    }

    func text(_ member: Member) -> String {
        String(decoding: bytes[member.valueStart..<member.valueEnd], as: UTF8.self)
    }

    func top() throws -> Object { try object(at: skipSpace(0)) }

    /// The top-level `preferences` object, nil if there is none.
    func preferences() throws -> Object? {
        guard let member = try top().members.last(where: { $0.key == "preferences" }) else { return nil }
        guard bytes[member.valueStart] == UInt8(ascii: "{") else {
            throw LocalStorageError.corrupt("preferences in \(LocalOnly.configName) must be a JSON object; it was left as it is")
        }
        return try object(at: member.valueStart)
    }

    mutating func replace(_ member: Member, with text: String) {
        bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(text.utf8))
    }

    /// Adds `key` as the first member of `preferences`, spaced like the member that was first.
    mutating func insertFirst(key: String, value: String, inPreferences: Bool) throws {
        guard let object = inPreferences ? try preferences() : try top() else { return }
        insert(key: key, value: value, in: object)
    }

    /// Adds a `preferences` object holding `key` as the first top-level member.
    mutating func insertPreferences(key: String, value: String) throws {
        let top = try top()
        let separator = top.members.first.map { String(decoding: bytes[$0.keyEnd..<$0.valueStart], as: UTF8.self) } ?? ": "
        insert(key: "preferences", value: "{\(Self.quoted(key))\(separator)\(value)}", in: top)
    }

    mutating func insert(key: String, value: String, in object: Object) {
        if let first = object.members.first {
            let lead = Array(bytes[(object.open + 1)..<first.keyStart])
            let separator = Array(bytes[first.keyEnd..<first.valueStart])
            let member = Array(Self.quoted(key).utf8) + separator + Array(value.utf8) + [UInt8(ascii: ",")] + lead
            bytes.insert(contentsOf: member, at: first.keyStart)
        } else {
            bytes.insert(contentsOf: Array("\(Self.quoted(key)): \(value)".utf8), at: object.open + 1)
        }
    }

    /// Removes a member with the comma and spacing that separated it, the reverse of `insert`.
    mutating func remove(_ index: Int, in object: Object) {
        let member = object.members[index]
        if index + 1 < object.members.count {
            bytes.removeSubrange(member.keyStart..<object.members[index + 1].keyStart)
        } else if index > 0 {
            bytes.removeSubrange(object.members[index - 1].valueEnd..<member.valueEnd)
        } else {
            bytes.removeSubrange((object.open + 1)..<object.close)
        }
    }

    private static func quoted(_ key: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
    }

    // MARK: Scanning

    private func skipSpace(_ start: Int) -> Int {
        var i = start
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        return i
    }

    private func expect(_ i: Int, _ character: Unicode.Scalar) throws {
        guard i < bytes.count, bytes[i] == UInt8(ascii: character) else {
            throw LocalStorageError.corrupt("\(LocalOnly.configName) could not be read at byte \(i); it was left as it is")
        }
    }

    private func stringEnd(_ start: Int) throws -> Int {
        try expect(start, "\"")
        var i = start + 1
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return i + 1
            default: i += 1
            }
        }
        throw LocalStorageError.corrupt("\(LocalOnly.configName) has an unfinished string; it was left as it is")
    }

    private func valueEnd(_ start: Int) throws -> Int {
        guard start < bytes.count else { throw LocalStorageError.corrupt("\(LocalOnly.configName) ends early") }
        switch bytes[start] {
        case UInt8(ascii: "\""): return try stringEnd(start)
        case UInt8(ascii: "{"): return try object(at: start).close + 1
        case UInt8(ascii: "["):
            var i = skipSpace(start + 1)
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { return i + 1 }
            while true {
                i = skipSpace(try valueEnd(skipSpace(i)))
                guard i < bytes.count else { break }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                try expect(i, "]")
                return i + 1
            }
            throw LocalStorageError.corrupt("\(LocalOnly.configName) has an unfinished list")
        default:
            var i = start
            while i < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[i]) { i += 1 }
            return i
        }
    }

    func object(at open: Int) throws -> Object {
        try expect(open, "{")
        var members: [Member] = []
        var i = skipSpace(open + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { return Object(open: open, close: i, members: []) }
        while true {
            let keyStart = i, keyEnd = try stringEnd(i)
            let key = (try? JSONSerialization.jsonObject(with: Data(bytes[keyStart..<keyEnd]), options: .fragmentsAllowed)) as? String ?? ""
            i = skipSpace(keyEnd)
            try expect(i, ":")
            let valueStart = skipSpace(i + 1)
            let valueEnd = try valueEnd(valueStart)
            members.append(Member(key: key, keyStart: keyStart, keyEnd: keyEnd, valueStart: valueStart, valueEnd: valueEnd))
            i = skipSpace(valueEnd)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = skipSpace(i + 1); continue }
            try expect(i, "}")
            return Object(open: open, close: i, members: members)
        }
    }
}
