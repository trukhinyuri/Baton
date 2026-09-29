#if DEBUG
    import Foundation

    /// Debug builds only: runs `baton` against a sandbox home folder with stand-in Claude windows, for
    /// `scripts/e2e-handover.sh`. `BATON_SANDBOX_HOME` names the home folder; `BATON_FAKE_LAUNCH` names the file the
    /// stand-in windows log to (`<home>/fake-launch.log` when unset). A release build reads neither variable.
    public struct SandboxRun: Sendable {
        public static let homeVariable = "BATON_SANDBOX_HOME"
        public static let launchVariable = "BATON_FAKE_LAUNCH"

        public let home: URL
        public let launchLog: URL

        /// `nil` unless `BATON_SANDBOX_HOME` names a folder.
        public init?(environment: [String: String]) {
            guard let home = environment[Self.homeVariable], !home.isEmpty else { return nil }
            self.home = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            launchLog =
                environment[Self.launchVariable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? self.home.appending(path: "fake-launch.log")
        }

        /// Baton's folders under the sandbox home, with the Claude app there, never this Mac's.
        public var paths: Paths { Paths(home: home, claudeApp: home.appending(path: "Applications/Claude.app", directoryHint: .isDirectory)) }

        /// A manager whose windows, Claude Code processes and links are the stand-ins: nothing on this Mac is started,
        /// quit or registered.
        public func manager(cliPath: URL?) -> ProfileManager {
            let manager = ProfileManager(paths: paths, cliPath: cliPath)
            StandInWindows(log: launchLog, paths: paths).wire(manager)
            return manager
        }
    }

    /// Stand-in Claude windows. What runs is kept in `<log>.state.json`, so one `baton` run sees what the one before
    /// started; every start, quit and link is appended to the log as a line (`start bravo`, `quit atlas`,
    /// `link bravo <session>`). A link makes its session continue: its transcript grows by one line and a Claude Code
    /// process of it runs in that window.
    public final class StandInWindows: @unchecked Sendable {
        public struct State: Codable, Equatable, Sendable {
            public struct Live: Codable, Equatable, Sendable {
                public var session: String
                public var window: String
                public var since: Date
                /// Holds its session open without working, as Claude Desktop keeps a process for every session it opened.
                public var idle: Bool?

                public init(session: String, window: String, since: Date = Date(), idle: Bool = false) {
                    self.session = session.lowercased(); self.window = window; self.since = since; self.idle = idle ? true : nil
                }
            }
            /// Window ids (`main` or a profile id) that run, with when each started.
            public var running: [String: Date] = [:]
            public var live: [Live] = []

            public init(running: [String: Date] = [:], live: [Live] = []) { self.running = running; self.live = live }
        }

        public static let version = "2.1.284"

        private let lock = NSLock()
        public let log: URL
        let paths: Paths
        private var state: State

        public var stateFile: URL { log.appendingPathExtension("state.json") }

        public init(log: URL, paths: Paths) {
            self.log = log
            self.paths = paths
            let file = log.appendingPathExtension("state.json")
            state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.fake.decode(State.self, from: $0) } ?? State()
        }

        /// Writes the stand-ins' state before a run: which windows run and which sessions are live where.
        public static func prepare(_ state: State, log: URL) throws {
            try JSONEncoder.fake.encode(state).write(to: log.appendingPathExtension("state.json"), options: .atomic)
        }

        public var current: State { lock.withLock { state } }

        /// The lines logged so far.
        public var events: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        var profiles: [Profile] { (try? ProfileRegistry(paths: paths).load()) ?? [] }

        func dataDir(_ window: String) -> URL { window == "main" ? paths.mainDataDir : paths.dataDir(for: window) }
        func app(_ window: String) -> URL { window == "main" ? paths.claudeApp : paths.engine(for: window) }
        func executable(_ window: String) -> String {
            dataDir(window).appending(path: "claude-code/\(Self.version)/claude.app/Contents/MacOS/claude").path
        }

        /// The window whose app `url` is.
        func window(of url: URL, profiles: [Profile]) -> String? {
            let path = url.standardizedFileURL.path
            if path == paths.claudeApp.standardizedFileURL.path { return "main" }
            return profiles.first { paths.engine(for: $0.id).standardizedFileURL.path == path }?.id
        }

        var running: [RunningClaude] {
            lock.withLock {
                state.running.sorted { $0.key < $1.key }.enumerated().map { index, entry in
                    let arguments =
                        [app(entry.key).appending(path: "Contents/MacOS/Claude").path]
                        + (entry.key == "main" ? [] : ["--user-data-dir=\(dataDir(entry.key).path)"])
                    return RunningClaude(
                        bundlePath: app(entry.key).standardizedFileURL.path, arguments: arguments, pid: pid_t(500 + index), launchDate: entry.value)
                }
            }
        }

        var processes: [LimitTracker.LiveProcess] {
            lock.withLock {
                state.live.enumerated().map { index, live in
                    LimitTracker.LiveProcess(
                        pid: pid_t(2000 + index), session: live.session, startedAt: live.since, version: Self.version, cwd: nil, hostSessionID: nil,
                        executable: executable(live.window))
                }
            }
        }

        private func change(_ note: String?, _ body: (inout State) -> Void) {
            lock.withLock {
                body(&state)
                try? JSONEncoder.fake.encode(state).write(to: stateFile, options: .atomic)
                guard let note else { return }
                let line = Data((note + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: log) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                    try? handle.close()
                } else {
                    try? line.write(to: log)
                }
            }
        }

        func start(_ window: String) { change("start \(window)") { $0.running[window] = Date() } }

        /// Claude Code work in `window` ends, as when its turns finish and their processes quit.
        func stopWork(in window: String) { change(nil) { $0.live.removeAll { $0.window == window } } }

        func quit(_ copy: RunningClaude, profiles: [Profile], forced: Bool) {
            guard let path = copy.bundlePath, let window = window(of: URL(fileURLWithPath: path), profiles: profiles) else { return }
            change("\(forced ? "force-quit" : "quit") \(window)") { state in
                state.running[window] = nil
                state.live.removeAll { $0.window == window }
            }
        }

        func deliver(_ links: [URL], to window: String) {
            for link in links {
                let session = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "session" }?.value ?? ""
                change("link \(window) \(session)") { state in
                    guard !session.isEmpty else { return }
                    state.live.append(State.Live(session: session, window: window))
                }
                guard !session.isEmpty, let transcript = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)[session.lowercased()],
                    let handle = try? FileHandle(forWritingTo: transcript)
                else { continue }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((#"{"type":"user","sessionId":"\#(session)","message":"continue"}"# + "\n").utf8))
                try? handle.close()
            }
        }

        /// Replaces every hook through which `manager` would look at, start, quit or register a Claude on this Mac.
        public func wire(_ manager: ProfileManager) {
            manager.signatureCheck = { _ in true }
            manager.launcherRegistrar = { _ in }
            manager.appBuilder = { _ in }
            manager.runningCopies = { self.running }
            manager.isProfileRunning = { id in self.current.running[id] != nil }
            manager.windowShown = { _ in true }
            manager.processTree = { ProcessTree(claudes: [], parent: { _ in nil }) }
            manager.liveSessionIDs = { Set(self.current.live.map(\.session)) }
            manager.processWorking = { pid, _ in
                let live = self.current.live, index = Int(pid) - 2000
                return !(live.indices.contains(index) && live[index].idle == true)
            }
            manager.limitTracker.liveProcesses = { _ in self.processes }
            manager.quitRequester = { self.quit($0, profiles: self.profiles, forced: false) }
            manager.forceQuitter = { self.quit($0, profiles: self.profiles, forced: true) }
            manager.appLauncher = { app, _, links in
                guard let window = self.window(of: app, profiles: self.profiles) else { return }
                self.start(window)
                self.deliver(links, to: window)
            }
            manager.appActivator = { app, links in
                guard let window = self.window(of: app, profiles: self.profiles) else { return }
                self.deliver(links, to: window)
            }
        }
    }

    extension JSONEncoder {
        fileprivate static var fake: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }
    }

    extension JSONDecoder {
        fileprivate static var fake: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }
#endif
