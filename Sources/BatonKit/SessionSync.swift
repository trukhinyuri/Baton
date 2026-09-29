import CryptoKit
import Foundation

/// Makes Claude Code sessions visible in every profile, whichever account created them.
///
/// Claude Desktop keeps a small index card per Claude Code session under
/// `<data dir>/claude-code-sessions/<account>/<organization>/local_<id>.json`; the conversation itself lives in
/// `~/.claude/projects` and is already shared by all profiles. Copying the cards into every account/organization
/// directory of every profile lets you continue a session from any window.
/// Native Project / Remote Control workers retain their account-and-organization scope; copying a card
/// does not grant access to its server project or bridge. Ambiguous copies made by old releases are preserved.
/// A copy for another account leaves out what the first account granted or connected (Remote Control bridges,
/// connectors, browser and computer-use grants, the session's permission rules, and the permission mode unless the
/// profile keeps it); copies between windows of one account are exact. A grant or rule that copies by older releases
/// left in two accounts is taken out of every copy, since which account gave it can't be told.
/// A card that isn't one whole JSON object, such as one a crash cut short, is never copied.
/// A session deleted in one window stays deleted everywhere, unless a window made a new card for it after that.
///
/// Cards are copied, not symlinked: Claude Desktop creates these directories with `mkdir` and fails on symlinks.
///
/// A window that did not load a card at launch imports the conversation under a new card named after its
/// transcript (`local_<cliSessionId>.json`) when asked to open it. A folder therefore never gets a second card for a
/// transcript it already has a card for, the older copy next to such an imported card is retired, and deleting
/// either card deletes the conversation.
public struct SessionSync: Sendable {
    public struct Report: Equatable, Sendable {
        public var pairs = 0
        public var cardsWritten = 0
        public var cardsRemoved = 0
        public var tombstonesWritten = 0
        /// Older copies retired next to the card a window made when it opened the same conversation.
        public var duplicatesRetired = 0
        public var archiveIndexesWritten = 0
        public var backedUp = 0
        /// Native Project / Remote Control workers shared only within one account and organization.
        public var accountBoundCards = 0
        /// Existing copies in several scopes are preserved without choosing an owner.
        public var ambiguousAccountBoundCards = 0
        /// Cards a folder rule keeps out of an account, not copied there.
        public var withheldByRule = 0
        /// Copies removed from a closed window whose account a folder rule does not allow.
        public var retiredByRule = 0
        /// Copies left as they are because a running `claude` process has their session open.
        public var keptLive = 0
        /// "Session deleted" markers removed after every window had them for 90 days.
        public var tombstonesExpired = 0
        /// "Session deleted" markers removed because a window made a new card for that session after it was deleted.
        public var tombstonesRetired = 0
        /// Copies that had a grant or rule another account's copy held too, which was taken out of them.
        public var grantsRemoved = 0
        /// Copies read to compare with their card. An idle run, in which no card changed, reads none.
        public var cardsCompared = 0
        /// The data folders (standardized paths) that got a session card in this run. A window that was already open
        /// shows those sessions only after a restart.
        public var wroteInto: Set<String> = []
        public var changes: Int {
            cardsWritten + cardsRemoved + tombstonesWritten + duplicatesRetired + archiveIndexesWritten + retiredByRule + tombstonesExpired
                + tombstonesRetired
        }
    }

    static let sessionsFolder = "claude-code-sessions"
    static let tombstoneLifetime: TimeInterval = 90 * 86_400
    static let archiveIndex = "archived-sessions.idx"

    public let paths: Paths
    public let dataDirs: [URL]
    private var fm: FileManager { .default }

    /// Counts what a run would do and writes, moves and removes nothing.
    public var dryRun = false
    /// Whether the window of a data directory is open. `nil`: every window counts as open, unless the run
    /// propagates deletions, which callers do only while no Claude Desktop window is running.
    public var isWindowOpen: (@Sendable (URL) -> Bool)?
    /// Sessions a running `claude` process has open; `nil` reads them as `LiveSessions` does.
    public var liveSessionIDs: Set<String>?
    /// Email of an account signed in to a data directory, for folder rules.
    public var email: @Sendable (URL, String) -> String? = { DesktopData.email(in: $0, accountID: $1) }
    /// Whether copies from other accounts keep `permissionMode` in a data directory's cards: the profile's
    /// “carry permission mode” choice. `nil` reads `carryPermissionMode` from each profile in the registry.
    public var carriesPermissionMode: (@Sendable (URL) -> Bool)?
    /// What each card says, kept while its file stays the same, so an idle run reads none of them again.
    public var cache: ScanCache = .shared

    /// - Parameter dataDirs: every Claude Desktop data directory to keep in sync, main one included.
    public init(paths: Paths, dataDirs: [URL]) {
        self.paths = paths
        self.dataDirs = dataDirs
    }

    /// - Parameter propagateDeletions: also spread "session deleted" markers and drop the deleted cards.
    ///   Do this only while no Claude Desktop window is open; otherwise sync only adds and updates.
    ///
    /// A card of a folder that a folder rule covers goes only to windows whose account the rule allows; an
    /// account whose email can't be read counts as not allowed. Copies made before the rule are retired from
    /// closed windows, with a backup and without a tombstone, once an allowed window has the card.
    @discardableResult
    public func run(propagateDeletions: Bool, now: Date = Date()) throws -> Report {
        var report = Report()
        let rules: [FolderRule]
        do { rules = try FolderRules(paths: paths).load() } catch { throw ProfileError.rulesUnreadable(error.localizedDescription) }
        let pairs = try self.pairs()
        report.pairs = pairs.count

        var cards: [String: Card] = [:]
        var holders: [String: [URL]] = [:]  // card name → folders that have a copy
        var transcriptsByFolder: [String: [String: String]] = [:]  // folder path → card name → transcript
        var importedByFolder: [String: Set<String>] = [:]  // folder path → cards a window imported
        var tombstones = Set<String>()
        var tombstonesByScope: [String: Set<String>] = [:]
        var tombstoneCopies: [String: (count: Int, newest: Date)] = [:]  // marker → folders that have it
        let scopeFile = paths.stateDir.appending(path: "code-native-session-scopes.json")
        let remembered = try NativeScopeState.load(from: scopeFile)
        var cardScopes = remembered.scopes.mapValues(Set.init)
        var accountBound = Set(remembered.scopes.keys)
        var observed = Set<String>()
        var archiveLists: [String: Set<String>] = [:]  // folder path → archived IDs, for folders that have an index
        var archiveVersion: Any = 1
        var reads: [String: CardRead] = [:]  // card file path → what it says
        var deletedAt: [String: Date] = [:]  // marker → when its session was deleted, the latest of its copies
        // Copies found to match their card by an earlier run, in any process; read again only when it changed.
        let matchesFile = paths.stateDir.appending(path: "session-sync-matches.json")
        let savedMatches = cache.value("matches", of: matchesFile, cost: { $0.copies.count * 256 }, read: Matches.load)
        let readsBefore = cache.reads
        var newMatches = false

        for pair in pairs {
            let scope = Self.scope(of: pair)
            // A read error must not look like an empty folder to deletion handling.
            for url in try fm.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                if name.hasPrefix("local_"), name.hasSuffix(".json") {
                    let read = try Self.read(url, cache: cache)
                    if let saved = savedMatches.copies[url.path] { read.restore(saved) }
                    let facts = read.facts
                    reads[url.path] = read
                    observed.insert(name)
                    cardScopes[name, default: []].insert(scope)
                    if facts.accountBound { accountBound.insert(name) }
                    // Not a whole card: it stays where it is, and no copy of it is made or relied on.
                    guard facts.valid else { continue }
                    holders[name, default: []].append(pair)
                    if let transcript = facts.transcript {
                        transcriptsByFolder[pair.path, default: [:]][name] = transcript
                        if facts.imported, Self.cardName(for: transcript) == name { importedByFolder[pair.path, default: []].insert(name) }
                    }
                    guard let time = read.modified else { continue }
                    let found = Card(
                        modified: SyncFolders.date(time), time: time, digest: read.digest, facts: facts, account: Self.account(of: pair),
                        created: read.created, url: url)
                    if let known = cards[name], !found.supersedes(known) { continue }
                    cards[name] = found
                } else if name.hasPrefix("deleted_") {
                    tombstones.insert(name)
                    tombstonesByScope[scope, default: []].insert(name)
                    let modified = SyncFolders.modificationDate(url) ?? now
                    let known = tombstoneCopies[name] ?? (0, .distantPast)
                    tombstoneCopies[name] = (known.count + 1, max(known.newest, modified))
                    // Claude writes the time of the deletion into its marker; an empty copy made by an older Baton has
                    // only its own date, which is later.
                    let at = cache.value("tombstone", of: url) { Self.deletionTime(in: $0) } ?? modified
                    deletedAt[name] = max(deletedAt[name] ?? .distantPast, at)
                } else if name == Self.archiveIndex, let index = readJSON(url) {
                    archiveLists[pair.path] = Set(index["archived"] as? [String] ?? [])
                    archiveVersion = index["v"] ?? archiveVersion
                }
            }
        }

