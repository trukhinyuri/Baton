import Foundation
import Testing

@testable import BatonKit

/// The windows, Claude Code processes and links of a handover test: WORK (a profile, the window at its limit) and
/// (main), which never touch this Mac. A link to a window makes its session continue there when `resumes` is on:
/// the transcript grows and a Claude Code process of it runs in that window.
final class HandoverWorld: @unchecked Sendable {
    private let lock = NSLock()
    let box: Sandbox
    private var copies: [RunningClaude] = []
    private var processes: [LimitTracker.LiveProcess] = []
    /// Processes that hold their session open without working, as Claude Desktop keeps them for hours.
    private var idlePIDs: Set<pid_t> = []
    private var log: [String] = []
    private var pid: pid_t = 100
    var resumes = true

    init(_ box: Sandbox) { self.box = box }

    var running: [RunningClaude] { lock.withLock { copies } }
    var live: [LimitTracker.LiveProcess] { lock.withLock { processes } }
    var events: [String] { lock.withLock { log } }
    var links: [String] { events.filter { $0.hasPrefix("link ") } }

    func dataDir(_ window: String) -> URL { window == "main" ? box.main : box.work }
    func executable(_ window: String) -> String { dataDir(window).appending(path: "claude-code/2.1.284/claude.app/Contents/MacOS/claude").path }
    func window(of app: URL) -> String { app.standardizedFileURL.path == box.paths.claudeApp.standardizedFileURL.path ? "main" : "work" }

    func start(_ window: String) {
        lock.withLock {
            pid += 1
            let app = window == "main" ? box.paths.claudeApp : box.paths.engine(for: "work")
            let arguments = [app.appending(path: "Contents/MacOS/Claude").path] + (window == "main" ? [] : ["--user-data-dir=\(box.work.path)"])
            copies.append(RunningClaude(bundlePath: app.standardizedFileURL.path, arguments: arguments, pid: pid, launchDate: Date()))
            log.append("start \(window)")
        }
    }

    /// The user quits the window, and whatever ran in it ends.
    func close(_ window: String) {
        lock.withLock {
            copies.removeAll { $0.bundlePath == (window == "main" ? box.paths.claudeApp : box.paths.engine(for: "work")).standardizedFileURL.path }
        }
        stopWork(in: window)
    }

    /// The window quits, and the Claude Code processes it kept end with it.
    func quit(_ copy: RunningClaude) {
        lock.withLock {
            copies.removeAll { $0.pid == copy.pid }
            if !copies.contains(where: { $0.bundlePath == copy.bundlePath }) {
                let window = copy.bundlePath == box.paths.claudeApp.standardizedFileURL.path ? "main" : "work"
                processes.removeAll { $0.executable == executable(window) }
            }
            log.append("quit \(copy.bundlePath == box.paths.claudeApp.standardizedFileURL.path ? "main" : "work")")
        }
    }

    func work(_ session: String, in window: String, startedAt: Date = Date().addingTimeInterval(-3600), idle: Bool = false) {
        lock.withLock {
            pid += 1
            if idle { idlePIDs.insert(pid) }
            processes.append(
                LimitTracker.LiveProcess(
                    pid: pid, session: session, startedAt: startedAt, version: "2.1.284", cwd: "/repo", hostSessionID: nil, executable: executable(window)))
        }
    }

    func stopWork(in window: String? = nil) {
        lock.withLock { processes.removeAll { window == nil || $0.executable == executable(window!) } }
    }

