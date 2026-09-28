import Foundation
import os
import Testing
@testable import ClaudeProfilesKit

@Suite("Window status, errors and logs")
struct WindowStatusTests {
    private func status(running: Bool, live: Int) -> WindowStatus {
        WindowStatus(id: "work", label: "WORK", isMain: false, isRunning: running, account: "a@example.com",
                     scope: "account aaaaaaaa · 1 organization", scopeSource: "config.json", liveSessions: live)
    }

    @Test func restartDisabledWithLiveSession() {
        // Window 100 runs a helper 200 that runs Claude Code 300; window 400 runs nothing.
        let parents: [pid_t: pid_t] = [300: 200, 200: 100, 100: 1, 400: 1, 500: 1]
        let parent = { (pid: pid_t) in parents[pid] }
        #expect(WindowStatus.liveSessionCount(windowPIDs: [100], claudePIDs: [300, 500], parent: parent) == 1)
        #expect(WindowStatus.liveSessionCount(windowPIDs: [400], claudePIDs: [300, 500], parent: parent) == 0)
        #expect(WindowStatus.liveSessionCount(windowPIDs: [], claudePIDs: [300], parent: parent) == 0)
        // A loop in a broken process table ends instead of hanging.
        #expect(WindowStatus.liveSessionCount(windowPIDs: [9], claudePIDs: [7], parent: { $0 == 7 ? 8 : 7 }) == 0)

        let busy = status(running: true, live: 1)
        #expect(!busy.canRestart)
        #expect(busy.restartTitle == "Restart WORK to apply")
        #expect(busy.restartHelp.contains("1 Claude Code session"))
        #expect(status(running: true, live: 0).canRestart)
        #expect(!status(running: false, live: 0).canRestart, "a closed window applies changes when it next opens")
    }

    @Test func collectsScopeSkipReasonsAndPendingChanges() throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: "w@example.com", color: "#123456")])
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        try box.pair(box.main, account: Sandbox.accountA)
        let manager = ProfileManager(paths: box.paths)
        let diagnostics = try Diagnostics.inspect(paths: box.paths)
        let windows = WindowStatus.collect(manager: manager, diagnostics: diagnostics,
                                           localOnly: ["work": true], pending: ["work": ["Local only turns on"]])
        #expect(windows.map(\.id) == ["main", "work"])
        #expect(windows[0].scope == "account aaaaaaaa · 1 organization")
        #expect(windows[0].scopeSource == "config.json (lastKnownAccountUuid)")
        #expect(windows[1].scope == nil)
        #expect(windows[1].skipReasons.contains { $0.contains("sign in") })
        #expect(windows[1].localOnly == true)
        #expect(windows[1].pendingChanges == ["Local only turns on"])
        #expect(windows.allSatisfy { !$0.canRestart })
    }

    @Test func alertTitlesNameTheErrorType() {
        #expect(WindowStatus.alertTitle(for: ProfileError.claudeNotInstalled("/Applications/Claude.app")) == "Claude Desktop isn’t installed")
        #expect(WindowStatus.alertTitle(for: ProfileError.duplicateLabel("WORK")) == "Check the subscription details")
        #expect(WindowStatus.alertTitle(for: ProfileError.notAllowed(folders: [], accounts: [], label: "W", email: nil)) == "A folder rule doesn’t allow this")
        #expect(WindowStatus.alertTitle(for: ProfileError.windowDidNotAppear(label: "W", links: 1)) == "The window didn’t appear")
        #expect(WindowStatus.alertTitle(for: CocoaError(.fileReadNoPermission)) == "Couldn’t read or write a file")
        #expect(WindowStatus.alertTitle(for: URLError(.badURL)) == "Something went wrong")
        #expect(WindowStatus.alertTitle(for: WindowStatus.RestartError.liveSessions(label: "WORK", count: 2)) == "Claude Code is still working")
    }

    @Test func reportIncludesRedactedLogTail() throws {
        let lines = (0..<250).map { "sync \($0): wrote a card for jane@example.com in /Users/jane/src/app-\($0)" }
        let facts = FeedbackReport.Facts(build: BuildInfo(version: "1.0.0", commit: "abc"), macOS: "15.1", architecture: "arm64",
                                         claudeVersion: nil, windows: [], diagnostics: [], lastSync: nil, lastSyncDate: nil,
                                         errors: [], log: lines, home: "/Users/jane", user: "jane", profiles: [])
        let markdown = FeedbackReport(facts: facts).markdown
        #expect(markdown.contains("### Log (last 200 entries)"))
        #expect(markdown.contains("sync 249: wrote a card for <email-1> in <folder>"))
        #expect(markdown.contains("sync 50: "))
        #expect(!markdown.contains("sync 49: "))
        #expect(!markdown.contains("jane"))

        // The tail comes from this app's own subsystem in the unified log.
        let marker = "report-tail-\(UUID().uuidString.prefix(8))"
        Log.logger("tests").notice("\(marker, privacy: .public) for jane@example.com")
        let tail = LogTail.read(limit: 50)
        #expect(tail.count <= 50)
        #expect(tail.contains { $0.contains(marker) && $0.contains("[tests]") }, "\(tail.suffix(5))")
    }
}
