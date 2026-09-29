import Foundation

/// One window's Code sidebar layout for one account scope: its groups, which sessions are in them and in what order,
/// its pins and their order. Handing work to another window carries the handed-over sessions' part of it.
///
/// Claude keeps each part in a primary store (Local Storage `dframe-store` for groups and pin order, IndexedDB for
/// pins) and mirrors it in Local Storage `LSS-persisted.*` and in `claude_desktop_config.json` → `epitaxyPrefs`. At
/// start it hydrates the primary stores and restores from the settings only what is missing. Whether it rewrites the
/// mirrors after every change is not measured, so reading never trusts one source alone, and writing writes them all.
struct SidebarLayout: Equatable {
    struct Group: Equatable {
        var id: String
        var name: String
        /// Other fields of the group, each as canonical JSON, kept as they are.
        var extra: [String: String] = [:]
    }
    var groups: [Group] = []
    /// `"code:local_<card>"` → group id.
    var assignments: [String: String] = [:]
    /// Group id → `["code:local_<card>", …]`.
    var order: [String: [String]] = [:]
    /// `["local_<card>", …]`
    var starred: [String] = []
    /// `["code:local_<card>", …]`
    var pinnedOrder: [String] = []

    struct CarryReport: Equatable {
        var groupsMatched = 0, groupsAdded = 0, pinsAdded = 0, ordered = 0
        var markerSet = false
        /// Group name → sessions that may lose the group at Claude's merge with its server copy.
        var ungrouped: [String: Int] = [:]
        /// Parts left alone, with the reason.
        var skipped: [String] = []
    }

    /// The layout was written but didn't read back as written; every place was put back as it was.
    struct NotCarried: Error, Equatable, LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    static let pinKey = "store:pin-state:dframe-starred-code"
    static let groupsMirror = "LSS-persisted.dframe-group-scopes", sliceMirror = "LSS-persisted.dframe-local-slice"
    static let starredMirror = "LSS-persisted.starred-local-code-sessions"
    static let groupsPref = "dframe-group-scopes", slicePref = "dframe-local-slice", starredPref = "starred-local-code-sessions"
    /// Makes Claude upload its sidebar store to the account's server copy at its next start; `|migrate` merges the two.
    static let pendingKey = "ccd-sync-pending:ccd/dframe-store", migrate = "|migrate"
    /// The account whose server copy this Local Storage last synced with; Claude honours the marker only for it.
    static let ownerKey = "ccd-sync-owner"

    // MARK: Reading

    /// What one source says, and how much and how recently.
    struct Source<Value> {
        var name: String
        var value: Value
        var length: Int
        var time: Date
    }

    /// The longer source, ties broken by the newer one.
    static func pick<Value>(_ sources: [Source<Value>], _ what: String, dataDir: URL) -> Value? {
        guard
            let best = sources.enumerated().max(by: { a, b in
                (a.element.length, a.element.time, -a.offset) < (b.element.length, b.element.time, -b.offset)
            })?.element
        else { return nil }
        if sources.count > 1 {
            let all = sources.map { "\($0.name) \($0.length)" }.joined(separator: ", ")
            Log.notice("layout", "\(dataDir.lastPathComponent): \(what) from \(best.name) (\(all))")
        }
        return best.value
    }

