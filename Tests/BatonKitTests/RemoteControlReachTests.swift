import Foundation
import Testing

@testable import BatonKit

extension Sandbox {
    /// Claude's Remote Control state for one window: each identity `"<account>:<org>"` serving or not, with its folders.
    func remoteControlState(_ dataDir: URL, _ identities: [String: (serve: String, folders: [String])], version: Int = 1) throws {
        var object: [String: Any] = [:]
        for (key, identity) in identities {
            let folders = Dictionary(uniqueKeysWithValues: identity.folders.map { ($0, ["environmentId": "env_example", "keys": [$0]] as [String: Any]) })
            object[key] = ["serve": identity.serve, "folders": folders, "pendingDelete": [], "pendingUnarchive": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "identities": object], options: [.sortedKeys])
        try write(String(decoding: data, as: UTF8.self), to: dataDir.appending(path: RemoteControlReach.stateName))
    }

    /// The window serves Remote Control for `folders` with this account and organization.
    func serveRemoteControl(_ dataDir: URL, account: String, org: String = "org-1", folders: [String]) throws {
        try remoteControlState(dataDir, ["\(account):\(org)": ("on", folders)])
    }
}

@Suite("Remote Control reach")
struct RemoteControlReachTests {
    static let scope = "\(Sandbox.accountA)/org-a"
    static let identity = "\(Sandbox.accountA):org-a"

    @Test func serveOnAndFolderInsideServedFolderReaches() throws {
        let box = try Sandbox()
        let served = box.root.appending(path: "Projects")
        try FileManager.default.createDirectory(at: served.appending(path: "app/sub"), withIntermediateDirectories: true)
        try box.remoteControlState(box.work, [Self.identity: ("on", [served.path])])

        let reach = RemoteControlReach.read(dataDir: box.work)

        #expect(reach.reaches(folder: served.path, scope: Self.scope))
        #expect(reach.reaches(folder: served.appending(path: "app/sub").path, scope: Self.scope), "a folder inside a served one")
        #expect(reach.reaches(folder: served.path + "/app/../app", scope: Self.scope), "paths are compared resolved")
        #expect(!reach.reaches(folder: box.root.appending(path: "ProjectsOther").path, scope: Self.scope), "a sibling with the same prefix is not inside")
        #expect(!reach.reaches(folder: box.root.appending(path: "Elsewhere").path, scope: Self.scope))
        #expect(!reach.reaches(folder: served.path, scope: "\(Sandbox.accountB)/org-a"), "another account's identity isn't served")
    }

    @Test func pinnedFolderReaches() throws {
        let box = try Sandbox()
        try box.remoteControlState(box.work, [Self.identity: ("on", ["/served"])])
        try box.write(#"{"preferences":{"remoteControlPinnedFolders":["/pinned/repo"]}}"#, to: box.desktopConfig(box.work))

        let reach = RemoteControlReach.read(dataDir: box.work)

        #expect(reach.pinned == ["/pinned/repo"])
        #expect(reach.reaches(folder: "/pinned/repo/src", scope: Self.scope))
    }

    @Test func serveOffReachesNothing() throws {
        let box = try Sandbox()
        try box.remoteControlState(box.work, [Self.identity: ("off", ["/served"])])
        try box.write(#"{"preferences":{"remoteControlPinnedFolders":["/pinned/repo"]}}"#, to: box.desktopConfig(box.work))

        let reach = RemoteControlReach.read(dataDir: box.work)

        #expect(!reach.reaches(folder: "/served", scope: Self.scope))
        #expect(!reach.reaches(folder: "/pinned/repo", scope: Self.scope), "a pinned folder needs a serving identity too")
    }

    @Test func missingFileReachesNothing() throws {
        let box = try Sandbox()
        try box.write(#"{"preferences":{"remoteControlPinnedFolders":["/pinned/repo"]}}"#, to: box.desktopConfig(box.work))

        let reach = RemoteControlReach.read(dataDir: box.work)

        #expect(!reach.unreadable)
        #expect(reach.identities.isEmpty)
        #expect(!reach.reaches(folder: "/pinned/repo", scope: Self.scope))
    }

    @Test func unknownVersionCountsAsReachable() throws {
        let box = try Sandbox()
        try box.remoteControlState(box.work, [Self.identity: ("off", [])], version: 2)
        #expect(RemoteControlReach.read(dataDir: box.work).unreadable)
        #expect(RemoteControlReach.read(dataDir: box.work).reaches(folder: "/anything", scope: Self.scope))

        try box.write("{ damaged", to: box.work.appending(path: RemoteControlReach.stateName))
        #expect(RemoteControlReach.read(dataDir: box.work).reaches(folder: "/anything", scope: Self.scope))
    }

    @Test func scopeMapsSlashToColon() {
        #expect(RemoteControlReach.matches("acct:org", scope: "acct/org"))
        #expect(!RemoteControlReach.matches("acct:other", scope: "acct/org"))
        #expect(!RemoteControlReach.matches("acct/org", scope: "acct/org"), "Claude's key uses a colon")
        let reach = RemoteControlReach(identities: ["acct:org": .init(serving: true, folders: ["/repo"])])
        #expect(reach.reaches(folder: "/repo", scope: "acct/org"))
        #expect(!reach.reaches(folder: "/repo", scope: "acct/other"))
    }
}
