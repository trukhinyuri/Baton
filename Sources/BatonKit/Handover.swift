import Foundation

// MARK: - What a handover moves

/// One session of the window at its limit that continues in another window.
public struct HandoverSession: Codable, Equatable, Sendable {
    /// `local_<card>`: its card in the window at its limit.
    public var card: String
    /// Its Claude Code session id (`cliSessionId`).
    public var transcript: String
    public var title: String
    public var folders: [String]
    /// The limit cut it mid-turn, so it resumes in the destination.
    public var cut: Bool
    /// A Claude Code process of it works in the window at its limit (`ClaudeWork`), so a copy continues instead of the
    /// session itself.
    public var asCopy: Bool
    /// Its last message, for the order sessions are shown in.
    public var lastActivity: Date
    /// Its auto-continue is on in the window at its limit, which continues it there at the reset while it runs.
    public var armed: Bool

    public init(
        card: String, transcript: String, title: String, folders: [String] = [], cut: Bool, asCopy: Bool, lastActivity: Date, armed: Bool = false
    ) {
        self.card = card; self.transcript = transcript.lowercased(); self.title = title; self.folders = folders
        self.cut = cut; self.asCopy = asCopy; self.lastActivity = lastActivity; self.armed = armed
    }
}

/// What doesn't follow the work, or follows it only in part: named in the handover's line.
public enum HandoverLeftover: Codable, Equatable, Sendable {
    /// Sessions a folder rule keeps out of the destination's account.
    case folderRule(count: Int, folder: String, accounts: [String])
    /// Sessions Remote Control reaches in the window at its limit, so they stay there.
    case remoteControl(count: Int)
    /// Sessions still open in the window at its limit, which continue as copies.
    case copies(count: Int)
    /// Seeded but not seen to continue: open in the destination, by title.
    case notResumed(titles: [String])
    /// Claude can't continue them by itself there: opened, not seeded, by title.
    case cannotResume(titles: [String])
    /// The destination was busy; it restarts once nothing works there.
    case waitingForDestination
    /// A group new to the destination whose sessions may lose it at Claude's merge with its server copy.
    case ungrouped(count: Int, group: String)
    /// Pins and groups couldn't be written, with the reason.
    case layoutNotCarried(String)
    /// Cowork tasks, which belong to their window.
    case coworkStays(count: Int)
    /// Sessions that couldn't be brought to the destination (their copy failed, or their card isn't there), by title.
    case notMoved(titles: [String])
    /// Copies made in the destination that stay there unused: the source's limit reset first.
    case copiesStay(count: Int)
    /// Sessions the limit cut that continue in the window at its limit when it resets: it stays open because Claude
    /// Code works there, so its own auto-continue for them stays on, and resuming them elsewhere too would put one
    /// session in two windows.
    case resumeInSource(count: Int)
    /// Sessions the limit cut that a Claude Code process still runs in the window at its limit, with their
    /// auto-continue on there: they keep running there and continue there at its reset. Their copies are made in the
    /// destination, so the history is there, but never resumed, or one cut turn would continue twice.
    case keepRunningInSource(count: Int)
}

/// What handing a window's work over would do, worked out without changing anything.
public struct HandoverPlan: Equatable, Sendable {
    public var source: String
    public var destination: String
    public var resetsAt: Date?
    public var sessions: [HandoverSession]
    public var sourceActivity: WindowActivity
    public var destinationActivity: WindowActivity
    public var seeding: Seeding
    public var leftovers: [HandoverLeftover]
    /// The reset is within `HandoverTrigger.waitsFor`: the window continues its own work then, and nothing is handed over.
    public var picksUpItself = false
    /// Moved by hand (the Continue sheet, `planMove`) rather than because of a limit: it runs even when this limit's
    /// work was handed over already.
    public var byHand = false
    /// The source was at its limit when this was planned; a move by hand may come from a window with room.
    public var sourceAtLimit = true

    /// Sessions that resume in the destination.
    public var cut: [HandoverSession] { sessions.filter(\.cut) }

    /// Sessions the limit cut that continue in the source at its reset instead, while the source stays open, with
    /// their auto-continue on there: moved as themselves (`waitsForSource`), or still running there, whose copies
    /// move without resuming (`keepsRunning`). A busy source is expected to stay open.
    public var resumeInSource: [HandoverSession] {
        sourceActivity.isBusy ? sessions.filter { Self.waitsForSource($0) || Self.keepsRunning($0) } : []
    }

    /// A cut session, not a copy, whose auto-continue is on in the source: the source continues it at its reset if
    /// it is still open then.
    static func waitsForSource(_ session: HandoverSession) -> Bool { session.cut && session.armed && !session.asCopy }

    /// A cut session still running in the source with its auto-continue on there: it continues there, so its copy
    /// in the destination is never seeded or resumed.
    static func keepsRunning(_ session: HandoverSession) -> Bool { session.cut && session.armed && session.asCopy }
}

/// What a handover did.
public struct HandoverResult: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The work continues in the destination.
        case done
        /// The destination is busy and restarts once nothing works there (`finishWaitingHandover`).
        case waiting
        /// The reset is within `HandoverTrigger.waitsFor`; nothing was done.
        case picksUpItself
        /// The source's limit reset before the destination was free: the work continues in the source.
        case resetFirst
        /// The destination didn't open; the sessions are there when it does.
        case failed
    }

    public var plan: HandoverPlan
    public var state: State
    /// Session ids seen to continue.
    public var resumed: [String] = []
    /// Session ids shown or due to be shown and not seen to continue.
    public var notResumed: [String] = []
    /// Baton closed the window at its limit.
    public var sourceClosed = false
    /// Why the destination didn't open, for `failed`.
    public var failure: String?
    public var line = ""
    public var isWarning = false

    public init(plan: HandoverPlan, state: State, sourceClosed: Bool = false) {
        self.plan = plan; self.state = state; self.sourceClosed = sourceClosed
    }
}

public enum HandoverError: LocalizedError, Equatable {
    case notAtLimit(String)
    case alreadyHandedOver(String)
    /// No other window has room: the line says so and names the one that frees up first, when known.
    case noRoom(String)
    case sameWindow(String)
    /// The chosen window is at its limit too.
    case destinationAtLimit(String)
    /// Another Baton is handing the window's work over right now.
    case inProgress(String)

    public var errorDescription: String? {
        switch self {
        case .notAtLimit(let label): "\(label) isn't at its limit, so its work stays there."
        case .alreadyHandedOver(let label): "\(label)'s work for this limit was handed over already."
        case .noRoom(let line): line
        case .sameWindow(let label): "\(label) is the window at its limit; choose another one."
        case .destinationAtLimit(let label): "\(label) is at its limit too; choose another window."
        case .inProgress(let label): "Baton is handing \(label)'s work over already."
        }
    }
}

// MARK: - The log

