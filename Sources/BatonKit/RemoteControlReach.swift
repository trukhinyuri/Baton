import Foundation

/// Which folders Claude's own Remote Control serves in one window, read from that window's files only.
///
/// Claude keeps its Remote Control state in `<dataDir>/remote-control-state.json` (version 1):
/// `identities["<account>:<org>"] = {serve, folders: {"<path>": …}, …}`, and the folders the user pinned for Remote
/// Control in `claude_desktop_config.json` → `preferences.remoteControlPinnedFolders`. A session in a folder the
/// window serves can be reached through Remote Control there, so Baton leaves it with that window. A state file Baton
/// can't read counts as reaching every folder: Baton never moves a session it can't show to be out of reach.
public struct RemoteControlReach: Equatable, Sendable {
    public struct Identity: Equatable, Sendable {
        public var serving: Bool
        public var folders: [String]

        public init(serving: Bool, folders: [String]) {
            self.serving = serving
            self.folders = folders
        }
    }

    public static let stateName = "remote-control-state.json"

    /// `"<account>:<org>"` → whether it serves (`serve == "on"`) and the folders it serves.
    public var identities: [String: Identity]
    /// The window's `remoteControlPinnedFolders`.
    public var pinned: [String]
    /// The state file is there but isn't version 1 or can't be parsed.
    public var unreadable: Bool

    public init(identities: [String: Identity] = [:], pinned: [String] = [], unreadable: Bool = false) {
        self.identities = identities
        self.pinned = pinned
        self.unreadable = unreadable
    }

    /// Reads the window's state file and pinned folders. A missing state file means nothing is served.
    public static func read(dataDir: URL) -> RemoteControlReach {
        var reach = RemoteControlReach()
        let config = dataDir.appending(path: LocalOnly.configName)
        if let data = try? Data(contentsOf: config),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prefs = object["preferences"] as? [String: Any]
        {
            reach.pinned = (prefs["remoteControlPinnedFolders"] as? [Any] ?? []).compactMap { $0 as? String }
        }
        let url = dataDir.appending(path: stateName)
        guard FileManager.default.fileExists(atPath: url.path) else { return reach }
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["version"] as? NSNumber)?.intValue == 1,
            let identities = object["identities"] as? [String: Any]
        else {
            reach.unreadable = true
            return reach
        }
        for (key, value) in identities {
            guard let identity = value as? [String: Any] else {
                reach.unreadable = true
                continue
            }
            let folders = (identity["folders"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            reach.identities[key] = Identity(serving: identity["serve"] as? String == "on", folders: folders)
        }
        return reach
    }

    /// Whether Remote Control can reach a session in `folder` for the account scope `scope` (`"<account>/<org>"`, as
    /// SessionSync names it; Claude's state names it `"<account>:<org>"`): that identity serves, and `folder` is one of
    /// its served folders or the window's pinned folders, or inside one. Paths are compared with links and `..`
    /// resolved. An unreadable state file reaches every folder.
    public func reaches(folder: String, scope: String) -> Bool {
        if unreadable { return true }
        let serving = identities.filter { key, identity in identity.serving && Self.matches(key, scope: scope) }
        guard !serving.isEmpty else { return false }
        let path = ConversationIndex.canonical(folder)
        let roots = serving.values.flatMap(\.folders) + pinned
        return roots.contains { root in
            let root = ConversationIndex.canonical(root)
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    /// `"<account>/<org>"` names the identity `"<account>:<org>"`; a scope with only an account names each of its orgs.
    static func matches(_ identity: String, scope: String) -> Bool {
        guard let slash = scope.firstIndex(of: "/") else { return identity.hasPrefix(scope + ":") || identity == scope }
        return identity == scope[..<slash] + ":" + scope[scope.index(after: slash)...]
    }
}
