import Foundation

/// Lets a profile window receive its own sign-in.
///
/// Claude Desktop's Google sign-in finishes in the browser and comes back through a `claude://` link.
/// macOS delivers that link to the registered copy of Claude, which is normally the main app, and the main
/// app ignores a sign-in it didn't start. While a profile signs in, only that profile's app copy stays
/// registered with Launch Services, so the link reaches the window that asked for it. Afterwards the main
/// app is registered again. The link itself is never read: it goes straight from macOS to Claude.
public struct SignInRouting: Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var profileID: String
        public var startedAt: Date
    }

    /// Longest time the main app stays unregistered if a sign-in is abandoned.
    public static let timeout: TimeInterval = 15 * 60
    /// Time a profile window gets to start before an unfinished sign-in is dropped.
    public static let launchGrace: TimeInterval = 60

    public let paths: Paths
    /// Registers (`true`) or unregisters (`false`) an app bundle with Launch Services; returns `lsregister`'s exit status.
    let register: @Sendable (URL, Bool) -> Int32
    /// Whether the main app is Claude as Anthropic signs it (`ClaudeSource.isSignedByAnthropic` unless a test
    /// substitutes it: a sandbox's Claude.app isn't signed).
    let isSignedByAnthropic: @Sendable (URL) -> Bool

    public init(paths: Paths) {
        self.init(
            paths: paths,
            registerReporting: { app, on in
                ProfileManager.run(
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    [on ? "-f" : "-u", app.path])
            }, isSignedByAnthropic: ClaudeSource.isSignedByAnthropic)
    }

    init(
        paths: Paths, isSignedByAnthropic: @escaping @Sendable (URL) -> Bool = ClaudeSource.isSignedByAnthropic,
        register: @escaping @Sendable (URL, Bool) -> Void
    ) {
        self.init(
            paths: paths,
            registerReporting: {
                register($0, $1); return 0
            }, isSignedByAnthropic: isSignedByAnthropic)
    }

    init(
        paths: Paths, registerReporting: @escaping @Sendable (URL, Bool) -> Int32,
        isSignedByAnthropic: @escaping @Sendable (URL) -> Bool = ClaudeSource.isSignedByAnthropic
    ) {
        self.paths = paths
        self.register = registerReporting
        self.isSignedByAnthropic = isSignedByAnthropic
    }

    var stateFile: URL { paths.stateDir.appending(path: "sign-in.json") }

    public var state: State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Sends `claude://` links to `profileID`'s app copy until `end()`.
    public func begin(profileID: String, allProfileIDs: [String], now: Date = Date()) throws {
        // Best-effort: a failure here still lets sign-in continue, and `restoreMainIfIdle`/`end` report and
        // recover from a stuck registration afterwards.
        _ = register(paths.claudeApp, false)
        for id in allProfileIDs where id != profileID {
            _ = register(paths.engine(for: id), false)
        }
        _ = register(paths.engine(for: profileID), true)
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(State(profileID: profileID, startedAt: now)).write(to: stateFile, options: .atomic)
    }

    /// Gives `claude://` links back to the main app. App copies are unregistered so they never outrank it.
    /// A main app Anthropic didn't sign is never registered, as at start-up: nothing is registered or unregistered then,
    /// and the sign-in is over all the same, so this is said once in the log rather than at every look at the windows.
    /// - Returns: the registrations that failed; unregistering an app copy that isn't there doesn't count.
    @discardableResult
    public func end(allProfileIDs: [String]) -> [SignInRoutingError] {
        guard isSignedByAnthropic(paths.claudeApp) else {
            Log.notice("sign-in", "Left claude:// links where they are: \(paths.claudeApp.lastPathComponent) isn't signed by Anthropic")
            try? FileManager.default.removeItem(at: stateFile)
            return []
        }
        var failures: [SignInRoutingError] = []
        for id in allProfileIDs {
            let engine = paths.engine(for: id)
            let status = register(engine, false)
            if status != 0 && FileManager.default.fileExists(atPath: engine.path) {
                failures.append(.lsregisterFailed(app: engine, status: status))
            }
        }
        let status = register(paths.claudeApp, true)
        if status != 0 { failures.append(.lsregisterFailed(app: paths.claudeApp, status: status)) }
        try? FileManager.default.removeItem(at: stateFile)
        return failures
    }

    /// Run at every start of the app and the CLI. With no sign-in in progress, or one abandoned for longer than
    /// `timeout`, the main app is registered with Launch Services again, so `claude://` links reach it even if an
    /// earlier run stopped halfway.
    /// - Returns: whether it registered the main app; `false` while a sign-in is in progress.
    /// - Throws: `SignInRoutingError.lsregisterFailed` when `lsregister` exits with an error.
    @discardableResult
    public func restoreMainIfIdle(allProfileIDs: [String], now: Date = Date()) throws -> Bool {
        let recorded = FileManager.default.fileExists(atPath: stateFile.path)
        if let state, now.timeIntervalSince(state.startedAt) <= Self.timeout { return false }
        if recorded {
            if let failure = end(allProfileIDs: allProfileIDs).first { throw failure }
            return true
        }
        let status = register(paths.claudeApp, true)
        guard status == 0 else { throw SignInRoutingError.lsregisterFailed(app: paths.claudeApp, status: status) }
        return true
    }

    /// Whether a sign-in in progress is over: done, abandoned, or its window never started.
    public static func isFinished(_ state: State, signedIn: Bool, running: Bool, profileExists: Bool, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(state.startedAt)
        return !profileExists || signedIn || elapsed > timeout || (!running && elapsed > launchGrace)
    }
}

public enum SignInRoutingError: LocalizedError, Equatable, Sendable {
    case lsregisterFailed(app: URL, status: Int32)

    public var errorDescription: String? {
        switch self {
        case let .lsregisterFailed(app, status):
            "Couldn't update Launch Services for \(app.lastPathComponent) (lsregister exited with \(status)). "
                + "Sign-in links may open the wrong Claude window; open Claude once from Applications to fix it."
        }
    }
}