/// Handovers Baton made or is waiting to finish, in `handovers.json` in the state folder, so an episode is handed over
/// once and a wait for a busy window survives a restart of Baton.
public struct HandoverLog: Sendable {
    /// What a waiting handover still has to do once its destination is free.
    public struct Pending: Codable, Equatable, Sendable {
        public var slice: SidebarLayoutData?
        /// Card names (`local_<id>`) in the destination to seed.
        public var seed: [String]
        /// Session ids to show, in order.
        public var show: [String]
        /// Titles by session id, for the line.
        public var titles: [String: String]
        /// Card names in the source that resume there if its limit resets first.
        public var sourceCut: [String]
        /// Session ids of those, in order.
        public var sourceShow: [String]
        /// Transcript sizes of the sessions to show when the handover prepared them, so a session that continued
        /// since (before an interrupt, or by the user's hand) is neither seeded nor shown again.
        public var lengths: [String: UInt64]? = nil
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var source: String
        public var resetsAt: Date?
        public var destination: String
        public var startedAt: Date
        public var finishedAt: Date?
        /// starting (closing the source and making copies; nothing prepared for the destination yet), waiting (ready
        /// for the destination), done, cancelled, failed, or restarted (stopped while starting and taken up afresh:
        /// kept only for its copies, and not a handover of its episode).
        public var state: String
        public var sessions: Int
        public var resumed: [String] = []
        public var line: String = ""
        public var sourceClosed = false
        /// When Baton shared the cards into the destination.
        public var sharedAt: Date?
        public var seeding: Seeding = .seed
        public var leftovers: [HandoverLeftover] = []
        public var pending: Pending?
        /// The cards the handover set out to move, for taking up one that stopped while it started.
        public var cards: [String]? = nil
        /// The copies made so far, by the source card they copy: the copy's session id. A handover that takes up one
        /// stopped while it started uses them again instead of making or moving anything else for those sessions.
        public var copies: [String: String]? = nil
    }

    struct State: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    let file: URL
    /// Entries older than this are dropped when the log is written.
    static let keep: TimeInterval = 7 * 86_400
    /// Two resets this close are the same limit.
    static let sameEpisode: TimeInterval = 3600
    /// The state of a handover stopped while it started and taken up afresh.
    static let restarted = "restarted"

    public init(paths: Paths) { file = paths.stateDir.appending(path: "handovers.json") }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.handovers.decode(State.self, from: data))?.entries ?? []
    }

    /// Whether the work of `source` at the limit that resets at `resetsAt` was handed over already, or is being.
    public func handled(source: String, resetsAt: Date?, now: Date = Date()) -> Bool {
        entries().contains { $0.state != Self.restarted && Self.same($0, source: source, resetsAt: resetsAt, now: now) }
    }

    static func same(_ entry: Entry, source: String, resetsAt: Date?, now: Date) -> Bool {
        guard entry.source == source else { return false }
        switch (entry.resetsAt, resetsAt) {
        case (let a?, let b?): return abs(a.timeIntervalSince(b)) <= sameEpisode
        case (nil, nil): return now.timeIntervalSince(entry.startedAt) < LimitKind.fiveHour.window
        default: return false
        }
    }

    /// Writes `entry` unless its episode was handed over already, in one step for the app and the CLI alike.
    /// - Returns: false when another handover of the episode got there first.
    func claim(_ entry: Entry, now: Date = Date()) throws -> Bool {
        try FileLock.withLock(lock, blocking: true) {
            guard !handled(source: entry.source, resetsAt: entry.resetsAt, now: now) else { return false }
            try save(entry, now: now)
            return true
        } ?? false
    }

    /// Handovers of `source`, or of every window, not finished yet: stopped while starting, waiting for their
    /// destination (or stopped while it opened), or done with the source left open before its reset, so Baton still
    /// has to close it once nothing works there.
    public func unfinished(source: String? = nil, now: Date = Date()) -> [Entry] {
        entries().filter { entry in
            guard source.map({ $0 == entry.source }) ?? true else { return false }
            if entry.state == "waiting" || entry.state == "starting" { return true }
            return entry.state == "done" && !entry.sourceClosed && (entry.resetsAt.map { $0 > now } ?? false)
        }
    }

    /// The handover of `source` waiting for its destination, if any.
    public func waiting(source: String) -> Entry? { entries().last { $0.source == source && $0.state == "waiting" } }

    /// Every handover waiting for its destination.
    public func waiting() -> [Entry] { entries().filter { $0.state == "waiting" } }

    /// Adds `entry`, or replaces the one for the same source started at the same moment. A source once closed stays
    /// closed in the log, whichever step writes last.
    func save(_ entry: Entry, now: Date = Date()) throws {
        try FileLock.withLock(lock, blocking: true) {
            var entry = entry
            let same = { (other: Entry) in other.source == entry.source && abs(other.startedAt.timeIntervalSince(entry.startedAt)) < 1 }
            let before = entries()
            if before.contains(where: { same($0) && $0.sourceClosed }) { entry.sourceClosed = true }
            var state = State()
            state.entries = before.filter { !same($0) && now.timeIntervalSince($0.startedAt) < Self.keep }
            state.entries.append(entry)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.handovers.encode(state).write(to: file, options: .atomic)
        }
    }

    /// Held by the process handing `source`'s work over for as long as it works on it; the system lets it go when
    /// that process ends, so a handover stopped by Ctrl-C or a crash can be taken up again.
    /// - Returns: `nil` when another handover of `source` holds it.
    func working(source: String) throws -> FileLock.Held? {
        try FileLock.Held.attempt(file.deletingLastPathComponent().appending(path: "handover-\(source).lock"))
    }

    /// Whether a handover of `source` runs right now, in this process or another.
    public func inProgress(source: String) -> Bool {
        do {
            guard let held = try working(source: source) else { return true }
            held.release()
        } catch {
            Log.error("handover", "Couldn't check the handover lock of window \(source): \(error.localizedDescription)")
        }
        return false
    }

    private var lock: URL { file.deletingLastPathComponent().appending(path: "handovers.lock") }
}

extension JSONEncoder {
    fileprivate static var handovers: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var handovers: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A sidebar layout as the log keeps it.
public struct SidebarLayoutData: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var extra: [String: String]
    }
    var groups: [Group]
    var assignments: [String: String]
    var order: [String: [String]]
    var starred: [String]
    var pinnedOrder: [String]

    init(_ layout: SidebarLayout) {
        groups = layout.groups.map { Group(id: $0.id, name: $0.name, extra: $0.extra) }
        assignments = layout.assignments; order = layout.order; starred = layout.starred; pinnedOrder = layout.pinnedOrder
    }

    var layout: SidebarLayout {
        SidebarLayout(
            groups: groups.map { SidebarLayout.Group(id: $0.id, name: $0.name, extra: $0.extra) }, assignments: assignments, order: order,
            starred: starred, pinnedOrder: pinnedOrder)
    }
}

// MARK: - What the handover says

public enum HandoverText {
    /// At most this many leftover clauses; the rest are "and more — baton doctor".
    static let maxClauses = 2
    /// At most this many titles in a clause; the rest are "and N more".
    static let maxTitles = 2

