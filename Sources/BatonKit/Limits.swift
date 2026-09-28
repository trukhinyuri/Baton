import Darwin
import Foundation

// MARK: - Samples

/// One plan usage sample Claude Desktop recorded in `plan-usage-history.json`.
public struct UsageSample: Equatable, Sendable {
    public var at: Date
    /// The organization it was taken for, lowercased; `nil` in the file's first format.
    public var org: String?
    public var fiveHour: Int?
    public var week: Int?
    /// Percent of the extra usage allowance used (`xu`); Claude records it only for an account with extra usage.
    public var extraUsage: Int?

    public init(at: Date, org: String? = nil, fiveHour: Int?, week: Int?, extraUsage: Int? = nil) {
        self.at = at; self.org = org; self.fiveHour = fiveHour; self.week = week; self.extraUsage = extraUsage
    }

    public var usage: Usage { Usage(fiveHour: fiveHour, week: week, sampledAt: at) }

    func value(_ kind: LimitKind) -> Int? { kind == .fiveHour ? fiveHour : week }
}

/// Reads `plan-usage-history.json`. Claude writes a sample at most every few minutes per organization while its window
/// runs, and keeps 30 days; it doesn't record when a limit resets.
public enum UsageHistory {
    public static let fileName = "plan-usage-history.json"

    /// Every sample, oldest first. Version 2 keeps the values under `u` with the organization, version 1 beside `t`.
    public static func samples(from data: Data) -> [UsageSample] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let samples = object["samples"] as? [[String: Any]]
        else { return [] }
        return samples.compactMap { sample -> UsageSample? in
            guard let t = number(sample["t"]) else { return nil }
            let values = sample["u"] as? [String: Any] ?? sample
            return UsageSample(
                at: Date(timeIntervalSince1970: t / 1000), org: (sample["org"] as? String)?.lowercased(),
                fiveHour: percent(values["fh"]), week: percent(values["sd"]), extraUsage: percent(values["xu"]))
        }.sorted { $0.at < $1.at }
    }

    /// The samples of the organizations the signed-in account uses in this window, when the file says which
    /// organization each sample is for; every sample when it doesn't, or when the organizations aren't known.
    /// Samples a previously signed-in account left in the file are never taken for this account's.
    public static func current(_ samples: [UsageSample], organizations: Set<String>) -> [UsageSample] {
        let organizations = Set(organizations.map { $0.lowercased() })
        guard !organizations.isEmpty, samples.contains(where: { $0.org != nil }) else { return samples }
        return samples.filter { $0.org.map(organizations.contains) ?? false }
    }

    /// This window's samples for its signed-in account (see `current`), oldest first.
    public static func samples(in dataDir: URL) -> [UsageSample] {
        guard let data = try? Data(contentsOf: dataDir.appending(path: fileName)) else { return [] }
        let all = samples(from: data)
        guard let account = DesktopData.accountID(in: dataDir) else { return all }
        return current(all, organizations: DesktopData.organizationIDs(in: dataDir, accountID: account))
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// Whole percent, rounded down: 99.6 is not yet the limit.
    static func percent(_ value: Any?) -> Int? { number(value).map { Int(min(max($0, 0), 1000).rounded(.down)) } }
}

// MARK: - Limits

/// Claude's two plan limits.
public enum LimitKind: String, Codable, Sendable, CaseIterable {
    case fiveHour = "five_hour"
    case week = "seven_day"

    /// How long one window of this limit lasts.
    public var window: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 86_400 }
    public var name: String { self == .fiveHour ? "5h" : "week" }
}

/// When a limit resets, and how Baton knows.
public struct LimitReset: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// Claude's own reset time for this window: its auto-continue entry, or a limit message in a session this
        /// window ran.
        case exact
        /// An earlier weekly reset time of this window, moved on by whole weeks. Shown as "about"; it never frees
        /// a window.
        case estimate
        /// A later sample of the same organization is lower, so the reset has already happened (at or before `at`).
        case inferred
    }

    public var at: Date
    public var source: Source

    public init(at: Date, source: Source) { self.at = at; self.source = source }
}

