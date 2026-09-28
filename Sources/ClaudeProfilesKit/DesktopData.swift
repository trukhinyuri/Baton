import Foundation

/// Plan usage as last recorded by Claude Desktop itself (`plan-usage-history.json`).
public struct Usage: Equatable, Sendable {
    /// Percent of the rolling 5-hour limit used.
    public var fiveHour: Int?
    /// Percent of the weekly limit used.
    public var week: Int?
    public var sampledAt: Date

    public init(fiveHour: Int?, week: Int?, sampledAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.sampledAt = sampledAt
    }

    /// The 5-hour window has certainly rolled over since this sample, so its value no longer applies.
    public func isFiveHourStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(sampledAt) > 5 * 3600
    }

    /// Claude records usage only while its window is open and in use, so a closed window's sample can be hours old.
    public static let staleAfter: TimeInterval = 3 * 3600

    /// How long ago this sample was taken.
    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(sampledAt)) }

    /// Recent enough to compare subscriptions by.
    public func isFresh(now: Date = Date()) -> Bool { age(now: now) <= Self.staleAfter }
}

/// Read-only access to the few non-secret facts Claude Profiles needs from a Claude Desktop data directory.
///
/// Privacy boundary: `config.json` also holds OAuth token caches. Only `lastKnownAccountUuid` is read
/// from it; nothing else is decoded, stored, logged or sent anywhere.
public enum DesktopData {
    /// UUID of the account last signed in to this data directory, if any.
    public static func accountID(in dataDir: URL) -> String? {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["lastKnownAccountUuid"] as? String, id.count == 36
        else { return nil }
        return id
    }