    /// The one line a handover ends with, such as "ROBIN is at its limit until 19:10 and was closed. Your work
    /// continues in PAY — 9 sessions resumed." It never asks the user to type anything.
    /// - Parameter labels: a window id → its label ("ROBIN", "(main)").
    public static func line(
        _ result: HandoverResult, labels: (String) -> String, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let plan = result.plan
        let source = labels(plan.source), destination = labels(plan.destination)
        let until = plan.resetsAt.map { " until " + untilText($0, now: now, timeZone: timeZone, locale: locale) } ?? ""
        let resumed = result.resumed.count
        let resumedText = resumed > 0 ? " — \(resumed) session\(resumed == 1 ? "" : "s") resumed" : ""
        let closed = result.sourceClosed ? " and was closed." : "."
        // A window moved by hand with room left isn't at its limit: only whether it was closed is said.
        let first = plan.sourceAtLimit ? "\(source) is at its limit\(until)\(closed) " : result.sourceClosed ? "\(source) was closed. " : ""
        let head: String
        switch result.state {
        case .picksUpItself:
            return "\(source) is at its limit\(until); work continues there then."
        case .resetFirst:
            head = "\(source)'s limit reset before \(destination) was free, so your work continues in \(source)\(resumedText)"
        case .waiting:
            head = "\(first)\(destination) restarts when its current work finishes"
        case .failed:
            head =
                "\(first)\(destination) didn't open: \(trimmed(result.failure ?? "unknown error")). "
                + "Your sessions are there when you open it"
        case .done:
            head = "\(first)Your work continues in \(destination)\(resumedText)"
        }
        let at = plan.resetsAt.map { LimitText.time($0, now: now, timeZone: timeZone, locale: locale) }
        let clauses =
            result.state == .picksUpItself ? [] : plan.leftovers.compactMap { clause($0, source: source, destination: destination, at: at) }
        var parts = Array(clauses.prefix(maxClauses))
        if clauses.count > maxClauses { parts.append("and more — baton doctor") }
        return ([head] + parts).joined(separator: "; ") + "."
    }

    /// Whether the line names something that didn't follow the work.
    public static func isWarning(_ result: HandoverResult) -> Bool {
        result.state == .failed
            || (result.state != .picksUpItself && result.plan.leftovers.contains { clause($0, source: "", destination: "") != nil })
    }

    /// "19:10", "tomorrow at 05:00": `LimitText.time` without its leading "at".
    static func untilText(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let text = LimitText.time(date, now: now, timeZone: timeZone, locale: locale)
        return text.hasPrefix("at ") ? String(text.dropFirst(3)) : text
    }

    static func trimmed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The clause the line names `leftover` with, such as "3 stay in ROBIN: Remote Control reaches them there".
    /// - Parameter at: when the source's limit resets ("at 19:10"), if known.
    public static func clause(_ leftover: HandoverLeftover, source: String, destination: String, at: String? = nil) -> String? {
        switch leftover {
        case .folderRule(let count, let folder, let accounts):
            let name = URL(fileURLWithPath: folder).lastPathComponent
            let who = accounts.map { $0.split(separator: "@").first.map { "\($0)@" } ?? $0 }.joined(separator: ", ")
            return "\(count) \(count == 1 ? "stays" : "stay") in \(source): a folder rule keeps \(name) for \(who)"
        case .remoteControl(let count):
            return "\(count) \(count == 1 ? "stays" : "stay") in \(source): Remote Control reaches \(count == 1 ? "it" : "them") there"
        case .copies(let count):
            return count == 1
                ? "1 still open in \(source) continues as a copy" : "\(count) still open in \(source) continue as copies"
        case .notResumed(let titles):
            guard !titles.isEmpty else { return nil }
            let one = titles.count == 1
            return "\(titles.count) didn't resume by \(one ? "itself" : "themselves") — \(one ? "it's" : "they're") open in \(destination): "
                + names(titles)
        case .cannotResume(let titles):
            guard !titles.isEmpty else { return nil }
            let one = titles.count == 1
            return "\(destination) can't resume \(one ? "it" : "them") by itself — \(one ? "it's" : "they're") open there: " + names(titles)
        case .waitingForDestination:
            return nil
        case .ungrouped(let count, let group):
            return "group “\(group)” is new to \(destination), so \(count) \(count == 1 ? "is" : "are") ungrouped there"
        case .layoutNotCarried(let reason):
            return "their pins and groups couldn't be written (\(trimmed(reason)))"
        case .coworkStays(let count):
            return "\(count) Cowork task\(count == 1 ? "" : "s") \(count == 1 ? "stays" : "stay") in \(source)"
        case .notMoved(let titles):
            guard !titles.isEmpty else { return nil }
            let one = titles.count == 1
            return "\(titles.count) couldn't be brought to \(destination) and \(one ? "stays" : "stay") in \(source): " + names(titles)
        case .copiesStay(let count):
            return count == 1 ? "the copy made in \(destination) stays there" : "the \(count) copies made in \(destination) stay there"
        case .resumeInSource(let count):
            return "\(count) \(count == 1 ? "continues" : "continue") in \(source) when its limit resets, as Claude Code still works there"
        case .keepRunningInSource(let count):
            let when = at ?? "when its limit resets"
            return count == 1
                ? "1 keeps running in \(source) and continues there \(when); its copy is in \(destination)"
                : "\(count) keep running in \(source) and continue there \(when); their copies are in \(destination)"
        }
    }

    /// “Fix CI”, “Docs” and 1 more.
    static func names(_ titles: [String]) -> String {
        let shown = titles.prefix(maxTitles).map { "“\($0)”" }.joined(separator: ", ")
        return titles.count > maxTitles ? "\(shown) and \(titles.count - maxTitles) more" : shown
    }
}

// MARK: - Planning and handing over

extension ProfileManager {
    /// What handing the work of `source`, a window at its limit, to another window would do: which sessions go,
    /// which resume there, which continue as copies because they are still open in `source`, and what stays. The
    /// destination is `destination`, or the window with the most room that the folder rules of the sessions to resume
    /// allow, a closed or idle one preferred when it is close (`DestinationRanking.forHandover`). Changes nothing.
    public func planHandover(from source: String, to destination: String? = nil, now: Date = Date()) throws -> HandoverPlan {
        try planHandover(from: source, to: destination, statuses: statuses(), now: now)
    }

    /// The same plan for moving `source`'s work by hand, from the Continue sheet: `source` need not be at its limit, and
    /// a limit whose work was handed over already, or that resets within minutes, doesn't stop it. Changes nothing.
    public func planMove(from source: String, to destination: String? = nil, now: Date = Date()) throws -> HandoverPlan {
        try planHandover(from: source, to: destination, statuses: statuses(), now: now, byHand: true)
    }

