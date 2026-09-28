import Foundation

/// Shares known display preferences and purely local Claude Code pins before a profile starts.
/// Project, cloud, Cowork-space, routine and account state stay in their owning profile: copying an ID
/// cannot give another account access to its resource. Permission choices are never remapped.
/// The main app wins except for a value changed only in the profile since the last successful merge.
/// Run it only while the profile's window is closed.
public struct InterfaceSync: Sendable {
    static let origin = "https://claude.ai"
    /// Copied as they are; removed from the profile when the main app doesn't have them.
    static let keys: Set<String> = [
        "LSS-persisted.starred-local-code-sessions", "LSS-sidebar-selected-mode", "epitaxy-editor-prefs",
        "LSS-persisted.epitaxy-transcript-links-in-preview", "LSS-persisted.epitaxy-transcript-links-chooser-seen",
        "LSS-persisted.epitaxy-default-transcript-view-nudge", "persisted.epitaxy-split-suggestion",
    ]
    static let prefixes: [String] = []
    static let accountPrefixes: [String] = []
    static let sidebarKey = "dframe-store"
    static let portableSidebarFields: Set<String> = ["sidebarWidth"]
    static let groupsField = "customGroupsByScope"
    static let pinDatabase = "keyval-store", pinObjectStore = "keyval"
    static let pinKeys = ["store:pin-state:dframe-starred-code"]

    static let desktopConfig = "claude_desktop_config.json"

    /// The `epitaxyPrefs` name of a Local Storage key, for the keys Claude keeps in both places.
    static func prefsName(_ key: String) -> String? {
        for prefix in ["LSS-persisted.", "persisted."] where key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
        return key == "ccd-sessions-filter" ? key : nil
    }

    static let prefsKeys = Set(keys.compactMap(prefsName))
    static let prefsAccountPrefixes = accountPrefixes.compactMap(prefsName)