/// One limit of one window, from Claude's samples and limit messages.
public struct LimitState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Below the limit by the latest sample.
        case below
        /// At the limit.
        case reached
        /// Was at the limit, and Claude's reset time for it has passed.
        case reset
        /// At the limit in a sample older than the limit's window, with no reset time known.
        case mayHaveReset
    }

    public var kind: LimitKind
    /// The latest sample's percent, or 100 when a limit message came after it.
    public var percent: Int?
    public var sampledAt: Date?
    /// The newest sign that the limit was reached since the last sample below it; `nil` when it wasn't.
    public var reachedAt: Date?
    public var reset: LimitReset?
    /// At 100%, but the account has extra usage left, so work goes on.
    public var extraUsage = false

    /// Claude resumes work 90 seconds after a reset; Baton counts a window free from then too.
    public static let grace: TimeInterval = 90

    public init(kind: LimitKind, percent: Int? = nil, sampledAt: Date? = nil, reachedAt: Date? = nil, reset: LimitReset? = nil, extraUsage: Bool = false) {
        self.kind = kind; self.percent = percent; self.sampledAt = sampledAt; self.reachedAt = reachedAt
        self.reset = reset; self.extraUsage = extraUsage
    }

    public func phase(now: Date = Date()) -> Phase {
        guard let reachedAt else { return .below }
        if let reset, reset.source == .exact { return now >= reset.at.addingTimeInterval(Self.grace) ? .reset : .reached }
        return now.timeIntervalSince(reachedAt) >= kind.window ? .mayHaveReset : .reached
    }

    /// At the limit with no extra usage to go on with.
    public func isBlocking(now: Date = Date()) -> Bool { phase(now: now) == .reached && !extraUsage }

    /// How much of this limit counts against a window when choosing where to continue: a five-hour sample only
    /// within its five hours; a weekly one however old, since a window kept in reserve is sampled only when used.
    func load(now: Date) -> Int? {
        switch phase(now: now) {
        case .reached: return 100
        case .reset: return 0
        case .mayHaveReset: return kind == .fiveHour ? 0 : 100
        case .below:
            guard let percent, let sampledAt else { return nil }
            if kind == .fiveHour && now.timeIntervalSince(sampledAt) > kind.window { return 0 }
            return percent
        }
    }

    static func evaluate(_ kind: LimitKind, samples: [UsageSample], hits: [LimitHit], autoResume: [Date]) -> LimitState {
        let values = samples.compactMap { sample in sample.value(kind).map { (at: sample.at, value: $0, extra: sample.extraUsage) } }
        let latest = values.last
        var state = LimitState(kind: kind, percent: latest?.value, sampledAt: latest?.at)
        let latestAt = latest?.at ?? .distantPast
        let lastBelow = values.last(where: { $0.value < 100 })?.at ?? .distantPast
        // Before the first sample of this organization the window may have been signed in with another account.
        let since = samples.first?.at ?? .distantPast
        let own = hits.filter { $0.kind == kind && $0.resetsAt > $0.at && $0.at >= since }
        // A limit message after the last sample below the limit, or an auto-continue entry whose reset comes after
        // the latest sample: usage only rises within a window, so the limit was reached after that sample.
        let messages = own.filter { $0.at > lastBelow }
        let entries = kind == .fiveHour ? autoResume.filter { $0 > latestAt } : []
        var reachedAt: Date? = (latest?.value ?? 0) >= 100 ? latestAt : nil
        if let newest = messages.map(\.at).max() { reachedAt = max(reachedAt ?? newest, newest) }
        if let entry = entries.max() {
            let since = max(lastBelow, entry.addingTimeInterval(-kind.window))
            reachedAt = max(reachedAt ?? since, since)
        }
        guard let reachedAt else {
            if values.count >= 2, values[values.count - 2].value >= 100, let latest {
                state.reset = LimitReset(at: latest.at, source: .inferred)
            }
            return state
        }
        state.reachedAt = reachedAt
        // Reached after a sample below the limit (a message or an auto-continue entry says so): it stands at 100% now.
        if (latest?.value ?? 0) < 100 { state.percent = 100 }
        // A reset counts only if it comes after the latest sample: a sample at 100% taken after it means the limit
        // was reached again, at a time Claude hasn't said.
        if let exact = (messages.map(\.resetsAt) + entries).filter({ $0 > latestAt }).max() {
            state.reset = LimitReset(at: exact, source: .exact)
        } else if kind == .week,
            let estimate = estimate(anchors: own.map(\.resetsAt), after: reachedAt, drops: drops(in: values.map { ($0.at, $0.value) }))
        {
            state.reset = LimitReset(at: estimate, source: .estimate)
        }
        state.extraUsage = messages.isEmpty && entries.isEmpty && (latest?.extra).map { $0 < 100 } == true
        return state
    }

    /// Where a later sample is at least five points lower than the one before: a reset happened in between.
    static func drops(in values: [(Date, Int)]) -> [(from: Date, to: Date)] {
        zip(values, values.dropFirst()).compactMap { a, b in a.1 - b.1 >= 5 ? (a.0, b.0) : nil }
    }

    /// The first weekly reset after `after`, counted in whole weeks from the newest known one; `nil` when the
    /// history shows a reset at another time of the week, so the schedule has changed.
    static func estimate(anchors: [Date], after: Date, drops: [(from: Date, to: Date)]) -> Date? {
        guard let anchor = anchors.max() else { return nil }
        let week = LimitKind.week.window, slack: TimeInterval = 3600
        for drop in drops {
            let first = ((drop.from.timeIntervalSince(anchor) - slack) / week).rounded(.up)
            if anchor.addingTimeInterval(first * week) > drop.to.addingTimeInterval(slack) { return nil }
        }
        var at = anchor.addingTimeInterval((after.timeIntervalSince(anchor) / week).rounded(.up) * week)
        if at <= after { at = at.addingTimeInterval(week) }
        return at
    }
}

