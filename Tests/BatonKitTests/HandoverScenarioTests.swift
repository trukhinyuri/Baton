import Foundation
import Testing

@testable import BatonKit

/// The handover of 29 September 2026 (`Fixtures/handover-incident`, made by scripts/e2e/make-incident-fixture.py),
/// materialized into a sandbox home: its time tokens set relative to now, `dot-claude` renamed `.claude`, stand-ins for
/// Claude.app and the profiles' app copies, and Local Storage and IndexedDB written from `stores.json`.
enum HandoverIncident {
    static var fixture: URL { Bundle.module.resourceURL!.appending(path: "Fixtures/handover-incident", directoryHint: .isDirectory) }

    struct Expected: Decodable {
        struct Kept: Decodable { var folderRule: [String]; var remoteControl: [String]; var ambiguous: [String] }
        struct Groups: Decodable { var id: String; var new: String; var newName: String; var mainMoved: [String]; var newMoved: [String] }
        struct Own: Decodable { var cards: [String]; var pin: String }
        var source: String
        var destination: String
        var labels: [String: String]
        var accounts: [String: String]
        var scopes: [String: String]
        var moved: [String]
        var kept: Kept
        var cut: [String]
        var armed: [String]
        var topPin: String
        var pinnedMoved: [String]
        var groups: Groups
        var bravoOwn: Own
    }

    static func expected() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: fixture.appending(path: "expected.json")))
    }

    /// Replaces "@S+n@", "@MS+n@" (numbers, quotes included) and @ISO+n@, @ISOF+n@ (dates) with times `n` seconds from `now`.
    static func substitute(_ text: String, now: Date) -> String {
        let pattern = try! NSRegularExpression(pattern: #""@(S|MS)([+-]\d+)@"|@(ISOF?)([+-]\d+)@"#)
        var result = "", last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            result += text[last..<range.lowerBound]
            let group = { (i: Int) in Range(match.range(at: i), in: text).map { String(text[$0]) } }
            if let kind = group(1), let offset = group(2).flatMap(Double.init) {
                let date = now.addingTimeInterval(offset)
                result += kind == "S" ? String(Int(date.timeIntervalSince1970)) : String(Int64(date.timeIntervalSince1970 * 1000))
            } else if let kind = group(3), let offset = group(4).flatMap(Double.init) {
                let options: ISO8601DateFormatter.Options = kind == "ISOF" ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                result += ISO8601DateFormatter.string(from: now.addingTimeInterval(offset), timeZone: TimeZone(identifier: "UTC")!, formatOptions: options)
            }
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// Writes the incident into `home` and returns its paths.
    @discardableResult
    static func materialize(into home: URL, now: Date = Date()) throws -> Paths {
        let fm = FileManager.default
        let source = fixture.appending(path: "home", directoryHint: .isDirectory)
        let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            var relative = String(url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1))
            if relative.hasPrefix("dot-claude/") { relative = ".claude/" + relative.dropFirst("dot-claude/".count) }
            let target = home.appending(path: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension == "json" || url.pathExtension == "jsonl" {
                try Data(substitute(String(contentsOf: url, encoding: .utf8), now: now).utf8).write(to: target)
            } else {
                try fm.copyItem(at: url, to: target)
            }
        }
        let paths = Paths(home: home, claudeApp: home.appending(path: "Applications/Claude.app", directoryHint: .isDirectory))
        let box = Sandbox(root: home, paths: paths)
        // Not Claude's bundle identifier, so nothing on this Mac is taken for one of these windows.
        try box.claudeBundle(at: paths.claudeApp, identifier: "test.baton.not-claude")
        for profile in try ProfileRegistry(paths: paths).load() {
            try box.claudeBundle(at: paths.engine(for: profile.id), identifier: "test.baton.not-claude")
        }
        let storesText = substitute(try String(contentsOf: fixture.appending(path: "stores.json"), encoding: .utf8), now: now)
        let stores = try #require(try JSONSerialization.jsonObject(with: Data(storesText.utf8)) as? [String: [String: Any]])
        let storageFixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage", directoryHint: .isDirectory)
        for (window, store) in stores {
            let dataDir = window == "main" ? paths.mainDataDir : paths.dataDir(for: window)
            if let items = store["localStorage"] as? [String: Any] {
                try fm.copyItem(at: storageFixture, to: dataDir.appending(path: "Local Storage", directoryHint: .isDirectory))
                try LocalStorage(dataDir: dataDir).update(
                    origin: InterfaceSync.origin, set: items.mapValues { SidebarLayout.json($0) }, remove: [])
            }
            if let pins = store["pins"] as? [String: Any] {
                let record: [String: Any] = ["state": ["starredIds": pins["starredIds"] ?? []], "version": 0, "updatedAt": pins["updatedAt"] ?? 0]
                _ = try InterfaceSyncTests().makePinStore(dataDir, records: [SidebarLayout.pinKey: (1, SidebarLayout.json(record))])
            }
        }
        return paths
    }
}

