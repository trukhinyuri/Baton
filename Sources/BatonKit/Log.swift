import Darwin
import Foundation
import os

/// One place for Baton's log. Every line goes to the unified log, with values marked `privacy: .private`, so paths,
/// emails and ids stay redacted in `log show` unless the Mac has private data logging turned on. Once the app or the
/// CLI has called `enableFile(in:)`, the same line also goes to Baton's own text log, `Logs/baton.log` in its data
/// folder, whenever that folder exists: a size-capped, rotating file a problem report attaches after redaction.
/// Nothing leaves the Mac.
public enum Log {
    public static let subsystem = "io.github.trukhinyuri.claudeprofiles"

    public enum Level: String, Sendable { case info, notice, error }

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static func info(_ category: String, _ message: String) { write(.info, category, message) }
    public static func notice(_ category: String, _ message: String) { write(.notice, category, message) }
    public static func error(_ category: String, _ message: String) { write(.error, category, message) }

    static func write(_ level: Level, _ category: String, _ message: String) {
        let logger = logger(category)
        switch level {
        case .info: logger.info("\(message, privacy: .private)")
        case .notice: logger.notice("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
        shared.file?.append(level: level, category: category, message: message)
    }

    /// `message` with every one of `paths` in it put in curly quotes, as the app quotes titles, so a problem report
    /// hides the whole path even when a folder name has a space in it. Longest first; one already quoted stays as it is.
    public static func quoting(paths: [String], in message: String) -> String {
        let candidates = Set(paths.filter { $0.count > 1 && $0.contains("/") }).sorted { $0.count > $1.count }
        guard !candidates.isEmpty,
            let regex = try? NSRegularExpression(
                pattern: "(?<!“)(?:" + candidates.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")")
        else { return message }
        return regex.stringByReplacingMatches(in: message, range: NSRange(message.startIndex..., in: message), withTemplate: "“$0”")
    }

    /// Writes Baton's own log into `<dataFolder>/Logs` from now on, each line only while the data folder exists. On a
    /// fresh Mac the first sync or `baton add` creates it, and the lines after that are kept. The log itself never
    /// creates Baton's data folder, which would win over a folder of the earlier name that isn't reachable right now.
    public static func enableFile(in dataFolder: URL) { shared.dataFolder = dataFolder }

    /// The last `limit` lines of Baton's own log, oldest first; empty until `enableFile(in:)` ran and the folder exists.
    public static func fileTail(limit: Int) -> [String] { shared.file?.tail(limit: limit) ?? [] }

    /// Baton's data folder the log goes to, checked at every line rather than once: it may not exist yet when the app
    /// or the CLI starts, and may be moved away while it runs.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?
        var dataFolder: URL? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        /// The log file, or nil while no data folder is set or it isn't a folder right now.
        var file: LogFile? {
            guard let dataFolder else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dataFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return LogFile(folder: dataFolder.appending(path: "Logs", directoryHint: .isDirectory))
        }
    }
    private static let shared = Sink()
}

/// A text log capped at `maxBytes` per file and `keep` files: `baton.log`, then `baton.log.1`, `baton.log.2`, oldest
/// last. The app and the CLI may write at once; an exclusive `flock` on `.lock` keeps lines whole and a rotation single.
/// Each line carries the time (UTC, ISO 8601), the level and the part of Baton that wrote it. A write that fails is
/// dropped: logging never stops the work it describes.
public struct LogFile: Sendable {
    public let folder: URL
    public var maxBytes: Int
    public var keep: Int
    public static let name = "baton.log"

    public init(folder: URL, maxBytes: Int = 1_048_576, keep: Int = 3) {
        self.folder = folder
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
    }

    public var current: URL { folder.appending(path: Self.name) }
    func rotated(_ n: Int) -> URL { n == 0 ? current : folder.appending(path: "\(Self.name).\(n)") }

    public func append(level: Log.Level, category: String, message: String, at date: Date = Date()) {
        let text = message.replacingOccurrences(of: "\n", with: " ")
        let line = Data("\(date.formatted(.iso8601)) \(level.rawValue) [\(category)] \(text)\n".utf8)
        _ = try? FileLock.withLock(folder.appending(path: ".lock"), blocking: true) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
            if size > 0, size + line.count > maxBytes { rotate() }
            let descriptor = Darwin.open(current.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    /// Shifts each file one place down; the oldest is replaced, which is what the cap is for.
    private func rotate() {
        let fm = FileManager.default
        for n in stride(from: keep - 1, through: 1, by: -1) {
            let from = rotated(n - 1), to = rotated(n)
            guard fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) { _ = try? fm.replaceItemAt(to, withItemAt: from) } else { try? fm.moveItem(at: from, to: to) }
        }
        if keep == 1 { try? Data().write(to: current) }
    }

    /// The last `limit` lines across the rotated files, oldest first.
    public func tail(limit: Int) -> [String] {
        var lines: [String] = []
        for n in 0..<keep where lines.count < limit {
            guard let text = try? String(contentsOf: rotated(n), encoding: .utf8) else { continue }
            let own = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines = own.suffix(limit - lines.count) + lines
        }
        return lines
    }
}
