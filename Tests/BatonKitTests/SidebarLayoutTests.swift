import Foundation
import Testing

@testable import BatonKit

@Suite("Sidebar layout")
struct SidebarLayoutTests {
    static let scope = "\(Sandbox.accountB)/org-b"
    static let account = Sandbox.accountB
    let ui = InterfaceSyncTests()

    func items(_ dir: URL) throws -> [String: String] { try LocalStorage(dataDir: dir).items(origin: InterfaceSync.origin) }
    func put(_ dir: URL, _ set: [String: String]) throws { try LocalStorage(dataDir: dir).update(origin: InterfaceSync.origin, set: set, remove: []) }
    func json(_ object: Any) -> String { SidebarLayout.json(object) }
    func mirror(_ value: Any, _ ms: Int64 = 1) -> String { json(["value": value, "tabId": "", "timestamp": ms] as [String: Any]) }
    func pins(_ ids: [String], updatedAt: Int64 = 1, version: Int = 0) -> String {
        json(["state": ["starredIds": ids], "version": version, "updatedAt": updatedAt] as [String: Any])
    }
    func groups(_ groups: [(String, String)], _ assignments: [String: String], _ order: [String: [String]]) -> [String: Any] {
        ["groups": groups.map { ["id": $0.0, "name": $0.1] }, "assignments": assignments, "order": order]
    }
    func store(_ scope: [String: Any]?, pinnedOrder: [String] = [], version: Int = 1) -> String {
        var state: [String: Any] = ["sidebarWidth": 240, "pinnedOrder": pinnedOrder, "lastSidebarScopeKey": Self.scope]
        state[InterfaceSync.groupsField] = scope.map { [Self.scope: $0] } ?? [:]
        return json(["state": state, "version": version] as [String: Any])
    }
    func prefs(_ dir: URL) throws -> [String: Any] { try ui.prefs(dir) }
    struct Missing: Error {}
    /// An `LSS-persisted` entry, parsed.
    func entry(_ text: String?) throws -> [String: Any] {
        guard let text, let object = InterfaceSync.object(text) else { throw Missing() }
        return object
    }
    func layout(_ dir: URL) throws -> SidebarLayout {
        guard let layout = SidebarLayout.read(dataDir: dir, scope: Self.scope) else { throw Missing() }
        return layout
    }
    func storeState(_ dir: URL) throws -> [String: Any] { try ui.sidebarState(items(dir)) }
    func pinRecord(_ dir: URL) throws -> [String: Any] {
        let store = IndexedDBStore(dataDir: dir, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
        let text = try #require(try store.read()?.records[SidebarLayout.pinKey]?.string)
        return try #require(InterfaceSync.object(text))
    }

    /// Holds a LevelDB database's `LOCK` the way a running window does, until the returned closure runs.
    func hold(_ dbDir: URL) throws -> () -> Void {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
            dbDir.appending(path: "LOCK").path,
        ]
        let stdout = Pipe(), stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        _ = stdout.fileHandleForReading.availableData
        return {
            stdin.fileHandleForWriting.closeFile()
            holder.waitUntilExit()
        }
    }

    // MARK: Reading