        report.accountBoundCards = accountBound.intersection(observed).count
        report.ambiguousAccountBoundCards = accountBound.intersection(observed).filter { (cardScopes[$0]?.count ?? 0) != 1 }.count
        // Remember native IDs before any deletion. Their later tombstones must never become global just
        // because the last card disappeared, and an ambiguous owner cannot be guessed on the next run.
        let nextScopes = cardScopes.filter { accountBound.contains($0.key) }.mapValues { $0.sorted() }
        if nextScopes != remembered.scopes, !dryRun { try NativeScopeState(scopes: nextScopes).save(to: scopeFile) }

        // A native worker is tied to its server-side account/organization and CCR bridge. Old versions may
        // already have copied it elsewhere; timestamps cannot establish which copy owns that bridge.
        // Preserve ambiguous copies, without relinking, replacing or deleting any of them.
        func permitted(_ name: String, in scope: String) -> Bool {
            guard accountBound.contains(name) else { return true }
            return cardScopes[name]?.count == 1 && cardScopes[name]?.contains(scope) == true
        }
        // A card a window made after its session was deleted, such as by importing the conversation again, is a new
        // start: the marker that names it no longer applies, and goes once no window is open.
        func madeAfter(_ name: String, _ time: Date) -> Bool {
            guard let card = cards[name], let made = card.facts.made ?? (card.facts.imported ? card.modified : nil) else { return false }
            return made > time
        }
        let retired = tombstones.filter { marker in
            let name = Self.cardName(for: String(marker.dropFirst("deleted_".count)))
            return !accountBound.contains(name) && madeAfter(name, deletedAt[marker] ?? .distantFuture)
        }
        func markers(in scope: String) -> Set<String> {
            Set(
                tombstones.filter { marker in
                    let name = Self.cardName(for: String(marker.dropFirst("deleted_".count)))
                    guard !retired.contains(marker) else { return false }
                    return !accountBound.contains(name)
                        || (permitted(name, in: scope) && tombstonesByScope[scope]?.contains(marker) == true)
                })
        }
        // Each window's email is read once, and only when a rule covers a card.
        var emails: [String: String?] = [:]
        func allows(_ card: Card, in pair: URL) -> Bool {
            guard let allowed = FolderRules.allowedAccounts(for: card.facts.folders, in: rules) else { return true }
            let dataDir = dataDir(of: pair), account = pair.deletingLastPathComponent().lastPathComponent
            let key = dataDir.path + "\n" + account
            if emails[key] == nil { emails[key] = .some(email(dataDir, account)?.lowercased()) }
            guard let known = emails[key] ?? nil else { return false }
            return allowed.accounts.contains(known)
        }