    func handed(_ app: URL, _ links: [URL]) {
        let window = window(of: app)
        for link in links {
            let session = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            lock.withLock { log.append("link \(window) \(session)") }
            guard resumes else { continue }
            if let transcript = ConversationIndex.transcriptFiles(in: box.paths.claudeProjectsDir)[session],
                let handle = try? FileHandle(forWritingTo: transcript)
            {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((#"{"type":"user","message":"continue"}"# + "\n").utf8))
                try? handle.close()
            }
            work(session, in: window, startedAt: Date())
        }
    }

    /// A manager whose windows, processes and links are this world's.
    func manager() throws -> ProfileManager {
        let manager = try box.closedWorkWindow(FakeWindows())
        wire(manager)
        return manager
    }

    func wire(_ manager: ProfileManager) {
        manager.signatureCheck = { _ in true }
        manager.runningCopies = { self.running }
        manager.appLauncher = { app, _, links in
            self.start(self.window(of: app))
            self.handed(app, links)
        }
        manager.appActivator = { app, links in self.handed(app, links) }
        manager.quitRequester = { self.quit($0) }
        manager.limitTracker.liveProcesses = { _ in self.live }
        manager.processTree = { ProcessTree(claudes: [], parent: { _ in nil }) }
        manager.liveSessionIDs = { Set(self.live.map(\.session)) }
        manager.processWorking = { pid, _ in !self.lock.withLock { self.idlePIDs.contains(pid) } }
    }
}

/// WORK at its limit with sessions in /repo; (main) signed in with room.
struct HandoverScene {
    static let a = "aaaaaaaa-0000-4000-8000-000000000001"
    static let b = "aaaaaaaa-0000-4000-8000-000000000002"
    static let c = "aaaaaaaa-0000-4000-8000-000000000003"
    static let d = "aaaaaaaa-0000-4000-8000-000000000004"
    static let org = "0d9e8c7b-0000-4000-8000-000000000001"

    let box: Sandbox
    let world: HandoverWorld
    let manager: ProfileManager
    let now = Date()
    let reset: Date
    let workPair: URL
    let mainPair: URL

    init(resetIn: TimeInterval = 7200) throws {
        box = try Sandbox()
        world = HandoverWorld(box)
        manager = try world.manager()
        reset = now.addingTimeInterval(resetIn)
        workPair = try box.pair(box.work, account: Sandbox.accountB, org: Self.org)
        mainPair = try box.pair(box.main, account: Sandbox.accountA, org: Self.org)
        try box.write("{}", to: box.main.appending(path: LocalOnly.configName))
        try armed([])
    }

    static func card(_ session: String) -> String { "local_\(session.suffix(12))" }

    /// A card in WORK and the session's transcript.
    func session(_ session: String, title: String, extra: String = "") throws {
        let card = Self.card(session)
        try box.write(
            #"{"sessionId":"\#(card)","cliSessionId":"\#(session)","cwd":"/repo","title":"\#(title)"\#(extra)}"#,
            to: workPair.appending(path: card + ".json"))
        let folder = box.paths.claudeProjectsDir.appending(path: "-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(session).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            try box.write(#"{"type":"user","sessionId":"\#(session)","message":"hello"}"# + "\n", to: url)
        }
    }

    /// WORK's auto-continue entries, on, for this limit.
    func armed(_ sessions: [String]) throws {
        let entries = sessions.map { #""\#(Self.card($0))":{"resetsAt":\#(Int(reset.timeIntervalSince1970)),"attempt":0,"optedIn":true}"# }
        try box.write(
            #"{"preferences":{"epitaxyPrefs":{"autoResumeRateLimit.\#(Sandbox.accountB)":{\#(entries.joined(separator: ","))}}}}"#,
            to: box.work.appending(path: LocalOnly.configName))
    }

    func entry(_ session: String, in window: String) -> AutoResumeEntry? {
        let (dir, account) = window == "main" ? (box.main, Sandbox.accountA) : (box.work, Sandbox.accountB)
        return AutoResume.entries(in: dir, account: account)?.first { $0.key == Self.card(session) }
    }

    var statuses: [ProfileStatus] {
        let hit = LimitHit(kind: .fiveHour, at: now.addingTimeInterval(-300), resetsAt: reset, session: "limit")
        return [
            ProfileStatus(
                profile: nil, accountID: Sandbox.accountA, email: "main@example.org", usage: Usage(fiveHour: 0, week: 10, sampledAt: now), isRunning: false),
            ProfileStatus(
                profile: Profile(id: "work", label: "WORK", email: nil, color: "#1971C2"), accountID: Sandbox.accountB, email: "work@example.org",
                usage: Usage(fiveHour: 100, week: 30, sampledAt: now), isRunning: true,
                limits: Limits(samples: [UsageSample(at: now.addingTimeInterval(-600), fiveHour: 90, week: 30)], hits: [hit])),
        ]
    }

    func plan(to destination: String? = nil) throws -> HandoverPlan {
        try manager.planHandover(from: "work", to: destination, statuses: statuses, now: now)
    }

    func session(_ plan: HandoverPlan, _ id: String) -> HandoverSession? { plan.sessions.first { $0.transcript == id } }

    /// A limit message in the session's transcript, and, with `answered`, a reply after it.
    func limitHit(_ session: String, answered: Bool = false) throws {
        let url = box.paths.claudeProjectsDir.appending(path: "-repo/\(session).jsonl")
        let stamp = { (date: Date) in
            ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        }
        var lines =
            #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"sessionId":"\#(session)","entrypoint":"claude-desktop","version":"2.1.284","timestamp":"\#(stamp(now.addingTimeInterval(-300)))","quotaLimits":{"status":"rejected","resetsAt":\#(Int(reset.timeIntervalSince1970)),"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false},"message":{"role":"assistant","content":[]}}"#
            + "\n"
        if answered {
            lines +=
                #"{"type":"assistant","requestId":"req_1","sessionId":"\#(session)","entrypoint":"claude-desktop","version":"2.1.284","timestamp":"\#(stamp(now.addingTimeInterval(-60)))","message":{"model":"claude-opus-5-5"}}"#
                + "\n"
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.utf8))
        try handle.close()
    }
}

@Suite("Handover plan")
struct HandoverPlanTests {
    typealias S = HandoverScene

    @Test func statusesAreAtTheirLimit() throws {
        let scene = try S()
        let work = try #require(scene.statuses.last)
        #expect(DestinationRanking.isAtLimit(work, now: scene.now))
        #expect(work.limits.binding(now: scene.now)?.reset?.at == scene.reset)
    }

    @Test func liveInSourceBecomesCopyWhateverItsEntry() throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed and live")
        try scene.session(S.b, title: "Live only")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.a, in: "work")
        scene.world.work(S.b, in: "work")

        let plan = try scene.plan()

        #expect(plan.destination == "main")
        #expect(scene.session(plan, S.a)?.asCopy == true && scene.session(plan, S.a)?.cut == true)
        #expect(scene.session(plan, S.b)?.asCopy == true && scene.session(plan, S.b)?.cut == false, "live, so a copy, though nothing is armed")
        #expect(plan.leftovers.contains(.copies(count: 1)), "the live-only one continues as a copy")
        #expect(plan.leftovers.contains(.keepRunningInSource(count: 1)), "the armed one keeps running in WORK")
        #expect(plan.resumeInSource.map(\.transcript) == [S.a], "its copy isn't to resume")
        #expect(plan.sourceActivity == .busy(working: 2))
    }