    /// Every source of a window, read without writing anything, so an open window can be read too.
    /// `nil` when the window has none of them.
    static func read(dataDir: URL, scope: String) -> SidebarLayout? {
        let files = Files(dataDir: dataDir)
        guard files.items != nil || files.prefs != nil || files.pinRecord != nil else { return nil }
        var layout = SidebarLayout()

        if let groups = files.storeScope(scope).flatMap({ ScopeValue(json: $0) }) {
            layout.take(groups)
        } else {
            var sources: [Source<ScopeValue>] = []
            if let mirror = files.mirror(groupsMirror), let value = ScopeValue(json: (mirror.value as? [String: Any])?[scope]) {
                sources.append(Source(name: "Local Storage", value: value, length: value.assignments.count, time: mirror.time))
            }
            if let value = ScopeValue(json: (files.prefs?[groupsPref] as? [String: Any])?[scope]) {
                sources.append(Source(name: "settings", value: value, length: value.assignments.count, time: files.prefsTime))
            }
            if let value = pick(sources, "groups", dataDir: dataDir) { layout.take(value) }
        }

        var pins: [Source<[String]>] = []
        if let record = files.pinObject, let ids = (record["state"] as? [String: Any])?["starredIds"] as? [String] {
            let time = (record["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            pins.append(Source(name: "IndexedDB", value: ids, length: ids.count, time: time))
        }
        if let mirror = files.mirror(starredMirror), let ids = mirror.value as? [String] {
            pins.append(Source(name: "Local Storage", value: ids, length: ids.count, time: mirror.time))
        }
        if let ids = files.prefs?[starredPref] as? [String] {
            pins.append(Source(name: "settings", value: ids, length: ids.count, time: files.prefsTime))
        }
        layout.starred = pick(pins, "pins", dataDir: dataDir) ?? []

        var order: [Source<[String]>] = []
        if let ids = files.storeState?["pinnedOrder"] as? [String] {
            order.append(Source(name: "dframe-store", value: ids, length: ids.count, time: files.storageTime))
        }
        if let mirror = files.mirror(sliceMirror), let ids = (mirror.value as? [String: Any])?["pinnedOrder"] as? [String] {
            order.append(Source(name: "Local Storage", value: ids, length: ids.count, time: mirror.time))
        }
        if let ids = (files.prefs?[slicePref] as? [String: Any])?["pinnedOrder"] as? [String] {
            order.append(Source(name: "settings", value: ids, length: ids.count, time: files.prefsTime))
        }
        layout.pinnedOrder = pick(order, "pin order", dataDir: dataDir) ?? []
        return layout
    }

    private mutating func take(_ value: ScopeValue) {
        groups = value.groups
        assignments = value.assignments
        order = value.order
    }

    // MARK: Slicing

    /// Only ordinary local Code items whose card (`local_<card>`) is in `cards`; `renamed` maps an original card to
    /// the copy that stands for it in the destination.
    func slice(cards: Set<String>, renamed: [String: String]) -> SidebarLayout {
        func keep(_ item: String) -> String? {
            guard item.hasPrefix("code:local_") else { return nil }
            let card = String(item.dropFirst(5))
            guard cards.contains(card) else { return nil }
            return "code:" + (renamed[card] ?? card)
        }
        let known = Set(groups.map(\.id))
        var result = SidebarLayout()
        for (item, group) in assignments where known.contains(group) {
            if let kept = keep(item) { result.assignments[kept] = group }
        }
        for (group, items) in order where known.contains(group) {
            let kept = items.compactMap(keep).filter { result.assignments[$0] == group }
            if !kept.isEmpty { result.order[group] = kept }
        }
        let used = Set(result.assignments.values)
        result.groups = groups.filter { used.contains($0.id) }
        result.starred = starred.filter { $0.hasPrefix("local_") && cards.contains($0) }.map { renamed[$0] ?? $0 }
        result.pinnedOrder = pinnedOrder.compactMap(keep)
        return result
    }

    /// The slice's grouped items in the source's order: each group's listed items, then the rest by name.
    var orderedItems: [(item: String, group: String)] {
        var seen = Set<String>(), result: [(String, String)] = []
        for group in groups {
            for item in order[group.id] ?? [] where assignments[item] == group.id && seen.insert(item).inserted {
                result.append((item, group.id))
            }
        }
        for (item, group) in assignments.sorted(by: { $0.key < $1.key }) where seen.insert(item).inserted {
            result.append((item, group))
        }
        return result
    }

    // MARK: Carrying

    /// Writes `slice` into a CLOSED window, merged with what it has: pins in IndexedDB, groups and pin order in
    /// `dframe-store`, then the Local Storage mirrors and the settings, all equal. Each place is backed up first and
    /// read back after; on a mismatch every place is put back and `NotCarried` is thrown. The caller holds
    /// `open.lock`, as every write to a window's settings does. Throws `LocalStorageError.databaseInUse` if open.
    ///
    /// A group new to the destination account is added with Claude's own `|migrate` marker, so Claude syncs the
    /// group's name and id to that account at its next start, as it does for a group made there by hand. Pins get no
    /// marker: they stay local.
    static func carry(
        _ slice: SidebarLayout, into dataDir: URL, scope: String, account: String,
        backup: Backup, now: Date, afterWrite: () throws -> Void = {}
    ) throws -> CarryReport {
        let files = Files(dataDir: dataDir)
        guard !files.storage.isInUse, !files.pins.isInUse else { throw LocalStorageError.databaseInUse }
        if files.configExists, files.config == nil {
            throw NotCarried(reason: "\(InterfaceSync.desktopConfig) can't be read")
        }
        let destination = read(dataDir: dataDir, scope: scope) ?? SidebarLayout()
        var report = CarryReport()
        let ms = Int64(now.timeIntervalSince1970 * 1000)

        // Groups and pin order need a store Baton knows, or no store at all (Claude then restores from the settings).
        var storeKnown = true
        if let version = files.store?["version"], (version as? Int) != 1 {
            storeKnown = false
            report.skipped.append("sidebar store version \(InterfaceSync.canonical(version))")
        } else if files.items?[InterfaceSync.sidebarKey] != nil, files.storeState == nil {
            storeKnown = false
            report.skipped.append("sidebar store has an unknown layout")
        }

        // Groups.
        var scopeValue: [String: Any]?
        if storeKnown, !slice.assignments.isEmpty {
            var merged = ScopeValue(layout: destination)
            var mapping: [String: String] = [:], added: [String: String] = [:]
            for group in slice.groups {
                if merged.groups.contains(where: { $0.id == group.id }) {
                    mapping[group.id] = group.id
                    report.groupsMatched += 1
                } else if let same = merged.groups.first(where: { $0.name == group.name }) {
                    mapping[group.id] = same.id
                    report.groupsMatched += 1
                } else {
                    merged.groups.append(group)
                    mapping[group.id] = group.id
                    added[group.id] = group.name
                    report.groupsAdded += 1
                }
            }
            for (item, source) in slice.orderedItems {
                guard let group = mapping[source] else { continue }
                merged.assignments[item] = group
                for key in merged.order.keys where key != group { merged.order[key]?.removeAll { $0 == item } }
                if merged.order[group]?.contains(item) != true { merged.order[group, default: []].append(item) }
                report.ordered += 1
            }
            if !added.isEmpty {
                let marker = files.items?[pendingKey], owner = files.items?[ownerKey]
                if files.items != nil, marker == nil, owner == nil || owner == account {
                    report.markerSet = true
                } else if marker != scope && marker != scope + migrate {
                    // Claude keeps local assignments only to groups its server copy knows.
                    for (id, name) in added {
                        let count = slice.assignments.values.filter { $0 == id }.count
                        if count > 0 { report.ungrouped[name, default: 0] += count }
                    }
                }
            }
            var base = files.storeScope(scope) ?? [:]
            if files.storeScope(scope) == nil {
                base = ((files.mirror(groupsMirror)?.value as? [String: Any])?[scope] as? [String: Any]) ?? [:]
            }
            scopeValue = merged.json(over: base)
        }

        // Pin order.
        var pinnedOrder: [String]?
        if storeKnown, !slice.pinnedOrder.isEmpty {
            let existing = files.storeState?["pinnedOrder"] as? [String] ?? destination.pinnedOrder
            pinnedOrder = slice.pinnedOrder + existing.filter { !slice.pinnedOrder.contains($0) }
        }

        // Pins: IndexedDB first; without a record, Claude restores them from the settings into its empty store.
        var starred: [String]?, pinBytes: [UInt8]?, pinText: String?
        if !slice.starred.isEmpty {
            if let record = files.pinRecord {
                if files.pinBlob {
                    report.skipped.append("pin record has blobs")
                } else if var object = files.pinObject, (object["version"] as? Int) == 0,
                    var state = object["state"] as? [String: Any], let existing = state["starredIds"] as? [String]
                {
                    let list = slice.starred + existing.filter { !slice.starred.contains($0) }
                    state["starredIds"] = list
                    object["state"] = state
                    object["updatedAt"] = ms
                    let text = json(object)
                    if let bytes = IDBValue.encode(text, like: record.value) {
                        (starred, pinBytes, pinText) = (list, bytes, text)
                        report.pinsAdded = slice.starred.filter { !existing.contains($0) }.count
                    } else {
                        report.skipped.append("pin record has a layout Baton can't write")
                    }
                } else {
                    report.skipped.append("pin record has an unknown version or layout")
                }
            } else {
                let existing = destination.starred
                starred = slice.starred + existing.filter { !slice.starred.contains($0) }
                report.pinsAdded = slice.starred.filter { !existing.contains($0) }.count
            }
        }

        // Local Storage: the store and its mirrors, and the marker.
        var set: [String: String] = [:]
        if let items = files.items {
            if var store = files.store, var state = files.storeState, scopeValue != nil || pinnedOrder != nil {
                if let scopeValue {
                    var scopes = state[InterfaceSync.groupsField] as? [String: Any] ?? [:]
                    scopes[scope] = scopeValue
                    state[InterfaceSync.groupsField] = scopes
                }
                if let pinnedOrder { state["pinnedOrder"] = pinnedOrder }
                store["state"] = state
                set[InterfaceSync.sidebarKey] = json(store)
            }
            if let scopeValue {
                var scopes = files.mirror(groupsMirror)?.value as? [String: Any] ?? [:]
                scopes[scope] = scopeValue
                set[groupsMirror] = mirrorText(scopes, items[groupsMirror], ms)
            }
            if let pinnedOrder {
                var value = files.mirror(sliceMirror)?.value as? [String: Any] ?? ["homeProjectsPinnedOrder": [String]()]
                value["pinnedOrder"] = pinnedOrder
                set[sliceMirror] = mirrorText(value, items[sliceMirror], ms)
            }
            if let starred, items[starredMirror] != nil { set[starredMirror] = mirrorText(starred, items[starredMirror], ms) }
            if report.markerSet { set[pendingKey] = scope + migrate }
        }

        // Settings.
        var config = files.config, prefsChanged = false
        if var whole = config, SettingsSync.mayWrite(files.configURL, in: dataDir) {
            var preferences = whole["preferences"] as? [String: Any] ?? [:]
            var prefs = preferences["epitaxyPrefs"] as? [String: Any] ?? [:]
            if let scopeValue {
                var scopes = prefs[groupsPref] as? [String: Any] ?? [:]
                scopes[scope] = scopeValue
                prefs[groupsPref] = scopes
                prefsChanged = true
            }
            if let pinnedOrder {
                var value = prefs[slicePref] as? [String: Any] ?? ["homeProjectsPinnedOrder": [String]()]
                value["pinnedOrder"] = pinnedOrder
                prefs[slicePref] = value
                prefsChanged = true
            }
            if let starred {
                prefs[starredPref] = starred
                prefsChanged = true
            }
            preferences["epitaxyPrefs"] = prefs
            whole["preferences"] = preferences
            config = whole
        }

        guard pinBytes != nil || !set.isEmpty || prefsChanged else {
            Log.notice("layout", "\(dataDir.lastPathComponent): nothing to carry (\(report.skipped.joined(separator: "; ")))")
            return report
        }

        // Backups, then the writes, primary stores first.
        let oldPin = files.pinRecord?.value, oldItems = files.items ?? [:]
        let oldConfig = prefsChanged ? try Data(contentsOf: LocalOnly.writeTarget(files.configURL)) : nil
        if pinBytes != nil {
            try backup.saveValues([pinKey: files.pinRecord?.string ?? NSNull()], as: "Layout/\(dataDir.lastPathComponent)-IndexedDB.json")
        }
        if !set.isEmpty { _ = try backup.save(files.storage.dbDir) }
        if prefsChanged { _ = try backup.save(LocalOnly.writeTarget(files.configURL)) }

        var configData: Data?
        do {
            if let pinBytes, let snapshot = files.snapshot { try files.pins.write([pinKey: pinBytes], into: snapshot) }
            if !set.isEmpty { try files.storage.update(origin: InterfaceSync.origin, set: set, remove: []) }
            if prefsChanged, let config {
                let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try LocalOnly.replace(files.configURL, with: data)
                configData = data
            }
            try afterWrite()
        } catch {
            restore(files, pin: pinBytes == nil ? nil : oldPin, items: oldItems, keys: Set(set.keys), config: oldConfig)
            throw error
        }

        // Read back every place written.
        let again = Files(dataDir: dataDir)
        var mismatch: [String] = []
        if let pinText, again.pinRecord?.string != pinText { mismatch.append("IndexedDB") }
        if set.contains(where: { again.items?[$0.key] != $0.value }) { mismatch.append("Local Storage") }
        if let configData, (try? Data(contentsOf: LocalOnly.writeTarget(files.configURL))) != configData { mismatch.append("settings") }
        guard mismatch.isEmpty else {
            restore(files, pin: pinBytes == nil ? nil : oldPin, items: oldItems, keys: Set(set.keys), config: oldConfig)
            Log.error("layout", "\(dataDir.lastPathComponent): \(mismatch.joined(separator: ", ")) didn't read back; put back as it was")
            throw NotCarried(reason: "\(mismatch.joined(separator: ", ")) didn't read back as written")
        }
        Log.notice(
            "layout",
            "\(dataDir.lastPathComponent): \(report.ordered) grouped (\(report.groupsMatched) groups matched, \(report.groupsAdded) added"
                + "\(report.markerSet ? ", marker set" : "")), \(report.pinsAdded) pins added")
        return report
    }

    /// Puts back what `carry` replaced: the pin record's old bytes, the Local Storage keys' old values, the settings file.
    private static func restore(_ files: Files, pin: [UInt8]?, items: [String: String], keys: Set<String>, config: Data?) {
        if let pin, let snapshot = try? files.pins.read() { try? files.pins.write([pinKey: pin], into: snapshot) }
        if !keys.isEmpty {
            let set = items.filter { keys.contains($0.key) }
            try? files.storage.update(origin: InterfaceSync.origin, set: set, remove: keys.subtracting(set.keys))
        }
        if let config { try? LocalOnly.replace(files.configURL, with: config) }
    }

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Claude's `LSS-persisted` wrapper around `value`, keeping the previous entry's tab.
    static func mirrorText(_ value: Any, _ previous: String?, _ ms: Int64) -> String {
        let tab = previous.flatMap(InterfaceSync.object)?["tabId"] ?? ""
        return json(["value": value, "tabId": tab, "timestamp": ms] as [String: Any])
    }

    // MARK: One scope's groups

    /// `{groups: [{id, name, …}], assignments: {item: group}, order: {group: [item]}}`.
    struct ScopeValue {
        var groups: [Group] = []
        var assignments: [String: String] = [:]
        var order: [String: [String]] = [:]

        init(layout: SidebarLayout) {
            groups = layout.groups
            assignments = layout.assignments
            order = layout.order
        }

        /// `nil` for a layout Baton doesn't know.
        init?(json: Any?) {
            guard let object = json as? [String: Any],
                let groups = (object["groups"] ?? [Any]()) as? [[String: Any]],
                let assignments = (object["assignments"] ?? [String: Any]()) as? [String: String],
                let order = (object["order"] ?? [String: Any]()) as? [String: [String]]
            else { return nil }
            var parsed: [Group] = []
            for group in groups {
                guard let id = group["id"] as? String else { return nil }
                let extra = group.filter { $0.key != "id" && $0.key != "name" }.mapValues(InterfaceSync.canonical)
                parsed.append(Group(id: id, name: group["name"] as? String ?? "", extra: extra))
            }
            self.groups = parsed
            self.assignments = assignments
            self.order = order
        }

        /// This value over `base`, whose other fields stay.
        func json(over base: [String: Any]) -> [String: Any] {
            var result = base
            result["groups"] = groups.map { group -> [String: Any] in
                var object: [String: Any] = ["id": group.id, "name": group.name]
                for (key, text) in group.extra {
                    object[key] = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
                }
                return object
            }
            result["assignments"] = assignments
            result["order"] = order
            return result
        }
    }

    // MARK: A window's files

    /// Everything `read` and `carry` look at in one window, read once.
    struct Files {
        let dataDir: URL
        let storage: LocalStorage
        let pins: IndexedDBStore
        let items: [String: String]?
        let snapshot: IndexedDBStore.Snapshot?
        let configURL: URL
        let configExists: Bool
        let config: [String: Any]?

        init(dataDir: URL) {
            self.dataDir = dataDir
            storage = LocalStorage(dataDir: dataDir)
            pins = IndexedDBStore(dataDir: dataDir, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
            // An open window can compact a database while it is read; one retry covers that.
            let origin = InterfaceSync.origin
            items = storage.exists ? (try? storage.items(origin: origin)) ?? (try? storage.items(origin: origin)) : nil
            snapshot = pins.exists ? ((try? pins.read()) ?? (try? pins.read())) : nil
            configURL = dataDir.appending(path: InterfaceSync.desktopConfig)
            configExists = FileManager.default.fileExists(atPath: configURL.path)
            config = SettingsSync.readJSON(configURL)
        }

        var prefs: [String: Any]? { (config?["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] }
        var prefsTime: Date { Self.modified(LocalOnly.writeTarget(configURL)) }
        /// When Claude last wrote its Local Storage: the newest file of the database.
        var storageTime: Date {
            let files = (try? FileManager.default.contentsOfDirectory(at: storage.dbDir, includingPropertiesForKeys: nil)) ?? []
            return files.map(Self.modified).max() ?? .distantPast
        }

        var store: [String: Any]? { items?[InterfaceSync.sidebarKey].flatMap(InterfaceSync.object) }
        /// The store's state, only for the store version Baton knows.
        var storeState: [String: Any]? {
            guard let store, store["version"] as? Int == 1 else { return nil }
            return store["state"] as? [String: Any]
        }
        func storeScope(_ scope: String) -> [String: Any]? {
            (storeState?[InterfaceSync.groupsField] as? [String: Any])?[scope] as? [String: Any]
        }

        /// An `LSS-persisted` entry's value and time.
        func mirror(_ key: String) -> (value: Any, time: Date)? {
            guard let object = items?[key].flatMap(InterfaceSync.object), let value = object["value"] else { return nil }
            let time = (object["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            return (value, time)
        }

        var pinRecord: IndexedDBStore.Record? { snapshot?.records[SidebarLayout.pinKey] }
        var pinBlob: Bool { snapshot?.blobKeys.contains(SidebarLayout.pinKey) == true }
        var pinObject: [String: Any]? { pinRecord?.string.flatMap(InterfaceSync.object) }

        static func modified(_ url: URL) -> Date {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        }
    }
}