extension Sandbox {
    /// A sandbox over a home folder something else filled.
    init(root: URL, paths: Paths) {
        self.root = root
        self.paths = paths
    }
}

/// One run of the incident: a sandbox home, the stand-in windows (ATLAS open) and a manager wired to them.
struct IncidentScene {
    let root: URL
    let paths: Paths
    let expected: HandoverIncident.Expected
    let fake: StandInWindows
    let manager: ProfileManager

    init(running: [String] = ["atlas"], live: [(session: String, window: String)] = []) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "baton-incident-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = try HandoverIncident.materialize(into: root)
        expected = try HandoverIncident.expected()
        let log = root.appending(path: "fake-launch.log")
        try StandInWindows.prepare(
            StandInWindows.State(
                running: Dictionary(uniqueKeysWithValues: running.map { ($0, Date().addingTimeInterval(-3600)) }),
                live: live.map { StandInWindows.State.Live(session: $0.session, window: $0.window, since: Date().addingTimeInterval(-600)) }), log: log)
        fake = StandInWindows(log: log, paths: paths)
        manager = ProfileManager(paths: paths)
        fake.wire(manager)
        manager.handoverSourceWait = (limit: 0.6, poll: 0.1, quit: 0.4)
    }

    func dataDir(_ window: String) -> URL { window == "main" ? paths.mainDataDir : paths.dataDir(for: window) }
    func cardsFolder(_ window: String) -> URL {
        dataDir(window).appending(path: "claude-code-sessions/\(expected.scopes[window]!)", directoryHint: .isDirectory)
    }
    func cards(_ window: String) -> Set<String> {
        Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: cardsFolder(window).path)) ?? []).filter { $0.hasPrefix("local_") }.map {
                String($0.dropLast(5))
            })
    }
    func card(_ window: String, _ name: String) -> [String: Any]? { ConversationIndex.readCard(cardsFolder(window).appending(path: name + ".json")) }
    func entries(_ window: String) -> [AutoResumeEntry] { AutoResume.entries(in: dataDir(window), account: expected.accounts[window]!) ?? [] }
    func items(_ window: String) throws -> [String: String] { try LocalStorage(dataDir: dataDir(window)).items(origin: InterfaceSync.origin) }
    func prefs(_ window: String) throws -> [String: Any] { try InterfaceSyncTests().prefs(dataDir(window)) }
    var links: [String] { fake.events.filter { $0.hasPrefix("link ") } }
    func label(_ id: String) -> String { expected.labels[id] ?? id }
}

@Suite("Handover scenario: the 29 September incident")
struct HandoverScenarioTests {
    static let remoteControlKeys = ["remoteControlSpawn", "projectThreadChild", "rcChild", "bridgeSessionIds"]

