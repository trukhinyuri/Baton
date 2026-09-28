import Foundation

/// Shares Code sidebar groups between every window: a group made in one window appears in all the others, each
/// under its own account's scope. Only ordinary local Code sessions travel with a group. Cowork, cloud and
/// account-bound items, and groups holding nothing else, stay in their window. Cloud Code Projects belong to one
/// account and are never touched.
///
/// Claude keeps a scope's groups in Local Storage `dframe-store`, read once when a window starts, and mirrors them
/// into `epitaxyPrefs["dframe-group-scopes"]`, which a running window rewrites after every change. So every window
/// is read and only closed ones are written. What each window changed since the last state Claude reported there
/// is merged into one shared copy, the latest editor winning a conflict; each closed window then gets that copy
/// next to its own groups. `Groups.json` keeps the shared copy and, per window, that last state and what was
/// last written there.
public struct GroupSync: Sendable {
    static let prefsKey = "dframe-group-scopes"
    /// Makes Claude upload a window's groups to its account's server copy instead of taking the server's list.
    /// `|migrate` merges the two; a bare scope replaces the server's list, so a removal isn't undone.
    static let pendingKey = "ccd-sync-pending:ccd/dframe-store"
    static let migrate = "|migrate"
    /// The account whose server copy a window's Local Storage last synced with. Claude honours the marker only
    /// when it is unset or this window's own account.
    static let ownerKey = "ccd-sync-owner"

    public struct Report: Equatable, Sendable {
        /// Windows whose groups were written.
        public var windowsChanged: [String] = []
        /// Groups shared between windows after the run.
        public var groupsShared = 0
        /// Windows left alone, with the reason.
        public var skipped: [String] = []
    }

    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    var stateFile: URL { paths.stateDir.appending(path: "Groups.json") }

    /// - Parameter windows: every window: `"main"` or a profile id, with its data directory.
    @discardableResult
    public func run(windows: [(id: String, dataDir: URL)], now: Date = Date()) throws -> Report {
        var report = Report()
        let ids = try InterfaceSync.portableSessionIDs(in: windows.map(\.dataDir),
                                                      nativeScopeFile: paths.stateDir.appending(path: "code-native-session-scopes.json"))
        var (canonical, records) = readState()
        var found: [Window] = [], unreadable: Set<String> = []
        for (id, dataDir) in windows {
            do {
                if let window = try read(id: id, dataDir: dataDir) { found.append(window) }
            } catch {
                unreadable.insert(id)
                report.skipped.append("\(id): \(error.localizedDescription); left unchanged")
            }
        }
        // A window that is gone, signed out or signed in to another account starts over.
        records = records.filter { id, record in
            unreadable.contains(id) || found.contains { $0.id == id && $0.scope == record.scope }
        }

        // Oldest edit first, so the latest editor wins.
        for window in found.sorted(by: Window.editedEarlier) {
            let observed = window.current.portable(ids)
            var record = records[window.id] ?? Record(scope: window.scope)
            let written = record.written?.portable(ids)
            // Still what Claude Profiles wrote: Claude hasn't reported this window's own state since.
            if let written, observed.text == written.text { continue }
            // With the marker honoured, Claude started from what was written, so what is missing now was removed
            // there. Without it Claude may have taken its server copy instead, which removes nothing.
            let start = record.marked ? written : nil
            canonical.merge(observed, base: start ?? record.base?.portable(ids), written: written)
            record.base = observed
            record.written = nil
            record.marked = false
            records[window.id] = record
        }
        canonical.normalize(ids)

        let backup = Backup(paths: paths, now: now)
        for window in found where !window.running {
            var record = records[window.id] ?? Record(scope: window.scope)
            // Groups this window got from the shared copy; one nobody shares any more was deleted elsewhere.
            let before = Set(record.base?.ids ?? []).union(record.written?.ids ?? [])
            do {
                guard let written = try write(window, shared: canonical, before: before, ids: ids, backup: backup) else { continue }
                record.written = written.portable(ids)
                record.marked = window.honoursMarker
                records[window.id] = record
                report.windowsChanged.append(window.id)
            } catch {
                report.skipped.append("\(window.id): \(error.localizedDescription)")
            }
        }
        try writeState(canonical, records)
        report.groupsShared = canonical.groups.count
        return report
    }

