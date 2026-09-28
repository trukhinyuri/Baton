import Darwin
import Foundation
import Testing

@testable import BatonKit

@Suite("Starting the app and the command line")
struct ProcessStartTests {
    @Test func theScrubRemovesClaudeAndAnthropicSettingsOnly() {
        let inherited = [
            "CLAUDECODE": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet", "ANTHROPIC_BASE_URL": "https://proxy.example",
            "ANTHROPIC_API_KEY": "sk-test-not-real", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "PATH": "/usr/bin:/bin", "HOME": "/Users/alex", "AGENT_TOOLS_REPO": "/Users/alex/agent-tools", "BATON_DEMO": "1",
            "LANG": "en_US.UTF-8", "MY_CLAUDE_NOTES": "kept: only the start of a name counts", "ANTHROPICISH": "kept",
        ]
        let kept = InheritedEnvironment.scrubbed(inherited)
        for name in ["CLAUDECODE", "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_ENTRYPOINT"] {
            #expect(kept[name] == nil, "\(name) is removed")
        }
        for name in ["PATH", "HOME", "AGENT_TOOLS_REPO", "BATON_DEMO", "LANG", "MY_CLAUDE_NOTES", "ANTHROPICISH"] {
            #expect(kept[name] == inherited[name], "\(name) is kept")
        }
        #expect(kept.count == 7)
    }

    @Test func versionHelpAndIconNeverBuildTheManager() throws {
        for args in [["--version"], ["version"], ["--help"], ["-h"], ["help"], ["__render-app-icon", "/tmp/x.png"]] {
            #expect(CLIDispatch.stage(for: args) == .early, "\(args)")
        }
        #expect(CLIDispatch.stage(for: ["migrate"]) == .migrate)
        for command in ["open", "add", "refresh", "continue", "remove"] {
            #expect(CLIDispatch.stage(for: [command, "x"]) == .manager(sharedLock: true), "\(command)")
        }
        #expect(CLIDispatch.stage(for: CommandAliases.resolve(["pass", "last", "--to", "work"])) == .manager(sharedLock: true))
        for args in [[], ["list"], ["doctor"], ["sync"], ["rules"], ["conversations"], ["report"], ["carry"], ["local-only", "status"]] {
            #expect(CLIDispatch.stage(for: args) == .manager(sharedLock: false), "\(args)")
        }

        #expect(CLIDispatch.runEarly(["--version"], usage: "USAGE").output == BuildInfo.current.description)
        #expect(CLIDispatch.runEarly(["--help"], usage: "USAGE").output == "USAGE")
        let missing = CLIDispatch.runEarly(["__render-app-icon"], usage: "USAGE")
        #expect(missing.exitCode == 1 && missing.error == "__render-app-icon needs an output path")

        let folder = FileManager.default.temporaryDirectory.appending(path: "icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appending(path: "AppIcon.png")
        let rendered = CLIDispatch.runEarly(["__render-app-icon", png.path], usage: "USAGE")
        #expect(rendered.exitCode == 0 && rendered.error == nil)
        let data = try Data(contentsOf: png)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "a PNG")
    }

    @Test func theCLIPathIsTheResolvedExecutable() throws {
        let running = try #require(RunningExecutable.url())
        #expect(running.path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: running.path))
        #expect(RunningExecutable.resolved(running.path) == running, "links already resolved")

        let folder = FileManager.default.temporaryDirectory.appending(path: "exe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appending(path: "Baton.app/Contents/Helpers/baton")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: real)
        let link = folder.appending(path: "bin/baton")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolved = try #require(RunningExecutable.resolved(link.path))
        #expect(resolved.path.hasSuffix("/Baton.app/Contents/Helpers/baton"))
        #expect(resolved == RunningExecutable.resolved(real.path))
        #expect(RunningExecutable.resolved(folder.appending(path: "missing").path) == nil)
    }

    @Test func anOutdatedCopyIsQuitNotHandedOverTo() {
        let current = "1.0.0"
        let old = AppInstances.RunningCopy(pid: 10, bundle: URL(fileURLWithPath: "/Users/a/Applications/Claude Profiles/Claude Profiles.app"), version: "1.0.0")
        let trashed = AppInstances.RunningCopy(pid: 11, bundle: URL(fileURLWithPath: "/Users/a/.Trash/Baton.app"), version: "1.0.0")
        let older = AppInstances.RunningCopy(pid: 12, bundle: URL(fileURLWithPath: "/Applications/Baton.app"), version: "0.9.4")
        let same = AppInstances.RunningCopy(pid: 13, bundle: URL(fileURLWithPath: "/Applications/Baton.app"), version: "1.0")
        let newer = AppInstances.RunningCopy(pid: 14, bundle: URL(fileURLWithPath: "/Applications/Baton.app"), version: "1.0.1")
        let unknown = AppInstances.RunningCopy(pid: 15, bundle: nil, version: nil)

        #expect(AppInstances.handover(others: [old], currentVersion: current) == .init(terminate: [10], handOverTo: nil))
        #expect(AppInstances.handover(others: [trashed, older], currentVersion: current) == .init(terminate: [11, 12], handOverTo: nil))
        #expect(AppInstances.handover(others: [same], currentVersion: current) == .init(terminate: [], handOverTo: 13))
        #expect(AppInstances.handover(others: [older, newer], currentVersion: current) == .init(terminate: [12], handOverTo: 14))
        #expect(
            AppInstances.handover(others: [unknown], currentVersion: current) == .init(terminate: [], handOverTo: 15),
            "unknown copies are handed over to, as before")
        #expect(
            AppInstances.handover(others: [older], currentVersion: "dev") == .init(terminate: [], handOverTo: 12), "a development build compares no versions")
        #expect(AppInstances.handover(others: [], currentVersion: current) == .init(terminate: [], handOverTo: nil))

        #expect(AppInstances.isVersion("0.9.10", below: "1.0"))
        #expect(AppInstances.isVersion("1.0.9", below: "1.0.10"))
        #expect(!AppInstances.isVersion("1.0", below: "1.0.0"))
        #expect(!AppInstances.isVersion("1.2", below: "1.1.9"))
        #expect(!AppInstances.isVersion("dev", below: "1.0"))
    }
}
