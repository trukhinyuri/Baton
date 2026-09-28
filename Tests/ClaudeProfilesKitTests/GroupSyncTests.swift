import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Sidebar group sharing")
struct GroupSyncTests {
    static let accountC = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    static let windowIDs = ["main", "work", "elena"]
    static let accounts = ["main": Sandbox.accountA, "work": Sandbox.accountB, "elena": accountC]
    static let orgs = ["main": "0fa2d5e5-0000-4000-8000-000000000001", "work": "f733de94-0000-4000-8000-000000000002",
                       "elena": "0fccfe26-0000-4000-8000-000000000003"]
    static let s1 = "code:local_s1", s2 = "code:local_s2", s3 = "code:local_s3"

    /// The main app and two profiles, all signed in and closed, each with Local Storage and preferences.
    /// Ordinary Code sessions `local_s1`…`local_s3` and a native Project worker `local_native` are in main.
    struct Windows {
        let box: Sandbox

        init() throws {
            box = try Sandbox()
            let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage", directoryHint: .isDirectory)
            for id in GroupSyncTests.windowIDs {
                let account = GroupSyncTests.accounts[id]!
                try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fixture, to: dir(id).appending(path: "Local Storage", directoryHint: .isDirectory))
                try box.write(#"{"lastKnownAccountUuid":"\#(account)"}"#, to: dir(id).appending(path: "config.json"))
                try box.pair(dir(id), account: account, org: GroupSyncTests.orgs[id]!)
                try setPrefs(id, [:])
            }
            let cards = try box.pair(box.main, account: Sandbox.accountA, org: GroupSyncTests.orgs["main"]!)
            for id in ["local_s1", "local_s2", "local_s3", "local_f24a00ac-186b-4b5c-bac3-541eb3f28e93"] {
                try box.write(#"{"sessionId":"\#(id)","cwd":"/shared/repo"}"#, to: cards.appending(path: "\(id).json"))
            }
            try box.write(#"{"sessionId":"local_native","projectThreadChild":true}"#, to: cards.appending(path: "local_native.json"))
        }

        func dir(_ id: String) -> URL { id == "main" ? box.main : box.paths.dataDir(for: id) }
        func scope(_ id: String) -> String { "\(GroupSyncTests.accounts[id]!)/\(GroupSyncTests.orgs[id]!)" }
        var list: [(id: String, dataDir: URL)] { GroupSyncTests.windowIDs.map { ($0, dir($0)) } }

        @discardableResult
        func run(now: Date = Date()) throws -> GroupSync.Report { try GroupSync(paths: box.paths).run(windows: list, now: now) }

        func setPrefs(_ id: String, _ scopes: [String: Any], modified: Date? = nil) throws {
            let config: [String: Any] = ["globalShortcut": "Alt+Space",
                                         "preferences": ["epitaxyPrefs": [GroupSync.prefsKey: scopes, "epitaxy-split-suggestion": true]]]
            let data = try JSONSerialization.data(withJSONObject: config)
            try box.write(String(decoding: data, as: UTF8.self), to: dir(id).appending(path: InterfaceSync.desktopConfig), modified: modified)
        }

        func setStore(_ id: String, _ scopes: [String: Any], version: Int = 1) throws {
            let state: [String: Any] = ["sidebarWidth": 250, "lastSidebarScopeKey": scope(id), InterfaceSync.groupsField: scopes]
            let data = try JSONSerialization.data(withJSONObject: ["state": state, "version": version])
            try LocalStorage(dataDir: dir(id)).update(origin: InterfaceSync.origin, set: [InterfaceSync.sidebarKey: String(decoding: data, as: UTF8.self)], remove: [])
        }

        /// What Claude saves after a change in that window: both copies; the preferences leave out an empty scope.
        func claudeSaves(_ id: String, _ value: [String: Any], modified: Date? = nil) throws {
            try setStore(id, [scope(id): value])
            let empty = (value["groups"] as? [Any])?.isEmpty ?? true
            try setPrefs(id, empty ? [:] : [scope(id): value], modified: modified)
        }

        func prefsScopes(_ id: String) throws -> [String: Any] {
            let config = try #require(SettingsSync.readJSON(dir(id).appending(path: InterfaceSync.desktopConfig)))
            let prefs = (config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any]
            return try #require(prefs?[GroupSync.prefsKey] as? [String: Any])
        }

        func items(_ id: String) throws -> [String: String] { try LocalStorage(dataDir: dir(id)).items(origin: InterfaceSync.origin) }

        func storeScopes(_ id: String) throws -> [String: Any]? {
            guard let text = try items(id)[InterfaceSync.sidebarKey] else { return nil }
            let store = try #require(InterfaceSync.object(text))
            return (store["state"] as? [String: Any])?[InterfaceSync.groupsField] as? [String: Any]
        }

        /// The groups the window starts with.
        func groups(_ id: String) throws -> GroupSync.Value {
            let prefs = try prefsScopes(id)[scope(id)].flatMap { GroupSync.Value($0) }
            let local = try storeScopes(id)?[scope(id)].flatMap { GroupSync.Value($0) }
            return GroupSync.hydrate(local: local, prefs: prefs)
        }

        func names(_ id: String) throws -> [String] { try groups(id).groups.compactMap { $0["name"] as? String } }
        func marker(_ id: String) throws -> String? { try items(id)[GroupSync.pendingKey] }

        /// The window's preferences file and Local Storage file names, to show nothing was written.
        func snapshot(_ id: String) throws -> [String] {
            let config = box.read(dir(id).appending(path: InterfaceSync.desktopConfig)) ?? ""
            return [config] + (try FileManager.default.contentsOfDirectory(atPath: LocalStorage(dataDir: dir(id)).dbDir.path).sorted())
        }

        /// Holds the window's Local Storage lock the way a running Claude does, until the returned closure is called.
        func hold(_ id: String) throws -> () -> Void {
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            holder.arguments = ["-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
                                LocalStorage(dataDir: dir(id)).dbDir.appending(path: "LOCK").path]
            let stdout = Pipe(), stdin = Pipe()
            holder.standardOutput = stdout
            holder.standardInput = stdin
            try holder.run()
            _ = stdout.fileHandleForReading.availableData   // the holder's "locked" line
            return { stdin.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
        }
    }

    /// A scope value; each group lists its items in the order given.
    static func value(_ groups: [(id: String, name: String)], _ items: [(String, String)]) -> [String: Any] {
        var assignments: [String: String] = [:], order: [String: [String]] = [:]
        for (item, group) in items {
            assignments[item] = group
            order[group, default: []].append(item)
        }
        return ["groups": groups.map { ["id": $0.id, "name": $0.name] }, "assignments": assignments, "order": order]
    }

    @Test func groupFromProfileReachesMainAndOtherProfilesUnderTheirOwnScope() throws {
        let w = try Windows()
        let id = "cg-48ad63be-9357-4381-a8b8-caad110550b0", session = "code:local_f24a00ac-186b-4b5c-bac3-541eb3f28e93"
        try w.claudeSaves("elena", Self.value([(id, "CloudLinux & TuxCare")], [(session, id)]))
        try w.setStore("main", [:])   // work has no sidebar store yet: it gets the preferences and the marker

        let report = try w.run()

        #expect(report.windowsChanged.sorted() == ["main", "work"])
        #expect(report.groupsShared == 1)
        for window in ["main", "work"] {
            #expect(Array(try w.prefsScopes(window).keys) == [w.scope(window)], "under the window's own account")
            let groups = try w.groups(window)
            #expect(try w.names(window) == ["CloudLinux & TuxCare"])
            #expect(groups.ids == [id])
            #expect(groups.assignments == [session: id])
            #expect(groups.order == [id: [session]])
            #expect(try w.marker(window) == w.scope(window) + GroupSync.migrate)
        }
        let mainStore = try #require(try w.storeScopes("main"))
        #expect(Array(mainStore.keys) == [w.scope("main")])
        #expect(try w.storeScopes("work") == nil, "no sidebar store is made up")
        #expect(try w.marker("elena") == nil, "the window it came from already has it")
    }

    @Test func onlyPortableLocalSessionsAreShared() throws {
        let w = try Windows()
        let shared = "cg-shared", own = "cg-own"
        try w.claudeSaves("elena", Self.value([(shared, "Mixed"), (own, "Cowork only")], [
            (Self.s1, shared), ("code:local_native", shared), ("cowork:task-1", shared), ("code:session_cloud", shared),
            ("code:local_unknown", shared), ("cowork:task-2", own),
        ]))
        let before = try w.snapshot("elena")

        let report = try w.run()

        let main = try w.groups("main")
        #expect(main.ids == [shared])
        #expect(main.assignments == [Self.s1: shared], "native workers, Cowork, cloud and unknown sessions stay")
        #expect(main.order == [shared: [Self.s1]])
        #expect(report.groupsShared == 1)
        #expect(try w.snapshot("elena") == before, "the source keeps its own items as they are")
    }

    @Test func runningWindowIsReadButNeverWritten() throws {
        let w = try Windows()
        try w.setPrefs("elena", [w.scope("elena"): Self.value([("cg-1", "From an open window")], [(Self.s1, "cg-1")])])
        try w.claudeSaves("main", Self.value([("cg-2", "From main")], [(Self.s2, "cg-2")]))
        let release = try w.hold("elena")
        defer { release() }
        let before = try w.snapshot("elena")

        let report = try w.run()

        #expect(try w.names("work") == ["From an open window", "From main"])
        #expect(try w.names("main") == ["From main", "From an open window"])
        #expect(!report.windowsChanged.contains("elena"))
        #expect(report.skipped.isEmpty, "an open window is expected, not a problem")
        #expect(try w.snapshot("elena") == before, "it gets main's group when it next starts")
    }

    @Test func markerIsMigrateForAdditionsAndPlainForRemovals() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g), (Self.s2, g)]))
        try w.run()
        #expect(try w.marker("main") == w.scope("main") + GroupSync.migrate)

        // A session leaves the group in ELENA's window; merging with the server's copy would bring it back.
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        #expect(try w.groups("main").assignments == [Self.s1: g])
        #expect(try w.marker("main") == w.scope("main"))

        // Until Claude uploads it, a bare marker stays bare, even for an addition.
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g), (Self.s3, g)]))
        try w.run()
        #expect(try w.groups("main").assignments == [Self.s1: g, Self.s3: g])
        #expect(try w.groups("main").order == [g: [Self.s1, Self.s3]])
        #expect(try w.marker("main") == w.scope("main"))
    }

    @Test func deleteInOneWindowRemovesEverywhereAndDoesNotResurrect() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()

        // work's window adds a session to the group and stays open.
        try w.claudeSaves("work", Self.value([(g, "Group")], [(Self.s1, g), (Self.s2, g)]), modified: Date().addingTimeInterval(-60))
        let release = try w.hold("work")
        try w.run()
        #expect(try w.groups("main").assignments == [Self.s1: g, Self.s2: g])

        // ELENA's window deletes the group.
        try w.claudeSaves("elena", Self.value([], []))
        var report = try w.run()
        #expect(report.groupsShared == 0)
        #expect(try w.names("main") == [])
        #expect(try w.groups("main").assignments.isEmpty)
        #expect(try w.marker("main") == w.scope("main"), "a merge with the server's copy would bring it back")

        report = try w.run()
        #expect(report.groupsShared == 0, "the open window still showing it doesn't bring it back")
        #expect(try w.names("work") == ["Group"], "an open window is not written")

        release()
        try w.run()
        #expect(try w.names("work") == [])
        #expect(try w.marker("work") == w.scope("work"))
        #expect(try w.run().groupsShared == 0)
    }

    @Test func groupDeletedInAWindowThatReceivedItIsDeletedEverywhere() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        #expect(try w.names("main") == ["Group"])
        // main started with the group it was given, then its user deleted it.
        try w.claudeSaves("main", Self.value([], []))

        try w.run()
        try w.run()

        for id in Self.windowIDs { #expect(try w.names(id) == [], "\(id)") }
        #expect(try w.marker("work") == w.scope("work"))
        #expect(try w.marker("elena") == w.scope("elena"))
    }

    @Test func sessionRemovedInAnOpenWindowThatReceivedItLeavesTheGroupEverywhere() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g), (Self.s2, g)]))
        try w.run()
        let release = try w.hold("main")
        // The open window rewrites its preferences: s2 is out of the group.
        try w.setPrefs("main", [w.scope("main"): Self.value([(g, "Group")], [(Self.s1, g)])])

        try w.run()
        release()
        try w.run()

        for id in Self.windowIDs {
            #expect(try w.groups(id).assignments == [Self.s1: g], "\(id)")
            #expect(try w.groups(id).order == [g: [Self.s1]], "\(id)")
        }
    }

    @Test func emptyLocalStorageScopeWinsOverStalePreferences() throws {
        let w = try Windows()
        // Claude starts main with no groups: the preferences still list one, but Local Storage has the scope, empty.
        try w.setStore("main", [w.scope("main"): Self.value([], [])])
        try w.setPrefs("main", [w.scope("main"): Self.value([("cg-stale", "Stale")], [(Self.s1, "cg-stale")])])

        let report = try w.run()

        #expect(report.groupsShared == 0)
        #expect(try w.storeScopes("work") == nil)
        #expect(try w.prefsScopes("work").isEmpty)
    }

    @Test func partialEmptyLocalStorageScopeCountsAsMissing() throws {
        let w = try Windows()
        // Claude drops an empty scope that isn't in its full form, so main starts from its preferences.
        try w.setStore("main", [w.scope("main"): [String: Any]()])
        try w.setPrefs("main", [w.scope("main"): Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")])])

        let report = try w.run()

        #expect(report.groupsShared == 1)
        let work = try #require(try w.prefsScopes("work")[w.scope("work")].flatMap { GroupSync.Value($0) })
        #expect(work.ids == ["cg-1"])
    }

    @Test func aGroupDeletedElsewhereKeepsAWindowsOwnItems() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        try w.claudeSaves("main", Self.value([(g, "Group")], [(Self.s1, g), ("cowork:task", g)]))
        try w.claudeSaves("elena", Self.value([], []))

        try w.run()

        let main = try w.groups("main")
        #expect(main.ids == [g], "main's own Cowork task is still in it")
        #expect(main.assignments == ["cowork:task": g])
        #expect(main.order == [g: ["cowork:task"]])
        #expect(try w.names("work") == [])
    }

    @Test func renameInOneWindowWins() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        try w.claudeSaves("elena", Self.value([(g, "Renamed")], [(Self.s1, g)]))

        try w.run()

        for id in Self.windowIDs { #expect(try w.names(id) == ["Renamed"]) }
        #expect(try w.marker("main") == w.scope("main") + GroupSync.migrate)
    }

    @Test func latestEditorWinsOnConflict() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        // main comes first in the list but renamed it last.
        let now = Date()
        try w.claudeSaves("work", Self.value([(g, "Work's name")], [(Self.s1, g)]), modified: now.addingTimeInterval(-120))
        try w.claudeSaves("main", Self.value([(g, "Main's name")], [(Self.s1, g)]), modified: now.addingTimeInterval(-60))

        try w.run()

        for id in Self.windowIDs { #expect(try w.names(id) == ["Main's name"]) }
    }

    @Test func unconfirmedWriteIsNotReadAsAChange() throws {
        let w = try Windows()
        let g = "cg-1"
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        // ELENA renames it; main hasn't started since it was written, though its preferences are newer.
        try w.claudeSaves("elena", Self.value([(g, "Renamed")], [(Self.s1, g)]), modified: Date().addingTimeInterval(-3600))

        try w.run()

        #expect(try w.names("main") == ["Renamed"])
        #expect(try w.names("elena") == ["Renamed"])
        let (_, records) = GroupSync(paths: w.box.paths).readState()
        #expect(records["main"]?.base?.isEmpty == true, "main's own last state is still the one before the write")
        #expect(records["main"]?.written?.ids == [g])
    }

    @Test func groupDroppedByClaudeBeforeConfirmationIsNotADeletion() throws {
        let w = try Windows()
        let g = "cg-1"
        // main's Local Storage last synced with another account, so Claude ignores the marker written there.
        try LocalStorage(dataDir: w.dir("main")).update(origin: InterfaceSync.origin, set: [GroupSync.ownerKey: Sandbox.accountB], remove: [])
        try w.claudeSaves("elena", Self.value([(g, "Group")], [(Self.s1, g)]))
        try w.run()
        // main starts, and Claude replaces its groups with its account's server copy, which doesn't have the group yet.
        try w.claudeSaves("main", Self.value([("cg-server", "From the server")], [("cowork:task", "cg-server")]))

        let report = try w.run()

        #expect(report.groupsShared == 1)
        #expect(try w.names("elena") == ["Group"])
        #expect(try w.names("work") == ["Group"])
        #expect(try w.names("main") == ["From the server", "Group"], "written again")
    }

    @Test func privateGroupsAndOtherScopesUntouched() throws {
        let w = try Windows()
        let own = Self.value([("cg-own", "Cowork only")], [("cowork:task", "cg-own")])
        let old = Self.value([("cg-old", "Another account")], [(Self.s1, "cg-old")])
        try w.setStore("main", [w.scope("main"): own, "old-account/old-org": old])
        try w.setPrefs("main", [w.scope("main"): own, "old-account/old-org": old])
        try w.claudeSaves("elena", Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")]))

        let report = try w.run()

        #expect(try w.names("main") == ["Cowork only", "Group"])
        #expect(try w.groups("main").assignments == ["cowork:task": "cg-own", Self.s1: "cg-1"])
        let storeScopes = try #require(try w.storeScopes("main"))
        #expect(InterfaceSync.canonical(storeScopes["old-account/old-org"]!) == InterfaceSync.canonical(old))
        #expect(try InterfaceSync.canonical(w.prefsScopes("main")["old-account/old-org"]!) == InterfaceSync.canonical(old))
        let text = try #require(try w.items("main")[InterfaceSync.sidebarKey])
        let store = try #require(InterfaceSync.object(text))
        #expect((store["state"] as? [String: Any])?["sidebarWidth"] as? Int == 250)
        let config = try #require(SettingsSync.readJSON(w.dir("main").appending(path: InterfaceSync.desktopConfig)))
        #expect(config["globalShortcut"] as? String == "Alt+Space")
        #expect(((config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])?["epitaxy-split-suggestion"] as? Bool == true)
        #expect(report.groupsShared == 1, "a group with only the window's own items is not shared")
        #expect(try w.names("work") == ["Group"])
    }

    @Test func unknownVersionOrShapeLeftAlone() throws {
        let w = try Windows()
        try w.claudeSaves("elena", Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")]))
        try w.setStore("main", [:], version: 2)
        try w.setPrefs("work", [w.scope("work"): ["groups": "not a list"]])
        let main = try w.snapshot("main"), work = try w.snapshot("work")

        let report = try w.run()

        #expect(report.windowsChanged.isEmpty)
        #expect(report.skipped.count == 2)
        #expect(report.skipped.contains { $0.hasPrefix("main:") })
        #expect(report.skipped.contains { $0.hasPrefix("work:") })
        #expect(try w.snapshot("main") == main)
        #expect(try w.snapshot("work") == work)
        #expect(report.groupsShared == 1, "the other windows still share theirs")
    }

    @Test func backupTakenBeforeWrite() throws {
        let w = try Windows()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try w.setStore("main", [:])
        let original = try #require(w.box.read(w.dir("main").appending(path: InterfaceSync.desktopConfig)))
        try w.claudeSaves("elena", Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")]))

        try w.run(now: now)

        let day = Backup(paths: w.box.paths, now: now).dayDir
        #expect(w.box.read(day.appending(path: "Claude/\(InterfaceSync.desktopConfig)")) == original)
        let saved = try LocalStorage(dataDir: day.appending(path: "Claude", directoryHint: .isDirectory)).items(origin: InterfaceSync.origin)
        #expect(saved[GroupSync.pendingKey] == nil)
        #expect(saved[InterfaceSync.sidebarKey] != nil)
        #expect(try w.marker("main") != nil)
    }

    @Test func noChangeMeansNoWrite() throws {
        let w = try Windows()
        try w.setStore("main", [:])
        try w.claudeSaves("elena", Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")]))
        try w.run()
        let before = try Self.windowIDs.map { try w.snapshot($0) }

        let report = try w.run()

        #expect(report.windowsChanged.isEmpty)
        #expect(report.groupsShared == 1)
        #expect(try Self.windowIDs.map { try w.snapshot($0) } == before)
    }

    @Test func periodicSyncSharesGroupsWithEveryProfile() throws {
        let w = try Windows()
        let manager = ProfileManager(paths: w.box.paths)
        try manager.registry.save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2"),
                                   Profile(id: "elena", label: "ELENA", email: nil, color: "#2F9E44")])
        try w.claudeSaves("elena", Self.value([("cg-1", "Group")], [(Self.s1, "cg-1")]))

        let report = try #require(try manager.syncSessions())

        #expect(report.groups.windowsChanged.sorted() == ["main", "work"])
        #expect(try w.names("main") == ["Group"])
    }
}