    // MARK: Reading

    /// One signed-in window's groups for its own scope, from both of Claude's copies.
    struct Window {
        let id: String, dataDir: URL, account: String, scope: String, running: Bool
        /// When the window last wrote its preferences, which a running window does after every group change.
        let modified: Date
        var config: [String: Any]?
        var prefs: Value?
        /// Local Storage `dframe-store` of a closed window.
        var store: [String: Any]?
        var local: Value?
        var marker: String?
        var owner: String?
        /// Whether it has a Local Storage database, where the marker goes.
        var hasStorage = false

        /// Whether Claude will keep what is written here rather than take its server copy: the marker goes to
        /// Local Storage, and Claude acts on it only for the account that last synced this store.
        var honoursMarker: Bool { hasStorage && (owner == nil || owner == account) }

        /// What the window shows: a running one's preferences; for a closed one, what Claude will start with.
        var current: Value { running ? prefs ?? Value() : GroupSync.hydrate(local: local, prefs: prefs) }

        static func editedEarlier(_ a: Window, _ b: Window) -> Bool {
            if a.modified != b.modified { return a.modified < b.modified }
            return a.id < b.id
        }
    }

    struct Unreadable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// - Returns: `nil` if the window isn't signed in. Throws if its groups can't be read safely.
    private func read(id: String, dataDir: URL) throws -> Window? {
        guard let account = DesktopData.accountID(in: dataDir) else { return nil }
        let storage = LocalStorage(dataDir: dataDir)
        let running = storage.isInUse
        var items: [String: String] = [:]
        if storage.exists {
            // A running window can compact its database while it is read; one retry covers that.
            let origin = InterfaceSync.origin
            items = running ? (try? storage.items(origin: origin)) ?? (try? storage.items(origin: origin)) ?? [:]
                            : try storage.items(origin: origin)
        }
        guard let scope = InterfaceSync.scope(in: items, account: account, dataDir: dataDir) else { return nil }
        let url = dataDir.appending(path: InterfaceSync.desktopConfig)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        var window = Window(id: id, dataDir: dataDir, account: account, scope: scope, running: running, modified: modified ?? .distantPast)

        if FileManager.default.fileExists(atPath: url.path) {
            guard let config = SettingsSync.readJSON(url) else { throw Unreadable(reason: "\(InterfaceSync.desktopConfig) can't be read") }
            guard let preferences = (config["preferences"] ?? [String: Any]()) as? [String: Any],
                  let epitaxy = (preferences["epitaxyPrefs"] ?? [String: Any]()) as? [String: Any],
                  let scopes = (epitaxy[Self.prefsKey] ?? [String: Any]()) as? [String: Any] else {
                throw Unreadable(reason: "its preferences have an unknown layout")
            }
            window.config = config
            if let value = scopes[scope] {
                guard let prefs = Value(value) else { throw Unreadable(reason: "its sidebar groups have an unknown layout") }
                window.prefs = prefs
            }
        }
        guard !running else { return window }
        if let text = items[InterfaceSync.sidebarKey] {
            guard let store = InterfaceSync.object(text), store["version"] as? Int == 1,
                  let state = store["state"] as? [String: Any],
                  let scopes = (state[InterfaceSync.groupsField] ?? [String: Any]()) as? [String: Any] else {
                throw Unreadable(reason: "its sidebar store has an unknown version or layout")
            }
            window.store = store
            if let value = scopes[scope] {
                guard let local = Value(value) else { throw Unreadable(reason: "its sidebar groups have an unknown layout") }
                // Claude keeps an empty scope only in its full form; any other empty one counts as missing.
                if !local.isEmpty || Value.isFullEmpty(value) { window.local = local }
            }
        }
        window.marker = items[Self.pendingKey]
        window.owner = items[Self.ownerKey]
        window.hasStorage = storage.exists
        return window
    }

