import Foundation
import Testing

@testable import BatonKit

@Suite("The command line's arguments and output")
struct CLIArgumentsTests {
    static let usage = """
        baton — test

        USAGE
          baton list [--json]                 Show every profile
          baton open <profile>                Open a profile's window
          baton continue <session|last> --to <profile> [--same [--anyway]|--fork] [--now] [--dry-run]
                                              Continue a conversation
          baton continue --folder <path> --to <profile> [--since 24h] [--max 6]
                         [--new] [--now] [--dry-run]
                                              Continue the Code sessions of a folder
          baton sync [--dry-run]              Share local Code sessions

        EXIT STATUS
          2  a command or option baton doesn't take
        """

    /// A mistyped option or a word too many stops the command before it runs, rather than being ignored: `sync
    /// --dryrun` must never sync.
    @Test func mistypedOptionsStopTheCommand() {
        for args in [
            ["sync", "--dryrun"], ["sync", "-n"], ["carry", "--dryrun"], ["list", "--bogus"], ["doctor", "--bogus"],
            ["conversations", "--bogus"], ["continue", "last", "--to", "work", "--dryrun"],
            ["continue", "--folder", "~/src", "--to", "work", "--since=2h"], ["add", "a@example.org", "--label=Work"],
            ["local-only", "on", "--json"], ["report", "--bogus"], ["refresh", "--dry-run"],
        ] {
            let problem = CLIArguments.problem(in: args)
            #expect(problem?.contains("has no option") == true, "\(args): \(problem ?? "accepted")")
        }
        #expect(CLIArguments.problem(in: ["list", "work"])?.contains("doesn't take “work”") == true)
        #expect(CLIArguments.problem(in: ["open", "work", "home"])?.contains("doesn't take “home”") == true)
        #expect(CLIArguments.problem(in: ["open"])?.contains("missing an argument") == true)
        #expect(CLIArguments.problem(in: ["continue", "last", "--to"]) == "--to needs a value")
        #expect(CLIArguments.problem(in: ["report", "--save", "--open"]) == "--save needs a value")
        #expect(CLIArguments.problem(in: ["frobnicate"]) == "unknown command “frobnicate”")
    }

    @Test func everyDocumentedFormIsAccepted() {
        for args in [
            [], ["list"], ["list", "--json"], ["add", "a@example.org", "--label", "Work", "--color", "#1971C2"], ["open", "work"],
            ["remove", "work"], ["sync"], ["sync", "--dry-run"], ["refresh"], ["doctor", "--json"], ["local-only", "on"],
            ["local-only", "off", "work"], ["local-only", "status", "main", "--json"], ["local-only", "cloud-lock", "status"],
            ["conversations", "--all", "--json"], ["continue", "last", "--to", "work", "--same", "--anyway", "--now", "--dry-run"],
            ["continue", "3f2a", "--to", "main", "--fork"],
            ["continue", "--folder", "~/src/app", "--to", "work", "--since", "2h", "--max", "3", "--new", "--now", "--dry-run"],
            ["rules"], ["rules", "--json"], ["rule", "~/src/acme", "--only", "a@example.org,b@example.org"], ["rule", "~/src/acme", "--remove"],
            ["carry", "--dry-run"], ["report"], ["report", "--save", "~/Desktop/report.md", "--open"], ["migrate"], ["migrate", "--x"],
        ] {
            #expect(CLIArguments.problem(in: args) == nil, "\(args): \(CLIArguments.problem(in: args) ?? "")")
        }
    }

    @Test func aProblemShowsThatCommandsLinesOfTheHelp() {
        #expect(CLIArguments.usage(for: ["sync", "--dryrun"], in: Self.usage) == "  baton sync [--dry-run]              Share local Code sessions")
        let folder = CLIArguments.usage(for: ["continue", "--folder", "x"], in: Self.usage).components(separatedBy: "\n")
        #expect(folder.count == 3 && folder[0].contains("--folder") && folder[2].contains("Continue the Code sessions"))
        let session = CLIArguments.usage(for: ["continue", "last"], in: Self.usage).components(separatedBy: "\n")
        #expect(session.count == 2 && session[0].contains("<session|last>"))
        #expect(CLIArguments.usage(for: ["frobnicate"], in: Self.usage) == Self.usage, "the whole help")
    }

