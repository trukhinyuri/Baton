import Foundation

/// Other names the `baton` command line accepts for its commands.
public enum CommandAliases {
    /// `baton pass` is `baton continue`.
    public static let names = ["pass": "continue"]

    /// The arguments with an alias in the command position replaced by the command it stands for.
    public static func resolve(_ args: [String]) -> [String] {
        guard let first = args.first, let command = names[first] else { return args }
        return [command] + args.dropFirst()
    }
}
