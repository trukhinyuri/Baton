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
    /// A Claude Code process of it runs in the window at its limit, so a copy continues instead of the session itself.
    public var asCopy: Bool
    /// Its last message, for the order sessions are shown in.
    public var lastActivity: Date

    public init(card: String, transcript: String, title: String, folders: [String] = [], cut: Bool, asCopy: Bool, lastActivity: Date) {
        self.card = card; self.transcript = transcript.lowercased(); self.title = title; self.folders = folders
        self.cut = cut; self.asCopy = asCopy; self.lastActivity = lastActivity
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
    /// The reset is minutes away: the window continues its own work then, and nothing is handed over.
    public var picksUpItself = false

    /// Sessions that resume in the destination.
    public var cut: [HandoverSession] { sessions.filter(\.cut) }
}

/// What a handover did.
public struct HandoverResult: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The work continues in the destination.
        case done
        /// The destination is busy and restarts once nothing works there (`finishWaitingHandover`).
        case waiting
        /// The reset is minutes away; nothing was done.
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

    public var errorDescription: String? {
        switch self {
        case .notAtLimit(let label): "\(label) isn't at its limit, so its work stays there."
        case .alreadyHandedOver(let label): "\(label)'s work for this limit was handed over already."
        case .noRoom(let line): line
        case .sameWindow(let label): "\(label) is the window at its limit; choose another one."
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
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var source: String
        public var resetsAt: Date?
        public var destination: String
        public var startedAt: Date
        public var finishedAt: Date?
        /// waiting, done, cancelled or failed.
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

    public init(paths: Paths) { file = paths.stateDir.appending(path: "handovers.json") }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.handovers.decode(State.self, from: data))?.entries ?? []
    }

    /// Whether the work of `source` at the limit that resets at `resetsAt` was handed over already, or is being.
    public func handled(source: String, resetsAt: Date?, now: Date = Date()) -> Bool {
        entries().contains { entry in
            guard entry.source == source else { return false }
            switch (entry.resetsAt, resetsAt) {
            case (let a?, let b?): return abs(a.timeIntervalSince(b)) <= Self.sameEpisode
            case (nil, nil): return now.timeIntervalSince(entry.startedAt) < LimitKind.fiveHour.window
            default: return false
            }
        }
    }

    /// The handover of `source` waiting for its destination, if any.
    public func waiting(source: String) -> Entry? { entries().last { $0.source == source && $0.state == "waiting" } }

    /// Every handover waiting for its destination.
    public func waiting() -> [Entry] { entries().filter { $0.state == "waiting" } }

    /// Adds `entry`, or replaces the one for the same source started at the same moment.
    func save(_ entry: Entry, now: Date = Date()) throws {
        var state = State()
        state.entries = entries().filter {
            !($0.source == entry.source && abs($0.startedAt.timeIntervalSince(entry.startedAt)) < 1) && now.timeIntervalSince($0.startedAt) < Self.keep
        }
        state.entries.append(entry)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.handovers.encode(state).write(to: file, options: .atomic)
    }
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
        let head: String
        switch result.state {
        case .picksUpItself:
            return "\(source) is at its limit\(until) and picks its work up by itself then."
        case .resetFirst:
            head = "\(source)'s limit reset before \(destination) was free, so your work continues in \(source)\(resumedText)"
        case .waiting:
            head = "\(source) is at its limit\(until)\(closed) \(destination) restarts when its current work finishes"
        case .failed:
            head =
                "\(source) is at its limit\(until)\(closed) \(destination) didn't open: \(trimmed(result.failure ?? "unknown error")). "
                + "Your sessions are there when you open it"
        case .done:
            head = "\(source) is at its limit\(until)\(closed) Your work continues in \(destination)\(resumedText)"
        }
        let clauses = result.state == .picksUpItself ? [] : plan.leftovers.compactMap { clause($0, source: source, destination: destination) }
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
    public static func clause(_ leftover: HandoverLeftover, source: String, destination: String) -> String? {
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

    func planHandover(from source: String, to destination: String?, statuses: [ProfileStatus], now: Date) throws -> HandoverPlan {
        let label = displayLabel(of: source)
        guard let status = statuses.first(where: { $0.id == source }) else { throw ProfileError.notFound(source) }
        guard let sourceAccount = status.accountID else { throw ProfileError.notSignedIn(label) }
        guard DestinationRanking.isAtLimit(status, now: now) else { throw HandoverError.notAtLimit(label) }
        let resetsAt = status.limits.binding(now: now)?.reset?.at
        let sourceActivity = activity(of: source)
        if let resetsAt, resetsAt.timeIntervalSince(now) <= AutoResumeOffer.within {
            return HandoverPlan(
                source: source, destination: source, resetsAt: resetsAt, sessions: [], sourceActivity: sourceActivity,
                destinationActivity: sourceActivity, seeding: .seed, leftovers: [], picksUpItself: true)
        }
        guard !HandoverLog(paths: paths).handled(source: source, resetsAt: resetsAt, now: now) else {
            throw HandoverError.alreadyHandedOver(label)
        }

        var leftovers: [HandoverLeftover] = []
        var candidates = handoverCandidates(source: source, account: sourceAccount, resetsAt: resetsAt, now: now)
        let remoteControl = candidates.filter(\.remoteControl).count
        candidates.removeAll(where: \.remoteControl)
        let rules = try FolderRules(paths: paths).load()
        let allowed = candidates.map { FolderRules.allowedAccounts(for: $0.session.folders, in: rules) }

        let target: String
        if let destination {
            guard destination != source else { throw HandoverError.sameWindow(label) }
            guard let chosen = statuses.first(where: { $0.id == destination }) else { throw ProfileError.notFound(destination) }
            guard chosen.isSignedIn else { throw ProfileError.notSignedIn(displayLabel(of: destination)) }
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
        let copies = sessions.filter(\.asCopy).count
        if copies > 0 { leftovers.append(.copies(count: copies)) }
        let cowork = ConversationIndex.scan(paths: paths, windows: windows).filter {
            $0.kind == .cowork && $0.ownerID == source && now.timeIntervalSince($0.lastActivity) < LimitKind.fiveHour.window
        }.count
        if cowork > 0 { leftovers.append(.coworkStays(count: cowork)) }
        let destinationAccount = targetStatus?.accountID ?? DesktopData.accountID(in: dataDir(of: target)) ?? ""
        let seeding = autoResume.seeding(window: target, account: destinationAccount, source: (source, sourceAccount), now: now)
        return HandoverPlan(
            source: source, destination: target, resetsAt: resetsAt, sessions: sessions, sourceActivity: sourceActivity,
            destinationActivity: activity(of: target), seeding: seeding, leftovers: leftovers)
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
        let live = liveSessions(in: source)
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
                    card: cardName, transcript: session, title: summary.title, folders: folders, cut: cut, asCopy: live.contains(session),
                    lastActivity: ConversationIndex.lastActivity(of: transcript) ?? .distantPast)
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
        var entry = HandoverLog.Entry(
            source: plan.source, resetsAt: plan.resetsAt, destination: plan.destination,
            startedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), state: "waiting",
            sessions: plan.sessions.count, seeding: plan.seeding)
        try log.save(entry, now: now)

        // 1. The source: closed when nothing is live there, so every session moves as itself; otherwise its live
        // sessions continue as copies and its turn-offs wait until it closes.
        progress("Closing \(displayLabel(of: plan.source))…")
        let sourceClosed = activity(of: plan.source).isBusy ? false : await quitWindow(plan.source)
        entry.sourceClosed = sourceClosed
        let live = sourceClosed ? [] : liveSessions(in: plan.source)
        for i in plan.sessions.indices { plan.sessions[i].asCopy = live.contains(plan.sessions[i].transcript) }
        plan.leftovers.removeAll { if case .copies = $0 { return true } else { return false } }
        let copies = plan.sessions.filter(\.asCopy).count
        if copies > 0 { plan.leftovers.append(.copies(count: copies)) }
        if sourceClosed {
            do { _ = try localOnly.reconcile(window: plan.source) } catch {
                Log.error("handover", "Local only in window \(plan.source): \(error.localizedDescription)")
            }
        }
        let handed = Set(plan.sessions.map(\.card))
        for armed in (AutoResume.armedEntries(in: sourceDir, account: sourceAccount, now: now) ?? []) where handed.contains(armed.key) {
            do {
                if sourceClosed {
                    try autoResume.turnOff(armed, window: plan.source, account: sourceAccount, now: now)
                } else {
                    try autoResume.addPending(armed, window: plan.source, account: sourceAccount, now: now)
                }
            } catch {
                Log.error("handover", "Auto-continue in window \(plan.source): \(error.localizedDescription)")
            }
        }

        // The copies, each with its own card in the destination, without Remote Control's keys.
        var renamed: [String: String] = [:]
        var shown: [String: String] = [:]
        for session in plan.sessions where session.asCopy {
            do {
                let copy = try makeHandoverCopy(session, from: plan.source, into: plan.destination)
                renamed[session.card] = copy.card
                shown[session.transcript] = copy.transcript
            } catch {
                Log.error("handover", "Couldn't copy a session still open in window \(plan.source): \(error.localizedDescription)")
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
        entry.pending = HandoverLog.Pending(
            slice: slice.map(SidebarLayoutData.init), seed: cut.map { renamed[$0.card] ?? $0.card }, show: show, titles: titles,
            sourceCut: cut.map(\.card), sourceShow: cut.map(\.transcript))
        entry.leftovers = plan.leftovers
        result.plan = plan
        result.sourceClosed = sourceClosed

        // 2. The destination: started now if closed or idle; a busy one restarts once nothing works there.
        var activity = activity(of: plan.destination)
        if activity == .idle, await quitWindow(plan.destination) { activity = .closed }
        guard activity == .closed else {
            entry.state = "waiting"
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
        while true {
            guard let entry = HandoverLog(paths: paths).waiting(source: source) else { return nil }
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
        let prepared = PrepareOutcome()
        let scope = sidebarScope(destinationDir)
        let paths = paths, autoResume = autoResume, source = entry.source
        progress("Opening \(displayLabel(of: destination))…")
        do {
            try await open(destination, links: []) {
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
                if seeding == .seed, !pending.seed.isEmpty {
                    do {
                        _ = try autoResume.seed(
                            pending.seed.map { AutoResumeEntry(key: $0, resetsAt: Date()) }, window: destination, account: destinationAccount,
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
        if let failure = prepared.failure { result.plan.leftovers.append(.layoutNotCarried(failure)) }

        let order = showOrder(pending.show, in: destinationDir)
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
        let title = { (session: String) in pending.titles[session] ?? session }
        if seeding == .seed {
            result.resumed = shown.resumed
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
        autoResume.dropPending(window: source, entries: Set(pending?.sourceCut ?? []))
        for change in autoResume.changes() where change.window == source && change.action == .turnedOff && change.changedAt >= entry.startedAt {
            do { try autoResume.undo(change) } catch {
                Log.error("handover", "Couldn't put back auto-continue in window \(source): \(error.localizedDescription)")
            }
        }
        result.state = .resetFirst
        result.plan.leftovers = []
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
        var cardOf: [String: String] = [:]
        for folder in cardFolders(in: dataDir) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                if let session = AutoResume.cliSessionID(inCard: folder.appending(path: name)) { cardOf[session] = String(name.dropLast(5)) }
            }
        }
        let items = sessions.map { session in
            ShowInTurn.Item(
                session: session, lastActivity: transcripts[session].flatMap(ConversationIndex.lastActivity(of:)) ?? .distantPast,
                pinRank: cardOf[session].flatMap { layout?.pinnedOrder.firstIndex(of: "code:" + $0) })
        }
        return ShowInTurn.order(items)
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
            destinationActivity: .busy(live: 0), seeding: entry.seeding, leftovers: entry.leftovers)
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
        sessions = plan.sessions.map {
            Session(card: $0.card, session: $0.transcript, title: $0.title, folders: $0.folders, resumes: $0.cut, asCopy: $0.asCopy)
        }
        leftovers = plan.leftovers.compactMap { HandoverText.clause($0, source: source, destination: destination) }
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