    /// `baton --help` shows `--json` for exactly the commands that take it: `local-only on --json` stops with exit 2,
    /// so its line must not offer it.
    @Test func theHelpOffersJSONOnlyWhereItIsTaken() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: repo.appending(path: "Sources/baton/main.swift"), encoding: .utf8)
        let help = try #require(main.components(separatedBy: "let usage = \"\"\"\n").last?.components(separatedBy: "    \"\"\"").first)
        for args in [
            ["list"], ["doctor"], ["rules"], ["conversations"], ["sync"], ["local-only", "on"], ["local-only", "off"],
            ["local-only", "status"], ["local-only", "cloud-lock", "status"],
        ] {
            let offered = CLIArguments.usage(for: args, in: help).contains("--json")
            #expect(offered == (CLIArguments.problem(in: args + ["--json"]) == nil), "\(args)")
        }
    }

    /// Only the commands that read skip re-registering the main Claude with Launch Services at start.
    @Test func readOnlyCommandsAreKnown() {
        for args in [
            [], ["list"], ["doctor", "--json"], ["report"], ["conversations"], ["rules"], ["local-only", "status"], ["local-only", "cloud-lock", "status"],
        ] {
            #expect(CLIDispatch.isReadOnly(args), "\(args)")
        }
        for args in [
            ["open", "work"], ["sync"], ["sync", "--dry-run"], ["refresh"], ["local-only", "on"], ["local-only", "cloud-lock", "on"], ["continue", "last"],
        ] {
            #expect(!CLIDispatch.isReadOnly(args), "\(args)")
        }
    }

    /// `baton list` never cuts an email: every column is as wide as its widest value.
    @Test func tableColumnsFitTheirWidestValue() {
        let long = "firstname.lastname@subdomain.example.com"
        let rows = CLIOutput.table([["Claude (main)", "open", long, "5h 10%"], ["Claude WORK", "closed", "a@example.org", "5h 99%"]])
        #expect(rows[0] == "Claude (main) open   \(long) 5h 10%")
        #expect(rows[1] == "Claude WORK   closed a@example.org" + String(repeating: " ", count: long.count - 13) + " 5h 99%")
        #expect(CLIOutput.table([]).isEmpty)
    }

    @Test func listAndConversationsAsJSON() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let work = Profile(id: "work", label: "WORK", email: "a@example.org", color: "#1971C2")
        let statuses = [
            ProfileStatus(profile: nil, accountID: "acc", email: "me@example.org", usage: Usage(fiveHour: 100, week: 40, sampledAt: now), isRunning: true),
            ProfileStatus(profile: work, accountID: nil, email: nil, usage: nil, isRunning: false),
        ]
        let windows = CLIOutput.windows(statuses, now: now)
        #expect(windows.map(\.id) == ["main", "work"])
        #expect(windows[0].email == "me@example.org" && windows[0].fiveHour == 100 && windows[0].atLimit && windows[0].open)
        #expect(!windows[1].signedIn && !windows[1].atLimit && windows[1].email == nil)
        let text = try CLIOutput.json(windows)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(parsed.count == 2 && parsed[0]["label"] as? String == "MAIN" && parsed[0]["usageAt"] as? String == "2027-01-15T08:00:00Z")

        let conversation = Conversation(
            kind: .code, sessionID: "3f2a", title: "Fix “the” build", folders: ["/src/app"], lastActivity: now,
            transcript: URL(fileURLWithPath: "/tmp/3f2a.jsonl"))
        let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(CLIOutput.json(CLIOutput.conversations([conversation])).utf8)) as? [[String: Any]])
        #expect(rows[0]["id"] as? String == "3f2a" && rows[0]["kind"] as? String == "code" && rows[0]["folders"] as? [String] == ["/src/app"])
        #expect(try CLIOutput.json([FolderRule(folder: "/", accounts: ["A@example.org"])]).contains("\"accounts\" : [\n      \"a@example.org\""))
    }

    @Test func conversationsSayHowManyMoreThereAre() {
        #expect(CLIOutput.moreConversations(shown: 20, of: 64) == "Showing the 20 most recent of 64; add --all for every one.")
        #expect(CLIOutput.moreConversations(shown: 20, of: 20) == nil)
        #expect(CLIOutput.moreConversations(shown: 64, of: 64) == nil)
    }

    /// A script reading `--json` gets every conversation, not a silent first 20.
    @Test func conversationsAsJSONAreAllOfThem() {
        #expect(CLIOutput.conversationLimit(for: ["conversations"]) == 20)
        #expect(CLIOutput.conversationLimit(for: ["conversations", "--all"]) == nil)
        #expect(CLIOutput.conversationLimit(for: ["conversations", "--json"]) == nil)
    }

    /// What every window has alike, such as the missing folders of the Code sessions they share, comes once.
    @Test func doctorSaysSharedFindingsOnce() {
        let missing = ["3 working folders are missing", "Missing: /src/a"]
        let findings = CLIOutput.doctorFindings([
            ("main", missing + ["46 Cowork cards without history"]), ("work", missing), ("home", missing + ["2 ambiguous"]),
        ])
        #expect(findings.shared == missing)
        #expect(findings.windows.map(\.name) == ["main", "work", "home"])
        #expect(findings.windows.map(\.lines) == [["46 Cowork cards without history"], [], ["2 ambiguous"]])
        let one = CLIOutput.doctorFindings([("main", missing)])
        #expect(one.shared.isEmpty && one.windows.map(\.lines) == [missing], "one window has nothing to share")
    }
}
