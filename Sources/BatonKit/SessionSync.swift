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
/// connectors, browser and computer-use grants, and the permission mode unless the profile keeps it); copies
/// between windows of one account are exact.
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
        /// The data folders (standardized paths) that got a session card in this run. A window that was already open
        /// shows those sessions only after a restart.
        public var wroteInto: Set<String> = []
        public var changes: Int {
            cardsWritten + cardsRemoved + tombstonesWritten + duplicatesRetired + archiveIndexesWritten + retiredByRule + tombstonesExpired
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
    /// Cards already read, kept while each file stays the same, so an idle run reads none of them again.
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

        for pair in pairs {
            let scope = Self.scope(of: pair)
            // A read error must not look like an empty folder to deletion handling.
            for url in try fm.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                if name.hasPrefix("local_"), name.hasSuffix(".json") {
                    let (data, facts) = try cache.value("card", of: url) { url in
                        let data = try Data(contentsOf: url)
                        return (data, Self.facts(of: data))
                    }
                    observed.insert(name)
                    holders[name, default: []].append(pair)
                    cardScopes[name, default: []].insert(scope)
                    if facts.accountBound { accountBound.insert(name) }
                    if let transcript = facts.transcript {
                        transcriptsByFolder[pair.path, default: [:]][name] = transcript
                        if facts.imported, Self.cardName(for: transcript) == name { importedByFolder[pair.path, default: []].insert(name) }
                    }
                    guard let modified = SyncFolders.modificationDate(url) else { continue }
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                    let found = Card(modified: modified, data: data, facts: facts, account: Self.account(of: pair), created: created)
                    if let known = cards[name], !found.supersedes(known) { continue }
                    cards[name] = found
                } else if name.hasPrefix("deleted_") {
                    tombstones.insert(name)
                    tombstonesByScope[scope, default: []].insert(name)
                    let modified = SyncFolders.modificationDate(url) ?? now
                    let known = tombstoneCopies[name] ?? (0, .distantPast)
                    tombstoneCopies[name] = (known.count + 1, max(known.newest, modified))
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
        func markers(in scope: String) -> Set<String> {
            Set(
                tombstones.filter { marker in
                    let name = Self.cardName(for: String(marker.dropFirst("deleted_".count)))
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
        var live: Set<String>?
        func isLive(_ transcript: String) -> Bool {
            if live == nil { live = liveSessionIDs ?? LiveSessions.ids(claudeDir: paths.claudeDir) }
            return live?.contains(transcript) == true
        }
        let backup = Backup(paths: paths, now: now)
        for pair in pairs {
            let dataDir = dataDir(of: pair)
            let scope = Self.scope(of: pair), account = Self.account(of: pair)
            let keepsPermissionMode = carriesPermissionMode?(dataDir) ?? carriers.contains(dataDir.standardizedFileURL.path)
            let windowOpen = isWindowOpen?(dataDir) ?? !propagateDeletions
            let applicableTombstones = markers(in: scope)
            var deletedNames = Set(applicableTombstones.map { Self.cardName(for: String($0.dropFirst("deleted_".count))) })
            // Deleting either card of a conversation that a window imported under its transcript deletes both.
            let deletedTranscripts = Set(deletedNames.compactMap { cards[$0]?.facts.transcript ?? Self.transcript(inCardName: $0) })
            // Project and Remote Control workers stay with their own card and tombstone.
            deletedNames.formUnion(cards.filter { !accountBound.contains($0.key) && $0.value.facts.transcript.map(deletedTranscripts.contains) == true }.keys)
            var present = Set(try fm.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil).map(\.lastPathComponent))
            var held = transcriptsByFolder[pair.path] ?? [:]
            // The window here imported this conversation after launch: its older copy is not loaded and would
            // show the conversation twice at the next launch.
            for imported in importedByFolder[pair.path] ?? [] {
                guard let transcript = held[imported] else { continue }
                for (name, other) in held where other == transcript && name != imported && !accountBound.contains(name) {
                    let target = pair.appending(path: name)
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
            // Newest first, so a folder that gets one of two cards for a conversation gets the current one.
            for (name, card) in cards.sorted(by: { $0.value.modified > $1.value.modified })
            where permitted(name, in: scope) && !deletedNames.contains(name) {
                let target = pair.appending(path: name)
                let native = accountBound.contains(name)
                if !native, !allows(card, in: pair) {
                    guard present.contains(name) else { report.withheldByRule += 1; continue }
                    // Retire a copy only where Claude can't be holding it, and only once it is safe elsewhere.
                    guard !windowOpen, holders[name, default: []].contains(where: { $0 != pair && allows(card, in: $0) }) else { continue }
                    if !dryRun {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                    }
                    present.remove(name)
                    report.retiredByRule += 1
                    continue
                }
                if !present.contains(name), let transcript = card.facts.transcript, heldTranscripts.contains(transcript) { continue }
                // A native worker's cwd is coupled to remoteControlSpawn.folder and its server bridge.
                // Even within one account/organization, preserve the complete card byte-for-byte.
                let existing = present.contains(name) ? try? Data(contentsOf: target) : nil
                // What another account granted or connected stays with that account; this window keeps its own.
                func shared(_ base: Data) -> Data {
                    let local = localized(base, for: dataDir, linking: !dryRun)
                    guard card.account != account else { return local }
                    return Self.withoutAccountFields(local, winner: card.data, existing: existing, keepPermissionMode: keepsPermissionMode)
                }
                var data = native ? card.data : shared(card.data), modified = card.modified
                if present.contains(name) {
                    guard let current = SyncFolders.modificationDate(target), let own = existing else { continue }
                    let here = Self.facts(of: own)
                    if let transcript = here.transcript, transcript != card.facts.transcript {
                        // Already a fork of the incoming conversation: never point the session back.
                        if let incoming = card.facts.transcript, here.priors.contains(incoming) { continue }
                        // Claude Code may write to that conversation at any moment; leave the card to it.
                        if isLive(transcript) { report.keptLive += 1; continue }
                    }
                    let behind = here.transcript.map(card.facts.priors.contains) == true
                    if current >= card.modified.addingTimeInterval(-1), !behind {
                        // This copy is as new as any; it may still need this window's scratch folder path.
                        data = native ? own : shared(own)
                        modified = current
                    }
                    guard own != data else { continue }
                    if !dryRun {
                        if try backup.save(target) { report.backedUp += 1 }
                        // Claude may have just updated this copy; never replace a newer card with an older one.
                        guard SyncFolders.modificationDate(target) == current, (try? Data(contentsOf: target)) == own else { continue }
                    }
                }
                if !dryRun {
                    try data.write(to: target, options: .atomic)
                    try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
                }
                if let transcript = card.facts.transcript { heldTranscripts.insert(transcript) }
                report.cardsWritten += 1
                if !dryRun { report.wroteInto.insert(dataDir.standardizedFileURL.path) }
            }
            if propagateDeletions {
                for tombstone in applicableTombstones where !present.contains(tombstone) {
                    if !dryRun { fm.createFile(atPath: pair.appending(path: tombstone).path, contents: Data()) }
                    report.tombstonesWritten += 1
                }
                for name in present where deletedNames.contains(name) && permitted(name, in: scope) {
                    let target = pair.appending(path: name)
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
            removeDeadScratchLinks()
            backup.prune()
        }
        return report
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
        var data: Data
        var facts: CardFacts
        /// The account of the folder this copy was found in.
        var account: String
        var created: Date

        /// Newer than `other`. A fork of the other's conversation is newer whatever the dates say, so a window
        /// still holding the card from before the fork can't point the session back. Of copies that are the same
        /// file, the one written first is where the card was made.
        func supersedes(_ other: Card) -> Bool {
            if let mine = facts.transcript, let theirs = other.facts.transcript, mine != theirs {
                if facts.priors.contains(theirs) { return true }
                if other.facts.priors.contains(mine) { return false }
            }
            if data == other.data { return created < other.created }
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

    /// Card fields that belong to the account a session was used under: Remote Control bridges and messages,
    /// connectors and their tools, browser and computer-use grants, and the permission mode unless kept.
    static func isAccountScoped(_ key: String, keepPermissionMode: Bool) -> Bool {
        ["bridgeSessionIds", "peerReceipts", "remoteMcpServersConfig", "enabledMcpTools", "chromePermissionMode", "cuGrantFlags"].contains(key)
            || key.hasPrefix("remoteControl") || (key == "permissionMode" && !keepPermissionMode)
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
        var accountBound = false
        /// The Claude Code conversation the card opens (`cliSessionId`).
        var transcript: String?
        /// Created by a window that opened an existing conversation it had no loaded card for.
        var imported = false
        /// `cwd` and `originCwd`, except "No folder" scratch workspaces, for folder rules.
        var folders: [String] = []
        /// The conversations Claude forked this session from (`priorCliSessionIds`).
        var priors: Set<String> = []
    }

    static func facts(of data: Data) -> CardFacts {
        guard let card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return CardFacts() }
        let folders = ["cwd", "originCwd"].compactMap { card[$0] as? String }
            .filter { !$0.isEmpty && !$0.contains(scratchFolder) }
        return CardFacts(
            accountBound: isAccountBoundCard(card),
            transcript: (card["cliSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() },
            imported: card["adoptedFromOtherSurface"] as? Bool == true,
            folders: Array(Set(folders)).sorted(),
            priors: Set((card["priorCliSessionIds"] as? [String] ?? []).map { $0.lowercased() }))
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
                        guard (try? fm.attributesOfItem(atPath: link)[.type] as? FileAttributeType) == .typeSymbolicLink,
                            let folder = try? fm.destinationOfSymbolicLink(atPath: link), folder.hasPrefix("/"),
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
                guard let name = (try? JSONSerialization.jsonObject(with: Data(key), options: .fragmentsAllowed)) as? String else { return nil }
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
