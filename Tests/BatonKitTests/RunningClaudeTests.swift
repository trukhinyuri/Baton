import Darwin
import Foundation
import Testing

@testable import BatonKit

@Suite("Telling which account a running Claude shows")
struct RunningClaudeTests {
    let main = URL(fileURLWithPath: "/Users/me/Library/Application Support/Claude", isDirectory: true)
    let work = URL(fileURLWithPath: "/Users/me/Library/Application Support/Claude Profiles/Profiles/work", isDirectory: true)
    let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
    let engine = URL(fileURLWithPath: "/Users/me/Applications/Claude Profiles/.engines/Claude work.app", isDirectory: true)
    let binary = "/Users/me/Applications/Claude Profiles/.engines/Claude work.app/Contents/MacOS/Claude"

    @Test func readsTheDataDirSwitchLikeChromium() {
        #expect(ProcessArguments.userDataDir(in: [binary, "--user-data-dir=/a b/c"]) == "/a b/c")
        #expect(ProcessArguments.userDataDir(in: [binary, "-user-data-dir=/x"]) == "/x")
        #expect(ProcessArguments.userDataDir(in: [binary, "--user-data-dir=/x", "--user-data-dir=/y"]) == "/y")
        #expect(ProcessArguments.userDataDir(in: [binary]) == nil)
        #expect(ProcessArguments.userDataDir(in: [binary, "--user-data-dir="]) == nil)
        #expect(ProcessArguments.userDataDir(in: [binary, "--", "--user-data-dir=/x"]) == nil)
        #expect(ProcessArguments.userDataDir(in: [binary, "--user-data-dir", "/x"]) == nil)
        #expect(ProcessArguments.userDataDir(in: ["--user-data-dir=/argv0-is-not-a-switch"]) == nil)
    }

    @Test func parsesProcArgs() {
        // Built with separate `+=`: long `[UInt8]` concatenations with literals time out type-checking on Swift 6.1.
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/bin/claude".utf8)
        bytes += [0, 0, 0, 0]
        bytes += Array("claude".utf8)
        bytes += [0, 0]
        bytes += Array("--user-data-dir=/d".utf8)
        bytes += [0]
        bytes += Array("HOME=/Users/me".utf8)
        bytes += [0]
        #expect(ProcessArguments.parse(procargs: bytes[...]) == ["claude", "", "--user-data-dir=/d"])
        #expect(ProcessArguments.parse(procargs: bytes.prefix(20)) == nil)
        #expect(ProcessArguments.parse(procargs: [1, 0][...]) == nil)
    }

    @Test func readsThisProcesssArguments() {
        #expect(ProcessArguments.of(getpid()) == CommandLine.arguments)
    }

    @Test func engineWithItsDataDirIsTheProfilesWindow() {
        let copy = RunningClaude(bundlePath: engine.path, arguments: [binary, "--user-data-dir=\(work.path)"])
        #expect(copy.uses(dataDir: work, mainDataDir: main, bundle: engine))
        #expect(!copy.uses(dataDir: main, mainDataDir: main, bundle: claudeApp))
        #expect(!copy.isStartedWithoutDataDir(engine: engine))
    }

    @Test func engineOpenedFromTheDockShowsTheMainAccount() {
        let copy = RunningClaude(bundlePath: engine.path, arguments: [binary])
        #expect(!copy.uses(dataDir: work, mainDataDir: main, bundle: engine))
        #expect(copy.uses(dataDir: main, mainDataDir: main, bundle: claudeApp))
        #expect(copy.isStartedWithoutDataDir(engine: engine))
    }

    @Test func mainAppIsNeverAProfileStartedWithoutData() {
        let copy = RunningClaude(bundlePath: claudeApp.path, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"])
        #expect(copy.uses(dataDir: main, mainDataDir: main, bundle: claudeApp))
        #expect(!copy.isStartedWithoutDataDir(engine: engine))
    }

    @Test func unreadableArgumentsFallBackToTheBundle() {
        let copy = RunningClaude(bundlePath: engine.path, arguments: nil)
        #expect(copy.uses(dataDir: work, mainDataDir: main, bundle: engine))
        #expect(!copy.uses(dataDir: main, mainDataDir: main, bundle: claudeApp))
        #expect(!copy.isStartedWithoutDataDir(engine: engine))
    }

    @Test func dataDirPathsAreCompared() {
        let copy = RunningClaude(bundlePath: engine.path, arguments: [binary, "--user-data-dir=\(work.path)/"])
        #expect(copy.uses(dataDir: work, mainDataDir: main, bundle: engine))
    }
}