/// A window's five-hour and weekly limits.
public struct Limits: Equatable, Sendable {
    public var fiveHour: LimitState
    public var week: LimitState

    /// - Parameters:
    ///   - samples: the window's samples for its current organization, oldest first (`UsageHistory.samples(in:)`).
    ///   - hits: limit messages from sessions this window ran (`LimitTracker`).
    ///   - autoResume: reset times of this window's auto-continue entries (`AutoResume.entries`).
    public init(samples: [UsageSample], hits: [LimitHit] = [], autoResume: [Date] = []) {
        fiveHour = .evaluate(.fiveHour, samples: samples, hits: hits, autoResume: autoResume)
        week = .evaluate(.week, samples: samples, hits: hits, autoResume: autoResume)
    }

    /// From one sample alone, the way Baton judged limits before it knew reset times.
    public init(usage: Usage?) {
        self.init(samples: usage.map { [UsageSample(at: $0.sampledAt, fiveHour: $0.fiveHour, week: $0.week)] } ?? [])
    }

    public var states: [LimitState] { [fiveHour, week] }

    public func isAtLimit(now: Date = Date()) -> Bool { states.contains { $0.isBlocking(now: now) } }

    /// The limit that holds the window back longest: of those blocking, the one with the later (or unknown) reset.
    public func binding(now: Date = Date()) -> LimitState? {
        states.filter { $0.isBlocking(now: now) }.max { ($0.reset?.at ?? .distantFuture) < ($1.reset?.at ?? .distantFuture) }
    }

    /// The binding limit's load, `max(five-hour while in its window, weekly)`; `nil` without any usage known.
    public func load(now: Date = Date()) -> Int? {
        let loads = states.compactMap { $0.load(now: now) }
        return loads.isEmpty ? nil : loads.max()
    }

    /// The first time after `now` a known reset frees this window: an exact reset plus the grace period.
    public func nextChange(after now: Date) -> Date? {
        states.compactMap { state -> Date? in
            guard state.reachedAt != nil, let reset = state.reset, reset.source == .exact else { return nil }
            let at = reset.at.addingTimeInterval(LimitState.grace)
            return at > now ? at : nil
        }.min()
    }
}

// MARK: - Limit messages in transcripts

/// A request Claude refused at a plan limit, as Claude Code records it in the session's transcript.
public struct LimitHit: Codable, Equatable, Sendable {
    public var kind: LimitKind
    public var at: Date
    public var resetsAt: Date
    public var session: String
    /// `claude-desktop` when a Claude Desktop window ran the session.
    public var entrypoint: String?
    /// Claude Code's version.
    public var version: String?
    public var overageStatus: String?
    public var isUsingOverage = false