    func planHandover(from source: String, to destination: String?, statuses: [ProfileStatus], now: Date, byHand: Bool = false) throws -> HandoverPlan {
        let label = displayLabel(of: source)
        guard let status = statuses.first(where: { $0.id == source }) else { throw ProfileError.notFound(source) }
        guard let sourceAccount = status.accountID else { throw ProfileError.notSignedIn(label) }
        let atLimit = DestinationRanking.isAtLimit(status, now: now)
        guard atLimit || byHand else { throw HandoverError.notAtLimit(label) }
        let resetsAt = atLimit ? status.limits.binding(now: now)?.reset?.at : nil
        let sourceActivity = activity(of: source)
        if !byHand, let resetsAt, resetsAt.timeIntervalSince(now) <= HandoverTrigger.waitsFor {
            return HandoverPlan(
                source: source, destination: source, resetsAt: resetsAt, sessions: [], sourceActivity: sourceActivity,
                destinationActivity: sourceActivity, seeding: .seed, leftovers: [], picksUpItself: true)
        }
        guard byHand || !HandoverLog(paths: paths).handled(source: source, resetsAt: resetsAt, now: now) else {
            throw HandoverError.alreadyHandedOver(label)
        }

        var leftovers: [HandoverLeftover] = []
        var candidates = handoverCandidates(source: source, account: sourceAccount, resetsAt: resetsAt, now: now)
        if byHand {
            // Sessions a handover of this limit already resumed elsewhere move, but don't resume a second time:
            // that window's auto-continue has them, and one session must not run in two windows.
            let earlier = Set(
                HandoverLog(paths: paths).entries().filter {
                    $0.state != HandoverLog.restarted && HandoverLog.same($0, source: source, resetsAt: resetsAt, now: now)
                }
                .flatMap { $0.cards ?? [] })
            for i in candidates.indices where earlier.contains(candidates[i].session.card) { candidates[i].session.cut = false }
        }
        let remoteControl = candidates.filter(\.remoteControl).count
        candidates.removeAll(where: \.remoteControl)
        let rules = try FolderRules(paths: paths).load()
        let allowed = candidates.map { FolderRules.allowedAccounts(for: $0.session.folders, in: rules) }

        let target: String
        if let destination {
            guard destination != source else { throw HandoverError.sameWindow(label) }
            guard let chosen = statuses.first(where: { $0.id == destination }) else { throw ProfileError.notFound(destination) }
            guard chosen.isSignedIn else { throw ProfileError.notSignedIn(displayLabel(of: destination)) }
            guard !DestinationRanking.isAtLimit(chosen, now: now) else { throw HandoverError.destinationAtLimit(displayLabel(of: destination)) }
            target = destination
        } else {
            let required = zip(candidates, allowed).filter { $0.0.session.cut }.map { $0.1?.accounts }
            guard
                let best = DestinationRanking.forHandover(
                    statuses, excluding: source, required: required, activity: { self.activity(of: $0) }, now: now)
            else { throw HandoverError.noRoom(noRoomLine(source: status, statuses: statuses, now: now)) }
            target = best
        }
        let targetStatus = statuses.first { $0.id == target }
        let email = targetStatus?.email?.lowercased()

        var sessions: [HandoverSession] = []
        var kept: [String: (count: Int, accounts: [String])] = [:]
        for (candidate, allowed) in zip(candidates, allowed) {
            if let allowed, !(email.map(allowed.accounts.contains) ?? false) {
                let folder = allowed.rules.map(\.folder).sorted().first ?? candidate.session.folders.first ?? ""
                kept[folder, default: (0, allowed.accounts.sorted())].count += 1
                continue
            }
            sessions.append(candidate.session)
        }
        for (folder, found) in kept.sorted(by: { $0.key < $1.key }) {
            leftovers.append(.folderRule(count: found.count, folder: folder, accounts: found.accounts))
        }
        if remoteControl > 0 { leftovers.append(.remoteControl(count: remoteControl)) }
        let running = sourceActivity.isBusy ? sessions.filter(HandoverPlan.keepsRunning).count : 0
        if running > 0 { leftovers.append(.keepRunningInSource(count: running)) }
        let copies = sessions.filter(\.asCopy).count - running
        if copies > 0 { leftovers.append(.copies(count: copies)) }
        if sourceActivity.isBusy {
            let later = sessions.filter(HandoverPlan.waitsForSource).count
            if later > 0 { leftovers.append(.resumeInSource(count: later)) }
        }
        let cowork = ConversationIndex.scan(paths: paths, windows: windows).filter {
            $0.kind == .cowork && $0.ownerID == source && now.timeIntervalSince($0.lastActivity) < LimitKind.fiveHour.window
        }.count
        if cowork > 0 { leftovers.append(.coworkStays(count: cowork)) }
        let destinationAccount = targetStatus?.accountID ?? DesktopData.accountID(in: dataDir(of: target)) ?? ""
        let seeding = autoResume.seeding(window: target, account: destinationAccount, source: (source, sourceAccount), now: now)
        return HandoverPlan(
            source: source, destination: target, resetsAt: resetsAt, sessions: sessions, sourceActivity: sourceActivity,
            destinationActivity: activity(of: target), seeding: seeding, leftovers: leftovers, byHand: byHand,
            sourceAtLimit: atLimit)
    }

    /// A session of the source, and whether Remote Control keeps it there.
    struct HandoverCandidate {
        var session: HandoverSession
        var remoteControl: Bool
    }

    /// The source's work: its cards whose session last ran in it, runs in it now, or was cut by this limit, with a
    /// transcript on this Mac and not archived. Cards Remote Control reaches in another window are left out; those it
    /// reaches in the source are marked.
    func handoverCandidates(source: String, account: String, resetsAt: Date?, now: Date) -> [HandoverCandidate] {
        let sourceDir = dataDir(of: source)
        let windows = windows
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        let live = liveSessions(in: source), working = workingSessions(in: source)
        let liveIn = limitTracker.liveWindows(paths: paths, windows: windows)
        let lastRan = limitTracker.lastWindows(paths: paths, windows: windows, now: now)
        let owners = SessionSync.owners(dataDirs: windows.map(\.dataDir), paths: paths)
        let sourcePath = sourceDir.standardizedFileURL.path
        let armed = Set((AutoResume.armedEntries(in: sourceDir, account: account, now: now) ?? []).map(\.key))

        // Limit messages of this episode in the source that no reply came after.
        var hitSessions = Set<String>()
        for hit in limitTracker.hits(paths: paths, windows: windows, now: now)[source] ?? [] {
            let episode = resetsAt.map { abs(hit.resetsAt.timeIntervalSince($0)) <= HandoverLog.sameEpisode } ?? (hit.resetsAt > now)
            guard episode, let transcript = transcripts[hit.session] else { continue }
            if let answer = limitTracker.scan(transcript).answer, answer.at > hit.at { continue }
            hitSessions.insert(hit.session)
        }

        var found: [HandoverCandidate] = []
        var seen = Set<String>()
        for folder in cardFolders(in: sourceDir) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for name in names where name.hasPrefix("local_") && name.hasSuffix(".json") && seen.insert(name).inserted {
                let url = folder.appending(path: name)
                guard let card = ConversationIndex.readCard(url) else { continue }
                let summary = ConversationIndex.CardSummary(card)
                guard !summary.archived, let session = summary.session, let transcript = transcripts[session] else { continue }
                let cardName = String(name.dropLast(".json".count))
                let elsewhere = (liveIn[session] ?? []).contains { $0 != source }
                let cut = !elsewhere && (hitSessions.contains(session) || armed.contains(cardName))
                guard cut || live.contains(session) || lastRan[session] == source else { continue }
                var remoteControl = false
                switch SessionSync.owner(of: name, in: owners) {
                case .owned(let dataDir, _)?:
                    guard dataDir == sourcePath else { continue }
                    remoteControl = true
                case .ambiguous(let dataDirs)?:
                    guard dataDirs.contains(sourcePath) else { continue }
                    remoteControl = true
                case nil:
                    break
                }
                let folders = summary.folder.map { $0.contains(SessionSync.scratchFolder) ? [] : [$0] } ?? []
                let item = HandoverSession(
                    card: cardName, transcript: session, title: summary.title, folders: folders, cut: cut, asCopy: working.contains(session),
                    lastActivity: ConversationIndex.lastActivity(of: transcript) ?? .distantPast, armed: armed.contains(cardName))
                found.append(HandoverCandidate(session: item, remoteControl: remoteControl))
            }
        }
        return found.sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// "ROBIN is at its limit until 19:10. No window has room: PAY frees up at 20:00."
    func noRoomLine(source: ProfileStatus, statuses: [ProfileStatus], now: Date) -> String {
        let until = source.limits.binding(now: now)?.reset.map { " until " + HandoverText.untilText($0.at, now: now, timeZone: .current, locale: .current) }
        let soonest =
            statuses.filter { $0.id != source.id && $0.isSignedIn }
            .compactMap { status in status.limits.binding(now: now)?.reset.map { (status, $0.at) } }
            .min { $0.1 < $1.1 }
        let frees = soonest.map { ": \($0.0.displayLabel) frees up \(LimitText.time($0.1, now: now))" } ?? ""
        return "\(source.displayLabel) is at its limit\(until ?? ""). No window has room\(frees)."
    }