        // What each window's archive list was after the last run. A session missing from a list now that was
        // in it then was unarchived there, and that wins over every other window's older list.
        let baselineFile = paths.stateDir.appending(path: "archive-baselines.json")
        let baselines = ArchiveBaselines.load(from: baselineFile)
        var nextBaselines = ArchiveBaselines()
        let unarchived = archiveLists.reduce(into: Set<String>()) { result, entry in
            result.formUnion(baselines.lists[entry.key].map { Set($0).subtracting(entry.value) } ?? [])
        }
        let carriers = carriesPermissionMode == nil ? permissionModeCarriers() : []
        func keepsPermissionMode(_ pair: URL) -> Bool {
            let dataDir = dataDir(of: pair)
            return carriesPermissionMode?(dataDir) ?? carriers.contains(dataDir.standardizedFileURL.path)
        }
        // Grants and rules that copies by older releases carried into other accounts. Looked for once, in the first
        // run of a release that keeps them apart, entry by entry (`grantItems`), so what one account added since
        // doesn't hide what the other gave; each is then taken out of every copy of its card.
        let leakedFile = paths.stateDir.appending(path: "cross-account-grants.json")
        var savedLeaks = LeakedGrants.load(from: leakedFile)
        var leaks = savedLeaks ?? LeakedGrants()
        if savedLeaks == nil {
            for (name, folders) in holders where !accountBound.contains(name) {
                var accounts: [String: Set<String>] = [:]  // grant item → accounts whose copy has it
                for pair in folders {
                    guard let facts = reads[pair.appending(path: name).path]?.facts else { continue }
                    for (field, items) in facts.grants where !Self.permissionModeFields.contains(field) || !keepsPermissionMode(pair) {
                        for item in items { accounts[item, default: []].insert(Self.account(of: pair)) }
                    }
                }
                let shared = accounts.filter { $0.value.count > 1 }.keys
                if !shared.isEmpty { leaks.cards[name] = shared.sorted() }
            }
            // Saved before any copy loses a grant: a run that stopped partway would look again and no longer find a
            // grant it already took out of one of the two accounts.
            if !dryRun {
                try leaks.save(to: leakedFile)
                savedLeaks = leaks
            }
        }
        var live: Set<String>?
        func isLive(_ transcript: String) -> Bool {
            if live == nil { live = liveSessionIDs ?? LiveSessions.ids(claudeDir: paths.claudeDir) }
            return live?.contains(transcript) == true
        }
        let backup = Backup(paths: paths, now: now)
        // Newest first, so a folder that gets one of two cards for a conversation gets the current one.
        let newestFirst = cards.sorted(by: { $0.value.modified > $1.value.modified })
        // A card's bytes are read when a copy has to be compared or written, once per run, and only if the file is
        // still what the scan found.
        var loaded: [String: Data] = [:]
        func bytes(of card: Card) -> Data? {
            if let data = loaded[card.url.path] { return data }
            guard let data = try? Data(contentsOf: card.url), Self.hex(SHA256.hash(data: data)) == card.digest else { return nil }
            loaded[card.url.path] = data
            return data
        }
        // Before a copy is removed: if it is the newest, the other windows still get it in this run.
        func keepBytes(of name: String, at target: URL) {
            if let card = cards[name], card.url.path == target.path { _ = bytes(of: card) }
        }
        for pair in pairs {
            let dataDir = dataDir(of: pair)
            let scope = Self.scope(of: pair), account = Self.account(of: pair)
            let keepsPermissionMode = keepsPermissionMode(pair)
            let windowOpen = isWindowOpen?(dataDir) ?? !propagateDeletions
            let applicableTombstones = markers(in: scope)
            var deletedBy: [String: Date] = [:]  // card name → the latest deletion that names it
            for marker in applicableTombstones {
                let name = Self.cardName(for: String(marker.dropFirst("deleted_".count)))
                deletedBy[name] = max(deletedBy[name] ?? .distantPast, deletedAt[marker] ?? .distantFuture)
            }
            // Deleting either card of a conversation that a window imported under its transcript deletes both.
            var deletedTranscripts: [String: Date] = [:]
            for (name, time) in deletedBy {
                guard let transcript = cards[name]?.facts.transcript ?? Self.transcript(inCardName: name) else { continue }
                deletedTranscripts[transcript] = max(deletedTranscripts[transcript] ?? .distantPast, time)
            }
            // Project and Remote Control workers stay with their own card and tombstone.
            for (name, card) in cards where !accountBound.contains(name) {
                guard let transcript = card.facts.transcript, let time = deletedTranscripts[transcript] else { continue }
                deletedBy[name] = max(deletedBy[name] ?? .distantPast, time)
            }
            let deletedNames = Set(deletedBy.filter { accountBound.contains($0.key) || !madeAfter($0.key, $0.value) }.keys)
            var present = Set(try fm.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil).map(\.lastPathComponent))
            var held = transcriptsByFolder[pair.path] ?? [:]
            // The window here imported this conversation after launch: its older copy is not loaded and would
            // show the conversation twice at the next launch.
            for imported in importedByFolder[pair.path] ?? [] {
                guard let transcript = held[imported] else { continue }
                for (name, other) in held where other == transcript && name != imported && !accountBound.contains(name) {
                    let target = pair.appending(path: name)
                    keepBytes(of: name, at: target)
                    if !dryRun {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                    }
                    held[name] = nil
                    present.remove(name)
                    report.duplicatesRetired += 1
                }
            }
            var heldTranscripts = Set(held.values)
            for (name, card) in newestFirst where permitted(name, in: scope) && !deletedNames.contains(name) {
                let target = pair.appending(path: name)
                let native = accountBound.contains(name)
                if !native, !allows(card, in: pair) {
                    guard present.contains(name) else { report.withheldByRule += 1; continue }
                    // Retire a copy only where Claude can't be holding it, and only once it is safe elsewhere.
                    guard !windowOpen, holders[name, default: []].contains(where: { $0 != pair && allows(card, in: $0) }) else { continue }
                    keepBytes(of: name, at: target)
                    if !dryRun {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                    }
                    present.remove(name)
                    report.retiredByRule += 1
                    continue
                }
                if !present.contains(name), let transcript = card.facts.transcript, heldTranscripts.contains(transcript) { continue }
                // This copy as the scan found it, and what it is compared with. A copy found to match that card in an
                // earlier run, and unchanged since, still matches.
                let mine = present.contains(name) ? reads[target.path] : nil
                let comparison = "\(card.digest)|\(card.modified.timeIntervalSince1970)|\(card.account)|\(native)|\(keepsPermissionMode)"
                let leaked = native ? [] : Set(leaks.cards[name] ?? [])
                if let mine, leaked.isEmpty, mine.matches(comparison) { continue }
                // Changed since the scan: the next run takes the new card.
                guard let winner = bytes(of: card) else { continue }
                // A native worker's cwd is coupled to remoteControlSpawn.folder and its server bridge.
                // Even within one account/organization, preserve the complete card byte-for-byte.
                let existing = present.contains(name) ? try? Data(contentsOf: target) : nil
                // What another account granted or connected stays with that account; this window keeps its own. A grant
                // older releases left in two accounts goes from every copy.
                func shared(_ base: Data) -> Data {
                    let local = Self.without(leaked, in: localized(base, for: dataDir, linking: !dryRun))
                    guard card.account != account else { return local }
                    return Self.withoutAccountFields(
                        local, winner: winner, existing: existing.map { Self.without(leaked, in: $0) }, keepPermissionMode: keepsPermissionMode)
                }
                var data = native ? winner : shared(winner), modified = card.time
                if present.contains(name) {
                    guard let current = SyncFolders.modificationDate(target), let own = existing else { continue }
                    report.cardsCompared += 1
                    let here = Self.facts(of: own)
                    if let transcript = here.transcript, transcript != card.facts.transcript {
                        // Already a fork of the incoming conversation: never point the session back.
                        if let incoming = card.facts.transcript, here.priors.contains(incoming) { continue }
                        // Claude Code may write to that conversation at any moment; leave the card to it.
                        if isLive(transcript) { report.keptLive += 1; continue }
                    }
                    let behind = here.transcript.map(card.facts.priors.contains) == true
                    let asNew = current >= card.modified.addingTimeInterval(-1) && !behind
                    // A copy that isn't whole and is newer than every whole one may be one Claude is still writing:
                    // left alone while its window is open, replaced by the newest whole copy once it is closed.
                    if !here.valid, asNew, windowOpen { continue }
                    if asNew, here.valid {
                        // This copy is as new as any; it may still need this window's scratch folder path.
                        data = native ? own : shared(own)
                        guard let time = SyncFolders.modificationTime(target), SyncFolders.date(time) == current else { continue }
                        modified = time
                    }
                    guard own != data else {
                        // Remembered for the usual copy only: the same conversation, and no scratch folder to link.
                        if !dryRun, let mine, leaked.isEmpty, here.transcript == card.facts.transcript, !here.scratch, !card.facts.scratch,
                            Self.hex(SHA256.hash(data: own)) == mine.digest
                        {
                            mine.match(comparison)
                            newMatches = true
                        }
                        continue
                    }
                    if !leaked.isEmpty, Self.without(leaked, in: own) != own { report.grantsRemoved += 1 }
                    if !dryRun {
                        if try backup.save(target) { report.backedUp += 1 }
                        // Claude may have just updated this copy; never replace a newer card with an older one.
                        guard SyncFolders.modificationDate(target) == current, (try? Data(contentsOf: target)) == own else { continue }
                    }
                }
                if !dryRun {
                    try data.write(to: target, options: .atomic)
                    SyncFolders.setModificationTime(target, modified)
                }
                if let transcript = card.facts.transcript { heldTranscripts.insert(transcript) }
                report.cardsWritten += 1
                if !dryRun { report.wroteInto.insert(dataDir.standardizedFileURL.path) }
            }
            if propagateDeletions {
                for tombstone in applicableTombstones where !present.contains(tombstone) {
                    // With the time of the deletion, as Claude writes it.
                    let time = deletedAt[tombstone].map { Data(String(Int64(($0.timeIntervalSince1970 * 1000).rounded())).utf8) }
                    if !dryRun { fm.createFile(atPath: pair.appending(path: tombstone).path, contents: time ?? Data()) }
                    report.tombstonesWritten += 1
                }
                // As Claude does in the window that imports a deleted conversation again.
                for tombstone in retired where present.contains(tombstone) {
                    let target = pair.appending(path: tombstone)
                    if !dryRun {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                    }
                    report.tombstonesRetired += 1
                }
                for name in present where deletedNames.contains(name) && permitted(name, in: scope) {
                    let target = pair.appending(path: name)
                    keepBytes(of: name, at: target)
                    if !dryRun {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                    }
                    report.cardsRemoved += 1
                }
            }
            // Keep own archive entries; import native worker entries only within their known scope.
            // Additions from every window are combined; an unarchive since the last run removes the entry everywhere.
            var archived = archiveLists[pair.path] ?? []
            for (path, ids) in archiveLists {
                let sourceScope = Self.scope(of: URL(fileURLWithPath: path))
                archived.formUnion(
                    ids.filter { id in
                        let name = Self.cardName(for: id)
                        return !accountBound.contains(name) || (sourceScope == scope && permitted(name, in: scope))
                    })
            }
            archived.subtract(unarchived)
            let url = pair.appending(path: Self.archiveIndex)
            if !archived.isEmpty || archiveLists[pair.path] != nil {
                nextBaselines.lists[pair.path] = archived.sorted()
                if archiveLists[pair.path] != archived {
                    if !dryRun {
                        if fm.fileExists(atPath: url.path), try backup.save(url) { report.backedUp += 1 }
                        let object: [String: Any] = ["v": archiveVersion, "archived": archived.sorted()]
                        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
                    }
                    report.archiveIndexesWritten += 1
                }
            }
        }
        // A marker every window has had for 90 days, with no copy of its card left anywhere, has done its job.
        if propagateDeletions {
            let expired = tombstoneCopies.filter { marker, copies in
                let name = Self.cardName(for: String(marker.dropFirst("deleted_".count)))
                return copies.count == pairs.count && now.timeIntervalSince(copies.newest) > Self.tombstoneLifetime
                    && !accountBound.contains(name) && !observed.contains(name)
            }.keys
            for marker in expired.sorted() {
                for pair in pairs where !dryRun {
                    let target = pair.appending(path: marker)
                    if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                    try fm.removeItem(at: target)
                }
                report.tombstonesExpired += 1
            }
        }
        if !dryRun {
            if nextBaselines.lists != baselines.lists { try nextBaselines.save(to: baselineFile) }
            // Unchanged when no card was read again and no copy newly found to match.
            if newMatches || cache.reads != readsBefore {
                let matches = Matches(copies: reads.compactMapValues(\.saved))
                if matches != savedMatches { try matches.save(to: matchesFile) }
            }
            // A grant stays on the list until a run with every window closed finds no copy that has it: an open window
            // may still hold it and write it back.
            if pairs.allSatisfy({ !(isWindowOpen?(dataDir(of: $0)) ?? !propagateDeletions) }) {
                for (name, grants) in leaks.cards {
                    let held = Set(
                        (holders[name] ?? []).flatMap { pair in
                            (reads[pair.appending(path: name).path]?.facts.grants ?? [:]).values.flatMap { $0 }
                        })
                    leaks.cards[name] = grants.filter(held.contains)
                    if leaks.cards[name]?.isEmpty == true { leaks.cards[name] = nil }
                }
            }
            if leaks != savedLeaks { try leaks.save(to: leakedFile) }
            removeDeadScratchLinks()
            backup.prune()
        }
        return report
    }

    /// When a "session deleted" marker says its session was deleted: Claude writes the time in milliseconds.
    static func deletionTime(in marker: URL) -> Date? {
        guard let data = try? Data(contentsOf: marker), data.count < 32,
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let ms = Double(text), ms > 0
        else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Copies found to match their card, by path: `session-sync-matches.json` in the state folder, so that a new
    /// process, such as `baton open`, compares none of them again while they and their cards stay the same. Holds
    /// file stamps and digests only.
    struct Matches: Codable, Equatable {
        var version = 1
        /// Card file path → its stamp and what it matched.
        var copies: [String: String] = [:]

        /// Missing, unreadable or of another version: nothing is known to match.
        static func load(from url: URL) -> Matches {
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(Matches.self, from: data), state.version == 1
            else { return Matches() }
            return state
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }

    /// Grants and session rules found in copies of one card in two accounts, which older releases copied between
    /// accounts: `cross-account-grants.json` in the state folder. Card name → its grant items (`grantItems`).
    /// Its absence means it was never looked for; a damaged file is looked for again, which only takes more out.
    struct LeakedGrants: Codable, Equatable {
        var version = 1
        var cards: [String: [String]] = [:]

        static func load(from url: URL) -> LeakedGrants? {
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(LeakedGrants.self, from: data), state.version == 1
            else { return nil }
            return state
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    /// `card` without the grant items `grants` names (`grantItems`): a value goes whole, an element of a list or an
    /// entry of an object on its own, and a field left with nothing goes too. Everything else keeps its bytes.
    static func without(_ grants: Set<String>, in card: Data) -> Data {
        guard !grants.isEmpty, let members = JSONMembers.parse([UInt8](card)) else { return card }
        var changed = false
        let kept = members.compactMap { member -> JSONMembers.Member? in
            guard isGrant(member.name) else { return member }
            let left = remaining(member.value, of: member.name, without: grants)
            changed = changed || left != member.value
            return left.map { JSONMembers.Member(name: member.name, key: member.key, value: $0) }
        }
        return changed ? Data(JSONMembers.object(kept)) : card
    }

    /// The value of grant field `field` without the items `grants` names, or `nil` if nothing is left of it.
    private static func remaining(_ bytes: ArraySlice<UInt8>, of field: String, without grants: Set<String>) -> ArraySlice<UInt8>? {
        func decoded(_ bytes: ArraySlice<UInt8>) -> Any? { try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed) }
        guard let value = decoded(bytes) else { return bytes }
        if grants.contains(field + " " + grantDigest(value)) { return nil }
        if value is [Any], let elements = JSONMembers.elements(bytes) {
            let kept = elements.filter { element in decoded(element).map { !grants.contains(field + "[] " + grantDigest($0)) } ?? true }
            return kept.count == elements.count ? bytes : kept.isEmpty ? nil : JSONMembers.array(kept)
        }
        if value is [String: Any], let members = JSONMembers.parse(Array(bytes)) {
            let kept = members.filter { member in
                decoded(member.value).map { !grants.contains(field + "{} " + grantDigest([member.name: $0])) } ?? true
            }
            return kept.count == members.count ? bytes : kept.isEmpty ? nil : JSONMembers.object(kept)
        }
        return bytes
    }

    /// Each session folder's archive list as the last run left it, keyed by the folder's path. Only session IDs.
    struct ArchiveBaselines: Codable {
        var version = 1
        var lists: [String: [String]] = [:]

        /// Missing or unreadable means no baseline: lists are then only combined, as before there was one.
        static func load(from url: URL) -> ArchiveBaselines {
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ArchiveBaselines.self, from: data),
                state.version == 1
            else { return ArchiveBaselines() }
            return state
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    /// The newest copy of a card found so far, and what it says.
    struct Card {
        var modified: Date
        /// `modified` to the nanosecond, which a copy gets exactly.
        var time: timespec
        /// Of the bytes the scan found, in hex.
        var digest: String
        var facts: CardFacts
        /// The account of the folder this copy was found in.
        var account: String
        var created: Date
        /// The file this copy was found in.
        var url: URL

        /// Newer than `other`. A fork of the other's conversation is newer whatever the dates say, so a window
        /// still holding the card from before the fork can't point the session back. Of copies that are the same
        /// file, or have the same date as a copy gets it, the one written first is where the card was made.
        func supersedes(_ other: Card) -> Bool {
            if let mine = facts.transcript, let theirs = other.facts.transcript, mine != theirs {
                if facts.priors.contains(theirs) { return true }
                if other.facts.priors.contains(mine) { return false }
            }
            if digest == other.digest || modified == other.modified { return created < other.created }
            return modified > other.modified
        }
    }

    static func account(of pair: URL) -> String { pair.deletingLastPathComponent().lastPathComponent }

    /// Data directories of profiles that chose to keep `permissionMode` in cards shared from other accounts.
    func permissionModeCarriers() -> Set<String> {
        guard let data = try? Data(contentsOf: paths.registryFile),
            let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return Set(
            entries.compactMap { entry in
                guard entry["carryPermissionMode"] as? Bool == true, let id = entry["id"] as? String else { return nil }
                return paths.dataDir(for: id).standardizedFileURL.path
            })
    }

    /// Remote Control bridges and messages, connectors and their tools, and browser grants.
    static let accountFields: Set<String> = ["bridgeSessionIds", "peerReceipts", "remoteMcpServersConfig", "enabledMcpTools", "chromePermissionMode"]
    /// The permission mode and the choice of it in the app: what a profile that keeps the permission mode keeps.
    static let permissionModeFields: Set<String> = ["permissionMode", "bypassChosenInApp", "autoChosenInApp"]
    /// What the session was allowed without asking: its allow rules and added folders, and the prompts answered
    /// "always allow". Never kept for another account.
    static let permissionRuleFields: Set<String> = ["sessionPermissionUpdates", "alwaysAllowedReasons"]

    /// Card fields that belong to the account a session was used under: Remote Control bridges and messages,
    /// connectors and their tools, browser grants, every computer-use field (`cuAllowedApps`, `cuGrantFlags`,
    /// `cuFlagsGrantedAt` and any later `cu…` one), the session's permission rules, and the permission mode unless
    /// kept.
    static func isAccountScoped(_ key: String, keepPermissionMode: Bool) -> Bool {
        accountFields.contains(key) || key.hasPrefix("remoteControl") || isComputerUse(key) || permissionRuleFields.contains(key)
            || (permissionModeFields.contains(key) && !keepPermissionMode)
    }

    /// The grants and rules older releases copied between accounts: computer-use fields and the permission fields.
    static func isGrant(_ key: String) -> Bool {
        isComputerUse(key) || permissionModeFields.contains(key) || permissionRuleFields.contains(key)
    }

    /// What the value of grant field `field` allows, item by item: each element of a list (an allowed app, one change
    /// to the session's rules) as "<field>[] <digest>", each entry of an object (one computer-use flag) as
    /// "<field>{} <digest of {key: value}>", and any other value as "<field> <digest>". Only items that allow
    /// something (`grantsSomething`) count, so an entry one account added doesn't change the others.
    static func grantItems(_ field: String, _ value: Any) -> Set<String> {
        switch value {
        case let list as [Any]: return Set(list.filter(grantsSomething).map { field + "[] " + grantDigest($0) })
        case let object as [String: Any]: return Set(object.filter { grantsSomething($0.value) }.map { field + "{} " + grantDigest([$0.key: $0.value]) })
        default: return grantsSomething(value) ? [field + " " + grantDigest(value)] : []
        }
    }

    /// Of a value as JSON with sorted keys, so equal values in differently written cards match.
    static func grantDigest(_ value: Any) -> String {
        hex(SHA256.hash(data: (try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])) ?? Data()))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in digest { text += [digits[Int(byte >> 4)], digits[Int(byte & 15)]] }
        return String(decoding: text, as: UTF8.self)
    }

    /// `cu` followed by a capital letter, as Claude names its computer-use fields.
    static func isComputerUse(_ key: String) -> Bool {
        let rest = key.utf8.dropFirst(2)
        return key.hasPrefix("cu") && rest.first.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) } == true
    }

    /// `base` as another account's window gets it: account-scoped fields dropped, local stdio tools (`local:`) kept
    /// enabled, and this window's own value of each such field kept. A value that equals the `winner`'s came from
    /// the other account, by an earlier copy; one that differs was set here. Unchanged fields keep their bytes.
    static func withoutAccountFields(_ base: Data, winner: Data, existing: Data?, keepPermissionMode: Bool) -> Data {
        guard let members = JSONMembers.parse([UInt8](base)) else { return base }
        let theirs = JSONMembers.parse([UInt8](winner)).map(JSONMembers.values) ?? [:]
        let mine = existing.flatMap { JSONMembers.parse([UInt8]($0)) }.map(JSONMembers.values) ?? [:]
        func own(_ key: String) -> ArraySlice<UInt8>? { mine[key].flatMap { $0 == theirs[key] ? nil : $0 } }
        var result: [JSONMembers.Member] = [], changed = false
        for member in members {
            guard isAccountScoped(member.name, keepPermissionMode: keepPermissionMode) else { result.append(member); continue }
            var value = own(member.name)
            if value == nil, member.name == "enabledMcpTools", let tools = JSONMembers.parse(Array(member.value)) {
                value = JSONMembers.object(tools.filter { $0.name.hasPrefix("local:") })
            }
            if let value { result.append(JSONMembers.Member(name: member.name, key: member.key, value: value)) }
            changed = changed || value != member.value
        }
        let names = Set(members.map(\.name))
        for member in (existing.flatMap { JSONMembers.parse([UInt8]($0)) } ?? [])
        where !names.contains(member.name) && isAccountScoped(member.name, keepPermissionMode: keepPermissionMode) && own(member.name) != nil {
            result.append(member)
            changed = true
        }
        return changed ? Data(JSONMembers.object(result)) : base
    }

    /// The data directory a session folder belongs to, as given rather than as listed: Claude writes paths with
    /// the data directory it was started with.
    func dataDir(of pair: URL) -> URL {
        let listed = pair.resolvingSymlinksInPath().path
        return dataDirs.first { listed.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
            ?? pair.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A second organization on the same account is not authorization for the native worker.
    static func scope(of pair: URL) -> String {
        pair.deletingLastPathComponent().lastPathComponent + "/" + pair.lastPathComponent
    }

    /// Missing session roots are normal for a new profile. Other enumeration errors are not evidence of
    /// deletion and must stop the sync before its baseline or cards change.
    static func sessionPairs(dataDirs: [URL], folder: String) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for dataDir in dataDirs {
            let root = dataDir.appending(path: folder, directoryHint: .isDirectory)
            let accounts: [URL]
            do {
                accounts = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
            for account in accounts where account.lastPathComponent.count == 36 {
                let values = try account.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                for org in try fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) where !org.lastPathComponent.hasPrefix(".") {
                    let values = try org.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true, values.isSymbolicLink != true { result.append(org) }
                }
            }
        }
        return result
    }

    static func cardName(for id: String) -> String {
        let name = id.hasPrefix("local_") ? id : "local_" + id
        return name.hasSuffix(".json") ? name : name + ".json"
    }

    static func isAccountBound(_ data: Data) -> Bool { facts(of: data).accountBound }

    struct CardFacts {
        /// One whole JSON object; a card cut short by a crash or a full disk is not.
        var valid = false
        var accountBound = false
        /// The Claude Code conversation the card opens (`cliSessionId`).
        var transcript: String?
        /// Created by a window that opened an existing conversation it had no loaded card for.
        var imported = false
        /// `cwd` and `originCwd`, except "No folder" scratch workspaces, for folder rules.
        var folders: [String] = []
        /// The conversations Claude forked this session from (`priorCliSessionIds`).
        var priors: Set<String> = []
        /// `cwd` or `originCwd` is a "No folder" scratch workspace, which each window's copy names in its own data
        /// directory.
        var scratch = false
        /// When a window made this card, by creating the session or importing it: the later of `createdAt` and
        /// `indexedAt`.
        var made: Date?
        /// What each computer-use and permission field allows (`grantItems`), by field, for fields that allow something.
        var grants: [String: Set<String>] = [:]
    }

    static func facts(of data: Data) -> CardFacts {
        guard let card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return CardFacts() }
        let paths = ["cwd", "originCwd"].compactMap { card[$0] as? String }
        let folders = paths.filter { !$0.isEmpty && !$0.contains(scratchFolder) }
        let made = ["createdAt", "indexedAt"].compactMap { card[$0] as? Double }.max()
        return CardFacts(
            valid: true,
            accountBound: isAccountBoundCard(card),
            transcript: (card["cliSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() },
            imported: card["adoptedFromOtherSurface"] as? Bool == true,
            folders: Array(Set(folders)).sorted(),
            priors: Set((card["priorCliSessionIds"] as? [String] ?? []).map { $0.lowercased() }),
            scratch: paths.contains { $0.contains(scratchFolder) },
            made: made.map { Date(timeIntervalSince1970: $0 / 1000) },
            grants: card.reduce(into: [:]) { grants, member in
                guard isGrant(member.key) else { return }
                let items = grantItems(member.key, member.value)
                if !items.isEmpty { grants[member.key] = items }
            })
    }

    /// Whether a computer-use or permission value allows anything: not empty, false, zero or `"default"`, the values
    /// Claude writes into every card.
    static func grantsSomething(_ value: Any) -> Bool {
        switch value {
        case let text as String: return !text.isEmpty && text != "default"
        case let number as NSNumber: return number.doubleValue != 0
        case let list as [Any]: return list.contains(where: grantsSomething)
        case let object as [String: Any]: return object.values.contains(where: grantsSomething)
        default: return false
        }
    }

    /// What a card file says, kept in `cache` while the file stays the same. The sync and the carry share it.
    static func read(_ url: URL, cache: ScanCache) throws -> CardRead {
        try autoreleasepool { try cache.value("card", of: url, cost: \CardRead.cost) { url in try CardRead(of: url) } }
    }

    /// What a run keeps of a card between runs, while its file stays the same: what it says and a digest of its
    /// bytes, not the bytes. A copy found to match its card is remembered here, so an idle run compares nothing.
    final class CardRead: @unchecked Sendable {
        let facts: CardFacts
        /// SHA-256 of the bytes, in hex.
        let digest: String
        /// The modification time, of the link itself for a symbolic link.
        let modified: timespec?
        let created: Date
        /// The file's modification and change times, size and inode when it was read.
        let stamp: String
        private let lock = NSLock()
        private var matched: String?

        init(of url: URL) throws {
            var info = stat()
            stamp =
                stat(url.path, &info) == 0
                ? "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec) \(info.st_size) \(info.st_ino)"
                : ""
            let data = try Data(contentsOf: url)
            facts = SessionSync.facts(of: data)
            digest = SessionSync.hex(SHA256.hash(data: data))
            modified = SyncFolders.modificationTime(url)
            created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
        }

        /// Roughly what keeping it takes, in bytes: measured at about 1 KB for a card with one folder and no priors.
        var cost: Int {
            let strings = [facts.transcript ?? ""] + facts.folders + Array(facts.priors) + facts.grants.values.flatMap { $0 }
            return 640 + strings.reduce(0) { $0 + $1.utf8.count + 48 }
        }

        /// Whether this copy was found to match a card as `comparison` describes it.
        func matches(_ comparison: String) -> Bool { lock.withLock { matched == comparison } }
        func match(_ comparison: String) { lock.withLock { matched = comparison } }

        /// Its stamp and match, for `Matches`.
        var saved: String? { lock.withLock { matched.map { stamp + "|" + $0 } } }
        /// A match an earlier process found, if it was found for this very file.
        func restore(_ saved: String) {
            guard !stamp.isEmpty, saved.hasPrefix(stamp + "|") else { return }
            lock.withLock { if matched == nil { matched = String(saved.dropFirst(stamp.count + 1)) } }
        }
    }

    /// `local_<uuid>.json` names the transcript it was imported from; any other name gives `nil`.
    static func transcript(inCardName name: String) -> String? {
        guard name.hasPrefix("local_"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst("local_".count).dropLast(".json".count))
        return UUID(uuidString: id) == nil ? nil : id.lowercased()
    }

    static func isAccountBoundCard(_ card: [String: Any]) -> Bool {
        if let spawn = card["remoteControlSpawn"], !(spawn is NSNull) { return true }
        return card["projectThreadChild"] as? Bool == true || card["rcChild"] as? Bool == true
    }

    /// Only native card identifiers and account/organization scopes, never conversation text or credentials.
    /// Shared by the two session kinds, each in its own file. Malformed/unknown state fails closed.
    struct NativeScopeState: Codable {
        var version = 1
        var scopes: [String: [String]] = [:]

        static func load(from url: URL) throws -> NativeScopeState {
            guard FileManager.default.fileExists(atPath: url.path) else { return NativeScopeState() }
            let state = try JSONDecoder().decode(NativeScopeState.self, from: Data(contentsOf: url))
            guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return state
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    static let scratchFolder = "/scratch-workspaces/"

    /// A session started in a "No folder" scratch workspace keeps that folder in the data directory of the window
    /// that started it. Claude lists a session under "No folder" only when `originCwd` is inside its own data
    /// directory, and offers side questions (`/btw`) only when `cwd` is the same path. So every other window gets a
    /// link to the folder at the same place in its own data directory, and its copy of the card names that link as
    /// both. Claude Code resolves the link, so the conversation stays filed under the folder's real path. Claude
    /// never sweeps or removes those links: it only cleans up real folders of its own account.
    ///
    /// When the folder is gone, or the link can't be made, only `originCwd` is changed, which keeps the session
    /// under "No folder" without side questions.
    /// - Parameter linking: make the link when it's missing; without it, only a link already there is used.
    func localized(_ card: Data, for dataDir: URL, linking: Bool = true) -> Data {
        let strings = Self.topLevelStrings(in: card)
        guard let originRange = strings["originCwd"], let origin = String(data: card[originRange], encoding: .utf8),
            let workspace = scratchWorkspace(origin)
        else { return card }
        let here = dataDir.path + Self.scratchFolder + workspace
        var changes = [(originRange, origin)]
        if let cwdRange = strings["cwd"], let cwd = String(data: card[cwdRange], encoding: .utf8),
            scratchWorkspace(cwd) == workspace, workspace.split(separator: "/").count == 3,
            let owner = owner(of: cwd, workspace: workspace),
            owner.path == dataDir.path || linkScratchFolder(at: here, to: owner.path + Self.scratchFolder + workspace, creating: linking)
        {
            changes.append((cwdRange, cwd))
        }
        var result = card
        for (range, value) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) where value != here {
            result.replaceSubrange(range, with: Data(here.utf8))
        }
        return result
    }

    /// `<account>/<organization>/<folder>` of a path inside any data directory's scratch workspaces.
    private func scratchWorkspace(_ path: String) -> String? {
        for dir in dataDirs where path.hasPrefix(dir.path + Self.scratchFolder) {
            let rest = String(path.dropFirst(dir.path.count + Self.scratchFolder.count))
            return rest.isEmpty || rest.split(separator: "/").contains { $0 == "." || $0 == ".." } ? nil : rest
        }
        return nil
    }

    /// The data directory whose real scratch folder `cwd` leads to, following any link.
    private func owner(of cwd: String, workspace: String) -> URL? {
        let real = URL(filePath: cwd).resolvingSymlinksInPath().path
        return dataDirs.first { dir in
            let folder = dir.path + Self.scratchFolder + workspace
            return isFolder(folder) && URL(filePath: folder).resolvingSymlinksInPath().path == real
        }
    }

    private func isFolder(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Makes `path` a link to `folder`, or checks that it already is one. Anything else at `path` is left alone.
    private func linkScratchFolder(at path: String, to folder: String, creating: Bool = true) -> Bool {
        if creating, (try? fm.attributesOfItem(atPath: path)) == nil {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: path, withDestinationPath: folder)
        }
        return (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
            && (try? fm.destinationOfSymbolicLink(atPath: path)) == folder
    }

    /// Removes links made by `localized(_:for:)` whose folder is gone, such as after that session or the profile
    /// that started it was removed. Only links to the same place in another data directory are touched.
    @discardableResult
    func removeDeadScratchLinks() -> Int {
        var removed = 0
        for dir in dataDirs {
            let root = dir.path + Self.scratchFolder
            for account in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                for org in (try? fm.contentsOfDirectory(atPath: root + account)) ?? [] {
                    let orgPath = root + account + "/" + org
                    for name in (try? fm.contentsOfDirectory(atPath: orgPath)) ?? [] {
                        let link = orgPath + "/" + name
                        // Only a link has a destination.
                        guard let folder = try? fm.destinationOfSymbolicLink(atPath: link), folder.hasPrefix("/"),
                            folder.hasSuffix(Self.scratchFolder + account + "/" + org + "/" + name),
                            !fm.fileExists(atPath: folder)
                        else { continue }
                        if (try? fm.removeItem(atPath: link)) != nil { removed += 1 }
                    }
                }
            }
        }
        return removed
    }

    /// Where each top-level string value of a card is, keyed by name; values with escapes and nested objects are
    /// skipped. Editing a card in place keeps the rest of it byte for byte as Claude wrote it.
    static func topLevelStrings(in card: Data) -> [String: Range<Data.Index>] {
        let bytes = [UInt8](card), base = card.startIndex
        var result: [String: Range<Data.Index>] = [:]
        var depth = 0, index = 0, key: String?
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                var end = index + 1, escaped = false
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    if bytes[end] == UInt8(ascii: "\\") { escaped = true; end += 1 }
                    end += 1
                }
                guard end < bytes.count else { return result }
                if depth == 1 {
                    var next = end + 1
                    while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                    if next < bytes.count, bytes[next] == UInt8(ascii: ":") {
                        key = escaped ? nil : String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    } else if let name = key, !escaped {
                        result[name] = (base + index + 1)..<(base + end)
                    }
                }
                index = end + 1
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1; index += 1
            default: index += 1
            }
        }
        return result
    }

    /// Every `<account>/<organization>` session directory across all data directories.
    func pairs() throws -> [URL] { try Self.sessionPairs(dataDirs: dataDirs, folder: Self.sessionsFolder) }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Copies a file into `Backups/<date>/` before Baton overwrites or removes it.
