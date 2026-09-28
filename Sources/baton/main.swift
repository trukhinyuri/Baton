import AppKit
import BatonKit
import Foundation

// First: whatever Claude or Anthropic settings the terminal or a Claude Code session passed along must not reach the
// windows this command opens.
InheritedEnvironment.scrub()

let usage = """
    baton — several Claude Desktop accounts on one Mac, and a clean handover between your own windows.

    USAGE
      baton list                          Show every profile, its account and plan usage
      baton add <email> [--label TEXT] [--color #RRGGBB]
                                          Create a profile and open it to sign in
      baton open <profile>                Open a profile's window (id or label)
      baton remove <profile>              Move a closed profile's copy and sign-in to the Trash
      baton sync [--dry-run]              Share local Code sessions; inspect Cowork without copying it
      baton refresh                       Rebuild app copies and launchers after a Claude Desktop update
      baton migrate                       Rename ~/Applications/Claude Profiles to Baton, with Baton quit and
                                          every Claude window closed. Exit 3: kept for now; the printed line
                                          says why
      baton doctor [--json]               Read-only session and folder checks
      baton local-only on|off|status [PROFILE|main] [--json]
                                          Keep new Claude Code sessions off Remote Control; on by
                                          default. No profile: every window without its own choice
      baton local-only cloud-lock on|off|status
                                          Optional, off by default: also deny the one MCP tool that
                                          moves a Claude Code session to the cloud, Mac-wide, in
                                          ~/.claude/settings.json
      baton conversations [--all]         Recent local Code sessions and Cowork tasks
      baton continue <session|last> --to <profile> [--same [--anyway]|--fork] [--now] [--dry-run]
                                          Continue a conversation in another profile: a Code session
                                          as itself or as a copy, or a new Cowork task with its history
      baton continue --folder <path> --to <profile> [--since 24h] [--max 6] [--same [--anyway]|--fork]
                     [--new] [--now] [--dry-run]
                                          Continue the Code sessions of a folder with a message since
                                          --since, in one go: the --max most recent (6 unless given);
                                          --new also starts a new session
                                          By default sessions still open in a running Claude Code
                                          process or with a message in the last 10 minutes continue
                                          as a copy; --same keeps the same session (add --anyway once
                                          you've closed it there), --fork copies
                                          If the session's window resets within 15 minutes and
                                          continues it by itself, nothing happens (exit 3) unless --now
      baton pass <session|last> --to <profile> [--same [--anyway]|--fork] [--now] [--dry-run]
                                          Same as `continue`, easier to shout across the track
      baton rules                         Show which accounts may continue the work in which folders
      baton rule <folder> --only <email>[,<email>…] | --remove
                                          Let only these accounts continue work in the folder and
                                          inside it, or drop the folder's rule
      baton carry [--dry-run]             Bring sub-agents, Workflow history, tool outputs and the scratchpad
                                          into sessions Claude Desktop continued as a new copy itself
      baton report [--save PATH] [--open] Print a redacted problem report; --save writes it to a file,
                                          --open opens a prefilled GitHub issue to review and submit.
                                          Nothing is sent
      baton --version                     Print the version and commit
    """