    /// Hands the work `plan` describes over: closes the source if nothing is live there (otherwise its live sessions
    /// continue as copies), turns its auto-continue off for the sessions that go, carries their pins and groups,
    /// seeds Claude's own auto-continue in the destination, opens it and shows each session to resume until Claude
    /// continues it. A busy destination is never interrupted and never sent a link: the handover waits
    /// (`finishWaitingHandover`) and says so. Nothing is imported by link.
    /// - Parameters:
    ///   - dwell: seconds each session stays on screen; by default 25 when Claude resumes them, 3 when it can't.
    ///   - lastWait: seconds to wait for the last sessions after the last is shown.
    public func handOver(
        _ plan: HandoverPlan, dwell: Double? = nil, lastWait: Double = 60, progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HandoverResult {
        try ensureWritable()
        let now = Date()
        var result = HandoverResult(plan: plan, state: .picksUpItself)
        guard !plan.picksUpItself else { return finished(result, entry: nil) }
        var plan = plan
        let sourceDir = dataDir(of: plan.source), destinationDir = dataDir(of: plan.destination)
        guard let sourceAccount = DesktopData.accountID(in: sourceDir), DesktopData.accountID(in: destinationDir) != nil else {
            throw ProfileError.notSignedIn(displayLabel(of: plan.destination))
        }
        let log = HandoverLog(paths: paths)
        // Held until this returns: another Baton leaves this handover alone meanwhile, and takes it up if it stops.
        guard let working = try log.working(source: plan.source) else { throw HandoverError.inProgress(displayLabel(of: plan.source)) }
        defer { working.release() }
        var entry = HandoverLog.Entry(
            source: plan.source, resetsAt: plan.resetsAt, destination: plan.destination,
            startedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), state: "starting",
            sessions: plan.sessions.count, seeding: plan.seeding, cards: plan.sessions.map(\.card))
        // One handover per episode, even when the app and the CLI start one at the same moment. A move by hand is
        // asked for, so it runs anyway, and still counts as this limit's handover.
        if plan.byHand {
            try log.save(entry, now: now)
        } else {
            guard try log.claim(entry, now: now) else { throw HandoverError.alreadyHandedOver(displayLabel(of: plan.source)) }
        }

        // 1. The source: closed when nothing works there, so every session moves as itself; otherwise its working
        // sessions continue as copies and its turn-offs wait until it closes (D1). A session open in a `claude` Baton
        // can't place stays live after the source quits, so it continues as a copy too; a source asked to quit that
        // stays open (Claude asked something) keeps every live session, so each continues as a copy.
        progress("Closing \(displayLabel(of: plan.source))…")
        let liveBefore = liveSessions(in: plan.source)
        let sourceBusy = activity(of: plan.source).isBusy
        let sourceClosed = sourceBusy ? false : await quitWindow(plan.source)
        entry.sourceClosed = sourceClosed
        plan.sourceActivity = sourceClosed ? .closed : activity(of: plan.source)
        let live =
            sourceClosed
            ? liveBefore.intersection(liveSessionIDs?() ?? LiveSessions.ids(claudeDir: paths.claudeDir))
            : sourceBusy ? workingSessions(in: plan.source) : liveSessions(in: plan.source)
        // Copies an earlier handover of this episode made before it stopped are used again, so no second card appears.
        let earlier =
            log.entries().last {
                $0.state == HandoverLog.restarted && $0.destination == plan.destination
                    && HandoverLog.same($0, source: plan.source, resetsAt: plan.resetsAt, now: now)
            }?.copies ?? [:]
        for i in plan.sessions.indices {
            plan.sessions[i].asCopy = live.contains(plan.sessions[i].transcript) || earlier[plan.sessions[i].card] != nil
        }
        if sourceClosed {
            do { _ = try localOnly.reconcile(window: plan.source) } catch {
                Log.error("handover", "Local only in window \(plan.source): \(error.localizedDescription)")
            }
        }

        // The copies, each with its own card in the destination, without Remote Control's keys. A session whose copy
        // fails stays in the source, untouched: the original must not continue in two windows.
        var renamed: [String: String] = [:]
        var shown: [String: String] = [:]
        var notCopied: [HandoverSession] = []
        var copies: [String: String] = [:]
        for session in plan.sessions where session.asCopy {
            do {
                let copy =
                    try reusedHandoverCopy(earlier[session.card], in: plan.destination)
                    ?? makeHandoverCopy(session, from: plan.source, into: plan.destination)
                renamed[session.card] = copy.card
                shown[session.transcript] = copy.transcript
                copies[session.card] = copy.transcript
            } catch {
                notCopied.append(session)
                Log.error("handover", "Couldn't copy a session still open in window \(plan.source): \(error.localizedDescription)")
                continue
            }
            // Noted at once, so a handover taken up after a stop here uses the copy again.
            entry.copies = copies
            do { try log.save(entry, now: now) } catch {
                Log.error("handover", "Couldn't note a copy in the handover log: \(error.localizedDescription)")
            }
        }
        let failed = Set(notCopied.map(\.card))
        plan.sessions.removeAll { failed.contains($0.card) }

        // A cut session whose auto-continue stays on in a source that stays open would continue there at its reset
        // too, so it isn't resumed in the destination: the source continues it then, and its entry stays on. One
        // still running there keeps running; its copy is in the destination but never seeded or resumed.
        let armed = AutoResume.armedEntries(in: sourceDir, account: sourceAccount, now: now) ?? []
        let armedCards = Set(armed.map(\.key))
        var later = Set<String>(), running = Set<String>()
        for i in plan.sessions.indices {
            plan.sessions[i].armed = armedCards.contains(plan.sessions[i].card)
            guard !sourceClosed, plan.sessions[i].cut, plan.sessions[i].armed else { continue }
            plan.sessions[i].cut = false
            if renamed[plan.sessions[i].card] != nil { running.insert(plan.sessions[i].card) } else { later.insert(plan.sessions[i].card) }
        }
        plan.leftovers.removeAll {
            switch $0 {
            case .copies, .resumeInSource, .keepRunningInSource: true
            default: false
            }
        }
        if !running.isEmpty { plan.leftovers.append(.keepRunningInSource(count: running.count)) }
        if renamed.count > running.count { plan.leftovers.append(.copies(count: renamed.count - running.count)) }
        if !later.isEmpty { plan.leftovers.append(.resumeInSource(count: later.count)) }
        if !notCopied.isEmpty { plan.leftovers.append(.notMoved(titles: notCopied.map(\.title))) }

        let handed = Set(plan.sessions.map(\.card))
        for armedEntry in armed where handed.contains(armedEntry.key) && !later.contains(armedEntry.key) && !running.contains(armedEntry.key) {
            do {
                if sourceClosed {
                    try autoResume.turnOff(armedEntry, window: plan.source, account: sourceAccount, now: now)
                } else {
                    try autoResume.addPending(armedEntry, window: plan.source, account: sourceAccount, now: now)
                }
            } catch {
                Log.error("handover", "Auto-continue in window \(plan.source): \(error.localizedDescription)")
            }
        }

        do { _ = try prepareSessionsForLaunch() } catch {
            Log.error("handover", "Sessions weren't all shared: \(error.localizedDescription)")
        }
        let sharedAt = Date()
        noteCardsShared(into: [destinationDir.standardizedFileURL.path], at: sharedAt)
        entry.sharedAt = sharedAt

        // What the destination gets when it starts.
        let sourceScope = sidebarScope(sourceDir)
        let slice = sourceScope.flatMap { SidebarLayout.read(dataDir: sourceDir, scope: $0) }?.slice(cards: handed, renamed: renamed)
        let cut = plan.cut
        let show = cut.map { shown[$0.transcript] ?? $0.transcript }
        var titles: [String: String] = [:]
        for session in cut { titles[shown[session.transcript] ?? session.transcript] = session.title }
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        var lengths: [String: UInt64] = [:]
        for session in show { lengths[session] = transcripts[session.lowercased()].map(Self.transcriptSize) ?? 0 }
        entry.pending = HandoverLog.Pending(
            slice: slice.map(SidebarLayoutData.init), seed: cut.map { renamed[$0.card] ?? $0.card }, show: show, titles: titles,
            sourceCut: cut.map(\.card), sourceShow: cut.map(\.transcript), lengths: lengths)
        entry.leftovers = plan.leftovers
        entry.sessions = plan.sessions.count
        result.plan = plan
        result.sourceClosed = sourceClosed
        // Ready for the destination: from here on, a handover stopped by Ctrl-C or a crash is finished from the log.
        entry.state = "waiting"
        try log.save(entry)

        // 2. The destination: started now if closed or idle; a busy one restarts once nothing works there.
        var activity = activity(of: plan.destination)
        if activity == .idle, await quitWindow(plan.destination) { activity = .closed }
        guard activity == .closed else {
            result.state = .waiting
            result = finished(result, entry: &entry)
            try log.save(entry)
            Log.notice("handover", "Window \(plan.destination) is busy; the handover from \(plan.source) waits for it")
            return result
        }
        return try await finishHandover(entry, result: result, dwell: dwell, lastWait: lastWait, progress: progress)
    }

