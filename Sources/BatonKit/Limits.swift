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
    /// organization each sample is for; every sample when it doesn't. With no organization of the account known,
    /// those of the organization Claude sampled last, leaving out `otherAccounts`' organizations: Claude samples the
    /// signed-in account's usage about 9 s after its window starts, so a previous account's samples are the newest
    /// only until then.
    public static func current(_ samples: [UsageSample], organizations: Set<String>, otherAccounts: Set<String> = []) -> [UsageSample] {
        let organizations = Set(organizations.map { $0.lowercased() })
        guard samples.contains(where: { $0.org != nil }) else { return samples }
        guard organizations.isEmpty else { return samples.filter { $0.org.map(organizations.contains) ?? false } }
        let others = Set(otherAccounts.map { $0.lowercased() })
        guard let newest = samples.last(where: { $0.org.map { !others.contains($0) } ?? false })?.org else { return [] }
        return samples.filter { $0.org == newest }
    }

    /// This window's samples for its signed-in account, oldest first: those of the organization Claude shows now
    /// (`DesktopData.scope`); of every organization folder the account has when Claude hasn't said which; and with
    /// no organization folder yet, those of the organization sampled last that no other account's folders in this
    /// window name. (`config.json` changes whenever Claude refreshes its sign-in or quits, so its date can't say when
    /// the account signed in.)
    public static func samples(in dataDir: URL) -> [UsageSample] {
        guard let data = try? Data(contentsOf: dataDir.appending(path: fileName)) else { return [] }
        let all = samples(from: data)
        guard let account = DesktopData.accountID(in: dataDir) else { return all }
        var organizations = DesktopData.organizationIDs(in: dataDir, accountID: account)
        if organizations.count > 1 {
            let items = (try? LocalStorage(dataDir: dataDir).items(origin: InterfaceSync.origin)) ?? [:]
            if let scope = DesktopData.scope(dataDir: dataDir, items: items)?.value, scope.hasPrefix(account + "/") {
                organizations = [String(scope.dropFirst(account.count + 1))]
            }
        }
        let others = organizations.isEmpty ? DesktopData.organizationIDs(in: dataDir, otherThan: account) : []
        return current(all, organizations: organizations, otherAccounts: others)
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
    /// Reached by a sample alone: no limit message or auto-continue entry says so, so no reset time is known.
    public var sampleOnly = false
    /// Below the limit because Claude answered, in one of the window's sessions, a request sent after the limit was
    /// reached; the latest sample still reads what it read before (`reset` is `.inferred`, at that reply). Claude
    /// answering shows the limit no longer binds, but not why: it may have reset, or extra usage may be paying for it.
    public var resetByAnswer = false

    /// Claude resumes work 90 seconds after a reset; Baton counts a window free from then too.
    public static let grace: TimeInterval = 90
    /// A reply counts as a sign of room only for a request sent at least this long after the newest sign of the limit:
    /// a request Claude admitted before the limit keeps streaming for a while, and so may one sent in the seconds
    /// after it (28.09: a sample at 100% at 20:04:41, another session refused at 20:04:43.8, and this one's replies at
    /// 20:04:48.5 and 20:04:49.6, asked for at 20:04:38.4, then its own refusal at 20:04:50.1).
    public static let answerMargin: TimeInterval = 60

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

    /// How much of this limit counts against a window when choosing where to continue: a sample only within its
    /// limit's own window (five hours, or a week), since after that the window has certainly reset. Within the week a
    /// weekly sample counts however old: a window kept in reserve is sampled only when used.
    func load(now: Date) -> Int? {
        switch phase(now: now) {
        case .reached: return 100
        case .reset, .mayHaveReset: return 0
        case .below:
            guard let percent, let sampledAt else { return nil }
            if resetByAnswer || now.timeIntervalSince(sampledAt) > kind.window { return 0 }
            return percent
        }
    }

    /// - Parameters:
    ///   - answeredAt: the newest reply Claude gave in a session this window ran (`LimitTracker`).
    ///   - askedAt: the newest time a request was sent that Claude then answered, in such a session.
    static func evaluate(
        _ kind: LimitKind, samples: [UsageSample], hits: [LimitHit], autoResume: [Date], answeredAt: Date? = nil, askedAt: Date? = nil
    ) -> LimitState {
        let values = samples.compactMap { sample in sample.value(kind).map { (at: sample.at, value: $0, extra: sample.extraUsage) } }
        let latest = values.last
        var state = LimitState(kind: kind, percent: latest?.value, sampledAt: latest?.at)
        let latestAt = latest?.at ?? .distantPast
        let lastBelow = values.last(where: { $0.value < 100 })?.at ?? .distantPast
        // Before the first sample of this organization the window may have been signed in with another account.
        let since = samples.first?.at ?? .distantPast
        let own = hits.filter { $0.kind == kind && $0.resetsAt > $0.at && $0.at >= since }
        // A limit message after the last sample below the limit, or an auto-continue entry whose reset comes after
        // the latest sample: usage only rises within a window, so the limit was reached after that sample. An entry
        // whose own window shows a drop was reset early, so it no longer says anything.
        let messages = own.filter { $0.at > lastBelow }
        let entries = kind == .fiveHour ? autoResume.filter { $0 > latestAt && !resetEarly(values.map { ($0.at, $0.value) }, entry: $0) } : []
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
        // Extra usage: from the newest sample that records it, within two hours of the latest and taken at 100%
        // (not before the limit was reached). Claude writes `xu` only on its full polls, about once an hour, and
        // doesn't record whether extra usage is turned on, so this is a best guess, not checked against real data.
        let reachedFrom = values.first { $0.at > lastBelow && $0.value >= 100 }?.at ?? .distantFuture
        let extra = values.last { $0.extra != nil && $0.at >= latestAt.addingTimeInterval(-2 * 3600) && $0.at >= reachedFrom }?.extra
        let extraUsage = messages.isEmpty && entries.isEmpty && extra.map { $0 < 100 } == true
        // Claude answered, in a session this window ran, a request sent well after the newest sign of this reach of
        // the limit, a sample at 100% or a limit message, both after the last sample below it: nothing was binding
        // then. Seen, not estimated. A reply to a request sent before that, or only just after it, was admitted
        // before the limit and may still be streaming (`answerMargin`). An auto-continue entry alone doesn't say
        // when Claude refused, so a reply proves nothing then, and neither does an older reach's sample or message.
        let evidence = [values.last { $0.value >= 100 && $0.at > lastBelow }?.at, messages.map(\.at).max()].compactMap { $0 }.max()
        if !extraUsage, let answeredAt, let askedAt, let evidence, askedAt > reachedAt, askedAt >= evidence.addingTimeInterval(answerMargin) {
            state.reset = LimitReset(at: answeredAt, source: .inferred)
            state.resetByAnswer = true
            return state
        }
        state.reachedAt = reachedAt
        state.sampleOnly = messages.isEmpty && entries.isEmpty
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
        state.extraUsage = extraUsage
        return state
    }

    /// Whether the samples show a reset inside the five-hour window an auto-continue entry belongs to: a sample at
    /// least five points below the one before it, taken at least ten minutes into that window and before its reset,
    /// where the one before was taken ten minutes in too, or reads 100% at least `previousWindowLag` in (the limit
    /// reached inside the window, then reset). Right after a window starts Claude may still report the previous
    /// window's value (28.09: 91% at 21:11:50 in a window from 21:10), so a drop from an earlier sample is that
    /// window ending, not an early reset.
    static func resetEarly(_ values: [(Date, Int)], entry resetsAt: Date) -> Bool {
        let start = resetsAt.addingTimeInterval(-LimitKind.fiveHour.window)
        let settled = start.addingTimeInterval(600), reached = start.addingTimeInterval(previousWindowLag)
        return zip(values, values.dropFirst()).contains { before, after in
            before.1 - after.1 >= 5 && after.0 >= settled && after.0 < resetsAt && (before.0 >= settled || before.1 >= 100 && before.0 >= reached)
        }
    }

    /// How long into a five-hour window a sample may still read the previous window's value: the one seen lagged
    /// under two minutes.
    static let previousWindowLag: TimeInterval = 300

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
    ///   - answeredAt: the newest reply Claude gave in a session this window ran (`LimitTracker`).
    ///   - askedAt: the newest time a request was sent in such a session that Claude then answered; a reply counts
    ///     only through it.
    public init(samples: [UsageSample], hits: [LimitHit] = [], autoResume: [Date] = [], answeredAt: Date? = nil, askedAt: Date? = nil) {
        fiveHour = .evaluate(.fiveHour, samples: samples, hits: hits, autoResume: autoResume, answeredAt: answeredAt, askedAt: askedAt)
        week = .evaluate(.week, samples: samples, hits: hits, autoResume: autoResume, answeredAt: answeredAt, askedAt: askedAt)
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
            if let hit = autoreleasepool(invoking: { parse(line: data[start..<end]) }) { found.append(hit) }
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

/// A reply Claude gave in a session: an assistant record with a request id that isn't an error and isn't one Claude
/// Code wrote itself (`<synthetic>`). One to a request sent well after the newest sign of a limit shows that the limit
/// had been reset.
public struct LimitAnswer: Equatable, Sendable {
    public var at: Date
    /// When Claude was asked for it, at the latest: the time of the record the reply follows once its own request's
    /// records are passed (the prompt or tool result, or what Claude Code attached to it), written before the request
    /// went out. `nil` when that record isn't in the part of the transcript read.
    public var askedAt: Date?
    public var session: String
    public var entrypoint: String?
    public var version: String?
    /// Its request (`requestId`) and the record it follows (`parentUuid`).
    var request: String?
    var parent: String?

    public init(at: Date, askedAt: Date? = nil, session: String, entrypoint: String? = "claude-desktop", version: String? = nil) {
        self.at = at; self.askedAt = askedAt; self.session = session.lowercased(); self.entrypoint = entrypoint; self.version = version
    }

    static let marker = Data(#""type":"assistant""#.utf8)
    static let requestKey = Data(#""requestId""#.utf8)

    /// One transcript line, if it is such a reply.
    static func parse(line: Data) -> LimitAnswer? {
        guard line.range(of: marker) != nil, line.range(of: requestKey) != nil,
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            object["type"] as? String == "assistant", object["isApiErrorMessage"] as? Bool != true,
            let request = object["requestId"] as? String, !request.isEmpty,
            (object["message"] as? [String: Any])?["model"] as? String != "<synthetic>",
            let at = (object["timestamp"] as? String).flatMap(LimitHit.parseTime),
            let session = object["sessionId"] as? String, !session.isEmpty
        else { return nil }
        var answer = LimitAnswer(at: at, session: session, entrypoint: object["entrypoint"] as? String, version: object["version"] as? String)
        answer.request = request
        answer.parent = object["parentUuid"] as? String
        return answer
    }

    /// The last reply in `data`, a run of whole JSON lines, read from the end, with the time Claude was asked for it:
    /// its parents are followed back, past the records of its own request, to the first other record. A parent is
    /// always written before its child, so the walk only goes on towards the start.
    static func newest(in data: Data) -> LimitAnswer? {
        var reply: LimitAnswer?
        var wanted: String?
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            if start < end {
                let line = data[start..<end]
                if var found = reply {
                    if let uuid = wanted, line.range(of: Data(uuid.utf8)) != nil,
                        let object = autoreleasepool(invoking: { (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }),
                        object["uuid"] as? String == uuid
                    {
                        if let request = found.request, object["requestId"] as? String == request {
                            wanted = object["parentUuid"] as? String
                            if wanted == nil { return found }
                        } else {
                            found.askedAt = (object["timestamp"] as? String).flatMap(LimitHit.parseTime)
                            return found
                        }
                    }
                } else if let found = autoreleasepool(invoking: { parse(line: line) }) {
                    reply = found
                    wanted = found.parent
                    if wanted == nil { return found }
                }
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return reply
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
        /// The account signed in to the window when the process was seen (`lastKnownAccountUuid`); `nil` in
        /// sightings recorded before Baton kept it, which no longer count.
        public var account: String?

        public init(
            session: String, window: String, pid: Int32, from: Date, lastSeen: Date, version: String? = nil, cwd: String? = nil,
            account: String? = nil
        ) {
            self.session = session.lowercased(); self.window = window; self.pid = pid; self.from = from; self.lastSeen = lastSeen
            self.version = version; self.cwd = cwd; self.account = account
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
        /// Where the next read of a grown file starts: a few lines before `offset`, so a reply there can still be
        /// followed back to the record it answers (`LimitAnswer.newest`).
        var resume: UInt64
        var hits: [LimitHit]
        var answer: LimitAnswer?
    }

    /// What the sessions a window ran say about its limits.
    public struct Activity: Equatable, Sendable {
        public var hits: [LimitHit] = []
        /// The newest reply Claude gave in one of them.
        public var answeredAt: Date?
        /// The newest time Claude was asked for a reply it gave in one of them.
        public var askedAt: Date?

        public init(hits: [LimitHit] = [], answeredAt: Date? = nil, askedAt: Date? = nil) {
            self.hits = hits; self.answeredAt = answeredAt; self.askedAt = askedAt
        }
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

    /// Records every running process of a window, with the account signed in to it, and returns the sightings of
    /// the last eight days, newest last. The file is shared by the app and the CLI, so it is read and written under
    /// a file lock.
    @discardableResult
    public func observe(paths: Paths, windows: [(id: String, dataDir: URL)], now: Date = Date()) -> [Sighting] {
        let live = liveProcesses(paths.claudeDir)
        let accounts = Dictionary(windows.map { ($0.id, DesktopData.accountID(in: $0.dataDir)) }, uniquingKeysWith: { a, _ in a })
        return lock.withLock {
            (try? FileLock.withLock(paths.stateDir.appending(path: "limit-sightings.lock"), blocking: true) {
                record(live, windows: windows, accounts: accounts, paths: paths, now: now)
            }) ?? nil ?? load(paths).sightings.sorted { $0.lastSeen < $1.lastSeen }
        }
    }

    private func record(
        _ live: [LiveProcess], windows: [(id: String, dataDir: URL)], accounts: [String: String?], paths: Paths, now: Date
    ) -> [Sighting] {
        var store = load(paths)
        let cutoff = now.addingTimeInterval(-Self.horizon)
        store.sightings.removeAll { $0.lastSeen < cutoff }
        var changed = false
        for process in live {
            guard let window = Self.window(of: process.executable, in: windows) else { continue }
            var sighting = Sighting(
                session: process.session, window: window, pid: process.pid, from: process.startedAt, lastSeen: now,
                version: process.version, cwd: process.cwd, account: accounts[window] ?? nil)
            if let i = store.sightings.firstIndex(where: { $0.key == sighting.key }) {
                sighting.lastSeen = max(store.sightings[i].lastSeen, now)
                // One process belongs to one sign-in: a later account never rewrites what an earlier one ran.
                if let before = store.sightings[i].account { sighting.account = before }
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
        activity(paths: paths, windows: windows, now: now).compactMapValues { $0.hits.isEmpty ? nil : $0.hits }
    }

    /// Limit messages and the newest reply of each window's sessions, by window id, both read in one pass over the
    /// end of each transcript.
    public func activity(paths: Paths, windows: [(id: String, dataDir: URL)], now: Date = Date()) -> [String: Activity] {
        let sightings = observe(paths: paths, windows: windows, now: now)
        var hits: [LimitHit] = []
        var answers: [LimitAnswer] = []
        var located: [String: URL] = [:]
        for sighting in sightings where located[sighting.session] == nil {
            if let url = transcript(of: sighting, paths: paths, now: now) { located[sighting.session] = url }
        }
        for (session, url) in located {
            guard (SyncFolders.modificationDate(url) ?? .distantPast) >= now.addingTimeInterval(-Self.horizon) else { continue }
            let found = scan(url)
            hits += found.hits.filter { $0.session == session }
            if let answer = found.answer, answer.session == session { answers.append(answer) }
        }
        let accounts = Dictionary(windows.map { ($0.id, DesktopData.accountID(in: $0.dataDir)) }, uniquingKeysWith: { a, _ in a })
        var result: [String: Activity] = [:]
        for (window, found) in Self.attribute(hits, to: sightings, accounts: accounts) { result[window, default: Activity()].hits = found }
        for answer in answers {
            guard
                let window = Self.window(
                    for: answer.session, at: answer.at, version: answer.version, entrypoint: answer.entrypoint, in: sightings, accounts: accounts)
            else { continue }
            result[window, default: Activity()].answeredAt = max(result[window]?.answeredAt ?? answer.at, answer.at)
            if let asked = answer.askedAt { result[window, default: Activity()].askedAt = max(result[window]?.askedAt ?? asked, asked) }
        }
        return result
    }

    /// Each hit goes to the one window whose process had its session open at the time, while signed in with the
    /// account the window has now; a hit that no window's process covers, or that two windows' processes cover, is
    /// left out. With `accounts` nil, the account isn't checked.
    static func attribute(_ hits: [LimitHit], to sightings: [Sighting], accounts: [String: String?]? = nil) -> [String: [LimitHit]] {
        var result: [String: [LimitHit]] = [:]
        for hit in hits {
            guard let window = window(for: hit.session, at: hit.at, version: hit.version, entrypoint: hit.entrypoint, in: sightings, accounts: accounts)
            else { continue }
            result[window, default: []].append(hit)
        }
        return result
    }

    /// The one window whose process had `session` open at `at`, signed in with the account the window has now.
    static func window(
        for session: String, at: Date, version: String?, entrypoint: String?, in sightings: [Sighting], accounts: [String: String?]?
    ) -> String? {
        guard entrypoint == "claude-desktop" else { return nil }
        let covering = sightings.filter {
            $0.session == session && at >= $0.from && at <= $0.lastSeen.addingTimeInterval(lastSeenGrace)
                && ($0.version == nil || version == nil || $0.version == version)
        }
        let windows = Set(covering.map(\.window))
        guard windows.count == 1, let window = windows.first else { return nil }
        if let accounts {
            guard let current = accounts[window] ?? nil, covering.contains(where: { $0.account == current }) else { return nil }
        }
        return window
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

    /// The hits and the newest reply in the last `tail` bytes of a transcript; a file that only grew is read from
    /// a few lines before where the last read ended, and its hits counted from there.
    func scan(_ url: URL) -> (hits: [LimitHit], answer: LimitAnswer?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value, let modified = attributes[.modificationDate] as? Date
        else { return ([], nil) }
        let cached = lock.withLock { scans[url.path] }
        if let cached, cached.size == size, cached.modified == modified { return (cached.hits, cached.answer) }
        var start = size > Self.tail ? size - Self.tail : 0
        var fresh = start
        var hits: [LimitHit] = []
        var answer: LimitAnswer?
        if let cached, size > cached.size, size - cached.resume <= Self.tail {
            start = cached.resume
            fresh = cached.offset
            hits = cached.hits
            answer = cached.answer
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], nil) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return ([], nil) }
        // Only whole lines: the rest is read again next time.
        let whole = data.lastIndex(of: 0x0A).map { data[..<($0 + 1)] } ?? Data()
        let newFrom = min(whole.startIndex + Int(fresh - start), whole.endIndex)
        hits += LimitHit.hits(in: whole[newFrom...])
        if var newer = LimitAnswer.newest(in: whole) {
            // Its request began before what was read: the time an earlier reply was asked for still stands.
            if newer.askedAt == nil { newer.askedAt = answer?.askedAt }
            answer = newer
        }
        let scan = Scan(
            size: size, modified: modified, offset: start + UInt64(whole.count), resume: start + UInt64(Self.resumePoint(in: whole) - whole.startIndex),
            hits: hits, answer: answer)
        lock.withLock { scans[url.path] = scan }
        return (hits, answer)
    }

    /// The start of the last few whole lines of `data`, at most 256 KB before its end.
    static func resumePoint(in data: Data, lines: Int = 16, limit: Int = 1 << 18) -> Data.Index {
        var resume = data.endIndex
        for _ in 0..<lines {
            guard resume > data.startIndex else { break }
            let before = data[..<(resume - 1)].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            guard data.endIndex - before <= limit else { break }
            resume = before
        }
        return resume
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

/// How limits read in the window list, the Continue sheet, the menu and `baton list`. A window at its limit is "at
/// its limit" everywhere; a reset time is "resets at 02:10" or "resets tomorrow at 02:10", and "resets Wed at about
/// 05:00" when it is an estimate.
public enum LimitText {
    /// "at 02:10" on the same day as `now`; "tomorrow at 05:00" or "yesterday at 23:10" on the days next to it; "Wed
    /// at 05:00" within five days of it; "Tue 6 Oct at 08:00" further off. With `about`, "at about 05:00". The time is
    /// in the style of `locale` (12- or 24-hour).
    public static func time(
        _ date: Date, now: Date = Date(), about: Bool = false, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let (day, clock) = parts(date, now: now, timeZone: timeZone, locale: locale)
        let at = about ? "at about \(clock)" : "at \(clock)"
        return day.map { "\($0) \(at)" } ?? at
    }

    /// "22:12", "yesterday 22:12", "Mon 22:12": a moment, as in "as of 22:12".
    public static func stamp(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let (day, clock) = parts(date, now: now, timeZone: timeZone, locale: locale)
        return day.map { "\($0) \(clock)" } ?? clock
    }

    /// The day of `date` as seen from `now` (`nil` on the same day) and its time of day.
    static func parts(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> (day: String?, clock: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let clock = formatter.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch days {
        case 0: return (nil, clock)
        case 1: return ("tomorrow", clock)
        case -1: return ("yesterday", clock)
        case -5...5:
            formatter.dateFormat = "EEE"
            return (formatter.string(from: date), clock)
        default:
            // Six or more days off, a weekday alone would read as this week's.
            formatter.dateFormat = "EEE d MMM"
            return (formatter.string(from: date), clock)
        }
    }

    /// "resets at 02:10", "resets tomorrow at 02:10", "resets Wed at about 05:00", "may have reset at about 05:00";
    /// `nil` without a reset time.
    public static func reset(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let reset = state.reset, reset.source != .inferred else { return nil }
        let exact = reset.source == .exact
        let when = time(reset.at, now: now, about: !exact, timeZone: timeZone, locale: locale)
        if exact { return "resets \(when)" }
        return reset.at > now ? "resets \(when)" : "may have reset \(when)"
    }

    /// "5h 40%", "5h 100% · resets at 02:10", "week 100% · resets Wed at about 05:00", "5h reset at 02:10",
    /// "week reset", "week 100%, extra usage available", "5h: Claude answered since".
    public static func describe(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let name = state.kind.name
        switch state.phase(now: now) {
        case .below:
            // Seen, not explained: the limit may have reset, or extra usage may be paying.
            if state.resetByAnswer { return "\(name): Claude answered since" }
            guard let percent = state.percent else { return "\(name) ?" }
            if state.kind == .fiveHour, let at = state.sampledAt, now.timeIntervalSince(at) > state.kind.window { return "\(name) reset" }
            return "\(name) \(percent)%"
        case .reached:
            let base = "\(name) \(state.percent ?? 100)%"
            if state.extraUsage { return base + ", extra usage available" }
            return reset(state, now: now, timeZone: timeZone, locale: locale).map { "\(base) · \($0)" } ?? base
        case .reset:
            return "\(name) reset \(time(state.reset?.at ?? now, now: now, timeZone: timeZone, locale: locale))"
        case .mayHaveReset:
            // Older than the limit's own window: that window has ended, so it has reset.
            return "\(name) reset"
        }
    }

    /// A short note for the window list beside the meters: "5h resets at 02:10", "week resets Wed at about 05:00",
    /// "5h reset at 02:10", "week reset", "week at 100%, extra usage available", "5h: Claude answered since the
    /// limit"; `nil` below the limit.
    public static func note(_ state: LimitState, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        let name = state.kind.name
        switch state.phase(now: now) {
        case .below: return state.resetByAnswer ? "\(name): Claude answered since the limit" : nil
        case .reached:
            if state.extraUsage { return "\(name) at 100%, extra usage available" }
            return reset(state, now: now, timeZone: timeZone, locale: locale).map { "\(name) \($0)" }
        case .reset, .mayHaveReset: return describe(state, now: now, timeZone: timeZone, locale: locale)
        }
    }

    /// The whole line for `baton list`: "5h 100% · resets at 02:10 · week 62% · as of 3m ago".
    public static func summary(
        _ limits: Limits, usage: Usage?, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        guard usage != nil || limits.states.contains(where: { $0.reachedAt != nil }) else { return "usage unknown" }
        var line = limits.states.map { describe($0, now: now, timeZone: timeZone, locale: locale) }.joined(separator: " · ")
        if let usage {
            line += " · as of \(relativeAge(since: usage.sampledAt, now: now))"
            if !usage.isFresh(now: now), limits.states.allSatisfy({ $0.phase(now: now) == .below }) { line += " (stale: may have changed since)" }
        }
        return line
    }

    /// For a window at its limit: "resets at 02:10" or "resets Wed at about 05:00", by the limit that holds it back
    /// longest; `nil` when that reset isn't known.
    public static func bindingReset(_ limits: Limits, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        limits.binding(now: now).flatMap { reset($0, now: now, timeZone: timeZone, locale: locale) }
    }

    /// For a window held back by a sample alone: "as of 22:12", the time of that sample; `nil` otherwise.
    public static func asOf(_ limits: Limits, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let binding = limits.binding(now: now), binding.sampleOnly, binding.reset == nil, let at = binding.reachedAt else { return nil }
        return "as of \(stamp(at, now: now, timeZone: timeZone, locale: locale))"
    }

    /// "at its limit, resets at 02:10", "at its limit, resets Wed at about 05:00", "at its limit as of 22:12" or
    /// "at its limit": the one phrase for a window at its limit in the menu, the Continue sheet, the banner and the
    /// line `baton list` prints under such a window.
    public static func atLimit(_ limits: Limits, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        if let reset = bindingReset(limits, now: now, timeZone: timeZone, locale: locale) { return "at its limit, \(reset)" }
        return asOf(limits, now: now, timeZone: timeZone, locale: locale).map { "at its limit \($0)" } ?? "at its limit"
    }

    /// For a closed window held back by a sample alone, with no reset time or only an estimate that has passed:
    /// Claude records usage only while the window is open.
    public static func checkHint(_ status: ProfileStatus, now: Date = Date()) -> String? {
        guard !status.isRunning, status.isSignedIn, status.limits.isAtLimit(now: now), let binding = status.limits.binding(now: now),
            binding.sampleOnly
        else { return nil }
        if let reset = binding.reset, reset.source != .estimate || reset.at > now { return nil }
        return "Open it to check: Claude records a new sample about 9 s after the window starts."
    }

    /// The tooltip of a window's usage in the window list: where reset times come from and why one may be missing,
    /// whenever a limit is reached or a note names a reset; that the sample may be behind; how to check a closed
    /// window. Empty when there is nothing to add.
    public static func columnHelp(_ status: ProfileStatus, now: Date = Date()) -> String {
        let states = status.limits.states
        var lines: [String] = []
        if states.contains(where: { $0.phase(now: now) == .reached || note($0, now: now) != nil }) {
            lines.append(
                "Reset times come from Claude: its limit messages and Auto-continue when limits reset. They appear for limits "
                    + "reached while Baton is running; one reached before that shows no time.")
        }
        if let usage = status.usage, !usage.isFresh(now: now) {
            lines.append("Claude records usage only while this window is open and in use, so this sample can be behind.")
        }
        if let hint = checkHint(status, now: now) { lines.append(hint) }
        return lines.joined(separator: " ")
    }
}

// MARK: - Scheduling

/// When the app looks at limits again, and which windows a reset has just freed.
public enum LimitSchedule {
    /// The earliest known reset (plus the grace period) still ahead among `statuses`.
    public static func nextRefresh(_ statuses: [ProfileStatus], now: Date = Date()) -> Date? {
        statuses.compactMap { $0.limits.nextChange(after: now) }.min()
    }

    /// Windows blocked at the previous check that a known reset has freed: an exact reset time passing, a newer
    /// sample below the limit, or a reply to a request sent since. A sample simply growing old, extra usage taking
    /// over, or another account signing in to the window isn't announced. `RoomAgainWatch` announces them.
    /// - Parameter blockedBefore: the windows blocked then, each with the account signed in to it (`blocked`).
    public static func freed(blockedBefore: [String: String], _ statuses: [ProfileStatus], now: Date = Date()) -> [ProfileStatus] {
        statuses.filter { status in
            guard let account = blockedBefore[status.id], status.isSignedIn, status.accountID == account else { return false }
            return status.limits.states.allSatisfy { [.below, .reset].contains($0.phase(now: now)) }
        }
    }

    /// The windows blocked at a limit now, each with its signed-in account, to compare with at the next check.
    public static func blocked(_ statuses: [ProfileStatus], now: Date = Date()) -> [String: String] {
        Dictionary(
            statuses.compactMap { status in
                guard status.isSignedIn, let account = status.accountID, status.limits.isAtLimit(now: now) else { return nil }
                return (status.id, account)
            }, uniquingKeysWith: { a, _ in a })
    }

    /// "Claude WORK has room again", or "Claude (main) has room again".
    public static func roomAgain(_ status: ProfileStatus) -> String { "Claude \(status.displayLabel) has room again" }

    /// Why: a reset Claude named, or a lower sample, is a reset; a reply in one of its sessions is only seen, since
    /// extra usage may be paying for it.
    public static func roomAgainReason(_ status: ProfileStatus) -> String {
        status.limits.states.contains(where: \.resetByAnswer) ? "Claude answered in it again." : "Its usage limit has reset."
    }
}

/// Which windows to announce as having room again: freed since a check where they were blocked, and still free, with
/// the same account, at a check at least `settle` later. A window blocked again in between isn't announced, so a
/// sign of room that lasts only seconds never becomes a notification.
public struct RoomAgainWatch: Sendable {
    /// How long a window must stay free before it is announced.
    public static let settle: TimeInterval = 60

    struct Waiting: Sendable {
        var account: String
        var since: Date
    }

    /// The windows blocked at the previous check, each with its signed-in account; `nil` before the first.
    private var blocked: [String: String]?
    private var waiting: [String: Waiting] = [:]

    public init() {}

    /// Takes one check's statuses.
    /// - Returns: the windows to announce now, in the order of `statuses`, and those blocked at a limit now.
    public mutating func update(_ statuses: [ProfileStatus], now: Date = Date()) -> (announce: [ProfileStatus], blocked: Set<String>) {
        let blockedNow = LimitSchedule.blocked(statuses, now: now)
        if let before = blocked {
            for status in LimitSchedule.freed(blockedBefore: before, statuses, now: now) where waiting[status.id] == nil {
                if let account = before[status.id] { waiting[status.id] = Waiting(account: account, since: now) }
            }
        }
        blocked = blockedNow
        var announce: [ProfileStatus] = []
        for status in statuses {
            guard let wait = waiting[status.id] else { continue }
            guard !LimitSchedule.freed(blockedBefore: [status.id: wait.account], [status], now: now).isEmpty else {
                waiting[status.id] = nil
                continue
            }
            if now.timeIntervalSince(wait.since) >= Self.settle {
                announce.append(status)
                waiting[status.id] = nil
            }
        }
        // A window that is gone from the list is no longer waiting.
        let ids = Set(statuses.map(\.id))
        waiting = waiting.filter { ids.contains($0.key) }
        return (announce, Set(blockedNow.keys))
    }

    /// When the next waiting window is due to be announced, if it is still free then.
    public var nextCheck: Date? { waiting.values.map { $0.since.addingTimeInterval(Self.settle) }.min() }
}
