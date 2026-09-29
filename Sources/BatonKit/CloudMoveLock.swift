import Foundation

/// An optional, explicit extra guarantee for Local only: also refuses the one MCP tool that could still move a
/// Claude Code session to the cloud from inside a session (`mcp__ccd_session__move_to_cloud`), by adding it to
/// `permissions.deny` in `~/.claude/settings.json`. This is Mac-wide, not per window, and separate from
/// `LocalOnly`, which only turns off Claude Desktop's own Remote Control preferences.
///
/// Off by default: nothing in Baton turns this on by itself, only an explicit choice from the CLI or
/// the app's toggle. Every write starts with a dated backup of `settings.json`, changes only the `deny` list, and
/// is read back afterwards. Turning it off removes only this one entry and leaves every other deny rule, and
/// every other setting in the file, as it was.
public struct CloudMoveLock: Sendable {
    /// The exact tool name this denies.
    public static let tool = "mcp__ccd_session__move_to_cloud"

    public enum Status: String, Codable, Sendable {
        /// `permissions.deny` in `~/.claude/settings.json` names the tool.
        case on
        case off
    }

    public let paths: Paths
    public var settingsFile: URL { paths.claudeSettingsFile }
    private var stateFile: URL { paths.stateDir.appending(path: "cloud-move-lock.json") }

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Whether `settings.json` currently denies the tool. Reads only; a missing or unreadable file counts as
    /// `off` rather than throwing, so status checks never fail the app or CLI.
    public func status() -> Status {
        ((try? deny()) ?? []).contains(Self.tool) ? .on : .off
    }

    /// Whether Baton is the one that turned this on, for a doctor line or a settings toggle.
    public func addedByThisApp() -> Bool {
        FileManager.default.fileExists(atPath: stateFile.path)
    }

    /// Adds or removes `tool` in `permissions.deny`. Turning it on when it is already there, or off when it is
    /// already absent, still backs up nothing and writes nothing beyond the provenance record.
    @discardableResult
    public func setEnabled(_ enabled: Bool, now: Date = Date()) throws -> Status {
        let current = try deny()
        let already = current.contains(Self.tool)
        if enabled {
            if !already { try write(current + [Self.tool]) }
            try record(now: now)
            return .on
        }
        if already { try write(current.filter { $0 != Self.tool }) }
        try clearRecord()
        return .off
    }

    // MARK: - Reading and writing settings.json

    private func settings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalStorageError.corrupt("\(settingsFile.lastPathComponent) must contain a JSON object; it was left as it is")
        }
        return object
    }

    private func deny() throws -> [String] {
        ((try settings())["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
    }

    /// Changes only the `deny` list and leaves every other byte of the file as it was. A linked `settings.json` stays
    /// a link: the file it leads to is backed up and written (`LocalOnly.replace`).
    private func write(_ deny: [String]) throws {
        let target = LocalOnly.writeTarget(settingsFile)
        let original = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        var patch = try JSONPatch(original ?? Data("{}".utf8))
        let list = String(decoding: try JSONSerialization.data(withJSONObject: deny, options: [.withoutEscapingSlashes]), as: UTF8.self)
        let top = try patch.top()
        if let permissions = top.members.last(where: { $0.key == "permissions" }) {
            guard patch.bytes[permissions.valueStart] == UInt8(ascii: "{") else {
                throw LocalStorageError.corrupt("permissions in \(settingsFile.lastPathComponent) must be a JSON object; it was left as it is")
            }
            let object = try patch.object(at: permissions.valueStart)
            if let member = object.members.last(where: { $0.key == "deny" }) {
                patch.replace(member, with: list)
            } else {
                patch.insert(key: "deny", value: list, in: object)
            }
        } else {
            patch.insert(key: "permissions", value: "{\"deny\": \(list)}", in: top)
        }
        if original != nil { _ = try Backup(paths: paths, now: Date()).save(target, everyTime: true) }
        try LocalOnly.replace(settingsFile, with: Data(patch.bytes))
        guard (try? self.deny()) == deny else {
            if let original { try LocalOnly.replace(settingsFile, with: original) }
            throw LocalStorageError.corrupt("\(settingsFile.lastPathComponent) didn't read back as written; the earlier file was put back")
        }
    }

    // MARK: - Provenance record

    private func record(now: Date) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let entry: [String: Any] = ["addedByClaudeProfiles": true, "at": ISO8601DateFormatter().string(from: now)]
        try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]).write(to: stateFile, options: .atomic)
    }

    private func clearRecord() throws {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        try FileManager.default.removeItem(at: stateFile)
    }
}
