import Foundation
import Testing

@testable import BatonKit

@Suite("Interface sharing")
struct InterfaceSyncTests {
    static let origin = InterfaceSync.origin
    static let mainScope = "\(Sandbox.accountA)/org-a"
    static let workScope = "\(Sandbox.accountB)/org-b"

    /// Sandbox with a signed-in main app and profile, each with an empty Local Storage database.
    func sandbox() throws -> Sandbox {
        let box = try Sandbox()
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage", directoryHint: .isDirectory)
        for (dir, account) in [(box.main, Sandbox.accountA), (box.work, Sandbox.accountB)] {
            try FileManager.default.copyItem(at: fixture, to: dir.appending(path: "Local Storage", directoryHint: .isDirectory))
            try box.write(#"{"lastKnownAccountUuid":"\#(account)"}"#, to: dir.appending(path: "config.json"))
        }
        let pair = try box.pair(box.main, account: Sandbox.accountA)
        for id in ["local_1", "local_2", "local_a", "local_main", "local_own"] {
            try box.write("{\"sessionId\":\"\(id)\",\"cwd\":\"/shared/repo\"}", to: pair.appending(path: "\(id).json"))
        }
        return box
    }

    func sidebar(_ state: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["state": state, "version": 1]), as: UTF8.self)
    }

    func sidebarState(_ items: [String: String]) throws -> [String: Any] {
        let text = try #require(items[InterfaceSync.sidebarKey])
        let store = try #require(InterfaceSync.object(text))
        return try #require(store["state"] as? [String: Any])
    }

    func items(_ dir: URL) throws -> [String: String] { try LocalStorage(dataDir: dir).items(origin: Self.origin) }

    func put(_ dir: URL, _ set: [String: String], remove: Set<String> = []) throws {
        try LocalStorage(dataDir: dir).update(origin: Self.origin, set: set, remove: remove)
    }

    @Test func portableSidebarFieldsAreSharedWithoutAccountOrPermissionState() throws {
        let box = try sandbox()
        try put(
            box.main,
            [
                InterfaceSync.sidebarKey: try sidebar([
                    "sidebarWidth": 242, "pinnedOrder": ["code:local_1"], "navPinnedIds": ["routines-chorus"],
                    "collapsedGroups": ["project-done"], "lastSidebarScopeKey": Self.mainScope,
                    "customGroupsByScope": [Self.mainScope: ["groups": ["g1"]], "old/scope": ["groups": ["stale"]]],
                    "sidebarRowCountsByScope": [Self.mainScope: ["code.recents": 18]], "navHasCodeRoutinesByOrg": ["org-a": true],
                ]),
                "epitaxy-unread-v1": #"{"state":{"unreadIds":["local_1"]},"version":0}"#,
                "LSS-persisted.epitaxy-folder-permission-mode.\(Sandbox.accountA)": #"{"value":{"scratch:":"auto"},"tabId":"","timestamp":1}"#,
                "composer-draft:epitaxy-local_1": "unsent text",
                "__qk_hint_account_uuid": Sandbox.accountA,
            ])
        try put(
            box.work,
            [
                InterfaceSync.sidebarKey: try sidebar([
                    "sidebarWidth": 288, "pinnedOrder": [], "navPinnedIds": NSNull(), "collapsedGroups": [],
                    "lastSidebarScopeKey": Self.workScope, "customGroupsByScope": [:],
                    "sidebarRowCountsByScope": [Self.workScope: ["code.recents": 50]], "navHasCodeRoutinesByOrg": [:],
                ]),
                "LSS-persisted.code-sessions-status-filter.\(Sandbox.accountB)": #"{"value":"all","tabId":"","timestamp":1}"#,
            ])

        let changed = try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")

        let work = try items(box.work)
        let state = try sidebarState(work)
        #expect(state["sidebarWidth"] as? Int == 242)
        #expect(state["pinnedOrder"] as? [String] == [], "pins stay the profile's own")
        #expect(state["navPinnedIds"] is NSNull)
        #expect(state["collapsedGroups"] as? [String] == [])
        #expect(state["lastSidebarScopeKey"] as? String == Self.workScope, "the profile's own account stays its own")
        #expect((state["customGroupsByScope"] as? [String: Any])?.isEmpty == true)
        #expect(((state["sidebarRowCountsByScope"] as? [String: Any])?[Self.workScope] as? [String: Int])?["code.recents"] == 50)
        #expect((state["navHasCodeRoutinesByOrg"] as? [String: Any])?.isEmpty == true)
        #expect(work["epitaxy-unread-v1"] == nil, "unread state can also contain cloud threads")
        #expect(work["LSS-persisted.epitaxy-folder-permission-mode.\(Sandbox.accountB)"] == nil, "permission grants are never remapped")
        #expect(work["LSS-persisted.code-sessions-status-filter.\(Sandbox.accountB)"] == #"{"value":"all","tabId":"","timestamp":1}"#)
        #expect(work["composer-draft:epitaxy-local_1"] == nil, "drafts are not copied")
        #expect(work["__qk_hint_account_uuid"] == nil, "account data is not copied")
        #expect(work["sidebarWidth"] == "240", "unrelated entries stay")
        #expect(changed == 1)
        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "a second run has nothing to do")
    }

    @Test func aChangeMadeOnlyInTheProfileStays() throws {
        let box = try sandbox()
        let sync = InterfaceSync(paths: box.paths)
        let unread = "epitaxy-unread-v1"
        try put(
            box.main,
            [
                InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 242, "pinnedOrder": ["code:local_1"]]),
                unread: #"{"state":{"unreadIds":["local_1"]}}"#,
            ])
        try put(box.work, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 288, "pinnedOrder": []])])
        try sync.run(into: box.work, profileID: "work")

        // The profile's window changes its width and reads the session; the main app pins another session.
        try put(
            box.work,
            [
                InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 300, "pinnedOrder": ["code:local_1"]]),
                unread: #"{"state":{"unreadIds":[]}}"#,
            ])
        try put(box.main, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 242, "pinnedOrder": ["code:local_2"]])])
        try sync.run(into: box.work, profileID: "work")

        var state = try sidebarState(try items(box.work))
        #expect(state["sidebarWidth"] as? Int == 300)
        #expect(state["pinnedOrder"] as? [String] == ["code:local_1"], "pins stay the profile's own")
        #expect(try items(box.work)[unread] == #"{"state":{"unreadIds":[]}}"#)

        // Once the main app changes the same setting too, the main app wins again.
        try put(box.main, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 250, "pinnedOrder": ["code:local_2"]])])
        try sync.run(into: box.work, profileID: "work")
        state = try sidebarState(try items(box.work))
        #expect(state["sidebarWidth"] as? Int == 250)
    }

    @Test func nothingIsWrittenBeforeSignInOrWhileTheWindowIsOpen() throws {
        let box = try sandbox()
        try put(box.main, ["epitaxy-editor-prefs": #"{"state":{"unreadIds":["local_1"]}}"#])
        let config = box.work.appending(path: "config.json")
        try FileManager.default.removeItem(at: config)
        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "not signed in yet")
        #expect(try items(box.work)["epitaxy-editor-prefs"] == nil)

        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: config)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
            LocalStorage(dataDir: box.work).dbDir.appending(path: "LOCK").path,
        ]
        let stdout = Pipe(), stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        defer { stdin.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
        _ = stdout.fileHandleForReading.availableData  // the holder's "locked" line

        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "the window is open")
        #expect(try items(box.work)["epitaxy-editor-prefs"] == nil)
    }

    // MARK: claude_desktop_config.json

    func prefs(_ dir: URL) throws -> [String: Any] {
        let config = try #require(SettingsSync.readJSON(dir.appending(path: InterfaceSync.desktopConfig)))
        return try #require((config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])
    }

    func writePrefs(_ box: Sandbox, _ dir: URL, _ prefs: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": prefs]])
        try box.write(String(decoding: data, as: UTF8.self), to: dir.appending(path: InterfaceSync.desktopConfig))
    }

    /// A linked `claude_desktop_config.json` stays a link after the interface merge too. One leading outside the profile's
    /// data, such as to a dotfiles file another window may use, is left as it is; one leading inside it is written where
    /// it leads, with that file's permissions, and backed up as content.
    @Test func aLinkedConfigStaysALinkAndOneLeadingOutsideIsLeftAsItIs() throws {
        let fm = FileManager.default
        for inside in [false, true] {
            let box = try sandbox()
            try writePrefs(box, box.main, ["epitaxy-transcript-links-in-preview": true])
            let target = (inside ? box.work.appending(path: "kept") : box.root.appending(path: "dotfiles")).appending(path: "work.json")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let servers = #""mcpServers":{"files":{"command":"/usr/bin/true","env":{"TOKEN":"x"}}}"#
            let before = "{\(servers),\"preferences\":{\"epitaxyPrefs\":{\"epitaxy-transcript-links-in-preview\":false}}}"
            try box.write(before, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let config = box.work.appending(path: InterfaceSync.desktopConfig)
            try fm.createSymbolicLink(at: config, withDestinationURL: target)

            let changed = try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")

            #expect(try fm.destinationOfSymbolicLink(atPath: config.path) == target.path, "still a link")
            #expect(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600, "its own permissions")
            let backups = fm.enumerator(at: box.paths.backupsDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            if inside {
                #expect(changed == 1)
                #expect(try prefs(box.work)["epitaxy-transcript-links-in-preview"] as? Bool == true, "written where it leads")
                let saved = backups.filter { $0.lastPathComponent == target.lastPathComponent }
                #expect(saved.count == 1 && saved.first.flatMap(box.read) == before, "backed up as content")
            } else {
                #expect(changed == 0)
                #expect(box.read(target) == before, "left as it is")
                #expect(backups.isEmpty)
            }
        }
    }

    /// Claude reads these settings from `claude_desktop_config.json` before Local Storage.
    @Test func portablePrefsShareWithoutImportingUnknownOrAccountPreferences() throws {
        let box = try sandbox()
        let (a, b) = (Sandbox.accountA, Sandbox.accountB)
        try writePrefs(
            box, box.main,
            [
                "epitaxy-transcript-links-in-preview": true,
                "epitaxy-folder-permission-mode.\(a)": ["scratch:": "auto"],
                "desktop-frame.paneStore.v1": ["project": "chan_other"],
                "projects.chan_other.overviewPaneOpen": true, "futurePreference": true,
            ])
        try writePrefs(
            box, box.work,
            [
                "epitaxy-transcript-links-in-preview": false,
                "epitaxy-folder-permission-mode.\(b)": ["scratch:": "ask"],
                "desktop-frame.paneStore.v1": ["project": "chan_own"],
                "projects.chan_own.overviewPaneOpen": false, "ownOnly": 2,
            ])
        let settings = SettingsSync(paths: box.paths), interface = InterfaceSync(paths: box.paths)
        try settings.run(into: box.work)
        try interface.run(into: box.work, profileID: "work")
        var work = try prefs(box.work)
        #expect(work["epitaxy-transcript-links-in-preview"] as? Bool == true)
        #expect((work["epitaxy-folder-permission-mode.\(b)"] as? [String: String]) == ["scratch:": "ask"])
        #expect(work["epitaxy-folder-permission-mode.\(a)"] == nil)
        #expect((work["desktop-frame.paneStore.v1"] as? [String: String]) == ["project": "chan_own"])
        #expect(work["projects.chan_other.overviewPaneOpen"] == nil)
        #expect(work["projects.chan_own.overviewPaneOpen"] as? Bool == false)
        #expect(work["futurePreference"] == nil)
        #expect(work["ownOnly"] as? Int == 2)
        #expect(try settings.run(into: box.work) == 0 && interface.run(into: box.work, profileID: "work") == 0)
        work["epitaxy-transcript-links-in-preview"] = false
        try writePrefs(box, box.work, work)
        try settings.run(into: box.work)
        try interface.run(into: box.work, profileID: "work")
        #expect(try prefs(box.work)["epitaxy-transcript-links-in-preview"] as? Bool == false)
    }

    @Test func cloudProjectAndMixedPinsStayWithTheirProfileInBothStores() throws {
        let box = try sandbox()
        let hidden = "dframe-unpinned-epitaxy-project-ids"
        let stars = "LSS-persisted.starred-local-code-sessions"
        let source = [
            hidden: #"["chan_main"]"#, stars: #"{"value":["local_main"]}"#,
            InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_main"], "sidebarWidth": 250]),
        ]
        let target = [
            hidden: #"["chan_own"]"#, stars: #"{"value":["local_own","session_remote"]}"#,
            InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_own", "project:chan_own"], "sidebarWidth": 240]),
        ]
        try put(box.main, source)
        try put(box.work, target)
        let starred = "store:pin-state:dframe-starred-code", projects = "store:pin-state:dframe-unpinned-epitaxy-project"
        try makePinStore(
            box.main,
            records: [
                starred: (1, #"{"state":{"starredIds":["local_main"]},"version":0}"#),
                projects: (2, #"{"state":{"unpinnedIds":["chan_main"]},"version":0}"#),
            ])
        let ownStarred = #"{"state":{"starredIds":["local_own","session_remote"]},"version":0}"#
        let ownProjects = #"{"state":{"unpinnedIds":["chan_own"]},"version":0}"#
        let idb = try makePinStore(box.work, records: [starred: (1, ownStarred), projects: (2, ownProjects)])
        try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")
        let result = try items(box.work)
        #expect(result[hidden] == target[hidden])
        #expect(result[stars] == target[stars])
        #expect(try sidebarState(result)["pinnedOrder"] as? [String] == ["code:local_own", "project:chan_own"])
        #expect(try sidebarState(result)["sidebarWidth"] as? Int == 250)
        #expect(try idb.read()?.records[starred]?.string == ownStarred)
        #expect(try idb.read()?.records[projects]?.string == ownProjects)
    }

    @Test func nativeWorkersAndUnknownLocalIDsAreNotPortablePins() throws {
        let box = try sandbox()
        let pair = try box.pair(box.main, account: Sandbox.accountA)
        try box.write(NativeSessionScopeTests.worker, to: pair.appending(path: "local_worker.json"))
        // Remote Control reaches the worker in the main window, so it stays there.
        try box.serveRemoteControl(box.main, account: Sandbox.accountA, folders: ["/shared/repo"])
        let key = "LSS-persisted.starred-local-code-sessions"
        try put(
            box.main,
            [
                key: #"{"value":["local_1","local_worker"]}"#,
                InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_worker"]]),
            ])
        let own = #"{"value":["local_2"]}"#
        try put(box.work, [key: own, InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_2"]])])
        let sync = InterfaceSync(paths: box.paths)
        try sync.run(into: box.work, profileID: "work")
        #expect(try items(box.work)[key] == own)
        #expect(try sidebarState(items(box.work))["pinnedOrder"] as? [String] == ["code:local_2"])
        try put(box.main, [key: #"{"value":["local_unknown"]}"#])
        try sync.run(into: box.work, profileID: "work")
        #expect(try items(box.work)[key] == own)
    }

    @Test func rememberedNativeOwnershipProtectsPinsAfterCardMarkersDisappear() throws {
        let box = try sandbox()
        // local_1 has an ordinary-looking current card, but the durable ownership state remembers it.
        let scopeFile = box.paths.stateDir.appending(path: "code-native-session-scopes.json")
        try SessionSync.NativeScopeState(scopes: ["local_1.json": [Self.mainScope]]).save(to: scopeFile)
        let key = "LSS-persisted.starred-local-code-sessions"
        let own = #"{"value":["local_2"]}"#
        try put(
            box.main,
            [
                key: #"{"value":["local_1"]}"#,
                InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_1"]]),
            ])
        try put(box.work, [key: own, InterfaceSync.sidebarKey: try sidebar(["pinnedOrder": ["code:local_2"]])])
        try writePrefs(box, box.main, ["starred-local-code-sessions": ["local_1"]])
        try writePrefs(box, box.work, ["starred-local-code-sessions": ["local_2"]])
        let stars = "store:pin-state:dframe-starred-code"
        try makePinStore(box.main, records: [stars: (1, #"{"state":{"starredIds":["local_1"]},"version":0}"#)])
        let ownPins = #"{"state":{"starredIds":["local_2"]},"version":0}"#
        let targetPins = try makePinStore(box.work, records: [stars: (1, ownPins)])
        try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")
        #expect(try items(box.work)[key] == own)
        #expect(try sidebarState(items(box.work))["pinnedOrder"] as? [String] == ["code:local_2"])
        #expect(try prefs(box.work)["starred-local-code-sessions"] as? [String] == ["local_2"])
        #expect(try targetPins.read()?.records[stars]?.string == ownPins)
    }

    // MARK: IndexedDB

    /// The serialized form of a one-byte string as Chromium stores it: Blink's header with its trailer offset,
    /// V8's header, then the string.
    static func serialized(_ text: String) -> [UInt8] {
        var length = ByteWriter()
        length.appendVarint64(UInt64(text.utf8.count))
        var bytes: [UInt8] = [0xFF, 0x15, 0xFE]
        bytes += [UInt8](repeating: 0, count: 12)
        bytes += [0xFF, 0x0F, 0x22]
        bytes += length.bytes
        bytes += Array(text.utf8)
        return bytes
    }

    /// Claude's key-value IndexedDB database with `records` (key → version, JSON text), built on a copy of the
    /// Local Storage fixture: any LevelDB database will do, the two kinds of keys never collide.
    @discardableResult
    func makePinStore(
        _ dataDir: URL, records: [String: (UInt64, String)], databaseID: UInt64 = 1,
        blobs: Set<String> = [], dataVersion: UInt64 = 0x10_0000_0015,
        extra: (_ database: UInt64, _ objectStore: UInt64) -> [([UInt8], [UInt8])] = { _, _ in [] }
    ) throws -> IndexedDBStore {
        let store = IndexedDBStore(dataDir: dataDir, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage/leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store.dbDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: store.dbDir)
        let db = databaseID, os: UInt64 = 1
        let versionKey: [UInt8] = IDBKey.prefix(0, 0, 0) + [IDBKey.dataVersionType]
        var databaseName: [UInt8] = IDBKey.prefix(0, 0, 0) + [201]
        databaseName += IDBKey.stringWithLength(store.origin)
        databaseName += IDBKey.stringWithLength(store.database)
        var storeName: [UInt8] = IDBKey.prefix(db, 0, 0) + [200]
        storeName += IDBKey.stringWithLength(store.objectStore)
        var put: [([UInt8], [UInt8])] = [
            (versionKey, IDBKey.encodeInt(dataVersion)),
            (databaseName, IDBKey.encodeInt(db)),
            (storeName, IDBKey.encodeInt(os)),
            (IDBKey.objectStoreMetadata(db, os, .name), IDBKey.utf16BE(store.objectStore)),
            (IDBKey.objectStoreMetadata(db, os, .lastVersion), IDBKey.encodeInt(records.values.map(\.0).max() ?? 0)),
        ]
        for (key, (version, json)) in records {
            var record = ByteWriter()
            record.appendVarint64(version)
            put.append((IDBKey.prefix(db, os, IDBKey.dataIndex) + IDBKey.string(key), record.bytes + Self.serialized(json)))
            put.append((IDBKey.prefix(db, os, IDBKey.existsIndex) + IDBKey.string(key), IDBKey.encodeInt(version)))
        }
        for key in blobs { put.append((IDBKey.prefix(db, os, IDBKey.blobIndex) + IDBKey.string(key), [0])) }
        put += extra(db, os)
        try store.store.append(put: put, delete: [])
        return store
    }

    /// Pins follow moved work (`SidebarLayout`), not the main app: main's pins and pin order never reach a profile,
    /// in Local Storage, the settings or IndexedDB, and baselines older releases recorded for them are dropped.
    @Test func pinsAreNoLongerCopiedFromMain() throws {
        let box = try sandbox()
        let starred = "store:pin-state:dframe-starred-code", stars = "LSS-persisted.starred-local-code-sessions"
        try put(
            box.main,
            [
                stars: #"{"value":["local_1"],"tabId":"","timestamp":1}"#,
                InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 250, "pinnedOrder": ["code:local_1"]]),
            ])
        let ownStars = #"{"value":["local_2"],"tabId":"","timestamp":1}"#
        try put(box.work, [stars: ownStars, InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 240, "pinnedOrder": ["code:local_2"]])])
        try writePrefs(box, box.main, ["starred-local-code-sessions": ["local_1"], "epitaxy-transcript-links-in-preview": true])
        try writePrefs(box, box.work, ["starred-local-code-sessions": ["local_2"]])
        try makePinStore(box.main, records: [starred: (1, #"{"state":{"starredIds":["local_1"]},"version":0}"#)])
        let ownPins = #"{"state":{"starredIds":["local_2"]},"version":0}"#
        let work = try makePinStore(box.work, records: [starred: (1, ownPins)])
        let sync = InterfaceSync(paths: box.paths)
        try InterfaceSync.writeState(
            ["idb:" + starred: "old", stars: "old", "prefs:starred-local-code-sessions": "old", "dframe-store/pinnedOrder": "old"],
            to: sync.stateFile(for: "work"))

        #expect(try sync.run(into: box.work, profileID: "work") == 2, "the sidebar width and one display setting")

        #expect(try items(box.work)[stars] == ownStars)
        #expect(try sidebarState(items(box.work))["pinnedOrder"] as? [String] == ["code:local_2"])
        #expect(try sidebarState(items(box.work))["sidebarWidth"] as? Int == 250)
        #expect(try prefs(box.work)["starred-local-code-sessions"] as? [String] == ["local_2"])
        #expect(try prefs(box.work)["epitaxy-transcript-links-in-preview"] as? Bool == true)
        #expect(try work.read()?.records[starred]?.string == ownPins)
        let state = InterfaceSync.readState(sync.stateFile(for: "work"))
        #expect(!state.keys.contains { $0.contains("starred") || $0.hasSuffix("pinnedOrder") }, "old pin baselines are dropped")
    }

    /// What was merged before a failure is remembered, so the next run doesn't take it for a change in the profile.
    @Test func placesMergedBeforeAFailureAreRemembered() throws {
        let box = try sandbox()
        let fm = FileManager.default
        try put(box.main, ["epitaxy-editor-prefs": #"{"wrap":true}"#])
        try writePrefs(box, box.main, ["epitaxy-transcript-links-in-preview": true])
        // The profile's settings file leads into a folder that can't be written, so the settings stage fails.
        let kept = box.work.appending(path: "kept")
        try fm.createDirectory(at: kept, withIntermediateDirectories: true)
        try box.write(#"{"preferences":{"epitaxyPrefs":{"ownOnly":2}}}"#, to: kept.appending(path: "work.json"))
        try fm.createSymbolicLink(at: box.work.appending(path: InterfaceSync.desktopConfig), withDestinationURL: kept.appending(path: "work.json"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: kept.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kept.path) }
        let sync = InterfaceSync(paths: box.paths)

        #expect(throws: (any Error).self) { try sync.run(into: box.work, profileID: "work") }

        let state = InterfaceSync.readState(sync.stateFile(for: "work"))
        #expect(state["epitaxy-editor-prefs"] != nil)
        #expect(state["prefs:epitaxy-transcript-links-in-preview"] == nil)
        #expect(try items(box.work)["epitaxy-editor-prefs"] == #"{"wrap":true}"#)
    }

    @Test func readsTheStringsChromiumSerializes() {
        #expect(IDBValue.string(in: Self.serialized("hello")) == "hello")
        // Two-byte string, after V8's padding byte: "Яb" in UTF-16LE.
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x00, 0x63, 0x04, 0x2F, 0x04, 0x62, 0x00]) == "Яb")
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x53, 0x02, 0xD0, 0xAF]) == "Я")
        #expect(IDBValue.string(in: Self.serialized("hello") + [0x00]) == nil, "anything after the string means another shape")
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x6F, 0x7B, 0x00]) == nil, "an object isn't a string")
    }
}