    @Test func readsPinsFromLongerSource() throws {
        let box = try ui.sandbox()
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, pins(["local_1"], updatedAt: Int64(Date().timeIntervalSince1970 * 1000)))])
        try put(box.work, [SidebarLayout.starredMirror: mirror(["local_1", "local_2", "local_3"])])
        try ui.writePrefs(box, box.work, [SidebarLayout.starredPref: ["local_2", "local_1"]])

        let layout = try layout(box.work)

        #expect(layout.starred == ["local_1", "local_2", "local_3"])
    }

    @Test func readsPinsFromNewestWhenEqualLength() throws {
        let box = try ui.sandbox()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, pins(["local_1", "local_2"], updatedAt: 1000))])
        try put(
            box.work,
            [
                SidebarLayout.starredMirror: mirror(["local_2", "local_1"], now),
                InterfaceSync.sidebarKey: store(nil, pinnedOrder: ["code:local_1", "code:local_2"]),
                SidebarLayout.sliceMirror: mirror(["pinnedOrder": ["code:local_2"], "homeProjectsPinnedOrder": []], now),
            ])
        try ui.writePrefs(box, box.work, [SidebarLayout.starredPref: ["local_3", "local_4"]])
        let config = box.work.appending(path: InterfaceSync.desktopConfig)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: config.path)

        let layout = try layout(box.work)

        #expect(layout.starred == ["local_2", "local_1"], "the newest of three lists of two")
        #expect(layout.pinnedOrder == ["code:local_1", "code:local_2"], "the longer pin order")
    }

    @Test func readsOpenWindowWithoutWriting() throws {
        let box = try ui.sandbox()
        try put(box.work, [InterfaceSync.sidebarKey: store(groups([("cg-1", "Work")], ["code:local_1": "cg-1"], ["cg-1": ["code:local_1"]]))])
        let before = try FileManager.default.subpathsOfDirectory(atPath: box.work.path).sorted()
        let release = try hold(LocalStorage(dataDir: box.work).dbDir)
        defer { release() }

        let layout = try layout(box.work)

        #expect(layout.assignments == ["code:local_1": "cg-1"])
        #expect(layout.groups == [SidebarLayout.Group(id: "cg-1", name: "Work")])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: box.work.path).sorted() == before, "nothing written")
        #expect(!FileManager.default.fileExists(atPath: box.paths.backupsDir.path))
    }

    // MARK: Slicing

    @Test func sliceKeepsOnlyHandedOverLocalItemsAndMapsCopies() {
        let layout = SidebarLayout(
            groups: [.init(id: "cg-1", name: "Work"), .init(id: "cg-2", name: "Other")],
            assignments: ["code:local_1": "cg-1", "code:local_2": "cg-1", "code:local_3": "cg-2", "project:chan_1": "cg-1", "code:local_4": "cg-9"],
            order: ["cg-1": ["code:local_2", "project:chan_1", "code:local_1"], "cg-2": ["code:local_3"]],
            starred: ["local_1", "local_3", "session_remote", "local_2"],
            pinnedOrder: ["project:chan_1", "code:local_2", "code:local_1", "code:local_3"])

        let slice = layout.slice(cards: ["local_1", "local_2", "local_4", "session_remote"], renamed: ["local_2": "local_2copy"])

        #expect(slice.groups == [.init(id: "cg-1", name: "Work")], "only groups that hold a handed-over session")
        #expect(slice.assignments == ["code:local_1": "cg-1", "code:local_2copy": "cg-1"], "no cloud items, no unknown groups")
        #expect(slice.order == ["cg-1": ["code:local_2copy", "code:local_1"]])
        #expect(slice.starred == ["local_1", "local_2copy"])
        #expect(slice.pinnedOrder == ["code:local_2copy", "code:local_1"])
    }

    // MARK: Carrying

    func slice(group: (String, String) = ("cg-1", "Work"), items: [String] = ["code:local_1"]) -> SidebarLayout {
        SidebarLayout(
            groups: [.init(id: group.0, name: group.1)],
            assignments: Dictionary(uniqueKeysWithValues: items.map { ($0, group.0) }),
            order: [group.0: items])
    }

    func carry(_ box: Sandbox, _ slice: SidebarLayout, now: Date = Date(), afterWrite: () throws -> Void = {}) throws -> SidebarLayout.CarryReport {
        try SidebarLayout.carry(
            slice, into: box.work, scope: Self.scope, account: Self.account,
            backup: Backup(paths: box.paths, now: now), now: now, afterWrite: afterWrite)
    }

    @Test func carryReusesGroupById() throws {
        let box = try ui.sandbox()
        try put(box.work, [InterfaceSync.sidebarKey: store(groups([("cg-1", "Work")], ["code:local_9": "cg-1"], ["cg-1": ["code:local_9"]]))])

        let report = try carry(box, slice(items: ["code:local_1", "code:local_2"]))

        let scope = try #require((try storeState(box.work)[InterfaceSync.groupsField] as? [String: Any])?[Self.scope] as? [String: Any])
        #expect((scope["groups"] as? [[String: Any]])?.count == 1)
        #expect(scope["assignments"] as? [String: String] == ["code:local_9": "cg-1", "code:local_1": "cg-1", "code:local_2": "cg-1"])
        #expect(scope["order"] as? [String: [String]] == ["cg-1": ["code:local_9", "code:local_1", "code:local_2"]])
        #expect(report.groupsMatched == 1 && report.groupsAdded == 0 && report.ordered == 2 && !report.markerSet)
        #expect(try items(box.work)[SidebarLayout.pendingKey] == nil)
    }

    @Test func carryMapsGroupByName() throws {
        let box = try ui.sandbox()
        // The session was in another group there before; it moves.
        let existing = groups([("cg-dest", "Work"), ("cg-old", "Old")], ["code:local_1": "cg-old"], ["cg-old": ["code:local_1"]])
        try put(box.work, [InterfaceSync.sidebarKey: store(existing)])

        let report = try carry(box, slice(group: ("cg-src", "Work")))

        let layout = try layout(box.work)
        #expect(layout.groups.map(\.id) == ["cg-dest", "cg-old"])
        #expect(layout.assignments == ["code:local_1": "cg-dest"])
        #expect(layout.order == ["cg-dest": ["code:local_1"], "cg-old": []])
        #expect(report.groupsMatched == 1 && report.groupsAdded == 0)
    }

    @Test(arguments: [nil, SidebarLayoutTests.account])
    func newGroupSetsMigrateMarkerForOwnAccountOnly(owner: String?) throws {
        let box = try ui.sandbox()
        try put(box.work, [InterfaceSync.sidebarKey: store(groups([("cg-1", "Work")], [:], [:]))])
        if let owner { try put(box.work, [SidebarLayout.ownerKey: owner]) }

        let report = try carry(box, slice(group: ("cg-new", "New")))

        #expect(report.groupsAdded == 1 && report.markerSet && report.ungrouped.isEmpty)
        #expect(try items(box.work)[SidebarLayout.pendingKey] == Self.scope + "|migrate", "the merge form, never the bare one")
        let layout = try layout(box.work)
        #expect(layout.groups.map(\.id) == ["cg-1", "cg-new"])
        #expect(layout.assignments == ["code:local_1": "cg-new"])
    }

    @Test func newGroupWithForeignSyncOwnerIsReported() throws {
        for (owner, marker) in [(Sandbox.accountA, nil), (nil, "1")] as [(String?, String?)] {
            let box = try ui.sandbox()
            try put(box.work, [InterfaceSync.sidebarKey: store(nil)])
            if let owner { try put(box.work, [SidebarLayout.ownerKey: owner]) }
            if let marker { try put(box.work, [SidebarLayout.pendingKey: marker]) }

            let report = try carry(box, slice(group: ("cg-new", "New"), items: ["code:local_1", "code:local_2"]))

            #expect(!report.markerSet && report.ungrouped == ["New": 2])
            #expect(try items(box.work)[SidebarLayout.pendingKey] == marker, "a marker is neither set nor changed")
            #expect(try layout(box.work).groups.map(\.id) == ["cg-new"], "still added here")
        }
    }

    @Test func carryWritesIndexedDBStoreMirrorsAndPrefsIdentically() throws {
        let box = try ui.sandbox()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, pins(["local_9"]))])
        let existing = groups([("cg-1", "Work")], ["code:local_9": "cg-1"], ["cg-1": ["code:local_9"]])
        try put(
            box.work,
            [
                InterfaceSync.sidebarKey: store(existing, pinnedOrder: ["code:local_9"]),
                SidebarLayout.groupsMirror: mirror([Self.scope: existing, "other/scope": ["groups": []]]),
                SidebarLayout.sliceMirror: mirror(["pinnedOrder": ["code:local_9"], "homeProjectsPinnedOrder": ["chan_1"]]),
                SidebarLayout.starredMirror: mirror(["local_9"]),
            ])
        try ui.writePrefs(box, box.work, [SidebarLayout.starredPref: ["local_9"], "ownOnly": 2])
        var slice = slice(items: ["code:local_1", "code:local_2"])
        slice.starred = ["local_2", "local_1"]
        slice.pinnedOrder = ["code:local_2", "code:local_1"]

        let report = try carry(box, slice, now: now)

        #expect(report.pinsAdded == 2 && report.ordered == 2 && !report.markerSet)
        let pinList = ["local_2", "local_1", "local_9"], order = ["code:local_2", "code:local_1", "code:local_9"]
        let record = try pinRecord(box.work)
        #expect((record["state"] as? [String: Any])?["starredIds"] as? [String] == pinList)
        #expect((record["updatedAt"] as? NSNumber)?.int64Value == ms && record["version"] as? Int == 0)
        let all = try items(box.work), prefs = try prefs(box.work)
        let starredMirror = try entry(all[SidebarLayout.starredMirror])
        #expect(starredMirror["value"] as? [String] == pinList && (starredMirror["timestamp"] as? NSNumber)?.int64Value == ms)
        #expect(prefs[SidebarLayout.starredPref] as? [String] == pinList)

        let state = try storeState(box.work)
        #expect(state["pinnedOrder"] as? [String] == order)
        let sliceMirror = try #require(try entry(all[SidebarLayout.sliceMirror])["value"] as? [String: Any])
        #expect(sliceMirror["pinnedOrder"] as? [String] == order && sliceMirror["homeProjectsPinnedOrder"] as? [String] == ["chan_1"])
        #expect((prefs[SidebarLayout.slicePref] as? [String: Any])?["pinnedOrder"] as? [String] == order)

        let inStore = try #require((state[InterfaceSync.groupsField] as? [String: Any])?[Self.scope])
        let mirrored = try #require(try entry(all[SidebarLayout.groupsMirror])["value"] as? [String: Any])
        let inPrefs = try #require((prefs[SidebarLayout.groupsPref] as? [String: Any])?[Self.scope])
        let mirroredScope = try #require(mirrored[Self.scope])
        #expect(InterfaceSync.canonical(inStore) == InterfaceSync.canonical(mirroredScope))
        #expect(InterfaceSync.canonical(inStore) == InterfaceSync.canonical(inPrefs))
        #expect(mirrored["other/scope"] != nil, "other scopes stay")
        #expect(prefs["ownOnly"] as? Int == 2, "other settings stay")
        #expect(state["sidebarWidth"] as? Int == 240)

        let layout = try layout(box.work)
        #expect(layout.starred == pinList && layout.pinnedOrder == order)
        #expect(layout.assignments == ["code:local_9": "cg-1", "code:local_1": "cg-1", "code:local_2": "cg-1"])
        let backups = try FileManager.default.subpathsOfDirectory(atPath: box.paths.backupsDir.path)
        #expect(backups.contains { $0.hasSuffix("Layout/work-IndexedDB.json") })
        #expect(backups.contains { $0.hasSuffix(InterfaceSync.desktopConfig) })
        #expect(backups.contains { $0.hasSuffix("Local Storage/leveldb") })
    }

    @Test func carryRefusesOpenWindow() throws {
        let box = try ui.sandbox()
        try put(box.work, [InterfaceSync.sidebarKey: store(nil)])
        let before = try items(box.work)
        let release = try hold(LocalStorage(dataDir: box.work).dbDir)
        defer { release() }

        #expect(throws: LocalStorageError.databaseInUse) { try carry(box, slice()) }
        #expect(try items(box.work) == before)
    }

    @Test func carryRestoresBackupsWhenReadBackFails() throws {
        let box = try ui.sandbox()
        let oldPins = pins(["local_9"])
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, oldPins)])
        try put(box.work, [InterfaceSync.sidebarKey: store(nil)])
        try ui.writePrefs(box, box.work, ["ownOnly": 2])
        let config = box.work.appending(path: InterfaceSync.desktopConfig)
        let oldConfig = try Data(contentsOf: config), oldItems = try items(box.work)
        var slice = slice()
        slice.starred = ["local_1"]

        #expect(throws: SidebarLayout.NotCarried.self) {
            try carry(box, slice) { try Data(#"{"changed":"meanwhile"}"#.utf8).write(to: config) }
        }

        #expect(try Data(contentsOf: config) == oldConfig)
        #expect(try items(box.work) == oldItems)
        let store = IndexedDBStore(dataDir: box.work, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
        #expect(try store.read()?.records[SidebarLayout.pinKey]?.string == oldPins)
    }

    @Test func carryLeavesUnknownStoreVersionsAlone() throws {
        let box = try ui.sandbox()
        let oldPins = pins(["local_9"], version: 1)
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, oldPins)])
        try put(box.work, [InterfaceSync.sidebarKey: store(nil, version: 2)])
        try ui.writePrefs(box, box.work, ["ownOnly": 2])
        let config = box.work.appending(path: InterfaceSync.desktopConfig)
        let oldConfig = try Data(contentsOf: config), oldItems = try items(box.work)
        var slice = slice(group: ("cg-new", "New"))
        slice.starred = ["local_1"]
        slice.pinnedOrder = ["code:local_1"]

        let report = try carry(box, slice)

        #expect(report.skipped.count == 2 && report.groupsAdded == 0 && report.pinsAdded == 0)
        #expect(try items(box.work) == oldItems)
        #expect(try Data(contentsOf: config) == oldConfig)
        let store = IndexedDBStore(dataDir: box.work, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
        #expect(try store.read()?.records[SidebarLayout.pinKey]?.string == oldPins)
    }

    @Test func pinsGetNoMarker() throws {
        let box = try ui.sandbox()
        try ui.makePinStore(box.work, records: [SidebarLayout.pinKey: (1, pins([]))])
        try put(box.work, [InterfaceSync.sidebarKey: store(nil)])
        let pinsOnly = SidebarLayout(starred: ["local_1"], pinnedOrder: ["code:local_1"])

        let report = try carry(box, pinsOnly)

        #expect(report.pinsAdded == 1 && !report.markerSet)
        #expect(try items(box.work)[SidebarLayout.pendingKey] == nil)
        #expect((try pinRecord(box.work)["state"] as? [String: Any])?["starredIds"] as? [String] == ["local_1"])
    }
}