/// Day folders older than a week go to the Trash, never straight to deletion.
///
/// The first overwrite of a file in a day is copied next to its path; every later content it is overwritten with
/// goes to the day's `.versions` folder, stored once by its SHA-256 whichever file it came from, with a line in
/// `index.jsonl` naming the file. Versions are kept at least 24 hours.
struct Backup {
    let paths: Paths
    let now: Date
    /// Where pruned backups go; the Trash unless a test substitutes it.
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    static let keepDays = 7

    var dayDir: URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return paths.backupsDir.appending(path: formatter.string(from: now), directoryHint: .isDirectory)
    }

    static let versionsFolder = ".versions"

    /// Every overwritten content and every removal is kept.
    /// - Returns: `true` if a copy was made.
    func save(_ url: URL, everyTime: Bool = false) throws -> Bool {
        let base = paths.applicationSupport.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
        var target = dayDir.appending(path: relative)
        if FileManager.default.fileExists(atPath: target.path) {
            guard everyTime else { return try saveVersion(of: url, relative: relative, dayCopy: target) }
            target = target.deletingLastPathComponent().appending(
                path: "\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: target)
        return true
    }

    /// A file's content after its first copy of the day, once per distinct content. Folders keep only that first copy.
    private func saveVersion(of url: URL, relative: String, dayCopy: URL) throws -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return false }
        let data = try Data(contentsOf: url)
        guard (try? Data(contentsOf: dayCopy)) != data else { return false }
        // A removal copy made earlier today already holds this content.
        let folder = dayCopy.deletingLastPathComponent()
        let removals = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix("-" + dayCopy.lastPathComponent) }
        if removals.contains(where: { (try? Data(contentsOf: folder.appending(path: $0))) == data }) { return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let versions = dayDir.appending(path: Self.versionsFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let entry: [String: Any] = ["at": Int(now.timeIntervalSince1970 * 1000), "path": relative, "sha256": hash]
        let line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        let index = versions.appending(path: "index.jsonl")
        if let handle = try? FileHandle(forWritingTo: index) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: index, options: .atomic)
        }
        let blob = versions.appending(path: hash)
        guard !FileManager.default.fileExists(atPath: blob.path) else { return false }
        try data.write(to: blob, options: .atomic)
        return true
    }

    /// Writes `values` as JSON to `relative` in today's folder, for data that can't be copied as a file.
    /// Every call gets its own file.
    func saveValues(_ values: [String: Any], as relative: String) throws {
        var target = dayDir.appending(path: relative)
        if FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appending(
                path: "\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: target, options: .atomic)
    }

    /// Moves backup day folders older than `keepDays` to the Trash, and a day's versions once the day is over
    /// by 24 hours.
    @discardableResult
    func prune() -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var moved = 0
        for day in (try? FileManager.default.contentsOfDirectory(at: paths.backupsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let date = formatter.date(from: day.lastPathComponent) else { continue }
            if date < cutoff {
                if (try? discard(day)) != nil { moved += 1 }
            } else if date.addingTimeInterval(2 * 86_400) <= now {
                let versions = day.appending(path: Self.versionsFolder, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: versions.path), (try? discard(versions)) != nil { moved += 1 }
            }
        }
        return moved
    }
}