    @Test func armedButNotLiveMovesAsItself() throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])
        scene.world.start("work")

        let plan = try scene.plan()

        #expect(scene.session(plan, S.a)?.cut == true)
        #expect(scene.session(plan, S.a)?.asCopy == false, "an armed entry alone doesn't make a copy")
        #expect(plan.sourceActivity == .idle)
    }

    @Test func idleProcessesDontMakeCopies() throws {
        let scene = try S()
        try scene.session(S.a, title: "Working")
        try scene.session(S.b, title: "Open, idle")
        scene.world.start("work")
        scene.world.work(S.a, in: "work")
        scene.world.work(S.b, in: "work", idle: true)

        let plan = try scene.plan()

        #expect(plan.sourceActivity == .busy(working: 1))
        #expect(scene.session(plan, S.a)?.asCopy == true, "working in WORK, so a copy")
        #expect(scene.session(plan, S.b)?.asCopy == false, "only open there, so itself")
    }

    @Test func sourceWithOnlyIdleProcessesIsClosedAndEverySessionMovesAsItself() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.session(S.b, title: "Docs")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.a, in: "work", idle: true)
        scene.world.work(S.b, in: "work", idle: true)
        let plan = try scene.plan()
        #expect(plan.sourceActivity == .idle && plan.sessions.allSatisfy { !$0.asCopy })

        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)

        #expect(result.sourceClosed && scene.world.events.contains("quit work"), "idle processes don't keep the window open")
        #expect(result.plan.sessions.allSatisfy { !$0.asCopy }, "nothing works in WORK once it's closed")
        #expect(scene.world.links.contains("link main \(S.a)"), "the cut session resumes as itself")
        let copies = result.plan.leftovers.filter {
            if case .copies = $0 { return true }
            return false
        }
        #expect(copies.isEmpty)
    }

    @Test func sourceWithNothingLiveIsClosedFirstAndAllMoveAsThemselves() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        scene.world.start("work")
        let plan = try scene.plan()

        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)

        #expect(result.state == .done && result.sourceClosed)
        let events = scene.world.events
        let quit = try #require(events.firstIndex(of: "quit work"))
        let started = try #require(events.firstIndex(of: "start main"))
        let link = try #require(events.firstIndex(of: "link main \(S.a)"))
        #expect(quit < started && started < link, "the source is closed before anything resumes: \(events)")
        #expect(result.plan.sessions.allSatisfy { !$0.asCopy })
        #expect(scene.entry(S.a, in: "work")?.optedIn == false, "turned off in the source")
        let seeded = try #require(scene.entry(S.a, in: "main"))
        #expect(seeded.optedIn && seeded.resetsAt < Date(), "seeded in the destination with its reset past")
        #expect(scene.box.exists(scene.mainPair.appending(path: S.card(S.a) + ".json")), "the same card, shared")
        #expect(result.resumed == [S.a])
        #expect(result.line.hasSuffix("and was closed. Your work continues in (main) — 1 session resumed."), "\(result.line)")
        #expect(HandoverLog(paths: scene.box.paths).entries().last?.state == "done")
    }

    @Test func resetWithinHalfAnHourPlansNothing() async throws {
        let scene = try S(resetIn: 25 * 60)
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])

        let plan = try scene.plan()
        #expect(plan.picksUpItself && plan.sessions.isEmpty)
        let result = try await scene.manager.handOver(plan)
        #expect(result.state == .picksUpItself && scene.world.events.isEmpty)
        #expect(result.line.hasSuffix("; work continues there then."))
    }

    @Test func cutSessionsAreHitsWithoutAnswerPlusArmedEntries() throws {
        let scene = try S()
        try scene.session(S.a, title: "Hit")
        try scene.session(S.b, title: "Hit, then answered")
        try scene.session(S.c, title: "Armed")
        try scene.session(S.d, title: "Ran here")
        try scene.armed([S.c])
        try scene.limitHit(S.a)
        try scene.limitHit(S.b, answered: true)
        // Seen running in WORK, then ended.
        for session in [S.a, S.b, S.d] { scene.world.work(session, in: "work") }
        _ = scene.manager.limitTracker.observe(paths: scene.box.paths, windows: scene.manager.windows)
        scene.world.stopWork()

        let plan = try scene.plan()

        #expect(Set(plan.cut.map(\.transcript)) == [S.a, S.c])
        #expect(Set(plan.sessions.map(\.transcript)) == [S.a, S.b, S.c, S.d], "the rest of its work moves too")
        #expect(plan.sessions.allSatisfy { !$0.asCopy })
    }

    @Test func sessionLiveElsewhereIsNotCut() throws {
        let scene = try S()
        try scene.session(S.a, title: "Runs in main")
        try scene.armed([S.a])
        scene.world.start("main")
        scene.world.work(S.a, in: "main")

        let plan = try scene.plan(to: "main")

        #expect(plan.cut.isEmpty, "it runs in (main)")
        #expect(plan.sessions.filter(\.asCopy).isEmpty)
    }

    @Test func resumeOrderEndsOnTopPin() throws {
        let scene = try S()
        for (session, card) in [(S.a, "local_top"), (S.b, "local_free"), (S.c, "local_second")] {
            try scene.box.write(#"{"cliSessionId":"\#(session)","title":"t"}"#, to: scene.mainPair.appending(path: card + ".json"))
        }
        try scene.box.write(
            #"{"preferences":{"epitaxyPrefs":{"dframe-local-slice":{"pinnedOrder":["code:local_top","code:local_second"]}}}}"#,
            to: scene.box.main.appending(path: LocalOnly.configName))

        #expect(scene.manager.showOrder([S.a, S.b, S.c], in: scene.box.main) == [S.b, S.c, S.a])
    }

    @Test func sameEpisodeIsNotHandedOverTwice() throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])
        try HandoverLog(paths: scene.box.paths).save(
            HandoverLog.Entry(
                source: "work", resetsAt: scene.reset.addingTimeInterval(600), destination: "main", startedAt: scene.now.addingTimeInterval(-60),
                state: "done", sessions: 1))

        #expect(throws: HandoverError.alreadyHandedOver("WORK")) { try scene.plan() }
    }

    @Test func flagOffPlansNoSeed() async throws {
        #expect(Seeding.decide(flag: false, optedOut: false) == .flagOff)
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        var plan = try scene.plan()
        #expect(plan.seeding == .seed, "the flag can't be read yet, so Baton seeds and watches")
        plan.seeding = .flagOff
        scene.world.resumes = false

        let result = try await scene.manager.handOver(plan, dwell: 0.1, lastWait: 0.1)

        #expect(scene.entry(S.a, in: "main") == nil, "nothing seeded")
        #expect(scene.world.links == ["link main \(S.a)"], "opened, so it's on screen")
        #expect(result.plan.leftovers.contains(.cannotResume(titles: ["Fix CI"])))
        #expect(result.line.contains("(main) can't resume it by itself — it's open there: “Fix CI”"), "\(result.line)")
    }

    @Test func chosenDestinationAtItsLimitIsRefused() throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])
        var statuses = scene.statuses
        let hit = LimitHit(kind: .fiveHour, at: scene.now.addingTimeInterval(-300), resetsAt: scene.reset, session: "limit")
        statuses[0].usage = Usage(fiveHour: 100, week: 10, sampledAt: scene.now)
        statuses[0].limits = Limits(samples: [UsageSample(at: scene.now.addingTimeInterval(-600), fiveHour: 90, week: 10)], hits: [hit])

        #expect(throws: HandoverError.destinationAtLimit("(main)")) {
            try scene.manager.planHandover(from: "work", to: "main", statuses: statuses, now: scene.now)
        }
    }

    @Test func busySourceKeepsArmedCutSessionsForItsReset() throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.session(S.b, title: "Live")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.b, in: "work")

        let plan = try scene.plan()

        #expect(plan.resumeInSource.map(\.transcript) == [S.a])
        #expect(plan.leftovers.contains(.resumeInSource(count: 1)))
        #expect(HandoverSummary(plan: plan, labels: { $0 }).sessions.first { $0.session == S.a }?.resumes == false)
    }

    @Test func folderRuleKeepsSessionsOutOfTheDestination() throws {
        let scene = try S()
        try scene.session(S.a, title: "Allowed")
        try scene.box.write(
            #"{"sessionId":"local_ruled","cliSessionId":"\#(S.b)","cwd":"/employer/app","title":"Ruled"}"#,
            to: scene.workPair.appending(path: "local_ruled.json"))
        try scene.box.write(#"{"type":"user"}"# + "\n", to: scene.box.paths.claudeProjectsDir.appending(path: "-repo/\(S.b).jsonl"))
        try FolderRules(paths: scene.box.paths).set("/employer", accounts: ["work@example.org"])
        try scene.armed([S.a])
        scene.world.work(S.b, in: "work")
        _ = scene.manager.limitTracker.observe(paths: scene.box.paths, windows: scene.manager.windows)
        scene.world.stopWork()

        let plan = try scene.plan()

        #expect(plan.sessions.map(\.transcript) == [S.a])
        #expect(plan.leftovers.contains(.folderRule(count: 1, folder: "/employer", accounts: ["work@example.org"])))
    }
}