    /// What Claude starts with: if Local Storage has the scope, even empty, its groups win and the preferences add
    /// assignments and order for those groups; otherwise the preferences are taken whole.
    static func hydrate(local: Value?, prefs: Value?) -> Value {
        guard let local else { return prefs ?? Value() }
        guard let prefs, !local.isEmpty else { return local }
        let known = Set(local.ids)
        var result = local
        for (item, group) in prefs.assignments where known.contains(group) && result.assignments[item] == nil {
            result.assignments[item] = group
        }
        for (group, items) in prefs.order where known.contains(group) {
            let own = result.order[group] ?? []
            result.order[group] = own + items.filter { !own.contains($0) }
        }
        return result
    }

    // MARK: Writing

    /// Writes the shared groups into a closed window next to its own: both copies, and the marker that makes
    /// Claude upload them. Both copies are backed up first.
    /// - Returns: the groups the window now starts with, or `nil` if it was already up to date.
    private func write(_ window: Window, shared: Value, before: Set<String>, ids: Set<String>, backup: Backup) throws -> Value? {
        let local = Self.project(window.current, shared: shared, before: before, ids: ids)
        let prefs = Self.project(window.prefs ?? Value(), shared: shared, before: before, ids: ids).withoutEmptyGroups
        let storeChanged = window.store != nil && local.text != (window.local ?? Value()).text
        let prefsChanged = window.config != nil && prefs.text != (window.prefs ?? Value()).text
        guard storeChanged || prefsChanged else { return nil }
        let storage = LocalStorage(dataDir: window.dataDir)
        guard !storage.isInUse else { throw LocalStorageError.databaseInUse }

        // A bare marker replaces the server's list; `|migrate` would bring back what was removed here.
        // One Claude hasn't consumed yet may stand for removals made in the window itself, so it stays bare.
        let current = window.current
        let removes = current.ids.contains { local.group($0) == nil }
            || current.assignments.keys.contains { local.assignments[$0] == nil }
        let pending = window.marker.map { !$0.hasSuffix(Self.migrate) && ($0 == window.scope || $0 == "1") } ?? false
        let marker = removes || pending ? window.scope : window.scope + Self.migrate

        let url = window.dataDir.appending(path: InterfaceSync.desktopConfig)
        if prefsChanged { _ = try backup.save(url) }
        if storage.exists { _ = try backup.save(storage.dbDir) }
        // The preferences first: if Local Storage then can't be written, Claude still starts from its own groups.
        if prefsChanged, var config = window.config {
            var preferences = config["preferences"] as? [String: Any] ?? [:]
            var epitaxy = preferences["epitaxyPrefs"] as? [String: Any] ?? [:]
            var scopes = epitaxy[Self.prefsKey] as? [String: Any] ?? [:]
            scopes[window.scope] = prefs.isEmpty ? nil : prefs.json
            epitaxy[Self.prefsKey] = scopes
            preferences["epitaxyPrefs"] = epitaxy
            config["preferences"] = preferences
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        if storage.exists {
            var set = [Self.pendingKey: marker]
            if storeChanged, var store = window.store, var state = store["state"] as? [String: Any] {
                var scopes = state[InterfaceSync.groupsField] as? [String: Any] ?? [:]
                scopes[window.scope] = local.json
                state[InterfaceSync.groupsField] = scopes
                store["state"] = state
                let data = try JSONSerialization.data(withJSONObject: store, options: [.withoutEscapingSlashes])
                set[InterfaceSync.sidebarKey] = String(decoding: data, as: UTF8.self)
            }
            try storage.update(origin: InterfaceSync.origin, set: set, remove: [])
        }
        return Self.hydrate(local: storeChanged ? local : window.local, prefs: prefsChanged ? prefs : window.prefs)
    }

    /// `own` with its shared part replaced by `shared`. A group this window got from the shared copy (`before`)
    /// that nobody shares any more is removed, unless it still holds items of the window's own.
    static func project(_ own: Value, shared: Value, before: Set<String>, ids: Set<String>) -> Value {
        var result = Value()
        let ownItems = own.assignments.filter { !isShared($0.key, ids) }
        result.assignments = ownItems.merging(shared.assignments) { $1 }
        var kept = Set(ownItems.values)
        for (group, items) in own.order where items.contains(where: { !isShared($0, ids) }) { kept.insert(group) }
        let removed = before.subtracting(shared.ids).subtracting(kept)

        for group in own.groups where !removed.contains(id(group)) {
            result.groups.append(shared.group(id(group)) ?? group)
        }
        result.groups += shared.groups.filter { own.group(id($0)) == nil }
        // The window's own items keep their places; the shared ones fill the places shared items had.
        for group in Set(own.order.keys).union(shared.order.keys) where !removed.contains(group) {
            var slots = (shared.order[group] ?? []).makeIterator()
            var items = (own.order[group] ?? []).compactMap { isShared($0, ids) ? slots.next() : $0 }
            while let item = slots.next() { items.append(item) }
            if !items.isEmpty || own.order[group] != nil { result.order[group] = items }
        }
        return result
    }

    /// An ordinary local Code session that every window has.
    static func isShared(_ item: String, _ ids: Set<String>) -> Bool {
        item.hasPrefix("code:") && ids.contains(String(item.dropFirst(5)))
    }

    static func id(_ group: [String: Any]) -> String { group["id"] as? String ?? "" }

    // MARK: Value

    /// One scope's groups: `{groups: [{id, name, …}], assignments: {item: group}, order: {group: [item]}}`.
    /// Group fields other than `id` are kept as they are.
    struct Value {
        var groups: [[String: Any]] = []
        var assignments: [String: String] = [:]
        var order: [String: [String]] = [:]

        init() {}

        /// `nil` for a layout Claude Profiles doesn't know.
        init?(_ json: Any?) {
            guard let object = json as? [String: Any],
                  let groups = (object["groups"] ?? [Any]()) as? [[String: Any]],
                  let assignments = (object["assignments"] ?? [String: Any]()) as? [String: String],
                  let order = (object["order"] ?? [String: Any]()) as? [String: [String]],
                  groups.allSatisfy({ $0["id"] is String }) else { return nil }
            self.groups = groups
            self.assignments = assignments
            self.order = order
        }

        var json: [String: Any] { ["groups": groups, "assignments": assignments, "order": order] }

        /// `{groups: [], assignments: {}, order: {}}`, the only empty form Claude keeps.
        static func isFullEmpty(_ json: Any) -> Bool {
            guard let object = json as? [String: Any] else { return false }
            return (object["groups"] as? [Any])?.isEmpty == true && (object["assignments"] as? [String: Any])?.isEmpty == true
                && (object["order"] as? [String: Any])?.isEmpty == true
        }
        var text: String { InterfaceSync.canonical(json) }
        var ids: [String] { groups.map(GroupSync.id) }
        var isEmpty: Bool { groups.isEmpty && assignments.isEmpty && order.isEmpty }

        func group(_ id: String) -> [String: Any]? { groups.first { GroupSync.id($0) == id } }

        /// The shared part: ordinary local Code sessions and the groups holding them.
        func portable(_ ids: Set<String>) -> Value {
            let known = Set(self.ids)
            var result = Value()
            result.assignments = assignments.filter { GroupSync.isShared($0.key, ids) && known.contains($0.value) }
            for (group, items) in order where known.contains(group) {
                let shared = items.filter { GroupSync.isShared($0, ids) }
                if !shared.isEmpty { result.order[group] = shared }
            }
            let used = Set(result.assignments.values).union(result.order.keys)
            result.groups = groups.filter { used.contains(GroupSync.id($0)) }
            return result
        }

        /// As Claude keeps it in the preferences: without groups that hold nothing, or empty orders.
        var withoutEmptyGroups: Value {
            var result = self
            result.order = order.filter { !$0.value.isEmpty }
            let used = Set(assignments.values).union(result.order.keys)
            result.groups = groups.filter { used.contains(GroupSync.id($0)) }
            return result
        }

        /// Takes what a window changed since `base`, the last state Claude reported there. A value that is only
        /// what Claude Profiles wrote there (`written`) is not a change. Without `base` nothing counts as removed.
        mutating func merge(_ observed: Value, base: Value?, written: Value?) {
            func changed<T: Equatable>(_ now: T?, _ before: T?, _ ours: T?) -> Bool {
                now != before && (written == nil || now != ours)
            }
            for group in observed.groups {
                let id = GroupSync.id(group)
                let now = InterfaceSync.canonical(group)
                guard changed(now, base?.group(id).map(InterfaceSync.canonical), written?.group(id).map(InterfaceSync.canonical)) else { continue }
                if let index = groups.firstIndex(where: { GroupSync.id($0) == id }) { groups[index] = group } else { groups.append(group) }
            }
            let deleted = (base?.ids ?? []).filter { id in
                observed.group(id) == nil && (written == nil || written?.group(id) != nil)
            }
            for id in deleted {
                groups.removeAll { GroupSync.id($0) == id }
                assignments = assignments.filter { $0.value != id }
                order[id] = nil
            }
            let items = Set(observed.assignments.keys).union(base.map { Array($0.assignments.keys) } ?? [])
            for item in items {
                let now = observed.assignments[item]
                guard changed(now, base?.assignments[item], written?.assignments[item]) else { continue }
                assignments[item] = now
            }
            let ordered = Set(observed.order.keys).union(base.map { Array($0.order.keys) } ?? [])
            for id in ordered {
                let now = observed.order[id]
                guard changed(now, base?.order[id], written?.order[id]) else { continue }
                // The window's order, then members it didn't list, such as ones another window just added.
                let listed = now ?? []
                let rest = assignments.filter { $0.value == id && !listed.contains($0.key) }.keys.sorted()
                order[id] = listed + rest
            }
        }

        /// Drops items whose group is gone or that are no longer shared, then groups left without items.
        mutating func normalize(_ ids: Set<String>) {
            let known = Set(self.ids)
            assignments = assignments.filter { GroupSync.isShared($0.key, ids) && known.contains($0.value) }
            var kept: [String: [String]] = [:]
            for (id, items) in order {
                let members = items.filter { assignments[$0] == id }
                if !members.isEmpty { kept[id] = members }
            }
            order = kept
            let used = Set(assignments.values)
            groups = groups.filter { used.contains(GroupSync.id($0)) }
        }
    }

    // MARK: State

    struct Record {
        /// The window's `account/organization`; its record starts over when it changes.
        var scope: String
        /// The shared part of the last state Claude reported there.
        var base: Value?
        /// The shared part Claude Profiles wrote there since, until Claude reports a state of its own.
        var written: Value?
        /// Whether that write set a marker Claude honours, so the window starts from it.
        var marked = false
    }

    /// A missing or unreadable file starts over: nothing counts as removed until each window is seen again.
    func readState() -> (Value, [String: Record]) {
        guard let data = try? Data(contentsOf: stateFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (Value(), [:]) }
        var records: [String: Record] = [:]
        for (id, entry) in object["windows"] as? [String: [String: Any]] ?? [:] {
            guard let scope = entry["scope"] as? String else { continue }
            records[id] = Record(scope: scope, base: entry["base"].flatMap { Value($0) }, written: entry["written"].flatMap { Value($0) },
                                 marked: entry["marked"] as? Bool ?? false)
        }
        return (Value(object["canonical"]) ?? Value(), records)
    }

    func writeState(_ canonical: Value, _ records: [String: Record]) throws {
        var windows: [String: Any] = [:]
        for (id, record) in records {
            var entry: [String: Any] = ["scope": record.scope]
            entry["base"] = record.base?.json
            entry["written"] = record.written?.json
            if record.marked { entry["marked"] = true }
            windows[id] = entry
        }
        let state: [String: Any] = ["canonical": canonical.json, "windows": windows]
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: stateFile, options: .atomic)
    }
}
