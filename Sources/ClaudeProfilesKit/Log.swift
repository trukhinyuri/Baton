import os

/// One place for the unified log. Values are logged with `privacy: .private` at the call site, so paths,
/// emails and ids stay redacted in `log show` unless the Mac has private data logging turned on.
public enum Log {
    public static let subsystem = "io.github.trukhinyuri.claudeprofiles"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