/// The top-level members of a JSON object, each with the exact bytes of its key and value, so that an object can
/// be rebuilt with some members dropped or replaced and everything else as it was.
enum JSONMembers {
    struct Member {
        /// The decoded key.
        var name: String
        /// The key as written, quotes included.
        var key: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
    }

    static func values(_ members: [Member]) -> [String: ArraySlice<UInt8>] {
        Dictionary(members.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Compact, the way `JSON.stringify` writes it.
    static func array(_ elements: [ArraySlice<UInt8>]) -> ArraySlice<UInt8> {
        var bytes: [UInt8] = [UInt8(ascii: "[")]
        for (i, element) in elements.enumerated() {
            if i > 0 { bytes.append(UInt8(ascii: ",")) }
            bytes += element
        }
        bytes.append(UInt8(ascii: "]"))
        return bytes[...]
    }

    /// The elements of the array `json` as written, spaces around them left out, or `nil` if it isn't one array.
    static func elements(_ json: ArraySlice<UInt8>) -> [ArraySlice<UInt8>]? {
        let space: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
        func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var bytes = bytes
            while let first = bytes.first, space.contains(first) { bytes = bytes.dropFirst() }
            while let last = bytes.last, space.contains(last) { bytes = bytes.dropLast() }
            return bytes
        }
        let json = trimmed(json)
        guard json.count >= 2, json.first == UInt8(ascii: "["), json.last == UInt8(ascii: "]") else { return nil }
        let end = json.endIndex - 1
        var result: [ArraySlice<UInt8>] = []
        var depth = 0, inString = false, start = json.startIndex + 1, i = start
        while i < end {
            if inString {
                if json[i] == UInt8(ascii: "\\") { i += 1 } else if json[i] == UInt8(ascii: "\"") { inString = false }
            } else {
                switch json[i] {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                case UInt8(ascii: ",") where depth == 0:
                    result.append(trimmed(json[start..<i]))
                    start = i + 1
                default: break
                }
            }
            i += 1
        }
        let last = trimmed(json[start..<end])
        if !last.isEmpty || !result.isEmpty { result.append(last) }
        guard !inString, depth == 0, !result.contains(where: \.isEmpty) else { return nil }
        return result
    }

    /// Compact, the way `JSON.stringify` writes it.
    static func object(_ members: [Member]) -> ArraySlice<UInt8> {
        var bytes: [UInt8] = [UInt8(ascii: "{")]
        for (i, member) in members.enumerated() {
            if i > 0 { bytes.append(UInt8(ascii: ",")) }
            bytes += member.key
            bytes.append(UInt8(ascii: ":"))
            bytes += member.value
        }
        bytes.append(UInt8(ascii: "}"))
        return bytes[...]
    }

    /// `nil` if `json` isn't exactly one well-formed object at the top.
    static func parse(_ json: [UInt8]) -> [Member]? {
        var i = 0
        func skipSpace() { while i < json.count, [0x20, 0x09, 0x0A, 0x0D].contains(json[i]) { i += 1 } }
        /// Moves past the string starting at `i`.
        func skipString() -> Bool {
            i += 1
            while i < json.count, json[i] != UInt8(ascii: "\"") { i += json[i] == UInt8(ascii: "\\") ? 2 : 1 }
            guard i < json.count else { return false }
            i += 1
            return true
        }
        func skipValue() -> Bool {
            guard i < json.count else { return false }
            switch json[i] {
            case UInt8(ascii: "\""): return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while i < json.count {
                    switch json[i] {
                    case UInt8(ascii: "\""): if !skipString() { return false }; continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                    default: break
                    }
                    i += 1
                    if depth == 0 { return true }
                }
                return false
            default:
                let start = i
                while i < json.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(json[i]) { i += 1 }
                return i > start
            }
        }
        skipSpace()
        guard i < json.count, json[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        skipSpace()
        var members: [Member] = []
        if i < json.count, json[i] == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                guard i < json.count, json[i] == UInt8(ascii: "\""), case let keyStart = i, skipString() else { return nil }
                let key = json[keyStart..<i]
                // A key without escapes is its own bytes; one with them is decoded as JSON.
                let plain = key.dropFirst().dropLast()
                let decoded =
                    plain.contains(UInt8(ascii: "\\"))
                    ? (try? JSONSerialization.jsonObject(with: Data(key), options: .fragmentsAllowed)) as? String : String(bytes: plain, encoding: .utf8)
                guard let name = decoded else { return nil }
                skipSpace()
                guard i < json.count, json[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipSpace()
                let valueStart = i
                guard skipValue() else { return nil }
                members.append(Member(name: name, key: key, value: json[valueStart..<i]))
                skipSpace()
                guard i < json.count else { return nil }
                if json[i] == UInt8(ascii: ",") { i += 1; skipSpace(); continue }
                guard json[i] == UInt8(ascii: "}") else { return nil }
                i += 1
                break
            }
        }
        skipSpace()
        return i == json.count ? members : nil
    }
}
