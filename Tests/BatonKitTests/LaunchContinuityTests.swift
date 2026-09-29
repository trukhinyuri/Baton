import Foundation
import Testing

@testable import BatonKit

@Suite("Cold-launch continuity")
struct LaunchContinuityTests {
    private func manager(_ box: Sandbox) throws -> ProfileManager {
        let manager = ProfileManager(paths: box.paths)
        try manager.registry.save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        return manager
    }

    @Test func coldLaunchLoadsNewAndUpdatedCardsWithoutBackgroundManager() throws {
        let box = try Sandbox()
        let manager = try manager(box)
        let source = try box.pair(box.main, account: Sandbox.accountA)
        let target = try box.pair(box.work, account: Sandbox.accountB)
        let sourceCard = source.appending(path: "local_task.json")
        try box.write(
            #"{"title":"First stopping point"}"#, to: sourceCard,
            modified: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try manager.prepareSessionsForLaunch()
        #expect(box.read(target.appending(path: "local_task.json")) == box.read(sourceCard))

        try box.write(
            #"{"title":"Verified result; next step ready"}"#, to: sourceCard,
            modified: Date(timeIntervalSince1970: 1_700_000_100))
        try box.write(#"{"title":"New task since last launch"}"#, to: source.appending(path: "local_new.json"))
        _ = try manager.prepareSessionsForLaunch()
        #expect(box.read(target.appending(path: "local_task.json")) == box.read(sourceCard))
        #expect(box.exists(target.appending(path: "local_new.json")))
    }

    @Test func launchNeverCopiesCloudWorkersOrDeletesExistingWork() throws {
        let box = try Sandbox()
        let manager = try manager(box)
        let source = try box.pair(box.main, account: Sandbox.accountA)
        let target = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"title":"Native worker","projectThreadChild":true}"#,
            to: source.appending(path: "local_native.json"))
        try box.write("", to: source.appending(path: "deleted_old"))
        try box.write(#"{"title":"Existing local work"}"#, to: target.appending(path: "local_old.json"))
        let report = try manager.prepareSessionsForLaunch()
        #expect(!box.exists(target.appending(path: "local_native.json")))
        #expect(box.exists(target.appending(path: "local_old.json")))
        #expect(report.cardsRemoved == 0)
        #expect(report.tombstonesWritten == 0)
    }

    @Test func corruptOwnershipStateStopsPreparation() throws {
        let box = try Sandbox()
        let manager = try manager(box)
        let source = try box.pair(box.main, account: Sandbox.accountA)
        let target = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"Do not guess ownership"}"#, to: source.appending(path: "local_new.json"))
        try box.write("broken", to: box.paths.stateDir.appending(path: "code-native-session-scopes.json"))
        #expect(throws: (any Error).self) { try manager.prepareSessionsForLaunch() }
        #expect(!box.exists(target.appending(path: "local_new.json")))
    }
}