@Suite("Handover run")
struct HandoverRunTests {
    typealias S = HandoverScene

    /// WORK closed at its limit with one armed session; (main) open and busy.
    func busyScene() throws -> (S, HandoverResult) {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        scene.world.start("main")
        scene.world.work(S.c, in: "main")
        return (scene, HandoverResult(plan: try scene.plan(), state: .waiting))
    }

    @Test func busyDestinationIsNeverSentALink() async throws {
        let (scene, planned) = try busyScene()
        #expect(planned.plan.destinationActivity == .busy(working: 1))

        let result = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)

        #expect(result.state == .waiting)
        #expect(scene.world.links.isEmpty && !scene.world.events.contains("quit main"), "running work isn't interrupted")
        #expect(result.line.hasSuffix(" (main) restarts when its current work finishes."), "\(result.line)")
        let entry = try #require(HandoverLog(paths: scene.box.paths).waiting(source: "work"))
        #expect(entry.pending?.seed == [S.card(S.a)] && entry.pending?.show == [S.a])
        #expect(scene.box.exists(scene.mainPair.appending(path: S.card(S.a) + ".json")), "shared now, shown after the restart")
    }

    @Test func busyDestinationRestartsWhenIdleOnTenSecondPoll() async throws {
        let (scene, planned) = try busyScene()
        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        let world = scene.world
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            world.stopWork(in: "main")
        }

        let result = try #require(try await scene.manager.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.3, lastWait: 0.3))

        #expect(result.state == .done && result.resumed == [S.a])
        let events = world.events
        let quit = try #require(events.firstIndex(of: "quit main"))
        let restarted = try #require(events.lastIndex(of: "start main"))
        #expect(quit < restarted && events.last == "link main \(S.a)", "\(events)")
        #expect(scene.entry(S.a, in: "main")?.optedIn == true, "seeded while it was closed")
        #expect(HandoverLog(paths: scene.box.paths).waiting().isEmpty)
    }

    @Test func waitingSurvivesRestartOfBaton() async throws {
        let (scene, planned) = try busyScene()
        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        scene.world.stopWork(in: "main")

        let later = ProfileManager(paths: scene.box.paths)
        scene.world.wire(later)
        #expect(HandoverLog(paths: scene.box.paths).waiting().map(\.source) == ["work"])
        let result = try #require(try await later.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.3, lastWait: 0.3))

        #expect(result.state == .done && result.resumed == [S.a], "the share time came from the log")
    }

    @Test func userQuittingDestinationContinuesAtOnce() async throws {
        let (scene, planned) = try busyScene()
        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        scene.world.close("main")

        let result = try #require(try await scene.manager.finishWaitingHandover(source: "work", poll: 5, dwell: 0.3, lastWait: 0.3))

        #expect(result.state == .done)
        #expect(!scene.world.events.contains("quit main"), "closed by the user; nothing to ask")
    }

    @Test func sourceResetFirstCancelsAndReopensSource() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.start("main")
        scene.world.work(S.c, in: "main")
        let first = try await scene.manager.handOver(try scene.plan(), dwell: 0.1, lastWait: 0.1)
        #expect(first.state == .waiting && first.sourceClosed)
        #expect(scene.entry(S.a, in: "work")?.optedIn == false)

        let reset = scene.reset
        let result = try #require(
            try await scene.manager.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.3, lastWait: 0.3, now: { reset.addingTimeInterval(1) }))

        #expect(result.state == .resetFirst && result.resumed == [S.a])
        #expect(scene.world.links == ["link work \(S.a)"], "(main) got nothing; WORK was reopened and shown the session")
        #expect(scene.entry(S.a, in: "work")?.optedIn == true, "WORK's auto-continue is back on")
        #expect(result.line == "WORK's limit reset before (main) was free, so your work continues in WORK — 1 session resumed.")
        #expect(HandoverLog(paths: scene.box.paths).entries().last?.state == "cancelled")
    }

    @Test func liveArmedSessionKeepsRunningInTheSourceAndItsCopyWaits() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI", extra: #","remoteControlSpawn":{"folder":"/elsewhere"},"bridgeSessionIds":["x"]"#)
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.a, in: "work")

        let result = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)

        #expect(result.state == .done && !result.sourceClosed)
        #expect(result.plan.leftovers.contains(.keepRunningInSource(count: 1)))
        #expect(!result.plan.leftovers.contains { if case .copies = $0 { true } else { false } }, "no copy continues")
        let at = LimitText.time(scene.reset)
        #expect(result.line.contains("1 keeps running in WORK and continues there \(at); its copy is in (main)"), "\(result.line)")
        let copy = try #require(
            try FileManager.default.contentsOfDirectory(atPath: scene.mainPair.path).first { $0 != S.card(S.a) + ".json" && $0.hasPrefix("local_") })
        let card = try #require(ConversationIndex.readCard(scene.mainPair.appending(path: copy)))
        #expect(card["remoteControlSpawn"] == nil && card["bridgeSessionIds"] == nil, "a copy never carries Remote Control's keys")
        #expect(card["title"] as? String == "Fix CI · from WORK", "its history is in (main)")
        let copyID = try #require(card["cliSessionId"] as? String)
        #expect(result.resumed.isEmpty && scene.world.links.isEmpty, "neither the copy nor the original is shown in (main)")
        #expect(scene.entry(copyID, in: "main") == nil, "the copy isn't seeded")
        #expect(scene.entry(S.a, in: "work")?.optedIn == true, "WORK continues it at its reset")
        #expect(scene.manager.autoResume.pending().isEmpty, "and its entry isn't turned off when WORK closes")
    }

    /// No copy of a session still running in the source with its auto-continue on is ever seeded or shown, whether
    /// the destination opens at once or after a wait.
    @Test(arguments: [false, true]) func copyOfLiveArmedSessionIsNeverSeeded(busyDestination: Bool) async throws {
        let scene = try S()
        try scene.session(S.a, title: "Running")
        try scene.session(S.b, title: "Armed, closed")
        try scene.session(S.c, title: "Running, not armed")
        try scene.limitHit(S.c)
        try scene.armed([S.a, S.b])
        scene.world.start("work")
        scene.world.work(S.a, in: "work")
        scene.world.work(S.c, in: "work")
        if busyDestination {
            scene.world.start("main")
            scene.world.work(S.d, in: "main")
        }

        var result = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)
        if busyDestination {
            #expect(result.state == .waiting)
            scene.world.stopWork(in: "main")
            result = try #require(try await scene.manager.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.3, lastWait: 0.3))
        }

        #expect(result.state == .done)
        let copies = scene.manager.cardsBySession(in: scene.box.main).filter { $0.key != S.d }
        let copyOfA = try #require(
            copies.keys.first { key in
                (ConversationIndex.readCard(scene.mainPair.appending(path: copies[key]! + ".json"))?["title"] as? String) == "Running · from WORK"
            })
        let copyOfC = try #require(
            copies.keys.first { key in
                (ConversationIndex.readCard(scene.mainPair.appending(path: copies[key]! + ".json"))?["title"] as? String)
                    == "Running, not armed · from WORK"
            })
        #expect(scene.entry(copyOfA, in: "main") == nil, "the copy of the running armed session isn't seeded")
        #expect(!scene.world.links.contains { $0.hasSuffix(copyOfA) } && !result.resumed.contains(copyOfA))
        #expect(result.resumed.contains(copyOfC), "the copy of a running session nothing continues in WORK resumes")
        #expect(!result.resumed.contains(S.b) && scene.entry(S.b, in: "main") == nil, "WORK continues the armed one at its reset")
        #expect(scene.entry(S.a, in: "work")?.optedIn == true && scene.entry(S.b, in: "work")?.optedIn == true)
        #expect(result.plan.leftovers.contains(.keepRunningInSource(count: 1)) && result.plan.leftovers.contains(.copies(count: 1)))
    }

    @Test func openSourceIsQuitOnceNothingLiveThenPendingApplied() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.limitHit(S.a)
        scene.world.start("work")
        scene.world.work(S.a, in: "work")

        let result = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)

        #expect(result.state == .done && !result.sourceClosed)
        #expect(result.plan.leftovers.contains(.copies(count: 1)))
        #expect(result.line.contains("WORK is at its limit until") && !result.line.contains("was closed"))
        let copy = try #require(
            try FileManager.default.contentsOfDirectory(atPath: scene.mainPair.path).first { $0 != S.card(S.a) + ".json" && $0.hasPrefix("local_") })
        let copyID = try #require(ConversationIndex.readCard(scene.mainPair.appending(path: copy))?["cliSessionId"] as? String)
        #expect(copyID != S.a && result.resumed == [copyID], "the copy resumes, not the session still open in WORK")

        #expect(HandoverLog(paths: scene.box.paths).unfinished(source: "work").count == 1, "the source still has to be closed")
        let world = scene.world
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            world.stopWork(in: "work")
        }
        let closed = try await scene.manager.watchHandoverSource("work", poll: 0.1)

        #expect(closed && scene.world.events.contains("quit work"))
        #expect(HandoverLog(paths: scene.box.paths).entries().last?.sourceClosed == true)
        #expect(HandoverLog(paths: scene.box.paths).unfinished(source: "work").isEmpty)
    }

    @Test func failedCopyStaysInTheSourceAndIsNamed() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.a, in: "work")
        let plan = try scene.plan()
        try FileManager.default.removeItem(at: scene.workPair.appending(path: S.card(S.a) + ".json"))

        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)

        #expect(result.resumed.isEmpty && !scene.world.links.contains { $0.hasSuffix(S.a) }, "the original, still open in WORK, isn't shown")
        #expect(result.plan.leftovers.contains(.notMoved(titles: ["Fix CI"])))
        #expect(!result.plan.leftovers.contains { if case .copies = $0 { true } else { false } })
        #expect(scene.manager.autoResume.pending().isEmpty, "its auto-continue in WORK stays on")
        #expect(HandoverLog(paths: scene.box.paths).entries().last?.pending == nil)
    }

    @Test func sessionOpenOutsideAnyWindowStaysACopyAfterTheSourceQuits() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.manager.liveSessionIDs = { [S.a] }

        let result = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)

        #expect(result.sourceClosed && result.plan.leftovers.contains(.copies(count: 1)))
        #expect(!result.resumed.isEmpty && !result.resumed.contains(S.a), "\(result.resumed)")
    }

    @Test func busySourceContinuesItsArmedSessionsItself() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.session(S.b, title: "Live")
        try scene.armed([S.a])
        scene.world.start("work")
        scene.world.work(S.b, in: "work")

        let result = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)

        #expect(result.state == .done && !result.sourceClosed)
        #expect(!scene.world.links.contains("link main \(S.a)"), "WORK resumes it at its reset, so (main) doesn't too")
        #expect(scene.entry(S.a, in: "main") == nil, "not seeded in (main)")
        #expect(scene.entry(S.a, in: "work")?.optedIn == true, "left on in WORK")
        #expect(scene.manager.autoResume.pending().isEmpty, "and not turned off when WORK closes")
        #expect(!result.resumed.contains(S.a))
        #expect(result.line.contains("1 continues in WORK when its limit resets, as Claude Code still works there"), "\(result.line)")
    }

    @Test func logIsReadyBeforeTheDestinationOpens() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        let paths = scene.box.paths
        let seen = Seen()
        let world = scene.world
        scene.manager.appLauncher = { app, _, links in
            seen.entry = HandoverLog(paths: paths).entries().last
            world.start(world.window(of: app))
            world.handed(app, links)
        }

        _ = try await scene.manager.handOver(try scene.plan(), dwell: 0.3, lastWait: 0.3)

        let entry = try #require(seen.entry)
        #expect(entry.state == "waiting" && entry.sourceClosed, "a Ctrl-C from here on is finished from the log")
        #expect(entry.pending?.show == [S.a] && entry.pending?.seed == [S.card(S.a)] && entry.pending?.lengths?[S.a] != nil)
    }

    @Test func handoverStoppedWhileStartingStartsOver() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.armed([S.a])
        let log = HandoverLog(paths: scene.box.paths)
        let started = Date(timeIntervalSince1970: (scene.now.timeIntervalSince1970 - 30).rounded(.down))
        try log.save(
            HandoverLog.Entry(
                source: "work", resetsAt: scene.reset, destination: "main", startedAt: started, state: "starting", sessions: 1, cards: [S.card(S.a)]))
        let armed = try #require(scene.entry(S.a, in: "work"))
        _ = try scene.manager.autoResume.turnOff(armed, window: "work", account: Sandbox.accountB)
        #expect(throws: HandoverError.alreadyHandedOver("WORK")) { try scene.plan() }
        #expect(log.unfinished(source: "work").map(\.state) == ["starting"])

        #expect(try scene.manager.restartStoppedHandover(source: "work") == "main")

        #expect(log.entries().map(\.state) == ["restarted"] && log.unfinished(source: "work").isEmpty)
        #expect(scene.entry(S.a, in: "work")?.optedIn == true, "its turn-off is put back, so it is cut again")
        let plan = try scene.plan()
        #expect(plan.cut.map(\.transcript) == [S.a])
        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)
        #expect(result.state == .done && result.resumed == [S.a])
        #expect(try scene.manager.restartStoppedHandover(source: "work") == nil)
    }

    @Test func handoverStoppedAfterItsCopiesUsesThemAgain() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        try scene.limitHit(S.a)
        try scene.armed([])
        scene.world.start("work")
        scene.world.work(S.a, in: "work")
        let log = HandoverLog(paths: scene.box.paths)
        // A handover that made its copy while WORK was busy, then stopped.
        let copy = try scene.manager.makeHandoverCopy(try #require(scene.session(try scene.plan(), S.a)), from: "work", into: "main")
        let started = Date(timeIntervalSince1970: (scene.now.timeIntervalSince1970 - 30).rounded(.down))
        try log.save(
            HandoverLog.Entry(
                source: "work", resetsAt: scene.reset, destination: "main", startedAt: started, state: "starting", sessions: 1,
                cards: [S.card(S.a)], copies: [S.card(S.a): copy.transcript]))
        let before = scene.manager.cardsBySession(in: scene.box.main)
        #expect(before.count == 1 && before[copy.transcript] == copy.card)
        // WORK finished its work meanwhile and was closed, so the session isn't live any more.
        scene.world.close("work")

        #expect(try scene.manager.restartStoppedHandover(source: "work") == "main")
        let result = try await scene.manager.handOver(try scene.plan(to: "main"), dwell: 0.3, lastWait: 0.3)

        #expect(result.state == .done && result.resumed == [copy.transcript], "the copy made before the stop resumes")
        #expect(
            scene.manager.cardsBySession(in: scene.box.main).filter { $0.key != S.a } == before,
            "one copy in (main), the one made before the stop; the original's card is only shared there")
        #expect(!scene.world.links.contains { $0.hasSuffix(S.a) })
        #expect(log.entries().last?.copies == [S.card(S.a): copy.transcript])
    }

    @Test func sessionThatContinuedMeanwhileIsNotResumedAgain() async throws {
        let (scene, planned) = try busyScene()
        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        let transcript = scene.box.paths.claudeProjectsDir.appending(path: "-repo/\(S.a).jsonl")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"user","message":"go on"}"# + "\n").utf8))
        try handle.close()
        scene.world.stopWork(in: "main")

        let result = try #require(try await scene.manager.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.3, lastWait: 0.3))

        #expect(result.state == .done && result.resumed == [S.a])
        #expect(scene.world.links.isEmpty, "not shown again: \(scene.world.events)")
        #expect(scene.entry(S.a, in: "main") == nil, "not seeded again")
    }

    @Test func anotherBatonAtWorkIsLeftAlone() async throws {
        let (scene, planned) = try busyScene()
        let log = HandoverLog(paths: scene.box.paths)
        let held = try #require(try log.working(source: "work"))
        #expect(log.inProgress(source: "work"))

        await #expect(throws: HandoverError.inProgress("WORK")) {
            _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        }
        #expect(log.entries().isEmpty)
        held.release()
        #expect(!log.inProgress(source: "work"))

        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        let again = try #require(try log.working(source: "work"))
        await #expect(throws: HandoverError.inProgress("WORK")) {
            _ = try await scene.manager.finishWaitingHandover(source: "work", poll: 0.1, dwell: 0.1, lastWait: 0.1)
        }
        again.release()
        #expect(log.waiting(source: "work") != nil, "still waiting for (main)")
    }

    @Test func secondHandoverOfTheSameEpisodeIsRefused() async throws {
        let (scene, planned) = try busyScene()
        _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)

        await #expect(throws: HandoverError.alreadyHandedOver("WORK")) {
            _ = try await scene.manager.handOver(planned.plan, dwell: 0.1, lastWait: 0.1)
        }
        #expect(HandoverLog(paths: scene.box.paths).entries().count == 1)
    }
}