    /// Finishes the handover of `source` that waits for a busy destination: checks every `poll` seconds, and once
    /// nothing works there, restarts it with what the handover prepared. If the source's limit resets first, the work
    /// continues in the source instead. Returns `nil` when no handover of `source` is waiting.
    public func finishWaitingHandover(
        source: String, poll: Double = 10, dwell: Double? = nil, lastWait: Double = 60, now: @escaping @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HandoverResult? {
        try ensureWritable()
        let log = HandoverLog(paths: paths)
        guard log.waiting(source: source) != nil else { return nil }
        guard let working = try log.working(source: source) else { throw HandoverError.inProgress(displayLabel(of: source)) }
        defer { working.release() }
        while true {
            guard let entry = log.waiting(source: source) else { return nil }
            var result = HandoverResult(plan: storedPlan(entry), state: .waiting, sourceClosed: entry.sourceClosed)
            if let reset = entry.resetsAt, now() >= reset {
                return try await cancelHandover(entry, result: result, dwell: dwell, lastWait: lastWait)
            }
            var activity = activity(of: entry.destination)
            if activity == .idle, await quitWindow(entry.destination) { activity = .closed }
            if activity == .closed {
                result.plan.destinationActivity = .closed
                return try await finishHandover(entry, result: result, dwell: dwell, lastWait: lastWait, progress: progress)
            }
            try await Task.sleep(for: .seconds(poll))
        }
    }

    /// Checks the source every `poll` seconds until `until` and quits it as soon as nothing is live there, never
    /// forcing it; then turns off the auto-continue entries the handover left on there.
    /// - Returns: whether the source was closed.
    public func closeSourceWhenFree(
        _ source: String, until: Date, poll: Double = 10, now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> Bool {
        try ensureWritable()
        while now() < until {
            if !activity(of: source).isBusy, await quitWindow(source) {
                let applied = autoResume.applyPending()
                Log.notice("handover", "Closed window \(source) once nothing worked there; turned off auto-continue in \(applied.count) window(s)")
                return true
            }
            try await Task.sleep(for: .seconds(poll))
        }
        return false
    }

    /// Closes the source of `source`'s latest unfinished handover once nothing works there, if Baton couldn't close
    /// it at the handover: checks every `poll` seconds until its reset (`closeSourceWhenFree`) and notes it in the log.
    /// - Returns: whether the source is closed now; `false` also when nothing needed watching.
    public func watchHandoverSource(_ source: String, poll: Double = 10, now: @escaping @Sendable () -> Date = { Date() }) async throws -> Bool {
        let log = HandoverLog(paths: paths)
        guard let entry = log.unfinished(source: source, now: now()).last, !entry.sourceClosed, let reset = entry.resetsAt else { return false }
        guard try await closeSourceWhenFree(source, until: reset, poll: poll, now: now) else { return false }
        if var latest = log.entries().last(where: { $0.source == source && $0.startedAt == entry.startedAt }) {
            latest.sourceClosed = true
            try log.save(latest)
        }
        return true
    }

    /// Takes up a handover of `source` that stopped while it started (Ctrl-C or a crash while it closed the source or
    /// made copies), before anything was ready for its destination: puts back the auto-continue it turned off in the
    /// source and drops the turn-offs it left waiting, so its sessions are cut again, then marks it restarted, so the
    /// episode is handed over afresh. The copies it made are used again by that handover (`HandoverLog.Entry.copies`),
    /// even with the source closed since, so no second card appears.
    /// - Returns: that handover's destination, or `nil` when no handover of `source` stopped that way.
    public func restartStoppedHandover(source: String) throws -> String? {
        try ensureWritable()
        let log = HandoverLog(paths: paths)
        guard let working = try log.working(source: source) else { throw HandoverError.inProgress(displayLabel(of: source)) }
        defer { working.release() }
        guard let entry = log.entries().last(where: { $0.source == source && $0.state == "starting" }) else { return nil }
        let cards = Set(entry.cards ?? [])
        autoResume.dropPending(window: source, entries: cards)
        for change in autoResume.changes()
        where change.window == source && change.action == .turnedOff && change.changedAt >= entry.startedAt && cards.contains(change.entry) {
            do { _ = try autoResume.undo(change) } catch {
                Log.error("handover", "Couldn't put back auto-continue in window \(source): \(error.localizedDescription)")
            }
        }
        var restarted = entry
        restarted.state = HandoverLog.restarted
        restarted.finishedAt = Date()
        try log.save(restarted)
        Log.notice("handover", "Starting over the handover from window \(source) that stopped before its destination was ready")
        return entry.destination
    }

    // MARK: Steps

    /// Opens the closed destination with the layout and the seeded entries written first, shows each session to
    /// resume, and composes the line.
    private func finishHandover(
        _ stored: HandoverLog.Entry, result: HandoverResult, dwell: Double?, lastWait: Double, progress: @escaping @Sendable (String) -> Void
    ) async throws -> HandoverResult {
        var entry = stored, result = result
        let destination = entry.destination, destinationDir = dataDir(of: destination)
        let pending = entry.pending ?? HandoverLog.Pending(slice: nil, seed: [], show: [], titles: [:], sourceCut: [], sourceShow: [])
        let destinationAccount = DesktopData.accountID(in: destinationDir) ?? ""
        let sourceAccount = DesktopData.accountID(in: dataDir(of: entry.source))
        let seeding = entry.seeding
        // A session that continued since the handover prepared it (before an interrupt, or by the user's hand) counts
        // as resumed and is neither seeded nor shown again.
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        let continued = pending.show.filter { session in
            guard let before = pending.lengths?[session] else { return false }
            return (transcripts[session.lowercased()].map(Self.transcriptSize) ?? 0) > before
        }
        let seed = zip(pending.seed, pending.show).filter { !continued.contains($0.1) }.map(\.0)
        let prepared = PrepareOutcome()
        let scope = sidebarScope(destinationDir)
        let paths = paths, autoResume = autoResume, source = entry.source
        progress("Opening \(displayLabel(of: destination))…")
        do {
            try await open(destination, links: []) {
                prepared.setRan()
                if let slice = pending.slice?.layout, let scope {
                    do {
                        let report = try SidebarLayout.carry(
                            slice, into: destinationDir, scope: scope, account: destinationAccount, backup: Backup(paths: paths, now: Date()),
                            now: Date())
                        prepared.set(ungrouped: report.ungrouped)
                    } catch {
                        prepared.set(failure: error.localizedDescription)
                    }
                }
                if seeding == .seed, !seed.isEmpty {
                    do {
                        _ = try autoResume.seed(
                            seed.map { AutoResumeEntry(key: $0, resetsAt: Date()) }, window: destination, account: destinationAccount,
                            source: sourceAccount.map { (source, $0) })
                    } catch {
                        Log.error("handover", "Couldn't seed auto-continue in window \(destination): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            entry.state = "failed"
            result.state = .failed
            result.failure = error.localizedDescription
            result = finished(result, entry: &entry)
            try HandoverLog(paths: paths).save(entry)
            return result
        }
        for (group, count) in prepared.ungrouped.sorted(by: { $0.key < $1.key }) {
            result.plan.leftovers.append(.ungrouped(count: count, group: group))
        }
        if let failure = prepared.failure {
            result.plan.leftovers.append(.layoutNotCarried(failure))
        } else if !prepared.ran, pending.slice != nil {
            result.plan.leftovers.append(.layoutNotCarried("\(displayLabel(of: destination)) started by itself first"))
        }

        // A session without its card in the destination would be imported by its link under a new card: named instead.
        let cards = cardsBySession(in: destinationDir)
        let title = { (session: String) in pending.titles[session] ?? session }
        let toShow = pending.show.filter { !continued.contains($0) }
        let missing = toShow.filter { cards[$0.lowercased()] == nil }
        if !missing.isEmpty { result.plan.leftovers.append(.notMoved(titles: missing.map(title))) }
        let order = showOrder(toShow.filter { cards[$0.lowercased()] != nil }, in: destinationDir)
        var shown = ShowInTurn.Result()
        if !order.isEmpty {
            progress("Resuming \(order.count) session\(order.count == 1 ? "" : "s") in \(displayLabel(of: destination))…")
            do {
                shown = try await showInTurn(
                    destination, sessions: order, sharedAt: entry.sharedAt, dwell: dwell ?? (seeding == .seed ? 25 : 3), lastWait: lastWait,
                    done: resumeWatch(order, in: destination))
            } catch {
                shown.notResumed = order
                shown.failure = error.localizedDescription
            }
        }
        result.resumed = continued
        if seeding == .seed {
            result.resumed += shown.resumed
            result.notResumed = shown.notResumed
            if !shown.notResumed.isEmpty { result.plan.leftovers.append(.notResumed(titles: shown.notResumed.map(title))) }
        } else {
            result.notResumed = order
            if !order.isEmpty { result.plan.leftovers.append(.cannotResume(titles: order.map(title))) }
        }
        entry.resumed = result.resumed
        entry.leftovers = result.plan.leftovers
        entry.state = "done"
        entry.pending = nil
        result.state = .done
        result = finished(result, entry: &entry)
        try HandoverLog(paths: paths).save(entry)
        Log.notice("handover", "Handed window \(entry.source)'s work to \(destination): \(result.resumed.count) resumed")
        return result
    }

    /// The source's limit reset before the destination was free: Baton's turn-offs in the source are put back, the
    /// pending ones dropped, and the source continues its own work, reopened if Baton closed it.
    private func cancelHandover(_ stored: HandoverLog.Entry, result: HandoverResult, dwell: Double?, lastWait: Double) async throws -> HandoverResult {
        var entry = stored, result = result
        let source = entry.source, sourceDir = dataDir(of: source)
        let pending = entry.pending
        let cut = Set(pending?.sourceCut ?? [])
        autoResume.dropPending(window: source, entries: cut)
        for change in autoResume.changes()
        where change.window == source && change.action == .turnedOff && change.changedAt >= entry.startedAt && cut.contains(change.entry) {
            do { try autoResume.undo(change) } catch {
                Log.error("handover", "Couldn't put back auto-continue in window \(source): \(error.localizedDescription)")
            }
        }
        result.state = .resetFirst
        // The copies already written into the destination stay there; nothing else of the plan happened.
        let copies = result.plan.leftovers.reduce(0) { total, leftover in
            switch leftover {
            case .copies(let count), .keepRunningInSource(let count): total + count
            default: total
            }
        }
        result.plan.leftovers = copies > 0 ? [.copiesStay(count: copies)] : []
        if entry.sourceClosed, activity(of: source) == .closed, let pending, !pending.sourceCut.isEmpty {
            let account = DesktopData.accountID(in: sourceDir) ?? ""
            let autoResume = autoResume
            do {
                try await open(source, links: []) {
                    do {
                        _ = try autoResume.seed(pending.sourceCut.map { AutoResumeEntry(key: $0, resetsAt: Date()) }, window: source, account: account)
                    } catch {
                        Log.error("handover", "Couldn't seed auto-continue in window \(source): \(error.localizedDescription)")
                    }
                }
                let order = showOrder(pending.sourceShow, in: sourceDir)
                let shown = try await showInTurn(
                    source, sessions: order, sharedAt: entry.sharedAt, dwell: dwell ?? 25, lastWait: lastWait, done: resumeWatch(order, in: source))
                result.resumed = shown.resumed
                result.notResumed = shown.notResumed
                if !shown.notResumed.isEmpty {
                    result.plan.leftovers.append(.notResumed(titles: shown.notResumed.map { pending.titles[$0] ?? $0 }))
                }
            } catch {
                Log.error("handover", "Couldn't reopen window \(source): \(error.localizedDescription)")
            }
        }
        entry.state = "cancelled"
        entry.pending = nil
        entry.resumed = result.resumed
        result = finished(result, entry: &entry)
        try HandoverLog(paths: paths).save(entry)
        return result
    }

    /// The copy `copy` (a session id) an earlier handover made in `destination`, while its card and transcript are
    /// still there.
    func reusedHandoverCopy(_ copy: String?, in destination: String) -> (card: String, transcript: String)? {
        guard let copy, ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)[copy.lowercased()] != nil else { return nil }
        let name = "local_" + copy
        guard cardFolders(in: dataDir(of: destination)).contains(where: { FileManager.default.fileExists(atPath: $0.appending(path: name + ".json").path) })
        else { return nil }
        return (name, copy)
    }

    /// A copy of a session still open in `source`, as `continueAll` makes one, with a card of its own in the
    /// destination: the source's card without Remote Control's keys, pointing at the copy.
    func makeHandoverCopy(_ session: HandoverSession, from source: String, into destination: String) throws -> (card: String, transcript: String) {
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        guard let transcript = transcripts[session.transcript] else { throw CocoaError(.fileNoSuchFile) }
        let copies = ContinueCopies(paths: paths)
        let copy: String
        if let reused = copies.existingCopy(of: session.transcript, transcript: transcript, in: destination) {
            copy = reused
        } else {
            let conversation = Conversation(
                kind: .code, sessionID: session.transcript, title: session.title, folders: session.folders, lastActivity: session.lastActivity,
                transcript: transcript)
            let made = try TranscriptFork.forkReporting(conversation, claudeDir: paths.claudeDir, tempDir: paths.claudeTempDir)
            copy = made.id
            try? copies.record(
                source: session.transcript, destination: destination, copy: made.id, sourceLength: made.sourceLength, sourceTail: made.sourceTail)
        }
        let sourceDir = dataDir(of: source), destinationDir = dataDir(of: destination)
        guard
            let original = cardFolders(in: sourceDir).lazy.map({ $0.appending(path: session.card + ".json") }).first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }),
            var card = ConversationIndex.readCard(original)
        else { throw CocoaError(.fileNoSuchFile) }
        for key in SessionSync.remoteControlKeys { card.removeValue(forKey: key) }
        let name = "local_" + copy
        card["cliSessionId"] = copy
        if card["sessionId"] != nil { card["sessionId"] = name }
        card["title"] = ConversationIndex.title(of: card) + " · from \(label(of: source))"
        guard
            let folder = sidebarScope(destinationDir).map({ destinationDir.appending(path: "\(SessionSync.sessionsFolder)/\($0)", directoryHint: .isDirectory) }
            )
                ?? cardFolders(in: destinationDir).first
        else { throw ProfileError.notSignedIn(displayLabel(of: destination)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: name + ".json")
        if !FileManager.default.fileExists(atPath: target.path) {
            try JSONSerialization.data(withJSONObject: card, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: target, options: .atomic)
        }
        Log.notice("handover", "Copied a session still open in window \(source) into window \(destination)")
        return (name, copy)
    }

    /// Unpinned sessions first, least recently active first, then pinned ones up to the top pin of the window at
    /// `dataDir` (`ShowInTurn.order`).
    func showOrder(_ sessions: [String], in dataDir: URL) -> [String] {
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        let layout = sidebarScope(dataDir).flatMap { SidebarLayout.read(dataDir: dataDir, scope: $0) }
        let cardOf = cardsBySession(in: dataDir)
        let items = sessions.map { session in
            ShowInTurn.Item(
                session: session, lastActivity: transcripts[session].flatMap(ConversationIndex.lastActivity(of:)) ?? .distantPast,
                pinRank: cardOf[session.lowercased()].flatMap { layout?.pinnedOrder.firstIndex(of: "code:" + $0) })
        }
        return ShowInTurn.order(items)
    }

    /// The window's cards (`local_<id>`) by the session each points at.
    func cardsBySession(in dataDir: URL) -> [String: String] {
        var cardOf: [String: String] = [:]
        for folder in cardFolders(in: dataDir) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                if let session = AutoResume.cliSessionID(inCard: folder.appending(path: name)) { cardOf[session.lowercased()] = String(name.dropLast(5)) }
            }
        }
        return cardOf
    }

    /// The `account/organization` scope Claude files the window's sidebar under, when it can be told.
    func sidebarScope(_ dataDir: URL) -> String? {
        let storage = LocalStorage(dataDir: dataDir)
        let items = storage.exists ? ((try? storage.items(origin: InterfaceSync.origin)) ?? [:]) : [:]
        return DesktopData.scope(dataDir: dataDir, items: items)?.value
    }

    /// A plan rebuilt from a log entry.
    func storedPlan(_ entry: HandoverLog.Entry) -> HandoverPlan {
        let pending = entry.pending
        let sessions = (pending?.show ?? []).map { session in
            HandoverSession(card: "", transcript: session, title: pending?.titles[session] ?? session, cut: true, asCopy: false, lastActivity: .distantPast)
        }
        return HandoverPlan(
            source: entry.source, destination: entry.destination, resetsAt: entry.resetsAt, sessions: sessions, sourceActivity: .closed,
            destinationActivity: .busy(working: 0), seeding: entry.seeding, leftovers: entry.leftovers)
    }

    private func finished(_ result: HandoverResult, entry: HandoverLog.Entry?) -> HandoverResult {
        var result = result
        result.line = HandoverText.line(result, labels: { self.displayLabel(of: $0) })
        result.isWarning = HandoverText.isWarning(result)
        return result
    }

    private func finished(_ result: HandoverResult, entry: inout HandoverLog.Entry) -> HandoverResult {
        let result = finished(result, entry: nil)
        entry.line = result.line
        if result.state != .waiting { entry.finishedAt = Date() }
        return result
    }
}

/// What the prepare step inside `open` found, read after it.
private final class PrepareOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [String: Int] = [:]
    private var reason: String?
    private var didRun = false

    /// Whether the prepare step ran: a window that started by itself meanwhile skips it.
    var ran: Bool { lock.withLock { didRun } }
    func setRan() { lock.withLock { didRun = true } }
    var ungrouped: [String: Int] { lock.withLock { groups } }
    var failure: String? { lock.withLock { reason } }
    func set(ungrouped: [String: Int]) { lock.withLock { groups = ungrouped } }
    func set(failure: String) { lock.withLock { reason = failure } }
}

// MARK: - For `baton handover --json`

/// A plan or a result as `baton handover --json` prints it.
public struct HandoverSummary: Encodable, Equatable {
    public struct Session: Encodable, Equatable {
        var card: String
        var session: String
        var title: String
        var folders: [String]
        var resumes: Bool
        var asCopy: Bool
    }

