import ClaudeProfilesKit
import Foundation

let usage = """
claude-profiles — several Claude subscriptions side by side in Claude Desktop.

USAGE
  claude-profiles list                          Show every profile, its account and plan usage
  claude-profiles add <email> [--label TEXT] [--color #RRGGBB]
                                                 Create a profile and open it to sign in
  claude-profiles open <profile>                Open a profile's window (id or label)
  claude-profiles remove <profile>              Quit it and move its copy and sign-in to the Trash
  claude-profiles sync                          Share local Code sessions; inspect Cowork without copying it
  claude-profiles refresh                       Rebuild app copies after a Claude Desktop update
  claude-profiles doctor [--json]               Read-only session, folder and Remote Control checks
  claude-profiles handoff --from PROFILE --to PROFILE --title TEXT --context FILE
                         [--folder PATH] [--source-url URL] [--open]
                                                 Save reviewed context for a new conversation; never sends it
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func value(of flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let manager = ProfileManager(cliPath: cli)
let args = Array(CommandLine.arguments.dropFirst())

func resolve(_ name: String) -> Profile {
    guard let profile = manager.profiles.first(where: { $0.id == name.lowercased() || $0.label.caseInsensitiveCompare(name) == .orderedSame })
    else { fail("no profile “\(name)”. Run `claude-profiles list`.") }
    return profile
}

func profileLabel(_ name: String) -> String {
    ["main", "claude"].contains(name.lowercased()) ? "MAIN" : resolve(name).label
}

func describe(_ usage: Usage?) -> String {
    guard let usage else { return "usage unknown" }
    let five = usage.isFiveHourStale() ? "reset" : usage.fiveHour.map { "\($0)%" } ?? "?"
    let week = usage.week.map { "\($0)%" } ?? "?"
    return "5h \(five) · week \(week) · as of \(usage.sampledAt.formatted(date: .abbreviated, time: .shortened))"
}

do {
    switch args.first {
    case "list", nil:
        if let problem = manager.registryError { print("⚠︎ \(problem)") }
        for s in manager.statuses() {
            let name = s.isMain ? "Claude (main)" : "Claude \(s.label)"
            let who = s.email ?? (s.isSignedIn ? "signed in" : "not signed in")
            let state = s.isRunning ? "open" : "closed"
            print("\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(state.padding(toLength: 7, withPad: " ", startingAt: 0)) \(who.padding(toLength: 32, withPad: " ", startingAt: 0)) \(describe(s.usage))")
            if s.isUnexpectedAccount, let expected = s.profile?.email { print("  ⚠︎ expected \(expected)") }
            if s.isOpenWithoutProfile, let id = s.profile?.id {
                print("  ⚠︎ a copy opened without this profile shows the main account; `claude-profiles open \(id)` replaces it")
            }
        }
    case "add":
        guard args.count >= 2 else { fail("add needs an email") }
        let email = args[1]
        let label = value(of: "--label", in: args)
            ?? Profile.suggestedLabel(for: email, taken: Set(manager.profiles.map(\.label)))
        let profile = try manager.create(label: label, email: email, color: value(of: "--color", in: args))
        try await manager.open(profile.id)
        print("Created Claude \(profile.label). Sign in as \(email) in the window that just opened.")
    case "open":
        guard args.count >= 2 else { fail("open needs a profile") }
        if ["main", "claude"].contains(args[1].lowercased()) { try await manager.openMain() }
        else { try await manager.open(resolve(args[1]).id) }
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
    case "remove":
        guard args.count >= 2 else { fail("remove needs a profile") }
        let profile = resolve(args[1])
        try await manager.remove(profile.id)
        print("Moved Claude \(profile.label) to the Trash. Ordinary local Code sessions stay available; local Cowork data moved with the profile.")
    case "sync":
        guard let r = try manager.syncSessions() else { fail("another sync is running; try again in a moment") }
        print("\(r.sessions.pairs) session folders · \(r.sessions.cardsWritten) cards copied · \(r.sessions.cardsRemoved) removed · \(r.sessions.tombstonesWritten) deletions shared")
        print("\(r.cowork.pairs) Cowork folders checked · kept in their original profiles; use handoff to continue elsewhere")
        print("\(r.sessions.accountBoundCards + r.cowork.accountBoundCards) account-linked cards scoped · \(r.sessions.ambiguousAccountBoundCards + r.cowork.ambiguousAccountBoundCards) ambiguous cards left untouched")
    case "doctor":
        let entries = try Diagnostics.inspect(paths: manager.paths)
        if args.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
        } else {
            print("Read-only local inventory. Cloud access and feature availability are not tested.")
            for entry in entries {
                print("\(entry.label): \(entry.localCode) local Code, \(entry.localCowork) Cowork cards, \(entry.accountBoundWorkers) account-linked workers")
                print("  Remote Control: \(entry.remoteControlEnabled.map { $0 ? "enabled" : "disabled" } ?? "not recorded"); \(entry.listedRemoteFolders) listed folders")
                for issue in entry.issues { print("  \(issue)") }
                for folder in entry.missingFolders { print("  Missing: \(folder)") }
            }
        }
    case "handoff":
        guard let from = value(of: "--from", in: args), let to = value(of: "--to", in: args),
              let title = value(of: "--title", in: args), let contextFile = value(of: "--context", in: args)
        else { fail("handoff needs --from, --to, --title and --context; run --help") }
        let handoff = Handoff(title: title, source: profileLabel(from), destination: profileLabel(to),
                              context: try String(contentsOfFile: contextFile, encoding: .utf8),
                              folder: value(of: "--folder", in: args) ?? "", sourceURL: value(of: "--source-url", in: args) ?? "")
        let file = try handoff.save(paths: manager.paths)
        print("Saved reviewed context: \(file.path)")
        print("Pause the original task. Use the saved context in a new conversation in \(handoff.destination). Nothing was sent.")
        if args.contains("--open") {
            if ["main", "claude"].contains(to.lowercased()) { try await manager.openMain() }
            else { try await manager.open(resolve(to).id) }
            if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
        }
    case "refresh":
        try manager.refresh()
        print("Profiles are up to date with Claude Desktop.")
    case "__render-app-icon":  // used by scripts/build-app.sh
        guard args.count >= 2 else { fail("__render-app-icon needs an output path") }
        let url = URL(fileURLWithPath: args[1])
        if url.pathExtension == "png" {
            try IconRenderer.pngData(IconRenderer.appIcon(), pixels: 1024)?.write(to: url)
        } else {
            try IconRenderer.icnsData(for: IconRenderer.appIcon()).write(to: url)
        }
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command “\(args[0])”\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