    @Test func incidentMovesTheWorkToTheWindowWithTheMostRoom() async throws {
        let scene = try IncidentScene()
        let x = scene.expected
        let plan = try scene.manager.planHandover(from: x.source)

        #expect(plan.destination == x.destination, "the window with the most room")
        #expect(Set(plan.sessions.map(\.card)) == Set(x.moved))
        #expect(Set(plan.cut.map(\.transcript)) == Set(x.cut))
        #expect(plan.sessions.allSatisfy { !$0.asCopy }, "nothing is live in ATLAS")
        #expect(plan.sourceActivity == .idle && plan.destinationActivity == .closed && plan.seeding == .seed)
        #expect(plan.leftovers.contains(.folderRule(count: 19, folder: "/work/client", accounts: ["atlas@example.org", "cedar@example.org"])))
        #expect(plan.leftovers.contains(.remoteControl(count: 8)), "6 ATLAS still serves, 2 ATLAS and CEDAR both serve")

        let result = try await scene.manager.handOver(plan, dwell: 5, lastWait: 1)

        #expect(result.state == .done && result.sourceClosed, "\(result.plan.leftovers)")
        #expect(Set(result.resumed) == Set(x.cut), "\(result.resumed)")
        // Every card that isn't withheld is in BRAVO, as itself; the withheld ones are not.
        let bravo = scene.cards("bravo")
        #expect(Set(x.moved).isSubset(of: bravo))
        #expect(bravo.isDisjoint(with: x.kept.folderRule + x.kept.remoteControl))
        // No copy Baton wrote carries Remote Control's keys; CEDAR's own marked copies are left alone.
        for window in ["main", "bravo", "cedar"] {
            for name in scene.cards(window) where !(window == "cedar" && x.kept.ambiguous.contains(name)) {
                let card = try #require(scene.card(window, name))
                #expect(Self.remoteControlKeys.allSatisfy { card[$0] == nil }, "\(window)/\(name)")
            }
        }
        for name in x.kept.ambiguous { #expect(scene.card("cedar", name)?["remoteControlSpawn"] != nil, "ambiguous: untouched") }
        // Pins, groups and pin order, the same in every place written.
        let layout = try #require(SidebarLayout.read(dataDir: scene.dataDir("bravo"), scope: x.scopes["bravo"]!))
        #expect(Set(layout.starred) == Set(x.pinnedMoved + [x.bravoOwn.pin]))
        for item in x.groups.mainMoved { #expect(layout.assignments[item] == x.groups.id, "\(item)") }
        for item in x.groups.newMoved { #expect(layout.assignments[item] == x.groups.new, "\(item)") }
        #expect(layout.groups.contains { $0.id == x.groups.new && $0.name == x.groups.newName })
        let items = try scene.items("bravo")
        #expect(items[SidebarLayout.pendingKey] == x.scopes["bravo"]! + SidebarLayout.migrate, "a group new to BRAVO: Claude syncs its name and id")
        let prefs = try scene.prefs("bravo")
        let value = { (key: String) in items[key].flatMap(InterfaceSync.object)?["value"] }
        let starredMirror = try #require(value(SidebarLayout.starredMirror) as? [String])
        #expect(Set(starredMirror) == Set(layout.starred) && Set(prefs[SidebarLayout.starredPref] as? [String] ?? []) == Set(layout.starred))
        let mirrorGroups = try #require(value(SidebarLayout.groupsMirror) as? [String: Any])
        let prefGroups = try #require(prefs[SidebarLayout.groupsPref] as? [String: Any])
        let assignments = { (value: Any?) in ((value as? [String: Any])?["assignments"] as? [String: String]) ?? [:] }
        #expect(assignments(mirrorGroups[x.scopes["bravo"]!]) == layout.assignments)
        #expect(assignments(prefGroups[x.scopes["bravo"]!]) == layout.assignments)
        // Auto-continue: seeded in BRAVO, off in ATLAS, in the settings and in Local Storage.
        let seeded = Dictionary(uniqueKeysWithValues: scene.entries("bravo").map { ($0.key, $0) })
        for session in plan.cut { #expect(seeded[session.card]?.optedIn == true && seeded[session.card]!.resetsAt < Date(), "\(session.card)") }
        for card in x.armed { #expect(scene.entries("atlas").first { $0.key == card }?.optedIn == false, "\(card)") }
        let atlasItems = try scene.items("atlas")
        let mirrorBucket = try #require(
            atlasItems[AutoResume.mirrorKey(x.accounts["atlas"]!)].flatMap(InterfaceSync.object)?["value"] as? [String: [String: Any]])
        for card in x.armed { #expect(mirrorBucket[card]?["optedIn"] as? Bool == false, "\(card) in Local Storage") }
        // ATLAS quit before BRAVO started, and BRAVO started before any link; the top pin comes last.
        let events = scene.fake.events
        let quit = try #require(events.firstIndex(of: "quit atlas"))
        let started = try #require(events.firstIndex(of: "start bravo"))
        let firstLink = try #require(events.firstIndex { $0.hasPrefix("link ") })
        #expect(quit < started && started < firstLink, "\(events)")
        #expect(scene.links.allSatisfy { $0.hasPrefix("link bravo ") } && scene.links.count == x.cut.count, "\(events)")
        #expect(scene.links.last == "link bravo \(x.topPin)")
        let entry = try #require(HandoverLog(paths: scene.paths).entries().last)
        #expect(entry.state == "done" && entry.destination == "bravo" && entry.sourceClosed && Set(entry.resumed) == Set(x.cut))
        let until = HandoverText.untilText(try #require(plan.resetsAt), now: Date(), timeZone: .current, locale: .current)
        #expect(
            result.line
                == "ATLAS is at its limit until \(until) and was closed. Your work continues in BRAVO — 8 sessions resumed; "
                + "19 stay in ATLAS: a folder rule keeps client for atlas@, cedar@; 8 stay in ATLAS: Remote Control reaches them there.",
            "\(result.line)")
    }

    @Test func sessionsLiveInTheSourceContinueAsCopiesAndTheSourceClosesLater() async throws {
        let base = try HandoverIncident.expected()
        let liveCards = ["local_ca4d0000-0000-4000-8000-000000000068", "local_ca4d0000-0000-4000-8000-000000000069"]
        #expect(base.moved.contains(liveCards[0]) && base.moved.contains(liveCards[1]))
        let live = liveCards.map { "5e55e000" + $0.dropFirst("local_ca4d0000".count) } + [base.cut[5]]
        let scene = try IncidentScene(live: live.map { ($0, "atlas") })

        let result = try await scene.manager.handOver(try scene.manager.planHandover(from: "atlas"), dwell: 5, lastWait: 1)

        #expect(result.state == .done && !result.sourceClosed, "Claude Code still works in ATLAS after the wait, so it stays open")
        #expect(result.plan.leftovers.contains(.copies(count: 3)))
        #expect(result.plan.leftovers.contains(.resumeInSource(count: 3)), "its armed cut sessions continue there at its reset")
        let copies = scene.cards("bravo").subtracting(base.moved + base.bravoOwn.cards).compactMap { scene.card("bravo", $0) }
            .filter { ($0["title"] as? String)?.hasSuffix(" · from ATLAS") == true }
        #expect(copies.count == 3)
        #expect(copies.allSatisfy { card in Self.remoteControlKeys.allSatisfy { card[$0] == nil } })
        #expect(!scene.links.contains("link bravo \(base.cut[5])"), "the original still open in ATLAS isn't shown in BRAVO")
        #expect(!scene.fake.events.contains("quit atlas"))
        #expect(result.line.hasPrefix("ATLAS is at its limit until ") && !result.line.contains("was closed"), "\(result.line)")

        let fake = scene.fake
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            fake.stopWork(in: "atlas")
        }
        #expect(try await scene.manager.watchHandoverSource("atlas", poll: 0.1))
        #expect(scene.fake.events.contains("quit atlas") && !scene.fake.events.contains("force-quit atlas"))
    }

    @Test func busyDestinationWaitsAndRestartsWhenItsWorkFinishes() async throws {
        let base = try HandoverIncident.expected()
        let own = "5e55e000" + base.bravoOwn.cards[0].dropFirst("local_ca4d0000".count)
        let scene = try IncidentScene(running: ["atlas", "bravo"], live: [(own, "bravo")])
        let plan = try scene.manager.planHandover(from: "atlas")
        #expect(plan.destination == "bravo" && plan.destinationActivity == .busy(working: 1), "more than 40 points ahead of CEDAR")

        let waiting = try await scene.manager.handOver(plan, dwell: 5, lastWait: 1)

        #expect(waiting.state == .waiting && scene.links.isEmpty && !scene.fake.events.contains("quit bravo"), "running work isn't interrupted")
        #expect(
            waiting.line.hasSuffix(
                "BRAVO restarts when its current work finishes; 19 stay in ATLAS: a folder rule keeps client for atlas@, cedar@; 8 stay in ATLAS: Remote Control reaches them there."
            ), "\(waiting.line)")
        let fake = scene.fake
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            fake.stopWork(in: "bravo")
        }
        let done = try #require(try await scene.manager.finishWaitingHandover(source: "atlas", poll: 0.1, dwell: 5, lastWait: 1))

        #expect(done.state == .done && Set(done.resumed) == Set(base.cut))
        let events = scene.fake.events
        let quit = try #require(events.firstIndex(of: "quit bravo"))
        let started = try #require(events.lastIndex(of: "start bravo"))
        #expect(quit < started && started < (events.firstIndex { $0.hasPrefix("link ") } ?? 0), "\(events)")
    }

    @Test func flagOffOpensTheCutSessionsAndNamesThem() async throws {
        let scene = try IncidentScene()
        var plan = try scene.manager.planHandover(from: "atlas")
        plan.seeding = .flagOff

        let result = try await scene.manager.handOver(plan, dwell: 0.2, lastWait: 0.2)

        #expect(scene.entries("bravo").isEmpty, "nothing seeded")
        #expect(scene.links.count == 8, "each is opened, so it's on screen")
        let titles = try #require(result.plan.leftovers.lazy.compactMap { if case .cannotResume(let titles) = $0 { titles } else { nil } }.first)
        #expect(titles.count == 8)
        #expect(!result.line.lowercased().contains("type"))
    }

    /// For scripts/e2e-handover.sh: writes the incident into `BATON_E2E_HOME`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BATON_E2E_HOME"] != nil))
    func materializesTheIncidentForTheEndToEndScript() throws {
        let home = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BATON_E2E_HOME"]), isDirectory: true)
        let paths = try HandoverIncident.materialize(into: home)
        #expect(try ProfileRegistry(paths: paths).load().count == 3)
    }
}