    /// Every organization folder that exists for `accountID` in `dataDir`, across both the Code and Cowork
    /// session folders.
    private static func organizationFolders(in dataDir: URL, accountID: String) -> [URL] {
        let fm = FileManager.default
        return ["claude-code-sessions", "local-agent-mode-sessions"].flatMap { folder in
            let account = dataDir.appending(path: "\(folder)/\(accountID)", directoryHint: .isDirectory)
            return ((try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.count == 36 && UUID(uuidString: $0.lastPathComponent) != nil }
        }
    }

    /// UUID of the organization Claude Desktop uses for `accountID`, taken from the folders it creates per
    /// account and organization. The most recently used one wins if there are several.
    ///
    /// A guess: nothing on disk says which organization Claude currently shows for this account when
    /// there is more than one. Prefer `scope(dataDir:items:)`, which uses Claude's own record of that
    /// when it has one.
    public static func organizationID(in dataDir: URL, accountID: String) -> String? {
        let orgs = organizationFolders(in: dataDir, accountID: accountID)
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return orgs.max(by: { modified($0) < modified($1) })?.lastPathComponent
    }

    /// UUIDs of every organization folder that exists for `accountID` in `dataDir`, across both the Code
    /// and Cowork session folders.
    public static func organizationIDs(in dataDir: URL, accountID: String) -> Set<String> {
        Set(organizationFolders(in: dataDir, accountID: accountID).map(\.lastPathComponent))
    }

    /// How `scope(dataDir:items:)` resolved the account's current organization.
    public enum ScopeSource: Equatable, Sendable {
        /// Claude's own `lastSidebarScopeKey`, so this is exact.
        case claude
        /// A guess: the account has exactly one organization folder on disk.
        case onlyOrgFolder
    }

    /// The account/organization scope Claude currently files sidebar and session state under, or why none
    /// could be resolved.
    public enum Scope: Equatable, Sendable {
        case resolved(String, source: ScopeSource)
        /// The account has more than one organization folder and Claude hasn't recorded which is current
        /// (`reason` is meant for a person, for example in `doctor`).
        case ambiguous(reason: String)

        /// The `account/organization` value, when one could be resolved.
        public var value: String? {
            guard case .resolved(let value, source: _) = self else { return nil }
            return value
        }
    }

    /// Resolves the `account/organization` scope Claude currently uses for the account signed in to
    /// `dataDir`: Claude's own `lastSidebarScopeKey`, read from `items` (that data directory's Local
    /// Storage for `https://claude.ai`), when it names this account; otherwise the account's only
    /// organization folder on disk; otherwise `.ambiguous`, when there is more than one and Claude hasn't
    /// recorded which is current. `nil` only when `dataDir` has no signed-in account, or none of its
    /// organization folders exist yet.
    public static func scope(dataDir: URL, items: [String: String]) -> Scope? {
        guard let account = accountID(in: dataDir) else { return nil }
        if let store = items[InterfaceSync.sidebarKey].flatMap(InterfaceSync.object),
           let state = store["state"] as? [String: Any],
           let key = state["lastSidebarScopeKey"] as? String, key.hasPrefix(account + "/") {
            return .resolved(key, source: .claude)
        }
        let orgs = organizationIDs(in: dataDir, accountID: account)
        if orgs.isEmpty { return nil }
        if orgs.count == 1, let only = orgs.first { return .resolved("\(account)/\(only)", source: .onlyOrgFolder) }
        return .ambiguous(reason: "several organizations: open the Code tab once")
    }

    public static func usage(in dataDir: URL) -> Usage? {
        struct History: Decodable {
            struct Sample: Decodable {
                struct Values: Decodable { let fh: Int?; let sd: Int? }
                let t: Double
                let u: Values?
            }
            let samples: [Sample]
        }
        guard let data = try? Data(contentsOf: dataDir.appending(path: "plan-usage-history.json")),
              let history = try? JSONDecoder().decode(History.self, from: data),
              let last = history.samples.max(by: { $0.t < $1.t })
        else { return nil }
        return Usage(fiveHour: last.u?.fh, week: last.u?.sd, sampledAt: Date(timeIntervalSince1970: last.t / 1000))
    }

    /// Email of the signed-in account, taken from the claude.ai profile that Claude Desktop caches in IndexedDB.
    /// The cache stores the account UUID shortly before `email_address`; requiring both avoids picking up
    /// unrelated addresses (for example, teammates listed in an organization).
    ///
    /// Each IndexedDB database is read record by record first: LevelDB usually Snappy-compresses its tables,
    /// which hides the profile from a scan of the files' bytes. The byte scan remains for what can't be parsed.
    public static func email(in dataDir: URL, accountID: String) -> String? {
        let root = dataDir.appending(path: "IndexedDB", directoryHint: .isDirectory)
        for database in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where database.lastPathComponent.hasSuffix(".leveldb") {
            guard let entries = try? LevelDBStore(dir: database).liveEntries() else { continue }
            for value in entries.values {
                if let found = email(inBlob: Data(value), accountID: accountID) { return found }
            }
        }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return nil }
        var files: [(Date, URL)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 64 << 20 else { continue }
            files.append((values.contentModificationDate ?? .distantPast, url))
        }
        for (_, url) in files.sorted(by: { $0.0 > $1.0 }) {
            if let data = try? Data(contentsOf: url), let found = email(inBlob: data, accountID: accountID) {
                return found
            }
        }
        return nil
    }

    static let emailMarker = Data("email_address".utf8)

    static func email(inBlob blob: Data, accountID: String) -> String? {
        let account = Data(accountID.utf8)
        var searchStart = blob.startIndex
        while let marker = blob.range(of: emailMarker, in: searchStart..<blob.endIndex) {
            searchStart = marker.upperBound
            let before = blob[max(blob.startIndex, marker.lowerBound - 80)..<marker.lowerBound]
            guard before.range(of: account) != nil else { continue }
            let after = blob[marker.upperBound..<min(blob.endIndex, marker.upperBound + 140)]
            if let found = firstEmail(in: after) { return found }
        }
        return nil
    }

    /// The first printable run in `bytes` that looks like an email address.
    static func firstEmail(in bytes: Data) -> String? {
        let text = String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
        guard let range = text.range(of: #"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,120}\.[A-Za-z]{2,24}"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
