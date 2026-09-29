import Foundation
import Testing

@testable import BatonKit

@Suite("Read-only session diagnostics")
struct DiagnosticsTests {
    @Test func reportsMissingFoldersAndMixedAccountWorkersWithoutMutatingCards() throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#123456")])
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountB)\"}", to: box.work.appending(path: "config.json"))
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let worker = #"{"remoteControlSpawn":{"projectThreadChild":true},"cwd":"/missing-folder-diagnostic"}"#
        try box.write(worker, to: a.appending(path: "local_worker.json"))
        try box.write(worker, to: b.appending(path: "local_worker.json"))
        try box.write(#"{"title":"portable"}"#, to: b.appending(path: "local_ordinary.json"))
        let reports = try Diagnostics.inspect(paths: box.paths)
        #expect(reports.count == 2)
        #expect(reports[1].localCode == 1)
        #expect(reports[1].accountBoundWorkers == 1)
        #expect(reports[1].ambiguousWorkers == 1)
        #expect(reports[1].missingFolders == ["/missing-folder-diagnostic"])
        #expect(box.read(b.appending(path: "local_worker.json")) == worker)
    }

    @Test func retainsRememberedOwnershipAndDoesNotTreatSSHPathsAsLocal() throws {
        let box = try Sandbox()
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.write(#"{"cwd":"/remote-only-folder","sshRemoteProcessId":17}"#, to: a.appending(path: "local_ssh.json"))
        try box.write(#"{"title":"marker no longer present"}"#, to: a.appending(path: "local_worker.json"))
        try SessionSync.NativeScopeState(scopes: ["local_worker.json": [Sandbox.accountA + "/org-1", Sandbox.accountB + "/org-1"]])
            .save(to: box.paths.stateDir.appending(path: "code-native-session-scopes.json"))
        let report = try Diagnostics.inspect(paths: box.paths)[0]
        #expect(report.missingFolders.isEmpty)
        #expect(report.ambiguousWorkers == 1)
        #expect(report.accountBoundWorkers == 1)
        #expect(report.localCode == 1)
    }

    @Test func nativeMarkerInLaterProfileClassifiesAllCopies() throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#123456")])
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountB)\"}", to: box.work.appending(path: "config.json"))
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"old copy"}"#, to: a.appending(path: "local_worker.json"))
        try box.write(#"{"remoteControlSpawn":{}}"#, to: b.appending(path: "local_worker.json"))
        let reports = try Diagnostics.inspect(paths: box.paths)
        #expect(reports.allSatisfy { $0.localCode == 0 && $0.accountBoundWorkers == 1 && $0.ambiguousWorkers == 1 })
    }

    @Test func distinguishesVisibleCoworkCardsFromAvailableLocalHistory() throws {
        let box = try Sandbox()
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: nil, color: "#123456")])
        let fm = FileManager.default
        var folders: [URL] = []
        for (directory, account) in [(box.main, Sandbox.accountA), (box.work, Sandbox.accountB)] {
            try box.write("{\"lastKnownAccountUuid\":\"\(account)\"}", to: directory.appending(path: "config.json"))
            let folder = directory.appending(path: "local-agent-mode-sessions/\(account)/org-1")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
        }
        let originalHistory = folders[0].appending(path: "local_shared")
        try fm.createDirectory(at: originalHistory, withIntermediateDirectories: true)
        try box.write("original history must remain untouched", to: originalHistory.appending(path: "history.txt"))
        let card = "{\"cwd\":\"\(originalHistory.path)\"}"
        for folder in folders { try box.write(card, to: folder.appending(path: "local_shared.json")) }
        try box.write("{}", to: folders[1].appending(path: "local_own.json"))
        try fm.createDirectory(at: folders[1].appending(path: "local_own"), withIntermediateDirectories: true)
        // A regular file with the expected name is not a usable session directory.
        try box.write("{}", to: folders[1].appending(path: "local_not_directory.json"))
        try box.write("not a directory", to: folders[1].appending(path: "local_not_directory"))

        let reports = try Diagnostics.inspect(paths: box.paths)
        let main = try #require(reports.first { $0.id == "main" })
        let work = try #require(reports.first { $0.id == "work" })
        #expect(main.localCowork == 1 && main.unavailableCoworkHistory == 0)
        #expect(work.localCowork == 3 && work.unavailableCoworkHistory == 2)
        #expect(work.issues.contains { $0.contains("A visible card does not prove") && $0.contains("profiles: MAIN") })
        #expect(work.missingFolders.isEmpty, "an accessible cwd elsewhere does not prove local history is present")
        #expect(box.read(folders[1].appending(path: "local_shared.json")) == card)
        #expect(box.read(originalHistory.appending(path: "history.txt")) == "original history must remain untouched")
        #expect(!box.exists(folders[1].appending(path: "local_shared")), "diagnostics do not fabricate missing history")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(work)) as? [String: Any])
        #expect(json["localCowork"] as? Int == 3)
        #expect(json["unavailableCoworkHistory"] as? Int == 2)
    }

    @Test func nativeCoworkWorkersAreNotReportedAsLegacyHistoryCopies() throws {
        let box = try Sandbox()
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        let pair = box.main.appending(path: "local-agent-mode-sessions/\(Sandbox.accountA)/org-1")
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        try box.write(#"{"remoteControlSpawn":{"projectThreadChild":true}}"#, to: pair.appending(path: "local_worker.json"))
        let report = try Diagnostics.inspect(paths: box.paths)[0]
        #expect(report.accountBoundWorkers == 1)
        #expect(report.localCowork == 0 && report.unavailableCoworkHistory == 0)
    }

    @Test(arguments: [
        ("local_12345678-1111-2222-3333-444444444444", "directory", true),
        ("local_12345678-1111-2222-3333-444444444444", "file", false),
        ("local_12345678-1111-2222-3333-444444444444", "symlink", false),
        ("local_12345678-not-a-uuid", "directory", false),
    ])
    func recognizesOnlyRealCompactCoworkHistoryFolders(id: String, kind: String, available: Bool) throws {
        let box = try Sandbox()
        let fm = FileManager.default
        try box.write("{\"lastKnownAccountUuid\":\"\(Sandbox.accountA)\"}", to: box.main.appending(path: "config.json"))
        let pair = box.main.appending(path: "local-agent-mode-sessions/\(Sandbox.accountA)/org-1")
        try fm.createDirectory(at: pair, withIntermediateDirectories: true)
        try box.write("{}", to: pair.appending(path: "\(id).json"))
        let compact = pair.appending(path: "12345678")
        switch kind {
        case "directory": try fm.createDirectory(at: compact, withIntermediateDirectories: true)
        case "file": try box.write("occupied", to: compact)
        default:
            let target = box.root.appending(path: "external-history")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: compact, withDestinationURL: target)
        }
        let report = try Diagnostics.inspect(paths: box.paths)[0]
        #expect(report.localCowork == 1)
        #expect(report.unavailableCoworkHistory == (available ? 0 : 1))
        #expect(!box.exists(pair.appending(path: id)), "read-only diagnostics never fabricate the long runtime path")
    }

}