    var source: String
    var destination: String
    var resetsAt: Date?
    var seeding: String
    var sessions: [Session]
    var leftovers: [String]
    var state: String?
    var line: String?
    var sourceClosed: Bool?
    var resumed: [String]?
    var notResumed: [String]?

    public init(plan: HandoverPlan, labels: (String) -> String) {
        let source = labels(plan.source), destination = labels(plan.destination)
        self.source = source
        self.destination = destination
        resetsAt = plan.resetsAt
        seeding = plan.seeding.rawValue
        let later = Set(plan.resumeInSource.map(\.card))
        sessions = plan.sessions.map {
            Session(
                card: $0.card, session: $0.transcript, title: $0.title, folders: $0.folders, resumes: $0.cut && !later.contains($0.card),
                asCopy: $0.asCopy)
        }
        let at = plan.resetsAt.map { LimitText.time($0) }
        leftovers = plan.leftovers.compactMap { HandoverText.clause($0, source: source, destination: destination, at: at) }
        if plan.picksUpItself { state = HandoverResult.State.picksUpItself.rawValue }
    }

    public init(result: HandoverResult, labels: (String) -> String) {
        self.init(plan: result.plan, labels: labels)
        state = result.state.rawValue
        line = result.line
        sourceClosed = result.sourceClosed
        resumed = result.resumed
        notResumed = result.notResumed
    }
}