@Suite("Handover text")
struct HandoverTextTests {
    let utc = TimeZone(identifier: "UTC")!
    let gb = Locale(identifier: "en_GB")
    /// Mon 2026-09-28 18:00 UTC.
    let now = Date(timeIntervalSince1970: 1_790_618_400)
    var reset: Date { now.addingTimeInterval(70 * 60) }

    func labels(_ id: String) -> String { ["robin": "ROBIN", "pay": "PAY"][id] ?? id }

    func result(
        _ state: HandoverResult.State, leftovers: [HandoverLeftover] = [], resumed: Int = 0, closed: Bool = true, failure: String? = nil
    ) -> HandoverResult {
        let plan = HandoverPlan(
            source: "robin", destination: "pay", resetsAt: reset, sessions: [], sourceActivity: .closed, destinationActivity: .closed,
            seeding: .seed, leftovers: leftovers, picksUpItself: state == .picksUpItself)
        var result = HandoverResult(plan: plan, state: state, sourceClosed: closed)
        result.resumed = (0..<resumed).map { "s\($0)" }
        result.failure = failure
        return result
    }

    func line(_ result: HandoverResult) -> String { HandoverText.line(result, labels: labels, now: now, timeZone: utc, locale: gb) }

    @Test func everyLine() {
        #expect(line(result(.done, resumed: 9)) == "ROBIN is at its limit until 19:10 and was closed. Your work continues in PAY — 9 sessions resumed.")
        #expect(line(result(.done)) == "ROBIN is at its limit until 19:10 and was closed. Your work continues in PAY.")
        #expect(line(result(.done, resumed: 1, closed: false)) == "ROBIN is at its limit until 19:10. Your work continues in PAY — 1 session resumed.")
        #expect(line(result(.waiting)) == "ROBIN is at its limit until 19:10 and was closed. PAY restarts when its current work finishes.")
        #expect(line(result(.resetFirst, resumed: 9)) == "ROBIN's limit reset before PAY was free, so your work continues in ROBIN — 9 sessions resumed.")
        #expect(line(result(.picksUpItself)) == "ROBIN is at its limit until 19:10; work continues there then.")
        #expect(
            line(result(.failed, failure: "The app couldn't start."))
                == "ROBIN is at its limit until 19:10 and was closed. PAY didn't open: The app couldn't start. Your sessions are there when you open it.")
    }

    @Test func sessionsKeptRunningInTheSourceNameTheReset() {
        #expect(
            line(result(.done, leftovers: [.keepRunningInSource(count: 2)], resumed: 3, closed: false))
                == "ROBIN is at its limit until 19:10. Your work continues in PAY — 3 sessions resumed; "
                + "2 keep running in ROBIN and continue there at 19:10; their copies are in PAY.")
        #expect(
            HandoverText.clause(.keepRunningInSource(count: 1), source: "ROBIN", destination: "PAY", at: "at 19:10")
                == "1 keeps running in ROBIN and continues there at 19:10; its copy is in PAY")
        #expect(
            HandoverText.clause(.keepRunningInSource(count: 1), source: "ROBIN", destination: "PAY")
                == "1 keeps running in ROBIN and continues there when its limit resets; its copy is in PAY")
    }

    @Test func everyClause() {
        let clauses: [(HandoverLeftover, String)] = [
            (
                .folderRule(count: 19, folder: "/Users/me/Sources/Assistant", accounts: ["robin@example.org", "yuri@example.org"]),
                "19 stay in ROBIN: a folder rule keeps Assistant for robin@, yuri@"
            ),
            (.remoteControl(count: 3), "3 stay in ROBIN: Remote Control reaches them there"),
            (.copies(count: 3), "3 still open in ROBIN continue as copies"),
            (.notResumed(titles: ["Fix CI", "Docs"]), "2 didn't resume by themselves — they're open in PAY: “Fix CI”, “Docs”"),
            (.cannotResume(titles: ["Fix CI", "Docs", "Tests"]), "PAY can't resume them by itself — they're open there: “Fix CI”, “Docs” and 1 more"),
            (.ungrouped(count: 4, group: "X"), "group “X” is new to PAY, so 4 are ungrouped there"),
            (.layoutNotCarried("the store is in use"), "their pins and groups couldn't be written (the store is in use)"),
            (.notMoved(titles: ["Fix CI"]), "1 couldn't be brought to PAY and stays in ROBIN: “Fix CI”"),
            (.copiesStay(count: 2), "the 2 copies made in PAY stay there"),
            (.resumeInSource(count: 2), "2 continue in ROBIN when its limit resets, as Claude Code still works there"),
        ]
        for (leftover, text) in clauses {
            #expect(HandoverText.clause(leftover, source: "ROBIN", destination: "PAY") == text)
            #expect(line(result(.done, leftovers: [leftover], resumed: 2)).hasSuffix("2 sessions resumed; \(text)."))
            #expect(result(.done, leftovers: [leftover]).plan.leftovers.count == 1)
        }
        #expect(HandoverText.clause(.waitingForDestination, source: "ROBIN", destination: "PAY") == nil)
    }

    @Test func atMostTwoClausesAndTwoTitles() {
        let all: [HandoverLeftover] = [.remoteControl(count: 3), .copies(count: 1), .ungrouped(count: 4, group: "X")]
        #expect(
            line(result(.done, leftovers: all))
                == "ROBIN is at its limit until 19:10 and was closed. Your work continues in PAY; 3 stay in ROBIN: Remote Control reaches them there; "
                + "1 still open in ROBIN continues as a copy; and more — baton doctor.")
        #expect(HandoverText.names(["a", "b", "c", "d"]) == "“a”, “b” and 2 more")
        #expect(HandoverText.names(["a", "b"]) == "“a”, “b”")
    }

    @Test func noLineAsksToType() {
        let leftovers: [HandoverLeftover] = [
            .folderRule(count: 1, folder: "/a", accounts: ["a@example.org"]), .remoteControl(count: 1), .copies(count: 2),
            .notResumed(titles: ["a"]), .cannotResume(titles: ["b"]), .ungrouped(count: 1, group: "g"), .layoutNotCarried("r"), .coworkStays(count: 1),
            .notMoved(titles: ["c"]), .copiesStay(count: 1), .resumeInSource(count: 1),
        ]
        for state in [HandoverResult.State.done, .waiting, .picksUpItself, .resetFirst, .failed] {
            for leftover in leftovers {
                #expect(!line(result(state, leftovers: [leftover], failure: "x")).lowercased().contains("type"))
            }
        }
        #expect(HandoverText.isWarning(result(.done, leftovers: [.copies(count: 1)])))
        #expect(!HandoverText.isWarning(result(.done)))
    }
}

@Suite("baton handover")
struct HandoverCommandTests {
    @Test func takesItsOptionsAndNoOthers() {
        #expect(CLIArguments.problem(in: ["handover"]) == nil)
        #expect(CLIArguments.problem(in: ["handover", "--from", "work", "--to", "main", "--dry-run", "--json"]) == nil)
        #expect(CLIArguments.problem(in: ["handover", "--dryrun"]) != nil)
        #expect(CLIArguments.problem(in: ["handover", "work"]) != nil, "the window goes after --from")
    }
}

/// What a hook saw, read after it ran.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HandoverLog.Entry?
    var entry: HandoverLog.Entry? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