    public init(
        kind: LimitKind, at: Date, resetsAt: Date, session: String, entrypoint: String? = "claude-desktop", version: String? = nil,
        overageStatus: String? = "rejected", isUsingOverage: Bool = false
    ) {
        self.kind = kind; self.at = at; self.resetsAt = resetsAt; self.session = session.lowercased(); self.entrypoint = entrypoint
        self.version = version; self.overageStatus = overageStatus; self.isUsingOverage = isUsingOverage
    }

    static let marker = Data(#""quotaLimits""#.utf8)

    /// One transcript line: a hit if Claude refused the request at the five-hour or weekly limit.
    static func parse(line: Data) -> LimitHit? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let quota = object["quotaLimits"] as? [String: Any], quota["status"] as? String == "rejected",
            let kind = (quota["rateLimitType"] as? String).flatMap(LimitKind.init(rawValue:)),
            let resets = UsageHistory.number(quota["resetsAt"]), resets > 0,
            let at = (object["timestamp"] as? String).flatMap(parseTime),
            let session = object["sessionId"] as? String, !session.isEmpty
        else { return nil }
        return LimitHit(
            kind: kind, at: at, resetsAt: Date(timeIntervalSince1970: resets), session: session,
            entrypoint: object["entrypoint"] as? String, version: object["version"] as? String,
            overageStatus: quota["overageStatus"] as? String, isUsingOverage: quota["isUsingOverage"] as? Bool ?? false)
    }