    /// Whether this is one of the explicitly portable `epitaxyPrefs` keys.
    static func sharesPref(_ key: String) -> Bool {
        prefsKeys.contains(key) || prefsAccountPrefixes.contains(where: key.hasPrefix)
    }

    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) { self.paths = paths }

    func stateFile(for profileID: String) -> URL {
        paths.stateDir.appending(path: "Interface/\(profileID).json")
    }

    /// Stands for "no such key" in comparisons and in the state file.
    static let missing = "\u{0}"

    /// - Returns: how many entries changed.
    @discardableResult
    public func run(into dataDir: URL, profileID: String, now: Date = Date()) throws -> Int {
        let source = LocalStorage(dataDir: paths.mainDataDir), target = LocalStorage(dataDir: dataDir)
        guard !target.isInUse, let mainAccount = DesktopData.accountID(in: paths.mainDataDir),
              let account = DesktopData.accountID(in: dataDir) else { return 0 }
        let backup = Backup(paths: paths, now: now)
        let portableIDs = try Self.portableSessionIDs(in: [paths.mainDataDir, dataDir],
                                                     nativeScopeFile: paths.stateDir.appending(path: "code-native-session-scopes.json"))
        // Discard obsolete baselines for account/grant/project keys formerly copied by older releases.
        let validStateKeys = Self.keys.union(Self.prefsKeys.map { "prefs:" + $0 })
            .union(Self.pinKeys.map { "idb:" + $0 })
            .union(Self.portableSidebarFields.union(["pinnedOrder"]).map { Self.sidebarKey + "/" + $0 })
        var base = Self.readState(stateFile(for: profileID)).filter { validStateKeys.contains($0.key) }
        var changed = 0, failure: Error?
        // Each place is merged on its own copy of the agreed values, kept only if its write went through:
        // recording a value that never reached the profile would later look like a change made there.
        func stage(_ merge: (inout [String: String]) throws -> Int) {
            var attempt = base
            do {
                changed += try merge(&attempt)
                base = attempt
            } catch {
                failure = failure ?? error
            }
        }
        if source.exists, target.exists {
            stage { try mergeLocalStorage(source: source, target: target, dataDir: dataDir,
                                          mainAccount: mainAccount, account: account, portableIDs: portableIDs, base: &$0, backup: backup) }
        }
        stage { try mergePrefs(into: dataDir, mainAccount: mainAccount, account: account, portableIDs: portableIDs, base: &$0, backup: backup) }
        stage { try mergePins(into: dataDir, profileID: profileID, portableIDs: portableIDs, base: &$0, backup: backup) }
        try Self.writeState(base, to: stateFile(for: profileID))
        if let failure { throw failure }
        return changed
    }

    private func mergeLocalStorage(source: LocalStorage, target: LocalStorage, dataDir: URL, mainAccount: String,
                                   account: String, portableIDs: Set<String>, base: inout [String: String], backup: Backup) throws -> Int {
        // The main app is running, so a compaction can swap files while they are read; one retry covers that.
        let main = try (try? source.items(origin: Self.origin)) ?? source.items(origin: Self.origin)
        let own = try target.items(origin: Self.origin)

        var wanted: [String: String] = [:]   // key -> value the main app implies, or `missing`
        for key in Self.keys {
            if key == "LSS-persisted.starred-local-code-sessions",
               (!Self.isLocalSessionList(main[key], portableIDs: portableIDs) || !Self.isLocalSessionList(own[key], portableIDs: portableIDs)) { continue }
            wanted[key] = main[key] ?? Self.missing
        }
        for (key, value) in main where Self.prefixes.contains(where: key.hasPrefix) { wanted[key] = value }
        for prefix in Self.accountPrefixes { wanted[prefix + account] = main[prefix + mainAccount] ?? Self.missing }

        var set: [String: String] = [:], remove: Set<String> = []
        for (key, mainValue) in wanted {
            let ownValue = own[key] ?? Self.missing
            let mainText = Self.comparable(mainValue), ownText = Self.comparable(ownValue)
            switch Self.resolve(own: ownText, main: mainText, base: base[key]) {
            case .main:
                base[key] = mainText
                guard mainText != ownText else { continue }
                if mainValue == Self.missing { remove.insert(key) } else { set[key] = mainValue }
            case .own:
                continue
            }
        }
        if let sidebar = mergeSidebar(main: main[Self.sidebarKey], own: own[Self.sidebarKey], base: &base,
                                      mainScope: Self.scope(in: main, dataDir: paths.mainDataDir),
                                      scope: Self.scope(in: own, dataDir: dataDir), portableIDs: portableIDs) {
            set[Self.sidebarKey] = sidebar
        }

        if !set.isEmpty || !remove.isEmpty {
            _ = try backup.save(target.dbDir)
            try target.update(origin: Self.origin, set: set, remove: remove)
        }
        return set.count + remove.count
    }

    /// The portable settings in `claude_desktop_config.json` → `preferences.epitaxyPrefs`, where Claude looks first.
    /// A key the main app doesn't have is removed, so Claude falls back to Local Storage, as it does in the main app.
    private func mergePrefs(into dataDir: URL, mainAccount: String, account: String,
                            portableIDs: Set<String>, base: inout [String: String], backup: Backup) throws -> Int {
        let url = dataDir.appending(path: Self.desktopConfig)
        guard let mainConfig = SettingsSync.readJSON(paths.mainDataDir.appending(path: Self.desktopConfig)),
              var config = SettingsSync.readJSON(url) else { return 0 }
        let mainPrefs = (mainConfig["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] ?? [:]
        var preferences = config["preferences"] as? [String: Any] ?? [:]
        let own = preferences["epitaxyPrefs"] as? [String: Any] ?? [:]

        var wanted: [(key: String, value: Any?)] = Self.prefsKeys.compactMap { key in
            if key == "starred-local-code-sessions",
               (!Self.isLocalSessionList(mainPrefs[key].map(Self.canonical), portableIDs: portableIDs)
                || !Self.isLocalSessionList(own[key].map(Self.canonical), portableIDs: portableIDs)) { return nil }
            return (key, mainPrefs[key])
        }
        wanted += Self.prefsAccountPrefixes.map { ($0 + account, mainPrefs[$0 + mainAccount]) }

        var prefs = own, changed = 0
        for (key, mainValue) in wanted {
            let mainText = mainValue.map(Self.canonical) ?? Self.missing
            let ownText = own[key].map(Self.canonical) ?? Self.missing
            guard Self.resolve(own: ownText, main: mainText, base: base["prefs:" + key]) == .main else { continue }
            base["prefs:" + key] = mainText
            guard mainText != ownText else { continue }
            prefs[key] = mainValue
            changed += 1
        }
        guard changed > 0 else { return 0 }
        preferences["epitaxyPrefs"] = prefs
        config["preferences"] = preferences
        _ = try backup.save(url)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return changed
    }

    /// Purely local Code stars in IndexedDB, copied as the main app serialized them.
    /// A store that is missing, in another format or another version on either side is left alone.
    private func mergePins(into dataDir: URL, profileID: String, portableIDs: Set<String>, base: inout [String: String], backup: Backup) throws -> Int {
        let source = IndexedDBStore(dataDir: paths.mainDataDir, database: Self.pinDatabase, objectStore: Self.pinObjectStore)
        let target = IndexedDBStore(dataDir: dataDir, database: Self.pinDatabase, objectStore: Self.pinObjectStore)
        guard source.exists, target.exists, !target.isInUse else { return 0 }
        // The main app is running; one retry covers a compaction swapping files during the read.
        guard let main = try (try? source.read()) ?? source.read(), let own = try target.read(),
              main.dataVersion == own.dataVersion else { return 0 }

        var put: [String: [UInt8]] = [:], previous: [String: Any] = [:]
        for key in Self.pinKeys {
            guard let mainRecord = main.records[key], !main.blobKeys.contains(key), !own.blobKeys.contains(key),
                  let mainStore = mainRecord.string.flatMap(Self.object), let mainState = mainStore["state"] else { continue }
            var ownText = Self.missing
            if let ownRecord = own.records[key] {
                guard let ownStore = ownRecord.string.flatMap(Self.object), let ownState = ownStore["state"],
                      Self.canonical(ownStore["version"] ?? NSNull()) == Self.canonical(mainStore["version"] ?? NSNull())
                else { continue }
                ownText = Self.canonical(ownState)
            }
            // Older Claude versions could put remote session IDs in this store too. Only a
            // completely local list is portable; mixed/unknown records remain byte-for-byte intact.
            guard let mainPins = mainState as? [String: Any], Set(mainPins.keys) == ["starredIds"],
                  Self.isLocalSessionList(mainPins["starredIds"].map(Self.canonical), portableIDs: portableIDs) else { continue }
            if let ownRecord = own.records[key], let ownStore = ownRecord.string.flatMap(Self.object) {
                guard let ownPins = ownStore["state"] as? [String: Any], Set(ownPins.keys) == ["starredIds"],
                      Self.isLocalSessionList(ownPins["starredIds"].map(Self.canonical), portableIDs: portableIDs) else { continue }
            }
            let mainText = Self.canonical(mainState)
            guard Self.resolve(own: ownText, main: mainText, base: base["idb:" + key]) == .main else { continue }
            base["idb:" + key] = mainText
            guard mainText != ownText else { continue }
            put[key] = mainRecord.value
            previous[key] = own.records[key]?.string ?? NSNull()
        }
        guard !put.isEmpty else { return 0 }
        // Only the replaced values are kept: the rest of this database can hold the profile's sign-in keys.
        try backup.saveValues(previous, as: "Interface/\(profileID)-IndexedDB.json")
        try target.write(put, into: own)
        return put.count
    }

    /// The merged sidebar store to write, or `nil` if the profile's is already right.
    private func mergeSidebar(main: String?, own: String?, base: inout [String: String],
                              mainScope: String?, scope: String?, portableIDs: Set<String>) -> String? {
        guard let main, let mainStore = Self.object(main), let mainState = mainStore["state"] as? [String: Any] else { return nil }
        let ownStore = own.flatMap(Self.object) ?? [:]
        // Another store version means another layout; the app migrates its own data, so the two aren't mixed.
        if own != nil, Self.canonical(ownStore["version"] ?? NSNull()) != Self.canonical(mainStore["version"] ?? NSNull()) {
            return nil
        }
        let ownState = ownStore["state"] as? [String: Any] ?? [:]
        var state = ownState
        var wanted = mainState.filter { Self.portableSidebarFields.contains($0.key) }
        // Keep cloud Projects and other account-owned pins. A mixed list cannot be copied safely.
        if let pins = mainState["pinnedOrder"] as? [String], pins.allSatisfy({ $0.hasPrefix("code:") && portableIDs.contains(String($0.dropFirst(5))) }),
           ownState["pinnedOrder"] == nil || (ownState["pinnedOrder"] as? [String])?.allSatisfy({ $0.hasPrefix("code:") && portableIDs.contains(String($0.dropFirst(5))) }) == true {
            wanted["pinnedOrder"] = pins
        }
        for (field, mainValue) in wanted {
            let key = "\(Self.sidebarKey)/\(field)"
            let mainText = Self.canonical(mainValue), ownText = ownState[field].map(Self.canonical) ?? Self.missing
            if Self.resolve(own: ownText, main: mainText, base: base[key]) == .main {
                state[field] = mainValue
                base[key] = mainText
            }
        }
        guard own == nil || !NSDictionary(dictionary: state).isEqual(to: ownState) else { return nil }
        var store = mainStore
        store["state"] = state
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A plain array or the standard Local Storage wrapper containing only local session IDs.
    /// Unknown representations are deliberately not treated as empty lists.
    static func isLocalSessionList(_ text: String?, portableIDs: Set<String>) -> Bool {
        guard let text else { return true }
        guard var value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else { return false }
        if let wrapper = value as? [String: Any], let inner = wrapper["value"] { value = inner }
        guard let ids = value as? [String] else { return false }
        return ids.allSatisfy { portableIDs.contains($0) }
    }

    /// A local_ prefix alone is not enough: native Project workers use it too. Require a valid
    /// ordinary Code card, and exclude an ID if any copy has native ownership or an unknown shape.
    static func portableSessionIDs(in dataDirs: [URL], nativeScopeFile: URL) throws -> Set<String> {
        // Native ownership outlives the card's current fields. A malformed ownership file must stop
        // the merge before any interface value changes, rather than make remembered workers portable.
        let remembered = try SessionSync.NativeScopeState.load(from: nativeScopeFile)
        var ordinary = Set<String>()
        var ownedOrUnknown = Set(remembered.scopes.keys.map { name in
            name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        })
        for pair in try SessionSync.sessionPairs(dataDirs: dataDirs, folder: SessionSync.sessionsFolder) {
            for url in try FileManager.default.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                let id = url.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: url),
                      let card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      !SessionSync.isAccountBoundCard(card) else {
                    ownedOrUnknown.insert(id)
                    continue
                }
                ordinary.insert(id)
            }
        }
        return ordinary.subtracting(ownedOrUnknown)
    }

    enum Side { case main, own }

    /// Three-way choice against `base`, the value both sides last agreed on (`nil` if never recorded).
    /// Only a change made on the profile's side alone is kept.
    static func resolve(own: String, main: String, base: String?) -> Side {
        guard let base, own != base else { return .main }
        return main == base ? .own : .main
    }

    /// `account/organization`, the key Claude files per-account sidebar state under.
    static func scope(in items: [String: String], dataDir: URL) -> String? {
        DesktopData.scope(dataDir: dataDir, items: items)?.value
    }

    /// What a value means, without the bookkeeping Claude adds to `LSS-` entries (the writing tab and time).
    static func comparable(_ value: String) -> String {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) else { return value }
        if let wrapper = parsed as? [String: Any], wrapper["timestamp"] != nil, let inner = wrapper["value"] {
            return canonical(inner)
        }
        return canonical(parsed)
    }

    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func readState(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    static func writeState(_ state: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
