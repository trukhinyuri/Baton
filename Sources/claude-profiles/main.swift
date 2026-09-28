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
  claude-profiles doctor [--json]               Read-only session and folder checks
  claude-profiles conversations [--all]         Recent local Code sessions and Cowork tasks
  claude-profiles continue <session|last> --to <profile> [--same [--anyway]|--fork] [--dry-run]
                                                 Continue a conversation in another profile: a Code session
                                                 as itself or as a copy, or a new Cowork task with its history
  claude-profiles continue --folder <path> --to <profile> [--since 24h] [--max 6] [--same [--anyway]|--fork]
                           [--new] [--dry-run]
                                                 Continue the Code sessions of a folder with a message since
                                                 --since, in one go: the --max most recent (6 unless given);
                                                 --new also starts a new session
                                                 By default sessions still open in a running Claude Code
                                                 process or with a message in the last 10 minutes continue
                                                 as a copy; --same keeps the same session (add --anyway once
                                                 you've closed it there), --fork copies
  claude-profiles rules                         Show which accounts may continue the work in which folders
  claude-profiles rule <folder> --only <email>[,<email>…] | --remove
                                                 Let only these accounts continue work in the folder and
                                                 inside it, or drop the folder's rule
  claude-profiles --version                     Print the version and commit
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

func age(_ date: Date) -> String { relativeAge(since: date) }

func kindName(_ conversation: Conversation) -> String {
    switch conversation.kind {
    case .code: "Code"
    case .cowork: "Cowork in \(manager.label(of: conversation.ownerID ?? "main"))"
    }
}

func describe(_ usage: Usage?) -> String {
    guard let usage else { return "usage unknown" }
    let five = usage.isFiveHourStale() ? "reset" : usage.fiveHour.map { "\($0)%" } ?? "?"
    let week = usage.week.map { "\($0)%" } ?? "?"
    return "5h \(five) · week \(week) · as of \(age(usage.sampledAt))" + (usage.isFresh() ? "" : " (stale: may be higher now)")
}

/// `24h`, `90m`, `2d`, or hours as a plain number.
func duration(_ text: String) -> TimeInterval? {
    let units: [Character: TimeInterval] = ["m": 60, "h": 3600, "d": 86_400]
    if let unit = text.last.flatMap({ units[$0] }), let n = Double(text.dropLast()), n > 0 { return n * unit }
    return Double(text).flatMap { $0 > 0 ? $0 * 3600 : nil }
}

func continueMode() -> ContinueMode {
    if args.contains("--same") && args.contains("--fork") { fail("use either --same or --fork") }
    if args.contains("--fork") { return .fork }
    return args.contains("--same") ? .same : .auto
}

func destinationID(_ name: String) -> String {
    ["main", "claude"].contains(name.lowercased()) ? "main" : resolve(name).id
}

/// Refuses to write to a session that may still be running in its window unless --anyway says it was closed there.
func refuseRunning(_ conversations: [Conversation], mode: ContinueMode) {
    guard mode == .same, !args.contains("--anyway") else { return }
    let running = conversations.filter { $0.mayStillWrite() }
    guard !running.isEmpty else { return }
    let names = running.map { "“\($0.title)” (\($0.hasLiveProcess ? "open in a running Claude Code process" : "a message \(age($0.lastActivity))"))" }
    fail("\(names.joined(separator: ", ")) may still be written to in its window. Continue as a copy (drop --same), or close it there first and add --anyway.")
}

func printPlan(_ plans: [ContinuePlan], to destination: String) {
    let label = manager.label(of: destination)
    for plan in plans {
        let how = plan.forks ? "copy" : "same"
        let status = switch plan.opened { case true?: "✓ "; case false?: "✗ "; case nil: "" }
        let folder = plan.conversation.folders.first.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        print("\(status)\(how)  \(plan.conversation.sessionID.prefix(8))  \(plan.conversation.title) — \(kindName(plan.conversation))\(folder)")
        if let note = plan.model { print("      \(note.isWarning ? "⚠︎ " : "")\(note.message(destination: label))") }
    }
}

/// Says what didn't open and exits with an error; returns if everything that can be checked opened.
func reportUnopened(_ plans: [ContinuePlan], in destination: String) {
    let missing = plans.filter { $0.opened == false }
    guard !missing.isEmpty else { return }
    fail("\(missing.count) of \(plans.count) did not show up in Claude \(manager.label(of: destination)) within \(Int(manager.importWait)) s: "
         + missing.map { "\($0.sessionID.prefix(8)) “\($0.conversation.title)”" }.joined(separator: ", ")
         + ". Open them there with `claude-profiles continue <id> --to \(destination) --same`.")
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
        print("\(r.cowork.pairs) Cowork folders checked · kept in their original profiles; use continue to carry one elsewhere")
        print("\(r.sessions.accountBoundCards + r.cowork.accountBoundCards) account-linked cards scoped · \(r.sessions.ambiguousAccountBoundCards + r.cowork.ambiguousAccountBoundCards) ambiguous cards left untouched")
    case "doctor":
        let entries = try Diagnostics.inspect(paths: manager.paths)
        if args.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
        } else {
            print("Read-only local inventory. Cloud access and feature availability are not tested.")
            for entry in entries {
                print("\(entry.label): \(entry.localCode) local Code, \(entry.localCowork) Cowork cards")
                for issue in entry.issues { print("  \(issue)") }
                for folder in entry.missingFolders { print("  Missing: \(folder)") }
            }
        }
    case "conversations":
        let all = manager.conversations()
        for c in args.contains("--all") ? all : Array(all.prefix(20)) {
            let folder = c.folders.first.map { " · " + $0 } ?? ""
            print("\(c.sessionID.prefix(8))  \(age(c.lastActivity).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title) — \(kindName(c))\(folder)")
        }
        if all.isEmpty { print("No local conversations found.") }
    case "continue" where args.count >= 2 && args[1] == "--folder":
        guard let folder = value(of: "--folder", in: args), let to = value(of: "--to", in: args) else {
            fail("continue --folder needs a folder and --to PROFILE")
        }
        let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
        let destination = destinationID(to)
        guard let since = duration(value(of: "--since", in: args) ?? "24h") else { fail("--since takes a duration such as 24h, 90m or 2d") }
        let mode = continueMode()
        guard let limit = Int(value(of: "--max", in: args) ?? String(ConversationIndex.continueAllLimit)), limit > 0 else {
            fail("--max takes a positive number, such as 6")
        }
        let (found, leftOut) = ConversationIndex.continueAllBatch(in: path, since: Date().addingTimeInterval(-since),
                                                                  from: manager.conversations(), to: destination, limit: limit)
        let leftOutNote = leftOut == 0 ? "" : " Left out \(leftOut) older ones: continue them one at a time or raise --max."
        let newSession = args.contains("--new") ? path : nil
        guard !found.isEmpty || newSession != nil else {
            fail("no Code sessions in \(path) with a message in the last \(value(of: "--since", in: args) ?? "24h"). Widen --since or add --new.")
        }
        refuseRunning(found, mode: mode)
        let label = manager.label(of: destination)
        if args.contains("--dry-run") {
            printPlan(try manager.plan(found, in: destination, mode: mode, newSessionIn: newSession), to: destination)
            print("Would open \(found.count) in Claude \(label)" + (newSession.map { " and start a new session in \($0)" } ?? "") + ". Nothing was changed." + leftOutNote)
            break
        }
        let plans = try await manager.continueAll(found, in: destination, mode: mode, newSessionIn: newSession)
        printPlan(plans, to: destination)
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
        reportUnopened(plans, in: destination)
        let checked = plans.filter { $0.opened == true }.count
        print("Opened \(plans.count) in Claude \(label)" + (newSession.map { " and started a new session in \($0)" } ?? "")
              + (checked > 0 ? "; \(checked) confirmed imported there" : "") + ". Nothing was sent." + leftOutNote)
    case "continue":
        guard args.count >= 2, let to = value(of: "--to", in: args) else { fail("continue needs a session (or “last”) and --to PROFILE") }
        let all = manager.conversations()
        let key = args[1].lowercased()
        let matches = key == "last" ? Array(all.prefix(1)) : all.filter { $0.sessionID.hasPrefix(key) }
        guard matches.count == 1, let conversation = matches.first else {
            fail(matches.isEmpty ? "no conversation “\(args[1])”. Run `claude-profiles conversations`." : "“\(args[1])” matches several conversations; use more of its id")
        }
        let destination = destinationID(to)
        let mode = continueMode()
        if args.contains("--anyway"), !args.contains("--same"), conversation.kind != .cowork {
            FileHandle.standardError.write(Data("note: --anyway applies only with --same; continuing as planned below.\n".utf8))
        }
        refuseRunning([conversation], mode: mode)
        if conversation.kind == .cowork, conversation.isActive(), !args.contains("--anyway") {
            fail("“\(conversation.title)” was working less than a minute ago, so its history may miss the last steps. Stop it in its window first, or add --anyway.")
        }
        if args.contains("--dry-run") {
            if conversation.kind == .cowork {
                print("Would start a new Cowork task in Claude \(manager.label(of: destination)) with “\(conversation.title)”'s history and files attached. Nothing was changed.")
            } else {
                printPlan(try manager.plan([conversation], in: destination, mode: mode), to: destination)
                print("Nothing was changed.")
            }
            break
        }
        switch try await manager.continueConversation(conversation, in: destination, mode: mode) {
        case .openedSession(let plan):
            printPlan([plan], to: destination)
            reportUnopened([plan], in: destination)
            print("Opened “\(conversation.title)”\(plan.forks ? " as a copy" : "") in Claude \(manager.label(of: destination))"
                  + (plan.opened == true ? "; confirmed imported there." : "."))
        case .startedCoworkTask(let handoff):
            print("Started a new Cowork task in Claude \(manager.label(of: destination)) with the history attached. Review it and send it there.")
            print("Prepared files: \(handoff.folder.path)")
        }
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
    case "rules":
        let rules: [FolderRule]
        do { rules = try FolderRules(paths: manager.paths).load() } catch { fail(ProfileError.rulesUnreadable(error.localizedDescription).localizedDescription) }
        if rules.isEmpty { print("No folder rules: work in any folder can continue in any subscription.") }
        for rule in rules { print("\((rule.folder as NSString).abbreviatingWithTildeInPath) → only \(rule.accounts.joined(separator: ", "))") }
    case "rule":
        guard args.count >= 3, !args[1].hasPrefix("--") else { fail("rule needs a folder and --only EMAIL[,EMAIL] or --remove") }
        let folder = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath).standardizedFileURL.path
        let rules = FolderRules(paths: manager.paths)
        if args.contains("--remove") {
            try rules.set(folder, accounts: [])
            print("Removed the rule for \(folder).")
        } else if let only = value(of: "--only", in: args) {
            let accounts = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !accounts.isEmpty, accounts.allSatisfy(Profile.isValidEmail) else { fail("--only takes email addresses separated by commas") }
            guard let rule = try rules.set(folder, accounts: accounts) else { fail("--only needs at least one email address") }
            print("Work in \(rule.folder) and inside it continues only in \(rule.accounts.joined(separator: ", ")).")
        } else {
            fail("rule needs --only EMAIL[,EMAIL] or --remove")
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
    case "--version", "version":
        print(BuildInfo.current.description)
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command “\(args[0])”\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