    /// Every hit in `data`, a run of whole or partial JSON lines.
    static func hits(in data: Data) -> [LimitHit] {
        var found: [LimitHit] = []
        var from = data.startIndex
        while let marker = data.range(of: marker, in: from..<data.endIndex) {
            let start = data[..<marker.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[marker.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let hit = parse(line: data[start..<end]) { found.append(hit) }
            from = end
        }
        return found
    }

    static func parseTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Which window ran a session

/// Remembers which window ran which Claude Code session and when, from Claude Code's list of running processes
/// (`~/.claude/sessions/<pid>.json`) and the path of each process, which lies inside the data directory of the window
/// that started it. A limit message in a transcript counts for a window only when exactly one window's process had
/// that session open at the time; anything else is ambiguous and ignored.
public final class LimitTracker: @unchecked Sendable {
    /// One process of one window with one session open.
    public struct Sighting: Codable, Equatable, Sendable {
        public var session: String
        public var window: String
        public var pid: Int32
        public var from: Date
        public var lastSeen: Date
        public var version: String?
        public var cwd: String?

        public init(session: String, window: String, pid: Int32, from: Date, lastSeen: Date, version: String? = nil, cwd: String? = nil) {
            self.session = session.lowercased(); self.window = window; self.pid = pid; self.from = from; self.lastSeen = lastSeen
            self.version = version; self.cwd = cwd
        }

        var key: String { "\(pid)|\(session)|\(Int(from.timeIntervalSince1970))" }
    }

    /// A running Claude Code process: its registry entry and the path of its executable.
    public struct LiveProcess: Equatable, Sendable {
        public var pid: Int32
        public var session: String
        public var startedAt: Date
        public var version: String?
        public var cwd: String?
        public var hostSessionID: String?
        public var executable: String

        public init(pid: Int32, session: String, startedAt: Date, version: String?, cwd: String?, hostSessionID: String?, executable: String) {
            self.pid = pid; self.session = session.lowercased(); self.startedAt = startedAt; self.version = version; self.cwd = cwd
            self.hostSessionID = hostSessionID; self.executable = executable
        }
    }

    struct Store: Codable {
        var version = 1
        var sightings: [Sighting] = []
    }

    struct Scan {
        var size: UInt64
        var modified: Date
        var offset: UInt64
        var hits: [LimitHit]
    }

    /// Only transcripts written in this long, and only sightings seen this recently, count.
    public static let horizon: TimeInterval = 8 * 86_400
    /// How much of the end of a transcript is read.
    static let tail: UInt64 = 1 << 20
    /// A message written this long after the last sighting still counts for the process sighted.
    static let lastSeenGrace: TimeInterval = 60

    private let lock = NSLock()
    private var scans: [String: Scan] = [:]
    private var saved: [String: Date] = [:]
    private var index: (built: Date, files: [String: URL])?
    /// The running Claude Code processes; replaced in tests.
    var liveProcesses: @Sendable (URL) -> [LiveProcess] = { LimitTracker.liveProcesses(claudeDir: $0) }

    public init() {}

    static func file(_ paths: Paths) -> URL { paths.stateDir.appending(path: "limit-sightings.json") }

    /// Records every running process of a window and returns the sightings of the last eight days, newest last.
    @discardableResult
    public func observe(paths: Paths, windows: [(id: String, dataDir: URL)], now: Date = Date()) -> [Sighting] {
        let live = liveProcesses(paths.claudeDir)
        return lock.withLock {
            var store = load(paths)
            let cutoff = now.addingTimeInterval(-Self.horizon)
            store.sightings.removeAll { $0.lastSeen < cutoff }
            var changed = false
            for process in live {
                guard let window = Self.window(of: process.executable, in: windows) else { continue }
                var sighting = Sighting(
                    session: process.session, window: window, pid: process.pid, from: process.startedAt, lastSeen: now,
                    version: process.version, cwd: process.cwd)
                if let i = store.sightings.firstIndex(where: { $0.key == sighting.key }) {
                    sighting.lastSeen = max(store.sightings[i].lastSeen, now)
                    store.sightings[i] = sighting
                    if sighting.lastSeen.timeIntervalSince(saved[sighting.key] ?? .distantPast) > 60 { changed = true }
                } else {
                    store.sightings.append(sighting)
                    changed = true
                }
            }
            if changed { save(store, paths) }
            return store.sightings.sorted { $0.lastSeen < $1.lastSeen }
        }
    }

    /// The window that last ran each session, by the newest sighting.
    public func lastWindows(paths: Paths, windows: [(id: String, dataDir: URL)], now: Date = Date()) -> [String: String] {
        observe(paths: paths, windows: windows, now: now).reduce(into: [:]) { $0[$1.session] = $1.window }
    }

    /// The windows whose running processes have each session open now.
    public func liveWindows(paths: Paths, windows: [(id: String, dataDir: URL)]) -> [String: Set<String>] {
        liveProcesses(paths.claudeDir).reduce(into: [:]) { result, process in
            if let window = Self.window(of: process.executable, in: windows) { result[process.session, default: []].insert(window) }
        }
    }

    /// Limit messages each window's sessions got, by window id.
    public func hits(paths: Paths, windows: [(id: String, dataDir: URL)], now: Date = Date()) -> [String: [LimitHit]] {
        let sightings = observe(paths: paths, windows: windows, now: now)
        var all: [LimitHit] = []
        var located: [String: URL] = [:]
        for sighting in sightings where located[sighting.session] == nil {
            if let url = transcript(of: sighting, paths: paths, now: now) { located[sighting.session] = url }
        }
        for (session, url) in located {
            guard (SyncFolders.modificationDate(url) ?? .distantPast) >= now.addingTimeInterval(-Self.horizon) else { continue }
            all += scan(url).filter { $0.session == session }
        }
        return Self.attribute(all, to: sightings)
    }

    /// Each hit goes to the one window whose process had its session open at the time; a hit that no window's
    /// process covers, or that two windows' processes cover, is left out.
    static func attribute(_ hits: [LimitHit], to sightings: [Sighting]) -> [String: [LimitHit]] {
        var result: [String: [LimitHit]] = [:]
        for hit in hits where hit.entrypoint == "claude-desktop" {
            let windows = Set(
                sightings.filter {
                    $0.session == hit.session && hit.at >= $0.from && hit.at <= $0.lastSeen.addingTimeInterval(lastSeenGrace)
                        && ($0.version == nil || hit.version == nil || $0.version == hit.version)
                }.map(\.window))
            guard windows.count == 1, let window = windows.first else { continue }
            result[window, default: []].append(hit)
        }
        return result
    }

    /// `<dataDir>/claude-code/<version>/claude.app/…` belongs to that window.
    static func window(of executable: String, in windows: [(id: String, dataDir: URL)]) -> String? {
        let path = URL(fileURLWithPath: executable).standardizedFileURL.path
        return windows.first { window in
            [window.dataDir.standardizedFileURL.path, window.dataDir.resolvingSymlinksInPath().path].contains { path.hasPrefix($0 + "/claude-code/") }
        }?.id
    }

    // MARK: Transcripts

    private func transcript(of sighting: Sighting, paths: Paths, now: Date) -> URL? {
        if let cwd = sighting.cwd {
            let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let url = paths.claudeProjectsDir.appending(path: "\(folder)/\(sighting.session).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let files: [String: URL] = lock.withLock {
            if let index, now.timeIntervalSince(index.built) < 60 { return index.files }
            let files = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
            index = (now, files)
            return files
        }
        return files[sighting.session]
    }

    /// The hits in the last `tail` bytes of a transcript; a file that only grew is read from where the last read ended.
    func scan(_ url: URL) -> [LimitHit] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value, let modified = attributes[.modificationDate] as? Date
        else { return [] }
        let cached = lock.withLock { scans[url.path] }
        if let cached, cached.size == size, cached.modified == modified { return cached.hits }
        var start = size > Self.tail ? size - Self.tail : 0
        var hits: [LimitHit] = []
        if let cached, size > cached.size, size - cached.offset <= Self.tail {
            start = cached.offset
            hits = cached.hits
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        // Only whole lines: the rest is read again next time.
        let whole = data.lastIndex(of: 0x0A).map { data[..<($0 + 1)] } ?? Data()
        hits += LimitHit.hits(in: whole)
        let scan = Scan(size: size, modified: modified, offset: start + UInt64(whole.count), hits: hits)
        lock.withLock { scans[url.path] = scan }
        return hits
    }

    // MARK: Store

    private func load(_ paths: Paths) -> Store {
        guard let data = try? Data(contentsOf: Self.file(paths)), let store = try? JSONDecoder.sightings.decode(Store.self, from: data), store.version == 1
        else { return Store() }
        return store
    }

    private func save(_ store: Store, _ paths: Paths) {
        guard (try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)) != nil,
            let data = try? JSONEncoder.sightings.encode(store), (try? data.write(to: Self.file(paths), options: .atomic)) != nil
        else { return }
        saved = Dictionary(store.sightings.map { ($0.key, $0.lastSeen) }, uniquingKeysWith: max)
    }

    // MARK: Processes

    /// Running Claude Code processes from `<claudeDir>/sessions/<pid>.json`, with the path of each executable.
    static func liveProcesses(claudeDir: URL) -> [LiveProcess] {
        let folder = claudeDir.appending(path: "sessions", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name in
            guard name.hasSuffix(".json"), let pid = pid_t(name.dropLast(".json".count)), pid > 0, LiveSessions.isClaude(pid),
                let data = try? Data(contentsOf: folder.appending(path: name)),
                let executable = executablePath(pid)
            else { return nil }
            return liveProcess(registry: data, pid: pid, executable: executable)
        }
    }

    /// One registry entry, if it names this process and a session.
    static func liveProcess(registry data: Data, pid: pid_t, executable: String) -> LiveProcess? {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (record["pid"] as? Int).map({ $0 == Int(pid) }) ?? true,
            let session = record["sessionId"] as? String, !session.isEmpty,
            let started = UsageHistory.number(record["startedAt"])
        else { return nil }
        return LiveProcess(
            pid: pid, session: session, startedAt: Date(timeIntervalSince1970: started / 1000), version: record["version"] as? String,
            cwd: record["cwd"] as? String, hostSessionID: record["hostSessionId"] as? String, executable: executable)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension JSONEncoder {
    fileprivate static var sightings: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var sightings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Text

/// How limits read in the window list, the Continue sheet, the menu and `baton list`.
public enum LimitText {
    /// "02:10" within 20 hours of `now`, "Wed 05:00" further away.
    public static func time(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = abs(date.timeIntervalSince(now)) < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// "resets 02:10", "resets about Wed 05:00", "may have reset about Wed 05:00"; `nil` without a reset time.
    public static func reset(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let reset = state.reset, reset.source != .inferred else { return nil }
        let when = time(reset.at, now: now, timeZone: timeZone)
        if reset.source == .exact { return "resets \(when)" }
        return reset.at > now ? "resets about \(when)" : "may have reset about \(when)"
    }

    /// "5h 40%", "5h 100% · resets 02:10", "week 100% · resets about Wed 05:00", "5h reset at 02:10",
    /// "week 100%, may have reset", "week 100%, extra usage available".
    public static func describe(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let name = state.kind.name
        switch state.phase(now: now) {
        case .below:
            guard let percent = state.percent else { return "\(name) ?" }
            if state.kind == .fiveHour, let at = state.sampledAt, now.timeIntervalSince(at) > state.kind.window { return "\(name) reset" }
            return "\(name) \(percent)%"
        case .reached:
            let base = "\(name) \(state.percent ?? 100)%"
            if state.extraUsage { return base + ", extra usage available" }
            return reset(state, now: now, timeZone: timeZone).map { "\(base) · \($0)" } ?? base
        case .reset:
            return "\(name) reset at \(time(state.reset?.at ?? now, now: now, timeZone: timeZone))"
        case .mayHaveReset:
            return "\(name) \(state.percent ?? 100)%, may have reset"
        }
    }

    /// A short note for the window list beside the meters: "5h resets 02:10", "week resets about Wed 05:00",
    /// "5h reset at 02:10", "week may have reset", "week at 100%, extra usage available"; `nil` below the limit.
    public static func note(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let name = state.kind.name
        switch state.phase(now: now) {
        case .below: return nil
        case .reached:
            if state.extraUsage { return "\(name) at 100%, extra usage available" }
            return reset(state, now: now, timeZone: timeZone).map { "\(name) \($0)" }
        case .reset: return describe(state, now: now, timeZone: timeZone)
        case .mayHaveReset: return "\(name) may have reset"
        }
    }

    /// The whole line for `baton list`: "5h 100% · resets 02:10 · week 62% · as of 3m ago".
    public static func summary(_ limits: Limits, usage: Usage?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard usage != nil || limits.states.contains(where: { $0.reachedAt != nil }) else { return "usage unknown" }
        var line = limits.states.map { describe($0, now: now, timeZone: timeZone) }.joined(separator: " · ")
        if let usage {
            line += " · as of \(relativeAge(since: usage.sampledAt, now: now))"
            if !usage.isFresh(now: now), limits.states.allSatisfy({ $0.phase(now: now) == .below }) { line += " (stale: may be higher now)" }
        }
        return line
    }

    /// For a window at its limit: "resets 02:10" or "resets about Wed 05:00", by the limit that holds it back
    /// longest; `nil` when that reset isn't known.
    public static func bindingReset(_ limits: Limits, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        limits.binding(now: now).flatMap { reset($0, now: now, timeZone: timeZone) }
    }
}

// MARK: - Scheduling

/// When the app looks at limits again, and which windows a reset has just freed.
public enum LimitSchedule {
    /// The earliest known reset (plus the grace period) still ahead among `statuses`.
    public static func nextRefresh(_ statuses: [ProfileStatus], now: Date = Date()) -> Date? {
        statuses.compactMap { $0.limits.nextChange(after: now) }.min()
    }

    /// Windows blocked at the previous check that a known reset has freed: an exact reset time passing, or a newer
    /// sample below the limit. A sample simply growing old, or extra usage taking over, isn't announced.
    public static func freed(blockedBefore: Set<String>, _ statuses: [ProfileStatus], now: Date = Date()) -> [ProfileStatus] {
        statuses.filter { status in
            guard blockedBefore.contains(status.id), status.isSignedIn else { return false }
            return status.limits.states.allSatisfy { [.below, .reset].contains($0.phase(now: now)) }
        }
    }

    /// The windows blocked at a limit now, to compare with at the next check.
    public static func blocked(_ statuses: [ProfileStatus], now: Date = Date()) -> Set<String> {
        Set(statuses.filter { $0.isSignedIn && $0.limits.isAtLimit(now: now) }.map(\.id))
    }

    /// "Claude WORK has room again", or "Claude has room again" for the main window.
    public static func roomAgain(_ status: ProfileStatus) -> String {
        "\(status.isMain ? "Claude" : "Claude \(status.label)") has room again"
    }
}