func fail(_ message: String) -> Never {
    // The log keeps the folders it was given in curly quotes, so a report hides them whole, spaces and all.
    let given = CommandLine.arguments.dropFirst().filter { $0.contains("/") || $0.hasPrefix("~") || $0 == "." || $0 == ".." }
    let paths = given.flatMap { argument -> [String] in
        let full = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath).standardizedFileURL.path
        return [argument, full, (full as NSString).abbreviatingWithTildeInPath]
    }
    Log.error("cli", Log.quoting(paths: paths, in: message))
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func value(of flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandAliases.resolve(Array(CommandLine.arguments.dropFirst()))
let home = FileManager.default.homeDirectoryForCurrentUser
// Launchers call this path, so it is the real file, not whatever name the shell found it by.
let cli = RunningExecutable.url() ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

switch CLIDispatch.stage(for: args) {
case .early:
    // Answered before anything reads or changes the profiles.
    let answer = CLIDispatch.runEarly(args, usage: usage)
    if let error = answer.error { fail(error) }
    if !answer.output.isEmpty { print(answer.output) }
    exit(answer.exitCode)
case .migrate:
    if let unreachable = Paths.unreachableFolder(home: home) { fail(unreachable) }
    // Only `baton migrate` renames the launchers folder, before any path is resolved; every other command uses it
    // where it is.
    if let migration = LegacyMigration.command(args, home: home, cli: cli) {
        if migration.exitCode == 1 { fail(migration.message) }
        print(migration.message)
        exit(migration.exitCode)
    }
case .manager(let sharedLock):
    // A folder of the earlier name that links nowhere right now: stop before anything creates a new, empty one.
    if let unreachable = Paths.unreachableFolder(home: home) { fail(unreachable) }
    Log.enableFile(in: Paths.stateRoot(home: home))
    // Held until this command exits, so the launchers folder isn't renamed while it opens windows or builds launchers.
    if sharedLock, let busy = LegacyMigration.holdShared(home: home) { fail(busy) }
}

let manager = ProfileManager(cliPath: cli)

// Re-registers the main Claude if a sign-in hand-off was abandoned, and notes a Claude Desktop version
// outside the tested range. Informational only: it never blocks the command that follows.
for warning in manager.startUpChecks() { FileHandle.standardError.write(Data("note: \(warning)\n".utf8)) }

func resolve(_ name: String) -> Profile {
    guard let profile = manager.profiles.first(where: { $0.id == name.lowercased() || $0.label.caseInsensitiveCompare(name) == .orderedSame })
    else { fail("no profile “\(name)”. Run `baton list`.") }
    return profile
}

func age(_ date: Date) -> String { relativeAge(since: date) }

func describe(_ status: LocalOnly.Status) -> String {
    switch status {
    case .on: "Local only: Remote Control off for new sessions"
    case .off: "Local only off"
    case .pending: "Local only applies when this window next starts"
    case .notSupported: "Local only not available in this Claude Desktop version"
    }
}

func describe(_ status: CloudMoveLock.Status) -> String {
    switch status {
    case .on: "Cloud move lock: mcp__ccd_session__move_to_cloud denied in ~/.claude/settings.json"
    case .off: "Cloud move lock off"
    }
}

func kindName(_ conversation: Conversation) -> String {
    switch conversation.kind {
    case .code: "Code"
    case .cowork: "Cowork in \(manager.label(of: conversation.ownerID ?? "main"))"
    }
}

/// "5h 100% · resets 02:10 · week 62% · as of 3m ago" (see `LimitText.summary`).
func describe(_ status: ProfileStatus) -> String { LimitText.summary(status.limits, usage: status.usage) }

/// Before continuing: when the source window picks the session up by itself within minutes, say so and stop,
/// unless `--now` says to continue anyway. Exits with 3, so a script can tell that nothing was done and why.
func offerToWait(_ conversations: [Conversation], in destination: String) {
    guard !args.contains("--now"), let offer = manager.autoResumeOffer(for: conversations, in: destination) else { return }
    print(offer.message())
    print("Wait for it there, or add --now to continue in Claude \(manager.label(of: destination)) anyway. Nothing was changed.")
    exit(3)
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

func printPlan(_ plans: [ContinuePlan], to destination: String) {
    let label = manager.label(of: destination)
    for plan in plans {
        let how = plan.forks ? "copy" : "same"
        let status =
            switch plan.opened {
            case true?: "✓ ";
            case false?: "✗ ";
            case nil: ""
            }
        let folder = plan.conversation.folders.first.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        print("\(status)\(how)  \(plan.conversation.sessionID.prefix(8))  \(plan.conversation.title) — \(kindName(plan.conversation))\(folder)")
        if let note = plan.model { print("      \(note.isWarning ? "⚠︎ " : "")\(note.message(destination: label))") }
        for item in plan.wontFollow {
            let names = item.names.isEmpty ? "" : " (\(item.names.joined(separator: ", ")))"
            print("      stays behind: \(item.detail)\(names)")
        }
        for note in plan.autoResume { print("      \(note.isWarning ? "⚠︎ " : "")\(note.message())") }
    }
}

/// After opening, whatever the copy's scratchpad left in the original session.
func printCarried(_ plans: [ContinuePlan]) {
    for plan in plans {
        guard let carried = plan.carried, !carried.leftBehind.isEmpty || !carried.worktrees.isEmpty else { continue }
        var parts: [String] = []
        if !carried.leftBehind.isEmpty { parts.append("scratchpad: \(carried.leftBehind.joined(separator: ", "))") }
        if !carried.worktrees.isEmpty { parts.append("git worktrees (not copied): \(carried.worktrees.joined(separator: ", "))") }
        print("Left in the original \(parts.joined(separator: "; "))")
    }
}

/// Says what didn't open and exits with an error; returns if everything that can be checked opened.
func reportUnopened(_ plans: [ContinuePlan], in destination: String) {
    let missing = plans.filter { $0.opened == false }
    guard !missing.isEmpty else { return }
    fail(
        "\(missing.count) of \(plans.count) did not show up in Claude \(manager.label(of: destination)) within \(Int(manager.importWait)) s: "
            + missing.map { "\($0.sessionID.prefix(8)) “\($0.conversation.title)”" }.joined(separator: ", ")
            + ". Open them there with `baton continue <id> --to \(destination) --same`.")
}

do {
    switch args.first {
    case "list", nil:
        if let problem = manager.registryError { print("⚠︎ \(problem)") }
        for s in manager.statuses() {
            let name = s.isMain ? "Claude (main)" : "Claude \(s.label)"
            let who = s.email ?? (s.isSignedIn ? "signed in" : "not signed in")
            let state = s.isRunning ? "open" : "closed"
            print(
                "\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(state.padding(toLength: 7, withPad: " ", startingAt: 0)) \(who.padding(toLength: 32, withPad: " ", startingAt: 0)) \(describe(s))"
            )
            if s.isUnexpectedAccount, let expected = s.profile?.email { print("  ⚠︎ expected \(expected)") }
            if s.isOpenWithoutProfile, let id = s.profile?.id {
                print("  ⚠︎ a copy opened without this profile shows the main account; `baton open \(id)` replaces it")
            }
        }
    case "add":
        guard args.count >= 2 else { fail("add needs an email") }
        let email = args[1]
        let label =
            value(of: "--label", in: args)
            ?? Profile.suggestedLabel(for: email, taken: Set(manager.profiles.map(\.label)))
        let profile = try manager.create(label: label, email: email, color: value(of: "--color", in: args))
        try await manager.open(profile.id)
        print("Created Claude \(profile.label). Sign in as \(email) in the window that just opened.")
    case "open":
        guard args.count >= 2 else { fail("open needs a profile") }
        if ["main", "claude"].contains(args[1].lowercased()) { try await manager.openMain() } else { try await manager.open(resolve(args[1]).id) }
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
    case "remove":
        guard args.count >= 2 else { fail("remove needs a profile") }
        let profile = resolve(args[1])
        try await manager.remove(profile.id)
        print("Moved Claude \(profile.label) to the Trash. Ordinary local Code sessions stay available; local Cowork data moved with the profile.")
    case "sync":
        let dryRun = args.dropFirst().contains("--dry-run")
        guard let r = try manager.syncSessions(dryRun: dryRun) else { fail("another sync is running; try again in a moment") }
        let verb = dryRun ? "would copy" : "copied", removedVerb = dryRun ? "would remove" : "removed", sharedVerb = dryRun ? "would share" : "shared"
        print(
            "\(r.sessions.pairs) session folders · \(r.sessions.cardsWritten) cards \(verb) · \(r.sessions.cardsRemoved) \(removedVerb) · \(r.sessions.tombstonesWritten) deletions \(sharedVerb)"
        )
        print(
            "\(r.sessions.withheldByRule) withheld by folder rules · \(r.sessions.retiredByRule) retired by folder rules · \(r.sessions.keptLive) kept live (open in a running Claude Code process) · \(r.sessions.tombstonesExpired) old tombstones expired"
        )
        print("\(r.cowork.pairs) Cowork folders checked · kept in their original profiles; use continue to carry one elsewhere")
        print(
            "\(r.sessions.accountBoundCards + r.cowork.accountBoundCards) account-linked cards scoped · \(r.sessions.ambiguousAccountBoundCards + r.cowork.ambiguousAccountBoundCards) ambiguous cards left untouched"
        )
        let carried = r.carried.reduce(0) { $0 + $1.added.count }
        if carried > 0 { print("\(carried) files carried into \(r.carried.count) sessions Claude Desktop continued as a copy") }
        if dryRun { print("Nothing was changed.") }
    case "local-only":
        guard args.count >= 2 else { fail("local-only needs on, off, status or cloud-lock") }
        switch args[1] {
        case "on", "off":
            let window = args.count >= 3 && !args[2].hasPrefix("--") ? destinationID(args[2]) : nil
            let result = try manager.setLocalOnly(args[1] == "on", window: window)
            for (id, status) in result.sorted(by: { manager.label(of: $0.key) < manager.label(of: $1.key) }) {
                print("\(manager.label(of: id)): \(describe(status))")
            }
        case "status":
            let rows = manager.localOnlyStatus()
            if args.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let payload = rows.map { ["window": $0.window, "label": $0.label, "status": $0.status.rawValue] }
                print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            } else {
                for row in rows { print("\(row.label): \(describe(row.status))") }
            }
        case "cloud-lock":
            guard args.count >= 3 else { fail("local-only cloud-lock needs on, off or status") }
            switch args[2] {
            case "on", "off": print(describe(try manager.setCloudMoveLock(args[2] == "on")))
            case "status": print(describe(manager.cloudMoveLock.status()))
            default: fail("local-only cloud-lock needs on, off or status")
            }
        default:
            fail("local-only needs on, off, status or cloud-lock")
        }
    case "doctor":
        let entries = try Diagnostics.inspect(paths: manager.paths)
        if args.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
        } else {
            print("Read-only local inventory. Cloud access and feature availability are not tested.")
            for note in LegacyMigration.notes(paths: manager.paths, cli: cli) { print(note) }
            let installed = ClaudeVersion.installed(at: manager.paths.claudeApp) ?? "unknown"
            print(
                "Claude Desktop: \(manager.paths.claudeApp.path), version \(installed) (tested \(ClaudeVersion.testedText))"
            )
            if let warning = manager.claudeVersionWarning { print("  \(warning)") }
            switch LocalOnly.missingKeys(in: manager.paths.claudeApp) {
            case nil: print("Local only: Claude.app unreadable, can't check its settings")
            case []: print("Local only keys present: ccRemoteControlDefaultEnabled, remoteControlStayReachable")
            case let missing?: print("Local only: missing in this Claude Desktop: \(missing.joined(separator: ", "))")
            }
            for row in manager.localOnlyStatus() { print("\(row.label): \(describe(row.status))") }
            print(describe(manager.cloudMoveLock.status()))
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
        if all.isEmpty { print("Nothing to hand off yet. No local conversations found.") }
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
        let (found, leftOut) = ConversationIndex.continueAllBatch(
            in: path, since: Date().addingTimeInterval(-since),
            from: manager.conversations(), to: destination, limit: limit)
        let leftOutNote = leftOut == 0 ? "" : " Left out \(leftOut) older ones: continue them one at a time or raise --max."
        let newSession = args.contains("--new") ? path : nil
        guard !found.isEmpty || newSession != nil else {
            fail(
                "Nothing to hand off yet. No Code sessions in \(path) with a message in the last \(value(of: "--since", in: args) ?? "24h"). Widen --since or add --new."
            )
        }
        let anyway = args.contains("--anyway")
        let label = manager.label(of: destination)
        if args.contains("--dry-run") {
            printPlan(try manager.plan(found, in: destination, mode: mode, newSessionIn: newSession, anyway: anyway), to: destination)
            print(
                "Would open \(found.count) in Claude \(label)" + (newSession.map { " and start a new session in \($0)" } ?? "") + ". Nothing was changed."
                    + leftOutNote)
            break
        }
        offerToWait(found, in: destination)
        let plans = try await manager.continueAll(found, in: destination, mode: mode, newSessionIn: newSession, anyway: anyway)
        printPlan(plans, to: destination)
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
        reportUnopened(plans, in: destination)
        printCarried(plans)
        let checked = plans.filter { $0.opened == true }.count
        print(
            "Opened \(plans.count) in Claude \(label)" + (newSession.map { " and started a new session in \($0)" } ?? "")
                + (checked > 0 ? "; \(checked) confirmed imported there" : "") + ". Nothing was sent." + leftOutNote)
    case "continue":
        guard args.count >= 2, let to = value(of: "--to", in: args) else { fail("continue needs a session (or “last”) and --to PROFILE") }
        let all = manager.conversations()
        let key = args[1].lowercased()
        let matches = key == "last" ? Array(all.prefix(1)) : all.filter { $0.sessionID.hasPrefix(key) }
        guard matches.count == 1, let conversation = matches.first else {
            if all.isEmpty { fail("Nothing to hand off yet. No local conversations found.") }
            fail(
                matches.isEmpty
                    ? "no conversation “\(args[1])”. Run `baton conversations`." : "“\(args[1])” matches several conversations; use more of its id")
        }
        let destination = destinationID(to)
        let mode = continueMode()
        let anyway = args.contains("--anyway")
        if anyway, !args.contains("--same"), conversation.kind != .cowork {
            FileHandle.standardError.write(Data("note: --anyway applies only with --same; continuing as planned below.\n".utf8))
        }
        if conversation.kind == .cowork, conversation.isActive(), !anyway {
            fail(
                "“\(conversation.title)” was working less than a minute ago, so its history may miss the last steps. Stop it in its window first, or add --anyway."
            )
        }
        if args.contains("--dry-run") {
            if conversation.kind == .cowork {
                print(
                    "Would start a new Cowork task in Claude \(manager.label(of: destination)) with “\(conversation.title)”'s history and files attached. Nothing was changed."
                )
            } else {
                printPlan(try manager.plan([conversation], in: destination, mode: mode, anyway: anyway), to: destination)
                print("Nothing was changed.")
            }
            break
        }
        offerToWait([conversation], in: destination)
        switch try await manager.continueConversation(conversation, in: destination, mode: mode, anyway: anyway) {
        case .openedSession(let plan):
            printPlan([plan], to: destination)
            printCarried([plan])
            reportUnopened([plan], in: destination)
            print(
                "Opened “\(conversation.title)”\(plan.forks ? " as a copy" : "") in Claude \(manager.label(of: destination))"
                    + (plan.opened == true ? "; confirmed imported there." : "."))
        case .startedCoworkTask(let handoff):
            print("Started a new Cowork task in Claude \(manager.label(of: destination)) with the history attached. Review it and send it there.")
            print("Prepared files: \(handoff.folder.path)")
        }
        if let warning = manager.lastOpenWarning { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
    case "rules":
        let rules: [FolderRule]
        do { rules = try FolderRules(paths: manager.paths).load() } catch {
            fail(ProfileError.rulesUnreadable(error.localizedDescription).localizedDescription)
        }
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
    case "carry":
        let dryRun = args.dropFirst().contains("--dry-run")
        let reports = try NativeForkCarry.run(paths: manager.paths, dataDirs: manager.dataDirs, dryRun: dryRun)
        if reports.isEmpty { print("Nothing to carry: every copy Claude Desktop made already has its old session's files.") }
        for report in reports {
            print(
                "\(report.lineage.old.prefix(8)) → \(report.lineage.new.prefix(8)): \(dryRun ? "would add" : "added") \(report.added.count) files, kept \(report.kept) the new session already had"
            )
            if !report.leftBehind.isEmpty {
                print("  left in the old scratchpad: \(report.leftBehind.count) items — folders of builds or project copies, files over 1 MB or not text")
            }
            for worktree in report.worktrees {
                print("  git worktree in the old scratchpad, not copied: \((worktree as NSString).abbreviatingWithTildeInPath) — `git worktree move` keeps it")
            }
        }
        if !reports.isEmpty {
            print("Rewind to points before Claude Desktop's copy works only in the old session; its checkpoints are kept there.")
        }
    case "report":
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? manager.paths.home
        let localOnly = Dictionary(uniqueKeysWithValues: manager.localOnlyStatus().map { ($0.window, $0.status == .on) })
        print(
            try FeedbackReport.command(
                args, paths: manager.paths, log: LogTail.read(), localOnly: localOnly, downloads: downloads,
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }, open: { NSWorkspace.shared.open($0) }))
    default:
        fail("unknown command “\(args[0])”\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
