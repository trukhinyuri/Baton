import Foundation

/// What each `baton` command accepts after its name, checked before anything is read or changed, so a mistyped option
/// such as `--dryrun` stops the command instead of being ignored.
public enum CLIArguments {
    /// Exit statuses of `baton`: 0 done, 1 failed, 2 a command or option it doesn't take (nothing was read or changed),
    /// 3 nothing was done, and the printed line says why.
    public static let usageExitCode: Int32 = 2

    struct Syntax {
        /// Options that stand alone.
        var flags: Set<String> = []
        /// Options followed by a value.
        var values: Set<String> = []
        /// How many other arguments it takes: a profile, a session, a folder.
        var plain: ClosedRange<Int> = 0...0
    }

    /// `nil` for a command `baton` doesn't have, and for `migrate`, which checks its own.
    static func syntax(for args: [String]) -> Syntax? {
        let continueFlags: Set<String> = ["--same", "--anyway", "--fork", "--now", "--dry-run"]
        return switch args.first {
        case nil, "list": Syntax(flags: ["--json"])
        case "add": Syntax(values: ["--label", "--color"], plain: 1...1)
        case "open", "remove": Syntax(plain: 1...1)
        case "sync", "carry": Syntax(flags: ["--dry-run"])
        case "refresh": Syntax()
        case "doctor", "rules": Syntax(flags: ["--json"])
        case "conversations": Syntax(flags: ["--all", "--json"])
        case "rule": Syntax(flags: ["--remove"], values: ["--only"], plain: 1...1)
        case "report": Syntax(flags: ["--open"], values: ["--save"])
        case "continue" where args.dropFirst().first == "--folder":
            Syntax(flags: continueFlags.union(["--new"]), values: ["--folder", "--to", "--since", "--max"])
        case "continue": Syntax(flags: continueFlags, values: ["--to"], plain: 1...1)
        case "local-only":
            switch args.dropFirst().first {
            case "status": Syntax(flags: ["--json"], plain: 1...2)
            case "on", "off": Syntax(plain: 1...2)
            case "cloud-lock": Syntax(plain: 2...2)
            default: Syntax(plain: 1...1)
            }
        default: nil
        }
    }

    /// Why `args` doesn't fit its command, to show with that command's lines of the help; `nil` when it fits.
    /// - Parameter args: everything after `baton`, aliases resolved.
    public static func problem(in args: [String]) -> String? {
        if args.first == "migrate" { return nil }
        guard let syntax = syntax(for: args) else { return "unknown command “\(args[0])”" }
        let command = "`baton \(args.first ?? "list")`"
        var plain: [String] = []
        var rest = args.dropFirst()
        while let argument = rest.popFirst() {
            if syntax.values.contains(argument) {
                guard let value = rest.popFirst(), !value.hasPrefix("--") else { return "\(argument) needs a value" }
            } else if syntax.flags.contains(argument) {
                continue
            } else if argument.count > 1 && argument.hasPrefix("-") {
                return "\(command) has no option “\(argument)”; nothing was changed"
            } else {
                plain.append(argument)
            }
        }
        if plain.count > syntax.plain.upperBound {
            return "\(command) doesn't take “\(plain[syntax.plain.upperBound])”; nothing was changed"
        }
        if plain.count < syntax.plain.lowerBound { return "\(command) is missing an argument; nothing was changed" }
        return nil
    }

    /// The lines of `usage` about the command in `args`: its line and the ones under it, such as `baton continue
    /// --folder`'s for `continue --folder ~/src --to work`; the whole help for a command `baton` doesn't have.
    public static func usage(for args: [String], in usage: String) -> String {
        let lines = usage.components(separatedBy: "\n")
        let names = [args.prefix(2), args.prefix(1)].filter { !$0.isEmpty }.map { "baton " + $0.joined(separator: " ") }
        for name in names {
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + " ") }) else { continue }
            var own = [lines[start]]
            for line in lines[(start + 1)...] {
                // The next command starts at the same indent; the command's own lines go on further in.
                guard line.prefix(while: { $0 == " " }).count > lines[start].prefix(while: { $0 == " " }).count else { break }
                own.append(line)
            }
            return own.joined(separator: "\n")
        }
        return usage
    }
}

/// The shape of what `baton` prints.
public enum CLIOutput {
    /// `rows` with each column padded to its widest value, so nothing is cut; the last column isn't padded.
    public static func table(_ rows: [[String]]) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: " ")
        }
    }

    /// Pretty-printed JSON with sorted keys and ISO 8601 dates.
    public static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// One window in `baton list --json`.
    public struct Window: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var email: String?
        public var signedIn: Bool
        public var open: Bool
        /// Percent used of the five-hour and weekly limits, as Claude last recorded them.
        public var fiveHour: Int?
        public var week: Int?
        public var usageAt: Date?
        public var atLimit: Bool
        /// When the limit that holds the window back resets, if known.
        public var resetsAt: Date?
    }

    public static func windows(_ statuses: [ProfileStatus], now: Date = Date()) -> [Window] {
        statuses.map { status in
            let limits = status.limits
            return Window(
                id: status.id, label: status.label, email: status.email, signedIn: status.isSignedIn, open: status.isRunning,
                fiveHour: status.usage?.fiveHour, week: status.usage?.week, usageAt: status.usage?.sampledAt,
                atLimit: status.isSignedIn && limits.isAtLimit(now: now), resetsAt: limits.binding(now: now)?.reset?.at)
        }
    }

    /// One conversation in `baton conversations --json`.
    public struct ConversationRow: Encodable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var title: String
        public var folders: [String]
        public var lastActivity: Date
        /// The window whose account owns a Cowork task; `nil` for Code sessions, which every window shares.
        public var owner: String?
    }

    public static func conversations(_ conversations: [Conversation]) -> [ConversationRow] {
        conversations.map {
            ConversationRow(
                id: $0.sessionID, kind: $0.kind.rawValue, title: $0.title, folders: $0.folders, lastActivity: $0.lastActivity,
                owner: $0.ownerID)
        }
    }

    /// The line under `baton conversations` when it shows only the most recent: how many more there are.
    public static func moreConversations(shown: Int, of total: Int) -> String? {
        total > shown ? "Showing the \(shown) most recent of \(total); add --all for every one." : nil
    }
}
